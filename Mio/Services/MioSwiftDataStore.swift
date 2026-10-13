import Foundation
import SwiftData

// SwiftData persistence for sessions, content and assistant data. Each row stores identity
// columns plus the existing Codable value as a JSON payload, so additive value-type fields
// persist without a schema change while every write touches only changed rows.

enum MioSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [SessionRow.self, SegmentRow.self, CaptureGapRow.self, ContentItemRow.self, SuggestionRow.self,
         LessonRow.self, AnalysisRow.self, DecisionRow.self, ProcessedSourceRow.self]
    }

    /// A `MioSession` without transcripts and capture gaps, which have their own rows.
    @Model final class SessionRow {
        #Index<SessionRow>([\.sessionID])
        var sessionID: UUID
        var startedAt: Date
        var payload: Data

        init(sessionID: UUID, startedAt: Date, payload: Data) {
            self.sessionID = sessionID
            self.startedAt = startedAt
            self.payload = payload
        }
    }

    /// One original `TranscriptSegment`; `ordinal` is its position in the session.
    @Model final class SegmentRow {
        #Index<SegmentRow>([\.sessionID], [\.segmentID])
        var segmentID: UUID
        var sessionID: UUID
        var ordinal: Int
        var payload: Data

        init(segmentID: UUID, sessionID: UUID, ordinal: Int, payload: Data) {
            self.segmentID = segmentID
            self.sessionID = sessionID
            self.ordinal = ordinal
            self.payload = payload
        }
    }

    @Model final class CaptureGapRow {
        #Index<CaptureGapRow>([\.sessionID], [\.gapID])
        var gapID: UUID
        var sessionID: UUID
        var ordinal: Int
        var payload: Data

        init(gapID: UUID, sessionID: UUID, ordinal: Int, payload: Data) {
            self.gapID = gapID
            self.sessionID = sessionID
            self.ordinal = ordinal
            self.payload = payload
        }
    }

    @Model final class ContentItemRow {
        #Index<ContentItemRow>([\.itemID])
        var itemID: UUID
        var payload: Data

        init(itemID: UUID, payload: Data) {
            self.itemID = itemID
            self.payload = payload
        }
    }

    @Model final class SuggestionRow {
        #Index<SuggestionRow>([\.suggestionID])
        var suggestionID: UUID
        var ordinal: Int
        var payload: Data

        init(suggestionID: UUID, ordinal: Int, payload: Data) {
            self.suggestionID = suggestionID
            self.ordinal = ordinal
            self.payload = payload
        }
    }

    @Model final class LessonRow {
        #Index<LessonRow>([\.lessonID], [\.sessionID])
        var lessonID: UUID
        var sessionID: UUID
        var ordinal: Int
        var payload: Data

        init(lessonID: UUID, sessionID: UUID, ordinal: Int, payload: Data) {
            self.lessonID = lessonID
            self.sessionID = sessionID
            self.ordinal = ordinal
            self.payload = payload
        }
    }

    /// One AI analysis record. Detailed lesson-note parts are records with sections.
    @Model final class AnalysisRow {
        #Index<AnalysisRow>([\.recordID], [\.sessionID])
        var recordID: UUID
        var sessionID: UUID
        var isDetailedPart: Bool
        var ordinal: Int
        var payload: Data

        init(recordID: UUID, sessionID: UUID, isDetailedPart: Bool, ordinal: Int, payload: Data) {
            self.recordID = recordID
            self.sessionID = sessionID
            self.isDetailedPart = isDetailedPart
            self.ordinal = ordinal
            self.payload = payload
        }
    }

    /// Identity-only analysis decision; rejected proposal text never lives here.
    @Model final class DecisionRow {
        #Index<DecisionRow>([\.decisionID])
        var decisionID: UUID
        var sessionID: UUID
        var ordinal: Int
        var payload: Data

        init(decisionID: UUID, sessionID: UUID, ordinal: Int, payload: Data) {
            self.decisionID = decisionID
            self.sessionID = sessionID
            self.ordinal = ordinal
            self.payload = payload
        }
    }

    @Model final class ProcessedSourceRow {
        #Index<ProcessedSourceRow>([\.sessionID, \.segmentID])
        var sessionID: UUID
        var segmentID: UUID

        init(sessionID: UUID, segmentID: UUID) {
            self.sessionID = sessionID
            self.segmentID = segmentID
        }
    }
}

enum MioStoreMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MioSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

typealias MioSessionRow = MioSchemaV1.SessionRow
typealias MioSegmentRow = MioSchemaV1.SegmentRow
typealias MioCaptureGapRow = MioSchemaV1.CaptureGapRow
typealias MioContentItemRow = MioSchemaV1.ContentItemRow
typealias MioSuggestionRow = MioSchemaV1.SuggestionRow
typealias MioLessonRow = MioSchemaV1.LessonRow
typealias MioAnalysisRow = MioSchemaV1.AnalysisRow
typealias MioDecisionRow = MioSchemaV1.DecisionRow
typealias MioProcessedSourceRow = MioSchemaV1.ProcessedSourceRow

enum MioPersistentStore {
    /// Opens `Mio/store/Mio.store`. The directory is private, protected until first unlock
    /// (capture checkpoints are written while the phone is locked) and excluded from backup;
    /// SQLite's -wal/-shm files inherit the directory's protection class.
    static func makeContainer(files: MioLegacyStoreFiles) throws -> ModelContainer {
        try files.prepareOwnedDirectory(files.directory)
        try files.prepareOwnedDirectory(files.storeDirectory)
        let schema = Schema(versionedSchema: MioSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, url: files.storeURL, allowsSave: true,
                                               cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, migrationPlan: MioStoreMigrationPlan.self,
                                           configurations: [configuration])
        try protectStoreFiles(in: files.storeDirectory)
        return container
    }

    /// Used only when the migrated store cannot be opened, so nothing is written to the
    /// legacy files and no stored data is replaced. Changes in this mode are not persisted.
    static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: MioSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: MioStoreMigrationPlan.self,
                                  configurations: [configuration])
    }

    private static func protectStoreFiles(in directory: URL) throws {
        let fileManager = FileManager.default
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }
}

/// Row payload coding. Dates keep full precision (no ISO-8601 rounding), so a reload
/// returns exactly the values the repository core cached after its last write.
enum MioRowCodec {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data { try encoder.encode(value) }
    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try decoder.decode(type, from: data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()
}

/// Saves the staged changes atomically; a failure discards every staged change.
enum MioSwiftDataWrite {
    static func commit(_ context: ModelContext, _ stage: () throws -> Void) throws {
        do {
            try context.transaction { try stage() }
        } catch {
            context.rollback()
            throw error
        }
    }
}

// MARK: - Sessions

final class MioSwiftDataSessionStorage: MioSessionStorage {
    private let context: ModelContext
    /// Bumped after a failed write so the core rereads the committed rows.
    private var generation: UInt64 = 1

    init(context: ModelContext) { self.context = context }

    func stamp() throws -> MioFileStamp? { MioFileStamp(modifiedAt: nil, size: generation, inode: 0) }

    func read() throws -> [MioSession]? {
        var sessions: [MioSession] = []
        try context.enumerate(FetchDescriptor<MioSessionRow>()) { row in
            let session = try MioRowCodec.decode(MioSession.self, from: row.payload)
            sessions.append(session)
        }
        var segments: [UUID: [(Int, TranscriptSegment)]] = [:]
        try context.enumerate(FetchDescriptor<MioSegmentRow>()) { row in
            let segment = try MioRowCodec.decode(TranscriptSegment.self, from: row.payload)
            segments[row.sessionID, default: []].append((row.ordinal, segment))
        }
        var gaps: [UUID: [(Int, CaptureGap)]] = [:]
        try context.enumerate(FetchDescriptor<MioCaptureGapRow>()) { row in
            let gap = try MioRowCodec.decode(CaptureGap.self, from: row.payload)
            gaps[row.sessionID, default: []].append((row.ordinal, gap))
        }
        for index in sessions.indices {
            let id = sessions[index].id
            sessions[index].transcripts = (segments[id] ?? []).sorted { $0.0 < $1.0 }.map { $0.1 }
            if sessions[index].captureGaps != nil {
                sessions[index].captureGaps = (gaps[id] ?? []).sorted { $0.0 < $1.0 }.map { $0.1 }
            }
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    func write(_ sessions: [MioSession], replacing previous: [MioSession]?) throws {
        do {
            try MioSwiftDataWrite.commit(context) { try stage(sessions, replacing: previous) }
        } catch {
            generation &+= 1
            MioLog.error(.storage, "session write failed")
            throw error
        }
    }

    func erase() throws {
        do {
            try MioSwiftDataWrite.commit(context) {
                try context.delete(model: MioSessionRow.self)
                try context.delete(model: MioSegmentRow.self)
                try context.delete(model: MioCaptureGapRow.self)
            }
        } catch {
            generation &+= 1
            throw error
        }
    }

    /// Stages changes without saving, so the migration can combine all domains in one transaction.
    func stage(_ sessions: [MioSession], replacing previous: [MioSession]?) throws {
        guard let previous else {
            for row in try context.fetch(FetchDescriptor<MioSessionRow>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<MioSegmentRow>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<MioCaptureGapRow>()) { context.delete(row) }
            for session in sessions { try insert(session) }
            return
        }
        let prior = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = Set(sessions.map(\.id))
        for id in prior.keys where !current.contains(id) { try deleteRows(sessionID: id) }
        for session in sessions {
            guard let old = prior[session.id] else { try insert(session); continue }
            guard old != session else { continue }
            if Self.header(of: old) != Self.header(of: session) {
                let id = session.id
                var descriptor = FetchDescriptor<MioSessionRow>(predicate: #Predicate { $0.sessionID == id })
                descriptor.fetchLimit = 1
                if let row = try context.fetch(descriptor).first {
                    row.startedAt = session.startedAt
                    row.payload = try MioRowCodec.encode(Self.header(of: session))
                } else {
                    context.insert(MioSessionRow(sessionID: id, startedAt: session.startedAt,
                                                 payload: try MioRowCodec.encode(Self.header(of: session))))
                }
            }
            if old.transcripts != session.transcripts {
                try syncSegments(session.transcripts, previous: old.transcripts, sessionID: session.id)
            }
            if (old.captureGaps ?? []) != (session.captureGaps ?? []) {
                try syncGaps(session.captureGaps ?? [], previous: old.captureGaps ?? [], sessionID: session.id)
            }
        }
    }

    /// The session payload keeps whether `captureGaps` was present, never the gaps themselves.
    private static func header(of session: MioSession) -> MioSession {
        var header = session
        header.transcripts = []
        header.captureGaps = session.captureGaps == nil ? nil : []
        return header
    }

    private func insert(_ session: MioSession) throws {
        context.insert(MioSessionRow(sessionID: session.id, startedAt: session.startedAt,
                                     payload: try MioRowCodec.encode(Self.header(of: session))))
        for (offset, segment) in session.transcripts.enumerated() {
            context.insert(MioSegmentRow(segmentID: segment.id, sessionID: session.id, ordinal: offset,
                                         payload: try MioRowCodec.encode(segment)))
        }
        for (offset, gap) in (session.captureGaps ?? []).enumerated() {
            context.insert(MioCaptureGapRow(gapID: gap.id, sessionID: session.id, ordinal: offset,
                                            payload: try MioRowCodec.encode(gap)))
        }
    }

    private func deleteRows(sessionID id: UUID) throws {
        for row in try context.fetch(FetchDescriptor<MioSessionRow>(predicate: #Predicate { $0.sessionID == id })) {
            context.delete(row)
        }
        for row in try context.fetch(FetchDescriptor<MioSegmentRow>(predicate: #Predicate { $0.sessionID == id })) {
            context.delete(row)
        }
        for row in try context.fetch(FetchDescriptor<MioCaptureGapRow>(predicate: #Predicate { $0.sessionID == id })) {
            context.delete(row)
        }
    }

    /// Live capture only appends, which inserts rows without reading the session's others.
    private func syncSegments(_ segments: [TranscriptSegment], previous: [TranscriptSegment], sessionID id: UUID) throws {
        if segments.count >= previous.count, segments[..<previous.count].elementsEqual(previous) {
            for (offset, segment) in segments.enumerated().dropFirst(previous.count) {
                context.insert(MioSegmentRow(segmentID: segment.id, sessionID: id, ordinal: offset,
                                             payload: try MioRowCodec.encode(segment)))
            }
            return
        }
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = Dictionary(
            try context.fetch(FetchDescriptor<MioSegmentRow>(predicate: #Predicate { $0.sessionID == id }))
                .map { ($0.segmentID, $0) }, uniquingKeysWith: { first, _ in first })
        for (offset, segment) in segments.enumerated() {
            if let row = rows.removeValue(forKey: segment.id) {
                if row.ordinal != offset { row.ordinal = offset }
                if old[segment.id] != segment { row.payload = try MioRowCodec.encode(segment) }
            } else {
                context.insert(MioSegmentRow(segmentID: segment.id, sessionID: id, ordinal: offset,
                                             payload: try MioRowCodec.encode(segment)))
            }
        }
        for row in rows.values { context.delete(row) }
    }

    private func syncGaps(_ gaps: [CaptureGap], previous: [CaptureGap], sessionID id: UUID) throws {
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = Dictionary(
            try context.fetch(FetchDescriptor<MioCaptureGapRow>(predicate: #Predicate { $0.sessionID == id }))
                .map { ($0.gapID, $0) }, uniquingKeysWith: { first, _ in first })
        for (offset, gap) in gaps.enumerated() {
            if let row = rows.removeValue(forKey: gap.id) {
                if row.ordinal != offset { row.ordinal = offset }
                if old[gap.id] != gap { row.payload = try MioRowCodec.encode(gap) }
            } else {
                context.insert(MioCaptureGapRow(gapID: gap.id, sessionID: id, ordinal: offset,
                                                payload: try MioRowCodec.encode(gap)))
            }
        }
        for row in rows.values { context.delete(row) }
    }
}

// MARK: - Content

final class MioSwiftDataContentStorage: MioContentStorage {
    private let context: ModelContext
    private var generation: UInt64 = 1

    init(context: ModelContext) { self.context = context }

    func stamp() throws -> MioFileStamp? { MioFileStamp(modifiedAt: nil, size: generation, inode: 0) }

    func read() throws -> [MioContentItem]? {
        var items: [MioContentItem] = []
        try context.enumerate(FetchDescriptor<MioContentItemRow>()) { row in
            let item = try MioRowCodec.decode(MioContentItem.self, from: row.payload)
            items.append(item)
        }
        return items
    }

    func write(_ items: [MioContentItem], replacing previous: [MioContentItem]?) throws {
        do {
            try MioSwiftDataWrite.commit(context) { try stage(items, replacing: previous) }
        } catch {
            generation &+= 1
            MioLog.error(.storage, "content write failed")
            throw error
        }
    }

    func erase() throws {
        do {
            try MioSwiftDataWrite.commit(context) { try context.delete(model: MioContentItemRow.self) }
        } catch {
            generation &+= 1
            throw error
        }
    }

    func stage(_ items: [MioContentItem], replacing previous: [MioContentItem]?) throws {
        guard let previous else {
            for row in try context.fetch(FetchDescriptor<MioContentItemRow>()) { context.delete(row) }
            for item in items {
                context.insert(MioContentItemRow(itemID: item.id, payload: try MioRowCodec.encode(item)))
            }
            return
        }
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = Set(items.map(\.id))
        for id in old.keys where !current.contains(id) {
            for row in try rows(id) { context.delete(row) }
        }
        for item in items where old[item.id] != item {
            let payload = try MioRowCodec.encode(item)
            if let row = try rows(item.id).first {
                row.payload = payload
            } else {
                context.insert(MioContentItemRow(itemID: item.id, payload: payload))
            }
        }
    }

    private func rows(_ id: UUID) throws -> [MioContentItemRow] {
        try context.fetch(FetchDescriptor<MioContentItemRow>(predicate: #Predicate { $0.itemID == id }))
    }
}

// MARK: - Assistant

final class MioSwiftDataAssistantStorage: MioAssistantStorage {
    private let context: ModelContext
    private var generation: UInt64 = 1
    /// Monotonic position for new rows, so removals never reorder the remaining rows.
    private var nextOrdinal: Int?

    init(context: ModelContext) { self.context = context }

    func stamp() throws -> MioFileStamp? { MioFileStamp(modifiedAt: nil, size: generation, inode: 0) }

    func read() throws -> MioAssistantStoreDocument? {
        var maximum = -1
        var suggestions: [(Int, MioSuggestion)] = []
        try context.enumerate(FetchDescriptor<MioSuggestionRow>()) { row in
            maximum = max(maximum, row.ordinal)
            let value = try MioRowCodec.decode(MioSuggestion.self, from: row.payload)
            suggestions.append((row.ordinal, value))
        }
        var lessons: [(Int, MioLesson)] = []
        try context.enumerate(FetchDescriptor<MioLessonRow>()) { row in
            maximum = max(maximum, row.ordinal)
            let value = try MioRowCodec.decode(MioLesson.self, from: row.payload)
            lessons.append((row.ordinal, value))
        }
        var analyses: [(Int, MioAnalysisRecord)] = []
        try context.enumerate(FetchDescriptor<MioAnalysisRow>()) { row in
            maximum = max(maximum, row.ordinal)
            let value = try MioRowCodec.decode(MioAnalysisRecord.self, from: row.payload)
            analyses.append((row.ordinal, value))
        }
        var decisions: [(Int, MioAnalysisDecision)] = []
        try context.enumerate(FetchDescriptor<MioDecisionRow>()) { row in
            maximum = max(maximum, row.ordinal)
            let value = try MioRowCodec.decode(MioAnalysisDecision.self, from: row.payload)
            decisions.append((row.ordinal, value))
        }
        var sources: Set<MioProcessedSource> = []
        try context.enumerate(FetchDescriptor<MioProcessedSourceRow>()) { row in
            sources.insert(MioProcessedSource(sessionID: row.sessionID, segmentID: row.segmentID))
        }
        nextOrdinal = maximum + 1
        func ordered<Value>(_ values: [(Int, Value)]) -> [Value] { values.sorted { $0.0 < $1.0 }.map { $0.1 } }
        return MioAssistantStoreDocument(
            suggestions: ordered(suggestions), lessons: ordered(lessons), processedSources: sources,
            analyses: analyses.isEmpty ? nil : ordered(analyses),
            analysisDecisions: decisions.isEmpty ? nil : ordered(decisions))
    }

    func write(_ document: MioAssistantStoreDocument, replacing previous: MioAssistantStoreDocument?) throws {
        do {
            try MioSwiftDataWrite.commit(context) { try stage(document, replacing: previous) }
        } catch {
            generation &+= 1
            nextOrdinal = nil
            MioLog.error(.storage, "assistant write failed")
            throw error
        }
    }

    func erase() throws {
        do {
            try MioSwiftDataWrite.commit(context) {
                try context.delete(model: MioSuggestionRow.self)
                try context.delete(model: MioLessonRow.self)
                try context.delete(model: MioAnalysisRow.self)
                try context.delete(model: MioDecisionRow.self)
                try context.delete(model: MioProcessedSourceRow.self)
            }
            nextOrdinal = 0
        } catch {
            generation &+= 1
            nextOrdinal = nil
            throw error
        }
    }

    func stage(_ document: MioAssistantStoreDocument, replacing previous: MioAssistantStoreDocument?) throws {
        guard let previous else {
            for row in try context.fetch(FetchDescriptor<MioSuggestionRow>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<MioLessonRow>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<MioAnalysisRow>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<MioDecisionRow>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<MioProcessedSourceRow>()) { context.delete(row) }
            // Insert directly: lookups could still see rows that are only pending deletion.
            var ordinal = 0
            func next() -> Int { defer { ordinal += 1 }; return ordinal }
            for value in document.suggestions {
                context.insert(MioSuggestionRow(suggestionID: value.id, ordinal: next(),
                                                payload: try MioRowCodec.encode(value)))
            }
            for value in document.lessons {
                context.insert(MioLessonRow(lessonID: value.id, sessionID: value.sessionID, ordinal: next(),
                                            payload: try MioRowCodec.encode(value)))
            }
            for value in document.analyses ?? [] {
                context.insert(MioAnalysisRow(recordID: value.id, sessionID: value.sessionID,
                                              isDetailedPart: value.sections != nil, ordinal: next(),
                                              payload: try MioRowCodec.encode(value)))
            }
            for value in document.analysisDecisions ?? [] {
                context.insert(MioDecisionRow(decisionID: value.id, sessionID: value.sessionID, ordinal: next(),
                                              payload: try MioRowCodec.encode(value)))
            }
            for source in document.processedSources {
                context.insert(MioProcessedSourceRow(sessionID: source.sessionID, segmentID: source.segmentID))
            }
            nextOrdinal = ordinal
            return
        }
        // read() sets the next position; it runs here only after a failed write.
        if nextOrdinal == nil { _ = try read() }

        try sync(document.suggestions, previous: previous.suggestions, key: \.id, rows: suggestionRows,
                 make: { (value: MioSuggestion, ordinal: Int, payload: Data) -> MioSuggestionRow in
                     MioSuggestionRow(suggestionID: value.id, ordinal: ordinal, payload: payload) },
                 update: { (row: MioSuggestionRow, _: MioSuggestion, payload: Data) in row.payload = payload })
        try sync(document.lessons, previous: previous.lessons, key: \.id, rows: lessonRows,
                 make: { (value: MioLesson, ordinal: Int, payload: Data) -> MioLessonRow in
                     MioLessonRow(lessonID: value.id, sessionID: value.sessionID, ordinal: ordinal, payload: payload) },
                 update: { (row: MioLessonRow, value: MioLesson, payload: Data) in
                     row.sessionID = value.sessionID
                     row.payload = payload
                 })
        try sync(document.analyses ?? [], previous: previous.analyses ?? [], key: \.id, rows: analysisRows,
                 make: { (value: MioAnalysisRecord, ordinal: Int, payload: Data) -> MioAnalysisRow in
                     MioAnalysisRow(recordID: value.id, sessionID: value.sessionID, isDetailedPart: value.sections != nil,
                                    ordinal: ordinal, payload: payload) },
                 update: { (row: MioAnalysisRow, value: MioAnalysisRecord, payload: Data) in
                     row.sessionID = value.sessionID
                     row.isDetailedPart = value.sections != nil
                     row.payload = payload
                 })
        try sync(document.analysisDecisions ?? [], previous: previous.analysisDecisions ?? [], key: \.id, rows: decisionRows,
                 make: { (value: MioAnalysisDecision, ordinal: Int, payload: Data) -> MioDecisionRow in
                     MioDecisionRow(decisionID: value.id, sessionID: value.sessionID, ordinal: ordinal, payload: payload) },
                 update: { (row: MioDecisionRow, value: MioAnalysisDecision, payload: Data) in
                     row.sessionID = value.sessionID
                     row.payload = payload
                 })

        for source in previous.processedSources.subtracting(document.processedSources) {
            let sessionID = source.sessionID, segmentID = source.segmentID
            for row in try context.fetch(FetchDescriptor<MioProcessedSourceRow>(
                predicate: #Predicate { $0.sessionID == sessionID && $0.segmentID == segmentID })) {
                context.delete(row)
            }
        }
        for source in document.processedSources.subtracting(previous.processedSources) {
            context.insert(MioProcessedSourceRow(sessionID: source.sessionID, segmentID: source.segmentID))
        }
    }

    /// Inserts, updates and deletes only values whose identity or content changed.
    private func sync<Value: Equatable & Encodable, Row: PersistentModel>(
        _ values: [Value], previous: [Value], key: KeyPath<Value, UUID>,
        rows: (UUID) throws -> [Row], make: (Value, Int, Data) -> Row, update: (Row, Value, Data) -> Void
    ) throws {
        let old = Dictionary(previous.map { ($0[keyPath: key], $0) }, uniquingKeysWith: { first, _ in first })
        let current = Set(values.map { $0[keyPath: key] })
        for id in old.keys where !current.contains(id) {
            for row in try rows(id) { context.delete(row) }
        }
        for value in values where old[value[keyPath: key]] != value {
            let payload = try MioRowCodec.encode(value)
            if let row = try rows(value[keyPath: key]).first {
                update(row, value, payload)
            } else {
                let ordinal = nextOrdinal ?? 0
                nextOrdinal = ordinal + 1
                context.insert(make(value, ordinal, payload))
            }
        }
    }

    private func suggestionRows(_ id: UUID) throws -> [MioSuggestionRow] {
        try context.fetch(FetchDescriptor<MioSuggestionRow>(predicate: #Predicate { $0.suggestionID == id }))
    }

    private func lessonRows(_ id: UUID) throws -> [MioLessonRow] {
        try context.fetch(FetchDescriptor<MioLessonRow>(predicate: #Predicate { $0.lessonID == id }))
    }

    private func analysisRows(_ id: UUID) throws -> [MioAnalysisRow] {
        try context.fetch(FetchDescriptor<MioAnalysisRow>(predicate: #Predicate { $0.recordID == id }))
    }

    private func decisionRows(_ id: UUID) throws -> [MioDecisionRow] {
        try context.fetch(FetchDescriptor<MioDecisionRow>(predicate: #Predicate { $0.decisionID == id }))
    }
}

// MARK: - Repositories

/// The pre-migration JSON backup may still hold deleted text until the next launch removes
/// it. Single deletions remove it right away, best effort: the rows are already gone, so a
/// file error must not report the deletion itself as failed. Full deletion still throws.
enum MioLegacyBackup {
    static func discardAfterDeletion() {
        do { try MioLegacyStoreFiles.standard.discardBackup() } catch {
            MioLog.error(.storage, "legacy backup cleanup after deletion failed")
        }
    }
}

/// Session repository backed by SwiftData. The shared core keeps the operation tokens,
/// merge and validation rules; only changed rows are written per checkpoint.
@ModelActor
actor MioSwiftDataSessionRepository: MioSessionStore {
    private var storedCore: SessionRepositoryCore?

    private var core: SessionRepositoryCore {
        if let storedCore { return storedCore }
        let created = SessionRepositoryCore(storage: MioSwiftDataSessionStorage(context: modelContext))
        storedCore = created
        return created
    }

    func loadSessions() throws -> [MioSession] { try core.loadSessions() }
    func operationGeneration() -> UUID { core.operationGeneration() }
    func operationToken(for id: UUID, generation expectedGeneration: UUID) throws -> SessionOperationToken {
        try core.operationToken(for: id, generation: expectedGeneration)
    }
    @discardableResult
    func saveCaptureCheckpoint(_ session: MioSession, token: SessionOperationToken) throws -> MioSession {
        try core.saveCaptureCheckpoint(session, token: token)
    }
    @discardableResult
    func updateMetadata(id: UUID, title: String?, note: String?, token: SessionOperationToken) throws -> MioSession {
        try core.updateMetadata(id: id, title: title, note: note, token: token)
    }
    @discardableResult
    func correctTranscript(sessionID: UUID, segmentID: UUID, text: String,
                           token: SessionOperationToken) throws -> MioSession {
        try core.correctTranscript(sessionID: sessionID, segmentID: segmentID, text: text, token: token)
    }
    @discardableResult
    func renameSpeaker(sessionID: UUID, speaker: Int, name: String,
                       token: SessionOperationToken) throws -> MioSession {
        try core.renameSpeaker(sessionID: sessionID, speaker: speaker, name: name, token: token)
    }
    func delete(id: UUID) throws {
        try core.delete(id: id)
        MioLegacyBackup.discardAfterDeletion()
    }
    func removeTemporaryExports() throws { try core.removeTemporaryExports() }
    @discardableResult
    func deleteAll() throws -> UUID {
        let generation = try core.deleteAll()
        try MioLegacyStoreFiles.standard.discardBackup()
        return generation
    }
    func makeExportFile(for session: MioSession) throws -> URL { try core.makeExportFile(for: session) }
}

@ModelActor
actor MioSwiftDataContentRepository: MioContentStore {
    private var storedCore: MioContentRepositoryCore?

    private var core: MioContentRepositoryCore {
        if let storedCore { return storedCore }
        let created = MioContentRepositoryCore(storage: MioSwiftDataContentStorage(context: modelContext))
        storedCore = created
        return created
    }

    func loadItems() throws -> [MioContentItem] { try core.loadItems() }
    func upsert(_ item: MioContentItem) throws -> [MioContentItem] { try core.upsert(item) }
    func delete(id: UUID) throws -> [MioContentItem] {
        let items = try core.delete(id: id)
        MioLegacyBackup.discardAfterDeletion()
        return items
    }
    func saveApprovedIfAbsent(_ item: MioContentItem) throws -> [MioContentItem] { try core.saveApprovedIfAbsent(item) }
    func unlinkSession(id: UUID) throws -> [MioContentItem] { try core.unlinkSession(id: id) }
    func deleteAll() throws {
        try core.deleteAll()
        try MioLegacyStoreFiles.standard.discardBackup()
    }
    func removeTemporaryExports() throws { try core.removeTemporaryExports() }
    func makeExportFile(content: [MioContentItem], sessions: [MioSession],
                        assistant: MioAssistantStoreDocument?, diagnostics: MioDiagnosticsExport?) throws -> URL {
        try core.makeExportFile(content: content, sessions: sessions, assistant: assistant, diagnostics: diagnostics)
    }
}

@ModelActor
actor MioSwiftDataAssistantRepository: MioAssistantStore {
    private var storedCore: MioAssistantRepositoryCore?

    private var core: MioAssistantRepositoryCore {
        if let storedCore { return storedCore }
        let created = MioAssistantRepositoryCore(storage: MioSwiftDataAssistantStorage(context: modelContext))
        storedCore = created
        return created
    }

    func loadDocument() throws -> MioAssistantStoreDocument { try core.loadDocument() }
    func claimSuggestion(id: UUID, expectedRevision: Int) throws -> MioSuggestionApprovalClaim {
        try core.claimSuggestion(id: id, expectedRevision: expectedRevision)
    }
    func releaseApproval(_ claim: MioSuggestionApprovalClaim) throws { try core.releaseApproval(claim) }
    func completeApproval(_ claim: MioSuggestionApprovalClaim) throws { try core.completeApproval(claim) }
    func reconcileAcceptedContent(id: UUID) throws { try core.reconcileAcceptedContent(id: id) }
    func addSuggestion(_ suggestion: MioSuggestion) throws { try core.addSuggestion(suggestion) }
    @discardableResult
    func detectSuggestions(in session: MioSession, now: Date) throws -> Int {
        try core.detectSuggestions(in: session, now: now)
    }
    @discardableResult
    func applyAnalysis(_ result: MioAnalysisResult, request: MioAnalysisRequest, session: MioSession) throws -> Int {
        try core.applyAnalysis(result, request: request, session: session)
    }
    func markLessonPartUnprocessed(request: MioAnalysisRequest, session: MioSession) throws {
        try core.markLessonPartUnprocessed(request: request, session: session)
    }
    func deferSuggestion(id: UUID, now: Date) throws { try core.deferSuggestion(id: id, now: now) }
    /// A rejected proposal's text must not outlive the rejection in the legacy backup.
    func removeSuggestion(id: UUID) throws {
        try core.removeSuggestion(id: id)
        MioLegacyBackup.discardAfterDeletion()
    }
    func saveLesson(_ lesson: MioLesson, session: MioSession) throws { try core.saveLesson(lesson, session: session) }
    func deleteLesson(id: UUID) throws {
        try core.deleteLesson(id: id)
        MioLegacyBackup.discardAfterDeletion()
    }
    func deleteSessionData(sessionID: UUID) throws {
        try core.deleteSessionData(sessionID: sessionID)
        MioLegacyBackup.discardAfterDeletion()
    }
    func deleteAll(now: Date) throws {
        try core.deleteAll(now: now)
        try MioLegacyStoreFiles.standard.discardBackup()
    }
}

// MARK: - Migration target

@ModelActor
actor MioSwiftDataMigrationTarget: MioStoreMigrationTarget {
    /// Replaces every row in one transaction: a failure leaves the previous rows untouched.
    func replaceAll(with snapshot: MioLegacyStoreSnapshot) throws {
        let sessions = MioSwiftDataSessionStorage(context: modelContext)
        let content = MioSwiftDataContentStorage(context: modelContext)
        let assistant = MioSwiftDataAssistantStorage(context: modelContext)
        try MioSwiftDataWrite.commit(modelContext) {
            try sessions.stage(snapshot.sessions, replacing: nil)
            try content.stage(snapshot.content, replacing: nil)
            try assistant.stage(snapshot.assistant, replacing: nil)
        }
    }

    func removeAll() throws {
        try MioSwiftDataWrite.commit(modelContext) {
            try modelContext.delete(model: MioSessionRow.self)
            try modelContext.delete(model: MioSegmentRow.self)
            try modelContext.delete(model: MioCaptureGapRow.self)
            try modelContext.delete(model: MioContentItemRow.self)
            try modelContext.delete(model: MioSuggestionRow.self)
            try modelContext.delete(model: MioLessonRow.self)
            try modelContext.delete(model: MioAnalysisRow.self)
            try modelContext.delete(model: MioDecisionRow.self)
            try modelContext.delete(model: MioProcessedSourceRow.self)
        }
    }

    func counts() throws -> MioStoreCounts {
        var counts = MioStoreCounts()
        counts.sessions = try modelContext.fetchCount(FetchDescriptor<MioSessionRow>())
        counts.segments = try modelContext.fetchCount(FetchDescriptor<MioSegmentRow>())
        counts.captureGaps = try modelContext.fetchCount(FetchDescriptor<MioCaptureGapRow>())
        counts.contentItems = try modelContext.fetchCount(FetchDescriptor<MioContentItemRow>())
        counts.suggestions = try modelContext.fetchCount(FetchDescriptor<MioSuggestionRow>())
        counts.lessons = try modelContext.fetchCount(FetchDescriptor<MioLessonRow>())
        counts.analyses = try modelContext.fetchCount(FetchDescriptor<MioAnalysisRow>())
        counts.decisions = try modelContext.fetchCount(FetchDescriptor<MioDecisionRow>())
        counts.processedSources = try modelContext.fetchCount(FetchDescriptor<MioProcessedSourceRow>())
        return counts
    }
}
