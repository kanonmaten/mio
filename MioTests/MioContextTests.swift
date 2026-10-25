import Foundation
import XCTest
@testable import Mio

final class MioContextTests: XCTestCase {
    private let zone = "Europe/Stockholm"

    func testNewContextContractSeparatesSourcesAndRejectsContextOnlyCandidates() throws {
        let old = TranscriptSegment(text: "Vi ses på biblioteket", containsMio: false)
        let next = TranscriptSegment(text: "på tisdag klockan femton.", containsMio: false)
        let a = MioAnalysisFragment.make(from: old)[0]
        let b = MioAnalysisFragment.make(from: next)[0]
        let request = MioAnalysisRequest(mode: .everyday, timeZone: zone, fragments: [b],
            contextFragments: [a], usesContextContract: true)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: request.validatedData()) as? [String: Any])
        XCTAssertEqual(Set(wire.keys), ["mode", "timeZone", "fragments", "contextFragments", "priorDecisions", "contextLimited"])
        XCTAssertEqual((wire["fragments"] as? [[String: Any]])?.first?["text"] as? String, next.text)
        let grounded = MioAnalysisCandidate(kind: .plan, title: "Biblioteket", body: "Granska tiden", scheduledAt: nil,
            sourceIDs: [a.id, b.id], evidence: old.text)
        XCTAssertNoThrow(try MioAnalysisResult(candidates: [grounded], highlights: [], uncertainties: []).validate(against: request))
        let stale = MioAnalysisCandidate(kind: .plan, title: "Biblioteket", body: "", scheduledAt: nil, sourceIDs: [a.id], evidence: old.text)
        XCTAssertThrowsError(try MioAnalysisResult(candidates: [stale], highlights: [], uncertainties: []).validate(against: request))
    }

    func testLegacyLessonWireDoesNotReceiveEverydayContextFields() throws {
        let fragment = MioAnalysisFragment.make(from: TranscriptSegment(text: "Definition.", containsMio: false))[0]
        let legacy = MioAnalysisRequest(mode: .lesson, timeZone: zone, fragments: [fragment])
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy.validatedData()) as? [String: Any])
        XCTAssertEqual(Set(wire.keys), ["mode", "timeZone", "fragments"])
        let invalid = MioAnalysisRequest(mode: .lesson, timeZone: zone, fragments: [fragment], usesContextContract: true)
        XCTAssertThrowsError(try invalid.validatedData())
    }

    func testPlannerUsesOnlyRecentConsentedSameContinuityAndPreservesNewText() throws {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        func segment(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
            TranscriptSegment(audioStartedAt: origin.addingTimeInterval(start), audioEndedAt: origin.addingTimeInterval(end), text: text, containsMio: false)
        }
        let before = segment("Före samtycke", 0, 10)
        let tooOld = segment("Gammalt", 20, 30)
        let recent = segment("Vi ses på biblioteket", 95, 100)
        let next = segment("på tisdag klockan femton.", 110, 115)
        var session = MioSession(transcripts: [before, tooOld, recent, next])
        let fresh = MioAnalysisFragment.make(from: next)
        let eligible: Set<UUID> = [tooOld.id, recent.id, next.id]
        let request = try MioEverydayContext.request(fragments: fresh, session: session,
            eligibleSegmentIDs: eligible, continuityStartedAt: origin.addingTimeInterval(15), decisions: [])
        XCTAssertEqual(request.fragments, fresh)
        XCTAssertEqual(request.contextFragments.map(\.text), [recent.text])
        session.captureGaps = [CaptureGap(startedAt: origin.addingTimeInterval(101), endedAt: origin.addingTimeInterval(105), reason: "Förlust")]
        let gap = try MioEverydayContext.request(fragments: fresh, session: session,
            eligibleSegmentIDs: eligible, continuityStartedAt: origin.addingTimeInterval(15), decisions: [])
        XCTAssertTrue(gap.contextFragments.isEmpty)
        XCTAssertTrue(gap.contextLimited)
        let paused = try MioEverydayContext.request(fragments: fresh, session: session,
            eligibleSegmentIDs: eligible, continuityStartedAt: origin.addingTimeInterval(106), decisions: [])
        XCTAssertTrue(paused.contextFragments.isEmpty)
    }

    func testContextBudgetNeverTruncatesOrRenumbersNewUnicodeFragments() throws {
        let now = Date.now
        let old = TranscriptSegment(audioStartedAt: now.addingTimeInterval(-20), text: String(repeating: "å", count: 2_800), containsMio: false)
        let new = TranscriptSegment(audioStartedAt: now, text: String(repeating: "👩🏽‍🏫", count: 500), containsMio: false)
        let session = MioSession(transcripts: [old, new])
        let fresh = MioAnalysisFragment.make(from: new)
        let batches = MioEverydayContext.batches(fresh)
        XCTAssertEqual(batches.flatMap { $0 }, fresh)
        for batch in batches {
            let request = try MioEverydayContext.request(fragments: batch, session: session,
                eligibleSegmentIDs: [old.id, new.id], continuityStartedAt: now.addingTimeInterval(-30), decisions: [])
            XCTAssertEqual(request.fragments, batch)
            XCTAssertLessThanOrEqual(request.allFragments.count, 8)
            XCTAssertLessThanOrEqual(request.allFragments.reduce(0) { $0 + $1.text.utf8.count }, 10_000)
            XCTAssertLessThanOrEqual(request.contextFragments.reduce(0) { $0 + $1.text.utf8.count }, 4_000)
            _ = try request.validatedData()
        }
    }

    func testContextTrimsOldestFragmentsUntilDecisionHintsFitLimit() throws {
        let origin = Date(timeIntervalSince1970: 1_900_000_000)
        func segment(_ index: Int) -> TranscriptSegment {
            TranscriptSegment(audioStartedAt: origin.addingTimeInterval(Double(index) * 3),
                              audioEndedAt: origin.addingTimeInterval(Double(index) * 3 + 2),
                              text: "Del \(index)", containsMio: false)
        }
        let old = (0..<14).map(segment)
        let newSegment = segment(14)
        let session = MioSession(transcripts: old + [newSegment])
        let fresh = MioAnalysisFragment.make(from: newSegment)
        let oldFragments = old.flatMap(MioAnalysisFragment.make)
        let decisions = oldFragments.prefix(13).map {
            MioAnalysisDecision(id: UUID(), sessionID: session.id, kind: .task, sourceIDs: [$0.id], isClosed: false)
        }
        let request = try MioEverydayContext.request(fragments: fresh, session: session,
            eligibleSegmentIDs: Set(session.transcripts.map(\.id)), continuityStartedAt: origin, decisions: decisions)
        XCTAssertLessThanOrEqual(request.priorDecisions.count, 12)
        XCTAssertTrue(request.contextLimited)
        XCTAssertFalse(request.contextFragments.map(\.id).contains(oldFragments[0].id))
    }

    func testContextDoesNotInvalidateAlreadyAnalyzedNewBatchAndClosedDecisionSurvivesReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("assistant.json")
        let repository = MioAssistantRepository(storageURL: url)
        let first = TranscriptSegment(text: "Vi ses på biblioteket", containsMio: false)
        let second = TranscriptSegment(text: "på tisdag klockan femton.", containsMio: false)
        let third = TranscriptSegment(text: "nej, på torsdag i stället.", containsMio: false)
        let session = MioSession(transcripts: [first, second, third])
        let a = MioAnalysisFragment.make(from: first)[0], b = MioAnalysisFragment.make(from: second)[0], c = MioAnalysisFragment.make(from: third)[0]
        let initial = MioAnalysisRequest(mode: .everyday, timeZone: zone, fragments: [a], usesContextContract: true)
        let candidate = MioAnalysisCandidate(kind: .plan, title: "Bibliotek", body: "Vilken tid?", scheduledAt: nil,
            sourceIDs: [a.id], evidence: first.text)
        let initialCount = try await repository.applyAnalysis(MioAnalysisResult(candidates: [candidate], highlights: [], uncertainties: []), request: initial, session: session)
        XCTAssertEqual(initialCount, 1)
        let document = try await repository.loadDocument()
        let id = try XCTUnwrap(document.suggestions.first?.id)
        let hint = MioAnalysisDecisionHint(id: id, kind: .plan, sourceIDs: [a.id], isOpen: true)
        let follow = MioAnalysisRequest(mode: .everyday, timeZone: zone, fragments: [b], contextFragments: [a], priorDecisions: [hint], usesContextContract: true)
        let update = MioAnalysisCandidate(kind: .plan, title: "Träff på biblioteket", body: "Tisdag kl 15", scheduledAt: "2027-01-19T15:00:00+01:00",
            sourceIDs: [a.id, b.id], evidence: second.text, replacesID: id)
        _ = try await repository.applyAnalysis(MioAnalysisResult(candidates: [update], highlights: [], uncertainties: []), request: follow, session: session)
        let updated = try await repository.loadDocument()
        XCTAssertEqual(updated.suggestions.count, 1)
        XCTAssertEqual(updated.suggestions.first?.id, id)
        XCTAssertEqual(updated.suggestions.first?.title, "Träff på biblioteket")
        XCTAssertEqual(updated.analyses?.last?.fragmentIDs, [b.id])
        try await repository.removeSuggestion(id: id)
        let reloaded = MioAssistantRepository(storageURL: url)
        let closed = try await reloaded.loadDocument()
        XCTAssertEqual(closed.analysisDecisions?.first?.isClosed, true)
        let staleHint = MioAnalysisDecisionHint(id: id, kind: .plan, sourceIDs: [b.id], isOpen: true)
        let later = MioAnalysisRequest(mode: .everyday, timeZone: zone, fragments: [c], contextFragments: [b], priorDecisions: [staleHint], usesContextContract: true)
        let correction = MioAnalysisCandidate(kind: .plan, title: "Bibliotek torsdag", body: "", scheduledAt: nil, sourceIDs: [b.id, c.id], evidence: third.text, replacesID: id)
        _ = try await reloaded.applyAnalysis(MioAnalysisResult(candidates: [correction], highlights: [], uncertainties: []), request: later, session: session)
        let final = try await reloaded.loadDocument()
        XCTAssertTrue(final.suggestions.isEmpty)
        XCTAssertEqual(final.analyses?.last?.fragmentIDs, [c.id])
        let archived = try JSONEncoder().encode(final.analysisDecisions)
        XCTAssertFalse(String(decoding: archived, as: UTF8.self).contains("Bibliotek"))
        try await reloaded.deleteSessionData(sessionID: session.id)
        let deleted = try await reloaded.loadDocument()
        XCTAssertTrue(deleted.analysisDecisions?.isEmpty == true)
    }

    func testKnownDecisionCannotBeResurrectedWithNewTitleAndNullReplacement() throws {
        let a = MioAnalysisFragment.make(from: TranscriptSegment(text: "Biblioteket", containsMio: false))[0]
        let b = MioAnalysisFragment.make(from: TranscriptSegment(text: "på torsdag", containsMio: false))[0]
        let hint = MioAnalysisDecisionHint(id: UUID(), kind: .plan, sourceIDs: [a.id], isOpen: false)
        let request = MioAnalysisRequest(mode: .everyday, timeZone: zone, fragments: [b], contextFragments: [a], priorDecisions: [hint], usesContextContract: true)
        let candidate = MioAnalysisCandidate(kind: .plan, title: "Helt annan rubrik", body: "", scheduledAt: nil, sourceIDs: [a.id, b.id], evidence: b.text)
        XCTAssertThrowsError(try MioAnalysisResult(candidates: [candidate], highlights: [], uncertainties: []).validate(against: request))
    }

    func testIdenticalNewOnlyEventsKeepSeparateDecisionIdentities() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MioAssistantRepository(storageURL: root.appendingPathComponent("assistant.json"))
        let first = TranscriptSegment(text: "Bibliotek på tisdag.", containsMio: false)
        let second = TranscriptSegment(text: "Bibliotek på tisdag.", containsMio: false)
        let session = MioSession(transcripts: [first, second])
        for segment in [first, second] {
            let fragment = MioAnalysisFragment.make(from: segment)[0]
            let request = MioAnalysisRequest(mode: .everyday, timeZone: zone, fragments: [fragment], usesContextContract: true)
            let candidate = MioAnalysisCandidate(kind: .plan, title: "Bibliotek", body: "", scheduledAt: "2027-01-19T15:00:00+01:00",
                sourceIDs: [fragment.id], evidence: segment.text)
            _ = try await repository.applyAnalysis(MioAnalysisResult(candidates: [candidate], highlights: [], uncertainties: []), request: request, session: session)
        }
        let document = try await repository.loadDocument()
        XCTAssertEqual(document.suggestions.count, 2)
        XCTAssertEqual(document.analysisDecisions?.count, 2)
        XCTAssertEqual(Set(document.analysisDecisions?.flatMap(\.sourceIDs) ?? []), Set(session.transcripts.flatMap(MioAnalysisFragment.make).map(\.id)))
        for suggestion in document.suggestions { try await repository.removeSuggestion(id: suggestion.id) }
        let closed = try await repository.loadDocument()
        XCTAssertTrue(closed.analysisDecisions?.allSatisfy(\.isClosed) == true)
    }
}
