import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

// This executable contains only synthetic text and timestamps. It compiles with
// the unchanged production models/repository/writer; it never captures audio.
private enum MeasurementError: Error {
    case invalidArguments, changedEvidence, unexpectedWrite, unavailableMemory
}

private struct TimingSummary: Codable {
    let samplesMilliseconds: [Double]
    let medianMilliseconds: Double
    let p95Milliseconds: Double

    init(_ values: [Double]) {
        samplesMilliseconds = values
        let sorted = values.sorted()
        medianMilliseconds = sorted[sorted.count / 2]
        p95Milliseconds = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
    }
}

private struct ProcessMemory: Codable {
    let currentRSSBytes: Int64?
    let peakRSSBytes: Int64
}

private struct HistoryMeasurement: Codable {
    let sessionCount: Int
    let segmentsPerSession: Int
    let segmentDurationSeconds: Int
    let totalSourceDurationSeconds: Int
    let initialEncodedBytes: Int
    let finalStoredBytes: Int
    let encode: TimingSummary
    let decode: TimingSummary
    let protectedAtomicWrite: TimingSummary
    let freshRepositoryLoad: TimingSummary
    let cachedRepositoryLoad: TimingSummary
    let metadataPatchWithAtomicWrite: TimingSummary
    let memoryBeforeFixture: ProcessMemory
    let memoryWithFixture: ProcessMemory
    let memoryAfterCodecs: ProcessMemory
    let memoryWithLoadedRepository: ProcessMemory
    let memoryAfterPatches: ProcessMemory
    let memoryAtCompletion: ProcessMemory
    let immutableEvidencePreserved: Bool
    let privatePOSIXPermissionsVerified: Bool
}

private func memory() throws -> ProcessMemory {
    #if os(Linux)
    let status = try String(contentsOfFile: "/proc/self/status", encoding: .utf8)
    let fields = status.split(separator: "\n").first { $0.hasPrefix("VmRSS:") }?.split(whereSeparator: { $0.isWhitespace })
    guard let fields, fields.count >= 2, let kilobytes = Int64(fields[1]) else { throw MeasurementError.unavailableMemory }
    let currentBytes: Int64? = kilobytes * 1024
    var usage = rusage()
    guard getrusage(Int32(RUSAGE_SELF.rawValue), &usage) == 0 else { throw MeasurementError.unavailableMemory }
    let peakBytes = Int64(usage.ru_maxrss) * 1024
    #else
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw MeasurementError.unavailableMemory }
    let peakBytes = Int64(usage.ru_maxrss)
    let currentBytes: Int64? = nil
    #endif
    return ProcessMemory(currentRSSBytes: currentBytes, peakRSSBytes: peakBytes)
}

private func elapsed(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1_000_000_000_000_000
}

private func fixture(count: Int) -> [MioSession] {
    let base = Date(timeIntervalSince1970: 1_735_689_600)
    let text = "Syntetiskt mätunderlag för Mio. Vi går igenom en påhittad vardag med anteckningar, lektioner och gemensamma planer. Ingen person har spelats in. Texten återkommer enbart för att mäta lagring av en lång historik med svenska bokstäver och bevarade tidsintervall. Alla uppgifter och exempel är konstruerade för mätningen."
    return (0..<count).reversed().map { index in
        let start = base.addingTimeInterval(Double(index) * 600)
        let transcripts = (0..<20).map { segment in
            let audioStart = start.addingTimeInterval(Double(segment) * 20)
            var value = TranscriptSegment(createdAt: audioStart, audioStartedAt: audioStart,
                audioEndedAt: audioStart.addingTimeInterval(20), text: text, containsMio: true)
            value.transcriptionMetadata = .init(model: "synthetic-fixture", revision: "measurement-v1", backend: "synthetic-fixture")
            value.sourceChunkID = UUID()
            value.timingValidity = .hostTime
            return value
        }
        var session = MioSession(startedAt: start, endedAt: start.addingTimeInterval(400), transcripts: transcripts,
            events: [DiagnosticEvent(createdAt: start, kind: .lifecycle, message: "Syntetisk mätsession")],
            title: "Syntetisk session \(index)", manualNote: "Syntetisk anteckning", captureMode: index % 2 == 0 ? .lesson : .everyday)
        session.mutationRevision = 1
        return session
    }
}

private func measure(count: Int, samples: Int, root: URL) async throws -> HistoryMeasurement {
    let beforeFixture = try memory()
    let history = fixture(count: count)
    let withFixture = try memory()
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    // The standalone codec measurements match the repository's compact ISO-8601
    // settings, but exclude actor hops, validation, file reads and file writes.
    let seed = try encoder.encode(history)
    let storage = root.appendingPathComponent("Mio/sessions.json")
    try MioProtectedFileWriter.write(seed, to: storage)
    var encodeTimes: [Double] = []
    var decodeTimes: [Double] = []
    var writeTimes: [Double] = []
    var freshLoadTimes: [Double] = []
    var cachedLoadTimes: [Double] = []
    var patchTimes: [Double] = []
    for _ in 0..<samples {
        let start = ContinuousClock.now
        let data = try encoder.encode(history)
        encodeTimes.append(elapsed(since: start))
        guard data.count == seed.count else { throw MeasurementError.unexpectedWrite }
    }
    for _ in 0..<samples {
        let start = ContinuousClock.now
        let decoded = try decoder.decode([MioSession].self, from: seed)
        decodeTimes.append(elapsed(since: start))
        guard decoded == history else { throw MeasurementError.changedEvidence }
    }
    let afterCodecs = try memory()
    for _ in 0..<samples {
        let start = ContinuousClock.now
        try MioProtectedFileWriter.write(seed, to: storage)
        writeTimes.append(elapsed(since: start))
    }
    for _ in 0..<samples {
        let repository = SessionRepository(storageURL: storage, exportDirectoryURL: root.appendingPathComponent("exports"))
        let start = ContinuousClock.now
        let loaded = try await repository.loadSessions()
        freshLoadTimes.append(elapsed(since: start))
        guard loaded == history else { throw MeasurementError.changedEvidence }
    }
    let repository = SessionRepository(storageURL: storage, exportDirectoryURL: root.appendingPathComponent("exports"))
    let initial = try await repository.loadSessions()
    guard initial == history else { throw MeasurementError.changedEvidence }
    let withRepository = try memory()
    for _ in 0..<samples {
        let start = ContinuousClock.now
        let loaded = try await repository.loadSessions()
        cachedLoadTimes.append(elapsed(since: start))
        guard loaded.count == count else { throw MeasurementError.changedEvidence }
    }
    let target = history[history.count / 2]
    let generation = await repository.operationGeneration()
    let token = try await repository.operationToken(for: target.id, generation: generation)
    // Three bounded actor-owned patches measure the complete cached-load,
    // mutation, validation, encoding, protected atomic write and fingerprint path.
    for patch in 0..<3 {
        let start = ContinuousClock.now
        let updated = try await repository.updateMetadata(id: target.id,
            title: "Syntetisk ändrad rubrik \(patch)", note: "Syntetisk ändrad anteckning \(patch)", token: token)
        patchTimes.append(elapsed(since: start))
        guard updated.transcripts == target.transcripts, updated.endedAt == target.endedAt,
              updated.mutationRevision == 2 + UInt64(patch) else { throw MeasurementError.changedEvidence }
    }
    let afterPatches = try memory()
    let final = try await SessionRepository(storageURL: storage).loadSessions()
    guard final.count == history.count else { throw MeasurementError.changedEvidence }
    for (original, stored) in zip(history, final) {
        var expected = original
        if original.id == target.id {
            expected.title = "Syntetisk ändrad rubrik 2"
            expected.manualNote = "Syntetisk ändrad anteckning 2"
            expected.mutationRevision = 4
        }
        guard stored == expected else { throw MeasurementError.changedEvidence }
    }
    let storedBytes = try Data(contentsOf: storage).count
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: storage.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: storage.deletingLastPathComponent().path)
    guard (fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
          (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw MeasurementError.unexpectedWrite }
    return HistoryMeasurement(sessionCount: count, segmentsPerSession: 20, segmentDurationSeconds: 20,
        totalSourceDurationSeconds: count * 400, initialEncodedBytes: seed.count, finalStoredBytes: storedBytes,
        encode: .init(encodeTimes), decode: .init(decodeTimes), protectedAtomicWrite: .init(writeTimes),
        freshRepositoryLoad: .init(freshLoadTimes), cachedRepositoryLoad: .init(cachedLoadTimes),
        metadataPatchWithAtomicWrite: .init(patchTimes), memoryBeforeFixture: beforeFixture,
        memoryWithFixture: withFixture, memoryAfterCodecs: afterCodecs, memoryWithLoadedRepository: withRepository,
        memoryAfterPatches: afterPatches, memoryAtCompletion: try memory(), immutableEvidencePreserved: true,
        privatePOSIXPermissionsVerified: true)
}

@main private enum SessionStoreMeasurement {
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 4, let count = Int(arguments[1]), [50, 500, 2_000].contains(count),
                  let samples = Int(arguments[2]), (3...9).contains(samples), samples % 2 == 1,
                  arguments[3].hasPrefix("/") else { throw MeasurementError.invalidArguments }
            let result = try await measure(count: count, samples: samples, root: URL(fileURLWithPath: arguments[3], isDirectory: true))
            let data = try JSONEncoder().encode(result)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardError.write(Data("Session-store measurement failed: \(type(of: error)).\n".utf8))
            exit(1)
        }
    }
}
