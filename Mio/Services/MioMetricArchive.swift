import Foundation

/// One MetricKit payload kept on the phone. Apple's JSON contains device, OS, build,
/// timing and call-stack facts, never Mio's text; the summary is built from numbers only.
struct MioMetricReport: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case metrics, crash, hang, cpu, disk, launch, diagnostic

        var title: String {
            switch self {
            case .metrics: "Dygnsmätvärden"
            case .crash: "Krasch"
            case .hang: "Häng"
            case .cpu: "CPU-undantag"
            case .disk: "Diskskrivning"
            case .launch: "Långsam start"
            case .diagnostic: "Diagnostik"
            }
        }
    }

    let id: UUID
    let receivedAt: Date
    let periodStart: Date
    let periodEnd: Date
    let kind: Kind
    let summary: String
    /// Apple's `jsonRepresentation()`, or nil when it exceeded the size cap.
    let payload: String?
    let payloadBytes: Int

    init(id: UUID = UUID(), receivedAt: Date = .now, periodStart: Date, periodEnd: Date, kind: Kind,
         summary: String, payload: Data) {
        self.id = id
        self.receivedAt = receivedAt
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.kind = kind
        self.summary = String(summary.prefix(300))
        payloadBytes = payload.count
        let isJSON = (try? JSONSerialization.jsonObject(with: payload)) != nil
        self.payload = isJSON && payload.count <= MioMetricArchive.maxPayloadBytes
            ? String(decoding: payload, as: UTF8.self) : nil
    }

    /// Duplicate deliveries (for example past payloads after a relaunch) share these facts.
    var deliveryKey: String {
        "\(kind.rawValue)|\(Int(periodStart.timeIntervalSince1970.rounded()))|\(Int(periodEnd.timeIntervalSince1970.rounded()))|\(payloadBytes)"
    }

    var shareText: String {
        payload ?? "{\"kind\":\"\(kind.rawValue)\",\"payloadBytes\":\(payloadBytes),\"note\":\"payload over size cap\"}"
    }
}

enum MioMetricArchiveStatus: String, Codable, Sendable {
    case available, unsupportedSchema, readFailed, writeFailed
}

private struct MioMetricArchiveDocument: Codable {
    static let currentSchemaVersion = 1
    var schemaVersion = currentSchemaVersion
    var reports: [MioMetricReport]
}

/// Bounded on-device MetricKit archive (`Mio/metrickit-v1.json`). An unknown schema is
/// never overwritten; deletion of all data removes it with the diagnostics journal.
actor MioMetricArchive {
    static let shared = MioMetricArchive()
    static let maxReports = 40
    static let maxPayloadBytes = 256 * 1024
    static let maxTotalBytes = 3 * 1024 * 1024
    static let retention: TimeInterval = 30 * 86_400

    private let storageURL: URL
    private let fileManager: FileManager
    private var reportsCache: [MioMetricReport] = []
    private var loaded = false
    private(set) var status: MioMetricArchiveStatus = .available

    init(storageURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.storageURL = storageURL ?? support.appendingPathComponent("Mio/metrickit-v1.json")
    }

    func add(_ incoming: [MioMetricReport], now: Date = .now) {
        load()
        guard status != .unsupportedSchema, status != .readFailed else { return }
        var keys = Set(reportsCache.map(\.deliveryKey))
        var changed = false
        for report in incoming where keys.insert(report.deliveryKey).inserted {
            reportsCache.append(report)
            changed = true
        }
        let before = reportsCache.count
        prune(now: now)
        if changed || before != reportsCache.count { persist() }
    }

    /// Newest first.
    func reports(now: Date = .now) -> [MioMetricReport] {
        load()
        let before = reportsCache.count
        prune(now: now)
        if before != reportsCache.count { persist() }
        return reportsCache.sorted { $0.receivedAt > $1.receivedAt }
    }

    func deleteAll() throws {
        if fileManager.fileExists(atPath: storageURL.path) { try fileManager.removeItem(at: storageURL) }
        reportsCache = []; loaded = true; status = .available
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        reportsCache = []; status = .available
        guard fileManager.fileExists(atPath: storageURL.path) else { return }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: storageURL.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= Self.maxTotalBytes * 2 else {
                status = .readFailed; return
            }
            let data = try Data(contentsOf: storageURL)
            let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard header?["schemaVersion"] as? Int == MioMetricArchiveDocument.currentSchemaVersion else {
                status = .unsupportedSchema; return
            }
            reportsCache = try JSONDecoder().decode(MioMetricArchiveDocument.self, from: data).reports
        } catch { status = .readFailed }
    }

    private func prune(now: Date) {
        var kept = reportsCache
            .filter { $0.receivedAt >= now.addingTimeInterval(-Self.retention) && $0.receivedAt <= now.addingTimeInterval(60) }
            .sorted { $0.receivedAt > $1.receivedAt }
        if kept.count > Self.maxReports { kept = Array(kept.prefix(Self.maxReports)) }
        var total = 0
        kept = kept.filter { report in
            total += report.payload?.utf8.count ?? 0
            return total <= Self.maxTotalBytes
        }
        reportsCache = kept
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(MioMetricArchiveDocument(reports: reportsCache))
            try MioProtectedFileWriter.write(data, to: storageURL, fileManager: fileManager)
            status = .available
        } catch {
            status = .writeFailed
            MioLog.error(.storage, "metric archive write failed")
        }
    }
}
