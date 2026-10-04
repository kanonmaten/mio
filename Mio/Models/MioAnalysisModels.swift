import Foundation

enum MioCaptureMode: String, Codable, Sendable {
    case everyday, lesson
}

struct MioAnalysisFragment: Codable, Hashable, Sendable {
    let id: String
    let text: String
    let occurredAt: String
    /// Captured with the approved text; excluded from the established server wire.
    var sourceRevision: Int? = nil

    private enum CodingKeys: String, CodingKey { case id, text, occurredAt }

    var segmentID: UUID? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 36, !parts[1].isEmpty,
              parts[1].utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UUID(uuidString: String(parts[0]))
    }

    static func make(from segment: TranscriptSegment) -> [Self] {
        var parts: [String] = []
        var part = ""
        var bytes = 0
        for character in segment.displayText {
            let count = String(character).utf8.count
            if bytes + count > 3_500, !part.isEmpty {
                parts.append(part); part = ""; bytes = 0
            }
            part.append(character); bytes += count
        }
        if !part.isEmpty { parts.append(part) }
        return parts.enumerated().compactMap { index, text in
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Self(id: "\(segment.id.uuidString):\(index)", text: text,
                        occurredAt: ISO8601DateFormatter().string(from: segment.audioStartedAt),
                        sourceRevision: MioSourceRevision.currentRevision(of: segment))
        }
    }
}

struct MioAnalysisDecisionHint: Codable, Hashable, Sendable {
    let id: UUID
    let kind: MioContentKind
    let sourceIDs: [String]
    let isOpen: Bool
}

struct MioAnalysisRequest: Codable, Sendable {
    let mode: MioCaptureMode
    let timeZone: String
    let fragments: [MioAnalysisFragment]
    var contextFragments: [MioAnalysisFragment] = []
    var priorDecisions: [MioAnalysisDecisionHint] = []
    var contextLimited: Bool = false
    var usesContextContract: Bool = false
    var queueSize: Int? = nil

    var allFragments: [MioAnalysisFragment] { contextFragments + fragments }

    var sourceRevisions: [MioSourceRevision]? {
        var revisions: [UUID: Int] = [:]
        for fragment in fragments {
            guard let segmentID = fragment.segmentID, let revision = fragment.sourceRevision, revision >= 0,
                  revisions[segmentID] == nil || revisions[segmentID] == revision else { return nil }
            revisions[segmentID] = revision
        }
        return revisions.sorted { $0.key.uuidString < $1.key.uuidString }
            .map { MioSourceRevision(segmentID: $0.key, correctionRevision: $0.value) }
    }

    private enum CodingKeys: String, CodingKey {
        case mode, timeZone, fragments, contextFragments, priorDecisions, contextLimited
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mode, forKey: .mode)
        try values.encode(timeZone, forKey: .timeZone)
        try values.encode(fragments, forKey: .fragments)
        if usesContextContract {
            try values.encode(contextFragments, forKey: .contextFragments)
            try values.encode(priorDecisions, forKey: .priorDecisions)
            try values.encode(contextLimited, forKey: .contextLimited)
        }
    }

    init(mode: MioCaptureMode, timeZone: String, fragments: [MioAnalysisFragment],
         contextFragments: [MioAnalysisFragment] = [], priorDecisions: [MioAnalysisDecisionHint] = [],
         contextLimited: Bool = false, usesContextContract: Bool = false, queueSize: Int? = nil) {
        self.mode = mode; self.timeZone = timeZone; self.fragments = fragments
        self.contextFragments = contextFragments; self.priorDecisions = priorDecisions
        self.contextLimited = contextLimited; self.usesContextContract = usesContextContract; self.queueSize = queueSize
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decode(MioCaptureMode.self, forKey: .mode)
        timeZone = try values.decode(String.self, forKey: .timeZone)
        fragments = try values.decode([MioAnalysisFragment].self, forKey: .fragments)
        usesContextContract = values.contains(.contextFragments)
        contextFragments = try values.decodeIfPresent([MioAnalysisFragment].self, forKey: .contextFragments) ?? []
        priorDecisions = try values.decodeIfPresent([MioAnalysisDecisionHint].self, forKey: .priorDecisions) ?? []
        contextLimited = try values.decodeIfPresent(Bool.self, forKey: .contextLimited) ?? false
    }

    func validatedData() throws -> Data {
        let all = allFragments
        let contextIDs = Set(contextFragments.map(\.id))
        guard TimeZone(identifier: timeZone) != nil, !fragments.isEmpty, (1...8).contains(all.count),
              Set(all.map(\.id)).count == all.count,
              all.allSatisfy({ $0.segmentID != nil && $0.id.utf8.count <= 80
                  && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.text.utf8.count <= 4_000 && ISO8601DateFormatter().date(from: $0.occurredAt) != nil }),
              all.reduce(0, { $0 + $1.text.utf8.count }) <= 10_000,
              contextFragments.reduce(0, { $0 + $1.text.utf8.count }) <= 4_000,
              priorDecisions.count <= 12, Set(priorDecisions.map(\.id)).count == priorDecisions.count,
              priorDecisions.allSatisfy({ [.plan, .task, .note].contains($0.kind)
                  && !$0.sourceIDs.isEmpty && Set($0.sourceIDs).count == $0.sourceIDs.count
                  && Set($0.sourceIDs).isSubset(of: contextIDs) }),
              usesContextContract ? mode == .everyday : (contextFragments.isEmpty && priorDecisions.isEmpty && !contextLimited)
        else { throw MioCloudError.invalidContext }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 20_000 else { throw MioCloudError.invalidContext }
        return data
    }

    static func batches(mode: MioCaptureMode, fragments: [MioAnalysisFragment], timeZone: String = TimeZone.current.identifier) -> [Self] {
        var batches: [Self] = []
        var current: [MioAnalysisFragment] = []
        var bytes = 0
        for fragment in fragments {
            if !current.isEmpty && (current.count == 8 || bytes + fragment.text.utf8.count > (mode == .lesson ? 3_500 : 10_000)) {
                batches.append(Self(mode: mode, timeZone: timeZone, fragments: current))
                current = []; bytes = 0
            }
            current.append(fragment); bytes += fragment.text.utf8.count
        }
        if !current.isEmpty { batches.append(Self(mode: mode, timeZone: timeZone, fragments: current)) }
        return batches
    }
}

struct MioAnalysisCandidate: Codable, Hashable, Sendable {
    let kind: MioContentKind
    let title: String
    let body: String
    let scheduledAt: String?
    let sourceIDs: [String]
    let evidence: String
    var replacesID: UUID? = nil
}

struct MioLessonHighlight: Codable, Hashable, Sendable {
    let text: String
    let sourceIDs: [String]
    let evidence: String
}

struct MioAnalysisResult: Codable, Hashable, Sendable {
    let candidates: [MioAnalysisCandidate]
    let highlights: [MioLessonHighlight]
    let uncertainties: [String]
    var sections: [MioLessonSection]? = nil
    var metadata: MioAnalysisMetadata? = nil

    func validate(against request: MioAnalysisRequest) throws {
        _ = try request.validatedData()
        if let sections {
            guard request.mode == .lesson, highlights.isEmpty, sections.count <= 12,
                  candidates.allSatisfy({ [.task, .plan].contains($0.kind) }),
                  let metadata, metadata.isValid else { throw MioCloudError.invalidResponse }
        } else if metadata != nil { throw MioCloudError.invalidResponse }
        let sources = Dictionary(uniqueKeysWithValues: request.allFragments.map { ($0.id, $0.text) })
        func grounded(_ ids: [String], _ evidence: String) -> Bool {
            !ids.isEmpty && ids.count <= 8 && Set(ids).count == ids.count
                && ids.allSatisfy { sources[$0] != nil }
                && !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && evidence.utf8.count <= 600 && ids.contains { sources[$0]?.contains(evidence) == true }
        }
        let newIDs = Set(request.fragments.map(\.id))
        func validReplacement(_ candidate: MioAnalysisCandidate) -> Bool {
            guard request.usesContextContract else { return candidate.replacesID == nil }
            guard !newIDs.isDisjoint(with: candidate.sourceIDs) else { return false }
            let linked = request.priorDecisions.filter { !Set($0.sourceIDs).isDisjoint(with: candidate.sourceIDs) }
            if let replacement = candidate.replacesID {
                return linked.count == 1 && linked[0].id == replacement && linked[0].isOpen && linked[0].kind == candidate.kind
            }
            return linked.isEmpty
        }
        let replacements = candidates.compactMap(\.replacesID)
        guard Set(replacements).count == replacements.count,
              candidates.count <= 6, highlights.count <= 8, uncertainties.count <= 6,
              uncertainties.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 500 }),
              request.mode == .lesson || highlights.isEmpty,
              candidates.allSatisfy({ candidate in
                  [.task, .plan, .note].contains(candidate.kind)
                      && !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && candidate.title.utf8.count <= 240 && candidate.body.utf8.count <= 2_000
                      && (candidate.scheduledAt == nil || MioAnalysisResult.parseDate(candidate.scheduledAt!) != nil)
                      && grounded(candidate.sourceIDs, candidate.evidence) && validReplacement(candidate)
              }), highlights.allSatisfy({ !$0.text.isEmpty && $0.text.utf8.count <= 1_500 && grounded($0.sourceIDs, $0.evidence) })
        else { throw MioCloudError.invalidResponse }
        for section in sections ?? [] {
            guard !section.heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  section.heading.utf8.count <= 240,
                  !section.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  section.body.utf8.count <= 8_000, grounded(section.sourceIDs, section.evidence)
            else { throw MioCloudError.invalidResponse }
        }
    }

    static func parseDate(_ value: String) -> Date? {
        // Foundation normalizes impossible dates and offsets; validate the original components first.
        guard value.utf8.count <= 64,
              let pattern = try? NSRegularExpression(pattern: #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?(?:Z|[+-]([0-9]{2}):([0-9]{2}))$"#),
              let match = pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let components = (1...8).map { index -> Int in
            guard let range = Range(match.range(at: index), in: value) else { return 0 }
            return Int(value[range]) ?? -1
        }
        let year = components[0], month = components[1], day = components[2]
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...days[month - 1]).contains(day),
              components[3] <= 23, components[4] <= 59, components[5] <= 59,
              components[6] <= 23, components[7] <= 59 else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}

/// Stores derived lesson notes and source identities, never another full transcript copy.
struct MioAnalysisRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let sessionID: UUID
    let fragmentIDs: [String]
    let highlights: [MioLessonHighlight]
    let uncertainties: [String]
    let createdAt: Date
    var sections: [MioLessonSection]? = nil
    var metadata: MioAnalysisMetadata? = nil
    var sourceRevisions: [MioSourceRevision]? = nil

    var sourceRevisionsAreValid: Bool {
        guard sourceRevisions != nil else { return true }
        let sourceIDs = fragmentIDs.compactMap { MioAnalysisFragment(id: $0, text: "", occurredAt: "").segmentID }
        return sourceIDs.count == fragmentIDs.count
            && MioSourceRevision.areValid(sourceRevisions, expectedIDs: Set(sourceIDs))
    }

    func freshness(in session: MioSession) -> MioSourceFreshness {
        guard session.id == sessionID, sourceRevisionsAreValid else { return .unknown }
        let sourceIDs = Set(fragmentIDs.compactMap { MioAnalysisFragment(id: $0, text: "", occurredAt: "").segmentID })
        return MioSourceFreshness.compare(sourceRevisions, with: session.transcripts, expectedIDs: sourceIDs)
    }
}

struct MioLessonSection: Codable, Hashable, Sendable {
    let heading: String
    let body: String
    let sourceIDs: [String]
    let evidence: String
}

struct MioAnalysisMetadata: Codable, Hashable, Sendable {
    let provider: String
    let model: String
    let promptVersion: String
    let lessonIntervalSeconds: Int

    var isValid: Bool {
        [provider, model, promptVersion].allSatisfy { !$0.isEmpty && $0.utf8.count <= 150 }
            && (60...3600).contains(lessonIntervalSeconds)
    }
}

/// Pure presentation over persisted parts; no extra summarizing model call.
struct MioLessonDocument {
    let session: MioSession
    let records: [MioAnalysisRecord]

    var fragments: [MioAnalysisFragment] { session.transcripts.flatMap(MioAnalysisFragment.make) }
    var orderedRecords: [MioAnalysisRecord] {
        let segmentOrder = Dictionary(session.transcripts.enumerated().map { ($0.element.id, $0.offset) },
                                      uniquingKeysWith: min)
        func position(_ record: MioAnalysisRecord) -> (Int, Int) {
            record.fragmentIDs.compactMap { id -> (Int, Int)? in
                let fragment = MioAnalysisFragment(id: id, text: "", occurredAt: "")
                guard let segmentID = fragment.segmentID, let segment = segmentOrder[segmentID],
                      let part = Int(id.split(separator: ":").last ?? "") else { return nil }
                return (segment, part)
            }.min(by: { $0 < $1 }) ?? (Int.max, Int.max)
        }
        // Corrections can remove current fragment suffixes. Sort persisted parts
        // by their stable segment/part identity, never the corrected text length.
        return records.enumerated().filter { $0.element.sessionID == session.id && $0.element.sections != nil }
            .sorted {
                let left = position($0.element), right = position($1.element)
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.element)
    }
    var completedCount: Int {
        let completed = Set(orderedRecords.flatMap(\.fragmentIDs))
        return fragments.filter { completed.contains($0.id) }.count
    }
    var remainingCount: Int { max(0, fragments.count - completedCount) }
    var remainingRequestCount: Int {
        let completed = Set(orderedRecords.flatMap(\.fragmentIDs))
        return MioAnalysisRequest.batches(mode: .lesson, fragments: fragments.filter { !completed.contains($0.id) }).count
    }
    var freshness: MioSourceFreshness {
        let values = orderedRecords.map { $0.freshness(in: session) }
        if values.contains(.older) { return .older }
        return values.isEmpty || values.contains(.unknown) ? .unknown : .current
    }
    var isComplete: Bool { session.endedAt != nil && !fragments.isEmpty && completedCount == fragments.count }
    var progress: String {
        "\(completedCount) av \(fragments.count) textdelar bearbetade. "
            + (isComplete ? "Alla textdelar är bearbetade; granska AI-utkastet." : "Ofullständiga anteckningar – återstående text kan bearbetas senare.")
    }
    var markdown: String {
        var parts = ["# \(session.title ?? "Lektion")", session.startedAt.formatted(date: .abbreviated, time: .shortened),
                     "AI-utkast. \(progress)"]
        if !orderedRecords.isEmpty { parts.append(freshness.message) }
        if let gaps = session.captureGaps, !gaps.isEmpty {
            parts.append("Ofullständigt ljudunderlag: \(gaps.count) avbrott. Tal under dessa intervall saknas och kan inte återskapas från texten.")
            parts += gaps.map { "- \($0.startedAt.formatted(date: .omitted, time: .standard))–\($0.endedAt.formatted(date: .omitted, time: .standard)): \($0.reason)" }
        }
        for record in orderedRecords {
            for section in record.sections ?? [] {
                parts.append("## \(section.heading)\n\n\(section.body)")
            }
            if !record.uncertainties.isEmpty {
                parts.append("### Osäkerheter\n\n" + record.uncertainties.map { "- " + $0 }.joined(separator: "\n"))
            }
        }
        return parts.joined(separator: "\n\n")
    }
}
