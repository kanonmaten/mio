#!/usr/bin/env python3
"""Dedicated complete-concurrency diagnostic; portable checks do not prove iOS builds."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from verify_swift_core import ROOT, SOURCES, portable_capture_source, portable_cloud_source


def concurrency_warnings(output: str) -> list[str]:
    """Inspect compiler warning blocks, including Swift's following explanatory notes."""
    blocks = re.split(r"(?=^.*?warning:)", output, flags=re.MULTILINE)
    relevant = re.compile(r"Sendable|concurren|actor.isolat|main actor|nonisolated|data race|"
                          r"Swift 6 language mode|sending .* risks", re.IGNORECASE)
    return [block.strip() for block in blocks if "warning:" in block and relevant.search(block)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true", help="Check the actual Mio target with Xcode on macOS.")
    parser.add_argument("--log", type=Path, help="Full diagnostic output (absolute path recommended).")
    args = parser.parse_args()
    log = (args.log or Path(tempfile.mkdtemp(prefix="mio-concurrency-log-")) / "concurrency.log").resolve()
    log.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mio-concurrency-") as temporary:
        build = Path(temporary)
        if args.native:
            if sys.platform != "darwin" or not shutil.which("xcodebuild"):
                print("UNAVAILABLE: native concurrency requires macOS, Xcode and the iOS SDK. No native check ran.")
                return 2
            command = ["xcodebuild", "-project", str(ROOT / "Mio.xcodeproj"), "-scheme", "Mio",
                       "-configuration", "Debug", "-sdk", "iphonesimulator",
                       "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(build),
                       "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
                       "COMPILER_INDEX_STORE_ENABLE=NO", "SWIFT_STRICT_CONCURRENCY=complete",
                       "OTHER_SWIFT_FLAGS=$(inherited) -warn-concurrency", "build"]
        else:
            swiftc = shutil.which(os.environ.get("SWIFT_EXECUTABLE", "swiftc"))
            if sys.platform != "linux" or not swiftc:
                print("UNAVAILABLE: portable concurrency requires Linux and Swift; use --native on macOS.")
                return 2
            cloud = build / "MioCloudPortable.swift"
            cloud.write_text(portable_cloud_source() + portable_capture_source())
            # SIL, not -typecheck: "sending ... risks causing data races" comes from region-based
            # isolation, a SIL pass that -typecheck never runs. The upcoming feature mirrors the
            # Mio target's SWIFT_UPCOMING_FEATURE_INFER_SENDABLE_FROM_CAPTURES.
            command = [swiftc, "-swift-version", "5", "-strict-concurrency=complete", "-warn-concurrency",
                       "-enable-upcoming-feature", "InferSendableFromCaptures",
                       "-module-cache-path", str(build / "module-cache"), "-wmo", "-emit-sil", "-o", os.devnull,
                       "-module-name", "Mio", *[str(ROOT / path) for path in SOURCES], str(cloud)]
        print(f"Checking {'native iOS target' if args.native else 'portable core with substituted native boundaries'}; log: {log}", flush=True)
        process = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log.write_text(process.stdout)
        warnings = concurrency_warnings(process.stdout)
        if process.returncode or warnings:
            print(f"FAIL: compiler exit {process.returncode}; {len(warnings)} concurrency warning blocks. See {log}.")
            return 1
        print("PASS: complete-concurrency diagnostic, no relevant warnings." +
              ("" if args.native else " Native SDK/AVFoundation/UIKit/Keychain boundaries remain unverified."))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
