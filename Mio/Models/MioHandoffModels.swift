import Foundation

/// Where an approved proposal was handed over (user decision 2026-10-13, version 0.9.1).
/// Apple's apps own the item from then on; Mio keeps only this record.
enum MioHandoffDestination: String, Codable, Hashable, Sendable {
    case calendar
    case reminders
    /// The share sheet's Notes extension.
    case notes
    /// The share sheet reported another app; its bundle identifier is not stored.
    case otherApp

    var title: String {
        switch self {
        case .calendar: "Kalender"
        case .reminders: "Påminnelser"
        case .notes: "Anteckningar"
        case .otherApp: "Annan app"
        }
    }

    var symbolName: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .notes: "note.text"
        case .otherApp: "square.and.arrow.up"
        }
    }
}

/// The only trace of a handed-over item: no text, no date and no status. Apple's app is the
/// single source for those.
struct MioHandoff: Codable, Hashable, Sendable {
    var destination: MioHandoffDestination
    /// `calendarItemIdentifier` of a reminder Mio created. Nil for the calendar editor and the
    /// share sheet, which do not report one.
    var externalIdentifier: String?
    var sentAt: Date
}

/// A reminder exactly as the user approved it in Mio's review.
struct MioReminderDraft: Equatable, Sendable {
    var title: String
    var notes: String
    /// Link back to the session; also identifies the reminder so a retry never duplicates it.
    var url: URL?
    /// Nil means no due date, like a plain line in Reminders.
    var dueDate: Date?
    /// A due date with a clock time also gets an alert at that time.
    var hasTime: Bool
    /// Nil means the default list.
    var listID: String?
}

struct MioReminderList: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

enum MioReminderAccess: Equatable, Sendable {
    case notDetermined
    case denied
    case granted
}

/// An upcoming, unfinished reminder shown on Hem. Read on demand, never stored.
struct MioReminderSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let dueDate: Date?
    let hasTime: Bool
}

enum MioReminderError: Error, LocalizedError, Equatable {
    case accessDenied
    case unavailable
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied: MioReminderPort.deniedMessage
        case .unavailable: "Påminnelser är inte tillgängligt på den här enheten."
        case .saveFailed: "Påminnelsen kunde inte sparas. Förslaget ligger kvar."
        }
    }
}

/// Reminders through EventKit. Apple offers no write-only access for reminders, so Mio asks for
/// full access once; calendar events go through Apple's own editor and need no access at all.
@MainActor
struct MioReminderPort {
    static let deniedMessage = "Mio har inte åtkomst till Påminnelser. Tillåt det i Inställningar → Mio → Påminnelser. Förslaget ligger kvar."
    static let lastListKey = "mio.reminders.lastListID"

    var access: @MainActor () -> MioReminderAccess
    var requestAccess: @MainActor () async -> Bool
    var lists: @MainActor () -> [MioReminderList]
    var defaultListID: @MainActor () -> String?
    /// Creates the reminder, or returns the identifier of one already created for the same URL.
    var save: @MainActor (MioReminderDraft) async throws -> String
    /// Unfinished reminders due in the interval, plus overdue ones, for Hem.
    var upcoming: @MainActor (DateInterval) async -> [MioReminderSummary]

    static var native: Self {
        #if canImport(EventKit) && os(iOS)
        let store = MioReminderStore.shared
        return Self(access: { store.access }, requestAccess: { await store.requestAccess() },
                    lists: { store.lists() }, defaultListID: { store.defaultListID() },
                    save: { try await store.save($0) }, upcoming: { await store.upcoming(in: $0) })
        #else
        return unavailable
        #endif
    }

    static var unavailable: Self {
        Self(access: { .denied }, requestAccess: { false }, lists: { [] }, defaultListID: { nil },
             save: { _ in throw MioReminderError.unavailable }, upcoming: { _ in [] })
    }
}

/// `mio://session/<UUID>?forslag=<UUID>`: opens a session; the proposal ID makes the link unique
/// per handed-over item. Treated like a notification route: only UUIDs, never starts capture or AI.
enum MioLink {
    static let scheme = "mio"

    static func session(_ sessionID: UUID, proposal: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "session"
        components.path = "/" + sessionID.uuidString
        components.queryItems = [URLQueryItem(name: "forslag", value: proposal.uuidString)]
        return components.url
    }

    /// For a proposal without a session (typed by hand): still unique, opens Mio's Förslag.
    static func proposal(_ proposal: UUID) -> URL? {
        URL(string: "\(scheme)://forslag/\(proposal.uuidString)")
    }

    /// The session to open, or nil for anything that is not exactly a Mio session link.
    static func sessionID(from url: URL) -> UUID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme, components.host == "session", components.user == nil,
              components.password == nil, components.port == nil, components.fragment == nil else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].isEmpty, let id = UUID(uuidString: String(parts[1])) else { return nil }
        let query = components.queryItems ?? []
        guard query.allSatisfy({ $0.name == "forslag" && $0.value.flatMap(UUID.init(uuidString:)) != nil }),
              query.count <= 1 else { return nil }
        return id
    }
}
