#!/usr/bin/env python3
"""Compile and run Mio's portable Swift core with XCTest, without an iOS SDK.

Only platform boundaries are substituted: Keychain-backed connection loading and
Apple's URLSession.bytes API. The latter always fails, so this harness cannot send
network/model traffic. Models, repositories, assistant VM and coordinator are real
workspace sources. This is not an Xcode, UI, Keychain or Apple transport test.
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "Mio/Models/MioSessionModels.swift",
    "Mio/Models/TranscriptionModels.swift",
    "Mio/Models/MioContentModels.swift",
    "Mio/Models/MioAssistantModels.swift",
    "Mio/Models/MioAnalysisModels.swift",
    "Mio/Models/MioEverydayContext.swift",
    "Mio/Models/MioDiagnosticsModels.swift",
    "Mio/Services/MioAssistantRepository.swift",
    "Mio/Services/MioContentRepository.swift",
    "Mio/Services/MioDiagnosticsRepository.swift",
    "Mio/Services/SessionRepository.swift",
    "Mio/Services/MioWakeWordDetector.swift",
    "Mio/MioMaintenanceState.swift",
    "Mio/MioAssistantViewModel.swift",
    "Mio/MioAnalysisCoordinator.swift",
]
TESTS = [
    "MioTests/MioContextTests.swift",
    "MioTests/MioDiagnosticsTests.swift",
    "MioTests/MioCoordinatorContextTests.swift",
    "MioTests/MioAnalysisTests.swift",
    "MioTests/MioAssistantTests.swift",
    "MioTests/MioContentRepositoryTests.swift",
]
UI_ONLY_TEST = "testCurrentSessionSnapshotWinsOverEarlierPersistedCopy"


def function_source(source: str, name: str) -> tuple[str, int, int]:
    """Find a named function's balanced body in these controlled Swift sources."""
    match = re.search(r"(?:static )?func " + re.escape(name) + r"\(", source)
    if not match:
        raise ValueError(f"Expected Swift function is missing: {name}")
    opening = source.index("{", match.end())
    depth = 1
    index = opening + 1
    while depth:
        depth += (source[index] == "{") - (source[index] == "}")
        index += 1
    return source[match.start():index], match.start(), index


def portable_cloud_source() -> str:
    source = (ROOT / "Mio/Services/MioCloudService.swift").read_text()
    settings_start = source.index("@MainActor\nenum MioCloudSettings")
    service_start = source.index("enum MioCloudService", settings_start)
    settings = source[settings_start:service_start]
    # Preserve the real URL validation used by default coordinator closures.
    endpoint, _, _ = function_source(settings, "endpoint")
    platform_settings = f'''@MainActor enum MioCloudSettings {{
    static let enabledKey = "mio.cloud.enabled"
    static let serverKey = "mio.cloud.server"
    static var serverAddress: String {{ UserDefaults.standard.string(forKey: serverKey) ?? "" }}
    {endpoint}
    static func connection() throws -> MioCloudConnection {{ throw MioCloudError.disabled }}
}}
'''
    source = source[:settings_start] + platform_settings + source[service_start:]
    source = source.replace("import Security", "import FoundationNetworking")
    # This Apple-only configuration property is get-only in corelibs Foundation.
    source = source.replace("        configuration.waitsForConnectivity = false\n", "")
    source += '''
// A platform boundary, never a model/repository/coordinator substitute.
extension URLSession {
    func bytes(for request: URLRequest, delegate: URLSessionTaskDelegate?) async throws
        -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
        throw MioCloudError.network
    }
}
'''
    return source


def main() -> int:
    requested = os.environ.get("SWIFT_EXECUTABLE", "swiftc")
    swiftc = shutil.which(requested)
    if not swiftc:
        print("Swift compiler unavailable; set SWIFT_EXECUTABLE to a compatible swiftc. No tests ran.", file=sys.stderr)
        return 2
    if sys.platform != "linux":
        print("This harness uses Linux FoundationNetworking; run native XCTest through Xcode on Apple hosts.", file=sys.stderr)
        return 2
    subprocess.run([swiftc, "--version"], check=True)
    with tempfile.TemporaryDirectory(prefix="mio-swift-core-") as temporary:
        build = Path(temporary)
        cloud = build / "MioCloudPortable.swift"
        cloud.write_text(portable_cloud_source())
        copied_tests: list[str] = []
        registrations: list[str] = []
        for relative in TESTS:
            source = (ROOT / relative).read_text()
            if relative.endswith("MioAnalysisTests.swift"):
                _, start, end = function_source(source, UI_ONLY_TEST)
                # Remove its @MainActor annotation along with its UIKit-dependent body.
                annotation = source.rfind("    @MainActor", 0, start)
                source = source[:annotation] + source[end:]
            class_match = re.search(r"final class (\w+): XCTestCase", source)
            if not class_match:
                raise ValueError(f"XCTest class missing in {relative}")
            class_name = class_match.group(1)
            entries: list[str] = []
            for match in re.finditer(r"func (test\w+)\(\)([^\{]*)\{", source):
                name, signature = match.groups()
                function = f"{class_name}.{name}"
                if "async" in signature:
                    function = f"asyncTest({function})"
                entries.append(f'("{name}", {function})')
            registrations.append("testCase([\n" + ",\n".join(entries) + "\n])")
            test_path = build / Path(relative).name
            test_path.write_text(source)
            copied_tests.append(str(test_path))
        runner = build / "main.swift"
        runner.write_text("import XCTest\nXCTMain([\n" + ",\n".join(registrations) + "\n])\n")
        module_cache = str(build / "module-cache")
        library = build / "libMio.so"
        compile_module = [swiftc, "-swift-version", "5", "-module-cache-path", module_cache,
                          "-enable-testing", "-emit-library", "-emit-module", "-module-name", "Mio",
                          "-emit-module-path", str(build / "Mio.swiftmodule"), "-o", str(library)]
        subprocess.run(compile_module + [str(ROOT / path) for path in SOURCES] + [str(cloud)], check=True)
        executable = build / "core-tests"
        subprocess.run([swiftc, "-swift-version", "5", "-module-cache-path", module_cache,
                        "-I", str(build), "-L", str(build), "-lMio"] + copied_tests
                       + [str(runner), "-o", str(executable)], check=True)
        environment = dict(os.environ)
        environment["LD_LIBRARY_PATH"] = str(build) + ":" + environment.get("LD_LIBRARY_PATH", "")
        print(f"Portable core XCTest; excludes UIKit-dependent {UI_ONLY_TEST}.", flush=True)
        subprocess.run([str(executable)], env=environment, check=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (subprocess.CalledProcessError, ValueError, OSError) as error:
        print(f"Portable Swift core verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
