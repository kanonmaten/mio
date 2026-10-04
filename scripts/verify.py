#!/usr/bin/env python3
"""One directory-independent Linux entry point; no deployment or real model requests."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def provenance() -> dict:
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT))
    files = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT)
    digest = hashlib.sha256()
    code_digest = hashlib.sha256()
    for name in sorted(set(files.split(b"\0")) - {b""}):
        path = ROOT / os.fsdecode(name)
        digest.update(name + b"\0")
        if path.is_symlink():
            content = b"symlink\0" + os.fsencode(os.readlink(path))
        elif path.is_file():
            content = path.read_bytes()
        else:
            content = b"deleted"
        digest.update(content)
        digest.update(b"\0")
        if path.suffix.lower() != ".md":
            code_digest.update(name + b"\0" + content + b"\0")
    return {"baseCommit": commit, "dirtyWorktree": dirty, "worktreeSHA256": digest.hexdigest(),
            "codeConfigurationSHA256": code_digest.hexdigest()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-swift", action="store_true", help="Run other gates; report a PARTIAL result with Swift SKIPPED.")
    parser.add_argument("--logs-dir", type=Path, help="Output directory; default: a new /tmp/mio-verify-* directory.")
    parser.add_argument("--measure-session-store", action="store_true", help="Also run the synthetic long-history storage benchmark.")
    args = parser.parse_args()
    if sys.platform != "linux":
        print("UNAVAILABLE: this entry point requires Linux. Run native XCTest/Xcode and verify_concurrency.py --native on macOS.")
        return 2
    logs = (args.logs_dir or Path(tempfile.mkdtemp(prefix="mio-verify-"))).resolve()
    logs.mkdir(parents=True, exist_ok=True)
    required = ["node", "npm", "uv", "git"]
    if not args.skip_swift or args.measure_session_store:
        required.append(os.environ.get("SWIFT_EXECUTABLE", "swiftc"))
    missing = [name for name in required if not shutil.which(name)]
    if missing:
        print("UNAVAILABLE: required executables missing: " + ", ".join(missing))
        return 2
    node_version = subprocess.check_output(["node", "--version"], text=True).strip()
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", node_version)
    if not match or not ((26, 10, 0) <= tuple(map(int, match.groups())) < (27, 0, 0)):
        print(f"UNAVAILABLE: Node {node_version}; supported and tested minimum is 26.10.0, range >=26.10.0 <27.")
        return 2
    receipt = {"startedAt": datetime.now(timezone.utc).isoformat(), **provenance(),
               "node": node_version, "uv": subprocess.check_output(["uv", "--version"], text=True).strip(),
               "nativeIOS": "NOT RUN", "realProvider": "NOT RUN", "gates": []}
    environment = dict(os.environ)
    # A fresh lockfile environment avoids stale interpreter symlinks and excludes GPU extras.
    environment["UV_PROJECT_ENVIRONMENT"] = str(logs / "python-venv")
    steps = [
        ("python-lock", ["uv", "--directory", str(ROOT / "transcription-server"), "sync", "--locked", "--extra", "test", "--python", "3.12"]),
        ("structure", ["uv", "--directory", str(ROOT / "transcription-server"), "run", "--no-sync", "--python", "3.12", "python", str(ROOT / "scripts/verify_project.py")]),
        ("verification-tools", ["uv", "--directory", str(ROOT / "transcription-server"), "run", "--no-sync", "--python", "3.12", "python", "-m", "unittest", "discover", "-s", str(ROOT / "scripts/tests")]),
        ("node-dependencies", ["npm", "ci", "--prefix", str(ROOT / "server"), "--ignore-scripts"]),
        ("node-tests", ["npm", "--prefix", str(ROOT / "server"), "test"]),
        ("transcription-fake", ["uv", "--directory", str(ROOT / "transcription-server"), "run", "--no-sync", "python", "-m", "pytest", "tests"]),
        ("worker-runtime", ["npm", "--prefix", str(ROOT / "server"), "run", "worker:test"]),
    ]
    if not args.skip_swift:
        steps.extend([
            ("swift-core", [sys.executable, str(ROOT / "scripts/verify_swift_core.py")]),
            ("capture-recovery", [sys.executable, str(ROOT / "scripts/verify_capture_recovery.py")]),
            ("concurrency-portable", [sys.executable, str(ROOT / "scripts/verify_concurrency.py"), "--log", str(logs / "concurrency-diagnostics.log")]),
        ])
    else:
        receipt["gates"].append({"gate": "Swift core/capture/concurrency", "result": "SKIPPED"})
    if args.measure_session_store:
        steps.append(("session-store", [sys.executable, str(ROOT / "scripts/measure_session_store.py"), "--output", str(logs / "session-store.json")]))
    print(f"Logs: {logs}\nNode {node_version}; base {receipt['baseCommit']}; dirty={receipt['dirtyWorktree']}\nSynthetic/local checks only. Xcode, installation and device/provider acceptance remain separate.", flush=True)
    failed = False
    for name, command in steps:
        log = logs / f"{name}.log"
        started = time.monotonic()
        print(f"RUN {name}", flush=True)
        try:
            with log.open("w") as output:
                result = subprocess.run(command, cwd=ROOT, env=environment, stdout=output, stderr=subprocess.STDOUT, timeout=600)
            code = result.returncode
        except (OSError, subprocess.TimeoutExpired) as error:
            with log.open("a") as output:
                output.write(f"\nVerifier process failed: {type(error).__name__}\n")
            code = 1
        receipt["gates"].append({"gate": name, "result": "PASS" if code == 0 else "FAIL", "exitCode": code,
                                 "seconds": round(time.monotonic() - started, 3), "log": log.name})
        print(f"{'PASS' if code == 0 else 'FAIL'} {name}: {log}", flush=True)
        if code:
            failed = True
            break
    receipt["finishedAt"] = datetime.now(timezone.utc).isoformat()
    receipt["result"] = "FAIL" if failed else "PARTIAL" if args.skip_swift else "PASS (Linux synthetic gates)"
    (logs / "verification.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"{receipt['result']}. Receipt: {logs / 'verification.json'}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
