import Foundation

/// A bounded overlap uses original fragment identities; only new sources are processed.
enum MioEverydayContext {
    /// Gateway capability for backlog batches (twelve new sources, 12,000 bytes).
    static let backlogCapability = "analysis-backlog-v1"

    /// Normal batches hold five new sources. A backlog (user decision 2026-10-13) holds twelve,
    /// so a long queue catches up in fewer calls; the fixed prompt then costs fewer tokens too.
    /// `shrink` halves both limits per step after the provider refused a batch as too large.
    static func batches(_ fragments: [MioAnalysisFragment], backlog: Bool = false, shrink: Int = 0) -> [[MioAnalysisFragment]] {
        var result: [[MioAnalysisFragment]] = []
        var batch: [MioAnalysisFragment] = []
        var bytes = 0
        let step = min(max(shrink, 0), MioWorkSplit.maximumShrink)
        let count = max(1, (backlog && step == 0 ? 12 : 5) >> step), limit = (backlog && step == 0 ? 12_000 : 6_000) >> step
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
                        decisions: [MioAnalysisDecision], shrink: Int = 0) throws -> MioAnalysisRequest {
        let newIDs = Set(fragments.map(\.id))
        // The live session is not repository-validated; duplicates must fail, not trap.
        let segmentIDs = Set(session.transcripts.map(\.id))
        guard segmentIDs.count == session.transcripts.count else { throw MioCloudError.invalidContext }
        let segments = Dictionary(uniqueKeysWithValues: session.transcripts.map { ($0.id, $0) })
        let all = session.transcripts.flatMap(MioAnalysisFragment.make)
        let allIDs = Set(all.map(\.id))
        guard !session.isLesson,
              let first = all.firstIndex(where: { newIDs.contains($0.id) }),
              let startID = all[first].segmentID,
              let start = segments[startID]?.audioStartedAt,
              allIDs.isSuperset(of: newIDs)
        else { throw MioCloudError.invalidContext }
        let windowStart = max(continuityStartedAt, start.addingTimeInterval(-60))
        let gaps = (session.captureGaps ?? []).filter { $0.startedAt < start && $0.endedAt > windowStart }
        let floor = max(windowStart, gaps.map(\.endedAt).max() ?? windowStart)
        let possible = all.prefix(first).filter { fragment in
            guard let id = fragment.segmentID, let segment = segments[id] else { return false }
            return eligibleSegmentIDs.contains(id) && segment.audioStartedAt >= windowStart
        }
        var context = possible.filter { fragment in
            guard let id = fragment.segmentID, let segment = segments[id] else { return false }
            return segment.audioStartedAt >= floor
        }
        var limited = context.count != possible.count || !gaps.isEmpty
        let fragmentBytes = context.map { $0.text.utf8.count }
        var contextBytes = fragmentBytes.reduce(0, +)
        let newBytes = fragments.reduce(0) { $0 + $1.text.utf8.count }
        // A shrunk batch also carries less earlier context, so the whole request gets smaller.
        let contextLimit = 4_000 >> min(max(shrink, 0), MioWorkSplit.maximumShrink)
        while !context.isEmpty {
            let allCount = context.count + fragments.count
            let totalLimit = allCount > 8 ? 16_000 : 10_000
            guard allCount > 16 || contextBytes > contextLimit || contextBytes + newBytes > totalLimit else { break }
            contextBytes -= context.removeFirst().text.utf8.count
            limited = true
        }
        let sessionDecisions = decisions.filter { $0.sessionID == session.id }
        var sourcesByDecision: [[String]] = []
        sourcesByDecision.reserveCapacity(sessionDecisions.count)
        var fragmentToDecisions: [String: [Int]] = [:]
        let contextOrder = Dictionary(context.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, decision) in sessionDecisions.enumerated() {
            // Merged lineages can name more sources than the gateway takes (1...8 per hint,
            // ultrareview A2): keep the eight newest that are in context, in source order.
            let sources = Array(Set(decision.sourceIDs).filter { contextOrder[$0] != nil }
                .sorted { contextOrder[$0]! < contextOrder[$1]! }.suffix(MioAnalysisRequest.maximumHintSources))
            sourcesByDecision.append(sources)
            for source in sources {
                fragmentToDecisions[source, default: []].append(index)
            }
        }
        func hints() -> [MioAnalysisDecisionHint] {
            sessionDecisions.enumerated().compactMap { index, decision in
                let sources = sourcesByDecision[index]
                guard !sources.isEmpty else { return nil }
                return MioAnalysisDecisionHint(id: decision.id, kind: decision.kind, sourceIDs: sources, isOpen: !decision.isClosed)
            }
        }
        // Remove whole old fragments, never trim or renumber new evidence. Encoding
        // bounds also cover long decision lineages and non-ASCII source text.
        while true {
            let decisions = hints()
            let request = MioAnalysisRequest(mode: .everyday, timeZone: TimeZone.current.identifier,
                fragments: fragments, contextFragments: context, priorDecisions: decisions,
                contextLimited: limited, usesContextContract: true)
            if (try? request.validatedData()) != nil { return request }
            guard !context.isEmpty else { throw MioCloudError.invalidContext }
            let removed = context.removeFirst().id
            if let affected = fragmentToDecisions[removed] {
                for index in affected {
                    sourcesByDecision[index].removeAll { $0 == removed }
                }
            }
            limited = true
        }
    }
}
