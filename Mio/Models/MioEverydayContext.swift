import Foundation

/// A bounded overlap uses original fragment identities; only new sources are processed.
enum MioEverydayContext {
    /// Gateway capability for backlog batches (twelve new sources, 12,000 bytes).
    static let backlogCapability = "analysis-backlog-v1"

    /// Normal batches hold five new sources. A backlog (user decision 2026-10-13) holds twelve,
    /// so a long queue catches up in fewer calls; the fixed prompt then costs fewer tokens too.
    static func batches(_ fragments: [MioAnalysisFragment], backlog: Bool = false) -> [[MioAnalysisFragment]] {
        var result: [[MioAnalysisFragment]] = []
        var batch: [MioAnalysisFragment] = []
        var bytes = 0
        let count = backlog ? 12 : 5, limit = backlog ? 12_000 : 6_000
        for fragment in fragments {
            // Reserve three source slots and 4,000 bytes for continuity.
            if !batch.isEmpty && (batch.count == count || bytes + fragment.text.utf8.count > limit) {
                result.append(batch); batch = []; bytes = 0
            }
            batch.append(fragment); bytes += fragment.text.utf8.count
        }
        if !batch.isEmpty { result.append(batch) }
        return result
    }

    static func request(fragments: [MioAnalysisFragment], session: MioSession,
                        eligibleSegmentIDs: Set<UUID>, continuityStartedAt: Date,
                        decisions: [MioAnalysisDecision]) throws -> MioAnalysisRequest {
        let all = session.transcripts.flatMap(MioAnalysisFragment.make)
        let newIDs = Set(fragments.map(\.id))
        guard !session.isLesson, let first = all.firstIndex(where: { newIDs.contains($0.id) }),
              let startID = all[first].segmentID,
              let start = session.transcripts.first(where: { $0.id == startID })?.audioStartedAt,
              Set(all.map(\.id)).isSuperset(of: newIDs)
        else { throw MioCloudError.invalidContext }
        let windowStart = max(continuityStartedAt, start.addingTimeInterval(-60))
        let gaps = (session.captureGaps ?? []).filter { $0.startedAt < start && $0.endedAt > windowStart }
        let floor = max(windowStart, gaps.map(\.endedAt).max() ?? windowStart)
        // The live session is not repository-validated; duplicates must fail, not trap.
        guard Set(session.transcripts.map(\.id)).count == session.transcripts.count else { throw MioCloudError.invalidContext }
        let segments = Dictionary(uniqueKeysWithValues: session.transcripts.map { ($0.id, $0) })
        let possible = all.prefix(first).filter { fragment in
            guard let id = fragment.segmentID, let segment = segments[id] else { return false }
            return eligibleSegmentIDs.contains(id) && segment.audioStartedAt >= windowStart
        }
        var context = possible.filter { fragment in
            guard let id = fragment.segmentID, let segment = segments[id] else { return false }
            return segment.audioStartedAt >= floor
        }
        var limited = context.count != possible.count || !gaps.isEmpty
        func hints(for context: [MioAnalysisFragment]) -> [MioAnalysisDecisionHint] {
            let ids = Set(context.map(\.id))
            return decisions.filter { $0.sessionID == session.id }.compactMap { decision in
                let sources = decision.sourceIDs.filter { ids.contains($0) }
                guard !sources.isEmpty else { return nil }
                return MioAnalysisDecisionHint(id: decision.id, kind: decision.kind, sourceIDs: sources, isOpen: !decision.isClosed)
            }
        }
        // Remove whole old fragments, never trim or renumber new evidence. Encoding
        // bounds also cover long decision lineages and non-ASCII source text.
        while true {
            let decisions = hints(for: context)
            let request = MioAnalysisRequest(mode: .everyday, timeZone: TimeZone.current.identifier,
                fragments: fragments, contextFragments: context, priorDecisions: decisions,
                contextLimited: limited, usesContextContract: true)
            if (try? request.validatedData()) != nil { return request }
            guard !context.isEmpty else { throw MioCloudError.invalidContext }
            context.removeFirst(); limited = true
        }
    }
}
