#!/usr/bin/env python3
"""Measure actual Mio session storage with synthetic histories; no iOS performance claim."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "Mio/Models/MioSessionModels.swift",
    "Mio/Models/TranscriptionModels.swift",
    "Mio/Services/MioProtectedFileWriter.swift",
    "Mio/Services/SessionRepository.swift",
]
MODE_SOURCE = "Mio/Models/MioAnalysisModels.swift"
FIXTURE = "scripts/SessionStoreMeasurement.swift"


def command_output(command: list[str], *, cwd: Path = ROOT) -> str:
    result = subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"Command failed with exit {result.returncode}: {result.stdout.strip()}")
    return result.stdout.strip()


def write_report(path: Path, report: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".mio-measurement-", delete=False) as output:
            temporary = output.name
            output.write(report + "\n")
        os.replace(temporary, path)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Optional absolute path for the JSON report; JSON is always printed.")
    parser.add_argument("--samples", type=int, choices=[3, 5, 7, 9], default=5,
                        help="Bounded odd sample count for codecs, loads and isolated writes (default: 5). Patches always use 3 samples.")
    args = parser.parse_args()
    if args.output and not args.output.is_absolute():
        parser.error("--output requires an absolute path")
    if sys.platform not in {"linux", "darwin"}:
        print("UNAVAILABLE: this measurement supports Linux or macOS hosts; no measurement ran.", file=sys.stderr)
        return 2
    swiftc = shutil.which(os.environ.get("SWIFT_EXECUTABLE", "swiftc"))
    if not swiftc:
        print("UNAVAILABLE: Swift compiler missing; set SWIFT_EXECUTABLE. No measurement ran.", file=sys.stderr)
        return 2
    source_hashes: dict[str, str] = {}
    paths = [*SOURCES, MODE_SOURCE, FIXTURE]
    source_bytes = {path: (ROOT / path).read_bytes() for path in paths}
    for path, data in source_bytes.items():
        source_hashes[path] = hashlib.sha256(data).hexdigest()
    mode_text = source_bytes[MODE_SOURCE].decode("utf-8")
    # Keep the actual production enum verbatim. Fail if its declaration gains
    # nested behavior rather than quietly replacing it with a benchmark stub.
    mode = re.search(r"enum MioCaptureMode:\s*String,\s*Codable,\s*Sendable\s*\{[^{}]*\}", mode_text)
    if not mode:
        raise RuntimeError("Production MioCaptureMode extraction needs review; no substitute was compiled.")
    swift_version = command_output([swiftc, "--version"])
    try:
        head = command_output(["git", "rev-parse", "HEAD"])
    except (RuntimeError, OSError):
        head = None
    cases: list[dict] = []
    with tempfile.TemporaryDirectory(prefix="mio-session-measurement-") as temporary:
        build = Path(temporary)
        compilation_sources: list[str] = []
        for path in [*SOURCES, FIXTURE]:
            copied = build / Path(path).name
            copied.write_bytes(source_bytes[path])
            compilation_sources.append(str(copied))
        capture_mode = build / "ProductionCaptureMode.swift"
        capture_mode.write_text(mode.group(0) + "\n", encoding="utf-8")
        compilation_sources.append(str(capture_mode))
        executable = build / "measure-session-store"
        command_output([swiftc, "-swift-version", "5", "-O", "-parse-as-library",
                        "-module-cache-path", str(build / "module-cache"),
                        "-module-name", "MioStoreMeasurement", *compilation_sources, "-o", str(executable)])
        for count in [50, 500, 2_000]:
            print(f"Measuring {count} ended sessions / {count * 20} synthetic segments …", file=sys.stderr, flush=True)
            # Independent processes keep each history's RSS high-water mark from
            # inheriting allocations from the preceding history or compiler.
            output = command_output([str(executable), str(count), str(args.samples), str(build / f"history-{count}")])
            cases.append(json.loads(output))
    if build.exists():
        raise RuntimeError("Temporary synthetic files were not removed; report withheld.")
    report = {
        "schemaVersion": 1,
        "measuredAtUTC": datetime.now(timezone.utc).isoformat(),
        "platform": {"system": platform.system(), "release": platform.release(), "machine": platform.machine(),
                     "pythonVersion": platform.python_version(), "swiftVersion": swift_version},
        "provenance": {"headCommit": head, "sourceSHA256": source_hashes,
                       "note": "Workspace source snapshot; HEAD alone may not identify uncommitted measured code.",
                       "captureMode": "Verbatim production MioCaptureMode enum; all other production sources compiled unchanged."},
        "method": {
            "build": "Swift 5 language mode, -O, actual SessionRepository/MioSession/MioProtectedFileWriter",
            "clock": "ContinuousClock monotonic milliseconds",
            "timingSamples": args.samples,
            "patchSamples": 3,
            "percentile": "Nearest-rank p95; with these small sample counts p95 is the maximum observation.",
            "codec": "Independent compact JSONEncoder/JSONDecoder, ISO-8601; excludes validation, actor and file IO.",
            "protectedAtomicWrite": "Production writer with already encoded bytes; includes directory/privacy attributes and atomic replacement.",
            "freshRepositoryLoad": "New repository actor each sample; includes file stamp/read, decode and validation. OS page cache is not flushed.",
            "cachedRepositoryLoad": "Previously loaded actor; includes scheduling and fingerprint validation, with repository cache retained.",
            "metadataPatchWithAtomicWrite": "Real actor patch; includes cache/fingerprint, mutation, full validation, full encoding, protected atomic write and final fingerprint. It is not encoder-only or write-only timing.",
            "memory": "Isolated process per history. Peak RSS uses getrusage (Linux KiB normalized to bytes; macOS bytes). Current RSS uses Linux /proc/self/status immediately before getrusage and is null on macOS. These are sequential kernel observations, not one atomic snapshot. Fixture, encoded bytes, live actor cache and verification copies contribute to process RSS; it is not the app's steady-state memory.",
            "seed": "Single direct protected seed write; no quadratic upsert seeding. All evidence checks are outside timing intervals.",
            "syntheticOnly": True,
            "rawAudioCreated": False,
            "temporaryDataCleaned": True,
        },
        "limitations": [
            "Linux/macOS host results do not prove iPhone performance, battery usage or Apple's iOS Data Protection.",
            "Repeated operations use a warm OS/file-system cache; fresh repository does not mean cold disk.",
            "Atomic Foundation replacement is measured without an added fsync; this is not a durability or power-loss test.",
            "Small bounded samples describe this run only; no improvement or database migration is inferred.",
        ],
        "histories": cases,
    }
    encoded = json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False)
    if args.output:
        write_report(args.output, encoded)
    print(encoded)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"Session-store measurement failed: {error}", file=sys.stderr)
        raise SystemExit(1)
