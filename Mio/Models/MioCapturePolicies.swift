import Foundation

/// Why Mio paused everyday capture by itself. Shown on Fånga until she starts again.
enum MioAutomaticPause: Equatable, Sendable {
    case lowBattery
    case lowPowerMode
    case silence

    var message: String {
        switch self {
        case .lowBattery: "Mio pausade eftersom batteriet är under 20 %. Tryck Fortsätt för att lyssna ändå."
        case .lowPowerMode: "Mio pausade eftersom strömsparläge är på. Tryck Fortsätt för att lyssna ändå."
        case .silence: "Mio pausade efter 25 minuter utan tal. Tryck Fortsätt när du vill lyssna igen."
        }
    }

    /// The listening bar's word, so the reason shows on every tab.
    var shortTitle: String {
        switch self {
        case .lowBattery: "Pausad, lågt batteri"
        case .lowPowerMode: "Pausad, strömsparläge"
        case .silence: "Pausad, tyst länge"
        }
    }

    /// Text-free line for the session's event log.
    var eventMessage: String {
        switch self {
        case .lowBattery: "Vardags-Mio pausades automatiskt: batteriet under 20 %. Mikrofonen stängdes av."
        case .lowPowerMode: "Vardags-Mio pausades automatiskt: strömsparläge. Mikrofonen stängdes av."
        case .silence: "Vardags-Mio pausades automatiskt efter lång tystnad. Mikrofonen stängdes av."
        }
    }
}

/// A plain reading of the phone's battery; `level` is nil when iOS does not know it.
struct MioBatteryStatus: Equatable, Sendable {
    var level: Float?
    /// Plugged in, charging or full.
    var isCharging: Bool
    var lowPowerMode: Bool

    static let unknown = MioBatteryStatus(level: nil, isCharging: false, lowPowerMode: false)
}

/// Battery rule for everyday capture (user decision 2026-11-19): below 20 % or in Low Power
/// Mode, everyday capture pauses and says why. While plugged in nothing pauses, since the
/// battery is not draining.
///
/// A lesson is never paused by the battery, also not when the level drops or Low Power Mode is
/// turned on in the middle of it. After the lesson the everyday rule applies again.
///
/// "She can start again right away": when she starts everyday capture herself while the rule
/// would pause it, Mio does not pause again for that low battery. The exception lasts until
/// the condition has cleared (20 % or more with Low Power Mode off, or charging); a later drop
/// pauses again.
struct MioBatteryGuard: Sendable {
    static let threshold: Float = 0.20

    private(set) var userOverride = false

    static func reason(for status: MioBatteryStatus) -> MioAutomaticPause? {
        guard !status.isCharging else { return nil }
        if status.lowPowerMode { return .lowPowerMode }
        if let level = status.level, level < threshold { return .lowBattery }
        return nil
    }

    /// Call when she starts or resumes everyday capture herself (never for a lesson).
    mutating func userStartedEveryday(with status: MioBatteryStatus) {
        userOverride = Self.reason(for: status) != nil
    }

    /// The reason to pause now, or nil. Must be called on every check, also while not
    /// listening, so that a cleared condition ends her exception.
    mutating func evaluate(_ status: MioBatteryStatus, isLesson: Bool, isListening: Bool) -> MioAutomaticPause? {
        guard let reason = Self.reason(for: status) else {
            userOverride = false
            return nil
        }
        guard !isLesson, isListening, !userOverride else { return nil }
        return reason
    }
}

/// What the silence check wants done now.
enum MioSilenceAction: Equatable, Sendable {
    case none
    /// Post "Lyssnar Mio fortfarande?".
    case ask
    case pause
}

/// Notification Mio posts or removes for the silence check.
enum MioSilenceNotice: Equatable, Sendable {
    case post
    case withdraw
}

/// Long silence during everyday capture (user decision 2026-11-19): after 20 minutes without
/// speech Mio asks "Lyssnar Mio fortfarande?"; without an answer within five minutes it pauses.
/// The same timing holds when notifications are not allowed (the question is then never shown),
/// so Mio pauses after 25 minutes either way. Ja resets the clock without restarting the
/// microphone. A pause from here never restarts by itself (existing rule). Lessons are exempt.
struct MioSilenceWatch: Sendable {
    static let askAfter: TimeInterval = 20 * 60
    static let answerWithin: TimeInterval = 5 * 60

    private(set) var lastSpeechAt: Date?
    private(set) var askedAt: Date?

    /// Speech arrived, listening (re)started or she answered Ja.
    mutating func reset(at date: Date) {
        lastSpeechAt = date
        askedAt = nil
    }

    mutating func evaluate(now: Date) -> MioSilenceAction {
        guard let lastSpeechAt else {
            reset(at: now)
            return .none
        }
        if let askedAt {
            return now.timeIntervalSince(askedAt) >= Self.answerWithin ? .pause : .none
        }
        guard now.timeIntervalSince(lastSpeechAt) >= Self.askAfter else { return .none }
        askedAt = now
        return .ask
    }
}

/// Everyday transcripts are kept for 30 days (user decision 2026-11-19). An ended everyday
/// session whose end is more than 30 days ago is deleted at launch and when the app goes to the
/// background, through the ordinary session deletion (journal, its proposals and analyses).
/// Lessons are kept, and so is an everyday session that was divided into lessons. Approved
/// proposals and notes live in the content store and are only unlinked from the session, so
/// they stay. A session that is still open is never touched.
enum MioRetentionPolicy {
    static let everydayDays = 30

    static func expiredEverydaySessionIDs(_ sessions: [MioSession], lessonSessionIDs: Set<UUID>, now: Date,
                                          calendar: Calendar = .current) -> [UUID] {
        guard let cutoff = calendar.date(byAdding: .day, value: -everydayDays, to: now) else { return [] }
        return sessions
            .filter { session in
                guard !session.isLesson, let ended = session.endedAt else { return false }
                return ended < cutoff && !lessonSessionIDs.contains(session.id)
            }
            .sorted { ($0.endedAt ?? $0.startedAt) < ($1.endedAt ?? $1.startedAt) }
            .map(\.id)
    }
}
