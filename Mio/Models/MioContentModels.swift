import Foundation

enum MioContentKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case timeline
    case note
    case task
    case plan
    case memory

    var id: Self { self }

    var title: String {
        switch self {
        case .timeline: "Tidslinjepost"
        case .note: "Anteckning"
        case .task: "Uppgift"
        case .plan: "Plan"
        case .memory: "Uttryckligt minne"
        }
    }

    var symbolName: String {
        switch self {
        case .timeline: "clock"
        case .note: "note.text"
        case .task: "checkmark.circle"
        case .plan: "calendar"
        case .memory: "bookmark"
        }
    }
}

struct MioContentItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var kind: MioContentKind
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date
    /// The user-selected time shown in the timeline. It is not a system calendar event.
    var scheduledAt: Date
    var completedAt: Date?
    /// Optional relationship to a local transcription session. The transcript remains
    /// in the session store and is never duplicated into this item.
    var sessionID: UUID?
    /// A day without a clock time; `scheduledAt` is then the start of that day (2026-10-13).
    /// Absent in older items, which always had a time.
    var isAllDay: Bool?

    var allDay: Bool { isAllDay == true }

    init(
        id: UUID = UUID(),
        kind: MioContentKind,
        title: String,
        body: String = "",
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        scheduledAt: Date? = nil,
        completedAt: Date? = nil,
        sessionID: UUID? = nil,
        isAllDay: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.scheduledAt = scheduledAt ?? createdAt
        self.completedAt = kind == .task ? completedAt : nil
        self.sessionID = sessionID
        self.isAllDay = (kind == .task || kind == .plan) && isAllDay == true ? true : nil
    }

    var isCompleted: Bool {
        completedAt != nil
    }

    func matches(searchText: String) -> Bool {
        let query = Self.normalized(searchText)
        guard !query.isEmpty else { return true }
        let searchableText = Self.normalized("\(kind.title) \(title) \(body)")
        return searchableText.contains(query)
    }

    static func timelineSorted(_ items: [MioContentItem]) -> [MioContentItem] {
        items.sorted {
            if $0.scheduledAt != $1.scheduledAt {
                return $0.scheduledAt > $1.scheduledAt
            }
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "sv-SE")
            )
            .lowercased(with: Locale(identifier: "sv-SE"))
    }
}

struct MioContentStoreDocument: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var items: [MioContentItem]

    init(schemaVersion: Int = currentSchemaVersion, items: [MioContentItem]) {
        self.schemaVersion = schemaVersion
        self.items = items
    }
}

struct MioLocalExport: Codable, Sendable {
    let schemaVersion: Int
    let exportedAt: Date
    let content: [MioContentItem]
    let sessions: [MioSession]
    /// Added in export schema 2; absent when decoding an older export.
    let assistant: MioAssistantStoreDocument?
    /// Additive in schema 2; available even without a session.
    let diagnostics: MioDiagnosticsExport?

    init(
        schemaVersion: Int = 2,
        exportedAt: Date = .now,
        content: [MioContentItem],
        sessions: [MioSession],
        assistant: MioAssistantStoreDocument? = nil,
        diagnostics: MioDiagnosticsExport? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.content = content
        self.sessions = sessions
        self.assistant = assistant
        self.diagnostics = diagnostics
    }
}
