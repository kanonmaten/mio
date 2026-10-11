import Foundation
import MetricKit

/// Keeps MetricKit payloads on the phone. iOS may call these methods on a background
/// queue; payload objects are converted to value types before any actor hop.
final class MioMetricKitSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = MioMetricKitSubscriber(archive: .shared)
    private let archive: MioMetricArchive

    init(archive: MioMetricArchive) {
        self.archive = archive
        super.init()
    }

    @MainActor
    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let reports = payloads.map { Self.report(for: $0) }
        let archive = archive
        MioLog.notice(.storage, "metric payloads received", value: reports.count)
        Task { await archive.add(reports) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.map { Self.report(for: $0) }
        let archive = archive
        MioLog.notice(.storage, "diagnostic payloads received", value: reports.count)
        Task { await archive.add(reports) }
    }

    private static func report(for payload: MXMetricPayload) -> MioMetricReport {
        var parts: [String] = []
        if let memory = payload.memoryMetrics {
            parts.append("Toppminne \(whole(memory.peakMemoryUsage.converted(to: .megabytes).value)) MB")
        }
        if let cpu = payload.cpuMetrics {
            parts.append("CPU \(whole(cpu.cumulativeCPUTime.converted(to: .seconds).value)) s")
        }
        if let disk = payload.diskIOMetrics {
            parts.append("Skrivet \(whole(disk.cumulativeLogicalWrites.converted(to: .megabytes).value)) MB")
        }
        return MioMetricReport(periodStart: payload.timeStampBegin, periodEnd: payload.timeStampEnd, kind: .metrics,
                               summary: parts.isEmpty ? "Inga nyckeltal i rapporten" : parts.joined(separator: " · "),
                               payload: payload.jsonRepresentation())
    }

    private static func report(for payload: MXDiagnosticPayload) -> MioMetricReport {
        let crashes = payload.crashDiagnostics ?? []
        let hangs = payload.hangDiagnostics ?? []
        let cpu = payload.cpuExceptionDiagnostics ?? []
        let disk = payload.diskWriteExceptionDiagnostics ?? []
        let launches = payload.appLaunchDiagnostics ?? []
        var parts: [String] = []
        if !crashes.isEmpty {
            let signals = Set(crashes.compactMap { $0.signal?.intValue }).sorted().map(String.init)
            parts.append("\(crashes.count) krasch" + (signals.isEmpty ? "" : " (signal \(signals.joined(separator: ", ")))"))
        }
        if !hangs.isEmpty {
            let longest = hangs.map { $0.hangDuration.converted(to: .seconds).value }.max() ?? 0
            parts.append("\(hangs.count) häng, längst \(whole(longest)) s")
        }
        if !cpu.isEmpty { parts.append("\(cpu.count) CPU-undantag") }
        if !disk.isEmpty { parts.append("\(disk.count) diskskrivningsundantag") }
        if !launches.isEmpty { parts.append("\(launches.count) långsam start") }
        let kind: MioMetricReport.Kind = !crashes.isEmpty ? .crash : !hangs.isEmpty ? .hang
            : !cpu.isEmpty ? .cpu : !disk.isEmpty ? .disk : !launches.isEmpty ? .launch : .diagnostic
        return MioMetricReport(periodStart: payload.timeStampBegin, periodEnd: payload.timeStampEnd, kind: kind,
                               summary: parts.isEmpty ? "Diagnostikrapport" : parts.joined(separator: " · "),
                               payload: payload.jsonRepresentation())
    }

    private static func whole(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, -1_000_000_000), 1_000_000_000).rounded())
    }
}
