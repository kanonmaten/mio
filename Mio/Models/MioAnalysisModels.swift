import Foundation

enum MioCaptureMode: String, Codable, Sendable {
    case everyday, lesson
}

struct MioAnalysisFragment: Codable, Hashable, Sendable {
    let id: String
    let text: String
    let occurredAt: String

    var segmentID: UUID? { UUID(uuidString: String(id.prefix(36))) }

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
                        occurredAt: ISO8601DateFormatter().string(from: segment.audioStartedAt))
        }
    }
}

struct MioAnalysisRequest: Codable, Sendable {
    let mode: MioCaptureMode
    let timeZone: String
    let fragments: [MioAnalysisFragment]

    func validatedData() throws -> Data {
        guard TimeZone(identifier: timeZone) != nil, (1...8).contains(fragments.count),
              Set(fragments.map(\.id)).count == fragments.count,
              fragments.allSatisfy({ $0.segmentID != nil && $0.id.utf8.count <= 80
                  && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.text.utf8.count <= 4_000 && ISO8601DateFormatter().date(from: $0.occurredAt) != nil }),
              fragments.reduce(0, { $0 + $1.text.utf8.count }) <= 10_000
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
        let sources = Dictionary(uniqueKeysWithValues: request.fragments.map { ($0.id, $0.text) })
        func grounded(_ ids: [String], _ evidence: String) -> Bool {
            !ids.isEmpty && ids.count <= 8 && Set(ids).count == ids.count
                && ids.allSatisfy { sources[$0] != nil }
                && !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && evidence.utf8.count <= 600 && ids.contains { sources[$0]?.contains(evidence) == true }
        }
        guard candidates.count <= 6, highlights.count <= 8, uncertainties.count <= 6,
              uncertainties.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 500 }),
              request.mode == .lesson || highlights.isEmpty,
              candidates.allSatisfy({ candidate in
                  [.task, .plan, .note].contains(candidate.kind)
                      && !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && candidate.title.utf8.count <= 240 && candidate.body.utf8.count <= 2_000
                      && (candidate.scheduledAt == nil || MioAnalysisResult.parseDate(candidate.scheduledAt!) != nil)
                      && grounded(candidate.sourceIDs, candidate.evidence)
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
        let order = Dictionary(uniqueKeysWithValues: fragments.enumerated().map { ($0.element.id, $0.offset) })
        return records.filter { $0.sessionID == session.id && $0.sections != nil }.sorted {
            ($0.fragmentIDs.compactMap { order[$0] }.min() ?? Int.max)
                < ($1.fragmentIDs.compactMap { order[$0] }.min() ?? Int.max)
        }
    }
    var completedCount: Int {
        let completed = Set(orderedRecords.flatMap(\.fragmentIDs))
        return fragments.filter { completed.contains($0.id) }.count
    }
    var isComplete: Bool { session.endedAt != nil && !fragments.isEmpty && completedCount == fragments.count }
    var progress: String {
        "\(completedCount) av \(fragments.count) textdelar bearbetade. "
            + (isComplete ? "Alla textdelar är bearbetade; granska AI-utkastet." : "Ofullständiga anteckningar – återstående text kan bearbetas senare.")
    }
    var markdown: String {
        var parts = ["# \(session.title ?? "Lektion")", session.startedAt.formatted(date: .abbreviated, time: .shortened),
                     "AI-utkast. \(progress)"]
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
