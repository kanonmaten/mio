import Foundation

enum MioRunState: String, Codable, Sendable {
    case off
    case preparing
    case stopping
    case listening
    case interrupted
    case paused
    case unavailable
    case failed

    var title: String {
        switch self {
        case .off: "Mio är av"
        case .preparing: "Mio förbereder sig"
        case .stopping: "Mio stänger mikrofonen"
        case .listening: "Mio lyssnar"
        case .interrupted: "Mio är tillfälligt avbruten"
        case .paused: "Mio är pausad"
        case .unavailable: "Servern behöver konfigureras"
        case .failed: "Mio behöver hjälp"
        }
    }
}

enum MicrophonePermission: String, Codable, Sendable {
    case notDetermined
    case granted
    case denied
    case restricted

    var title: String {
        switch self {
        case .notDetermined: "Inte frågat ännu"
        case .granted: "Tillåten"
        case .denied: "Nekad"
        case .restricted: "Begränsad"
        }
    }
}

struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// Canonical segment timestamp derived from the source-audio interval, not callback time.
    let createdAt: Date
    let audioStartedAt: Date
    let audioEndedAt: Date
    let text: String
    /// Optional user correction. The original transcript and its evidence fields stay intact.
    var correctedText: String?
    let containsMio: Bool
    /// True only when usable source audio overlapped an app-background interval.
    /// The time at which the recognition callback arrived is irrelevant.
    let wasObservedInBackground: Bool
    /// True when the validated result range was finite and nonnegative. This alone is not
    /// evidence that audio was captured while the app was in the background.
    let audioTimingIsValid: Bool
    var transcriptionMetadata: TranscriptionMetadata? = nil
    var sourceChunkID: UUID? = nil
    var timingValidity: AudioTimingValidity? = nil
    var correctionRevision: Int? = nil
    /// Server speaker number (1–4) for this turn; nil in older data or without labels.
    /// Part of the original evidence; display names live in `MioSession.speakerNames`.
    var speaker: Int? = nil

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        audioStartedAt: Date? = nil,
        audioEndedAt: Date? = nil,
        text: String,
        correctedText: String? = nil,
        containsMio: Bool,
        wasObservedInBackground: Bool = false,
        audioTimingIsValid: Bool = true
    ) {
        self.id = id
        self.createdAt = createdAt
        self.audioStartedAt = audioStartedAt ?? createdAt
        self.audioEndedAt = audioEndedAt ?? audioStartedAt ?? createdAt
        self.text = text
        self.correctedText = correctedText
        self.containsMio = containsMio
        self.wasObservedInBackground = wasObservedInBackground
        self.audioTimingIsValid = audioTimingIsValid
    }

    var displayText: String {
        let correction = correctedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let correction, !correction.isEmpty {
            return correction
        }
        return text
    }
}

struct BackgroundInterval: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?

    init(id: UUID = UUID(), startedAt: Date = .now, endedAt: Date? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    func overlaps(audioStart: Date, audioEnd: Date, now: Date = .now) -> Bool {
        let intervalEnd = endedAt ?? now
        return audioEnd >= startedAt && audioStart <= intervalEnd
    }
}

enum DiagnosticEventKind: String, Codable, Sendable {
    case info
    case lifecycle
    case interruption
    case routeChange
    case wakeWord
    case warning
    case error
}

struct DiagnosticEvent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let kind: DiagnosticEventKind
    let message: String

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        kind: DiagnosticEventKind,
        message: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.message = message
    }
}

enum BatteryStateName: String, Codable, Sendable {
    case unknown
    case unplugged
    case charging
    case full
}

struct BatteryReading: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    /// A value from 0 through 1. A negative value means that iOS didn't report a level.
    let level: Float
    let state: BatteryStateName

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        level: Float,
        state: BatteryStateName
    ) {
        self.id = id
        self.createdAt = createdAt
        self.level = level
        self.state = state
    }

    var percentageText: String {
        guard level >= 0 else { return "Okänd" }
        return "\(Int((level * 100).rounded())) %"
    }
}

struct MioSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var transcripts: [TranscriptSegment]
    var events: [DiagnosticEvent]
    var batteryReadings: [BatteryReading]
    var backgroundIntervals: [BackgroundInterval]
    /// Optional session metadata. Missing keys decode as nil for legacy files.
    var title: String?
    var manualNote: String?
    var captureMode: MioCaptureMode?
    var captureGaps: [CaptureGap]? = nil
    /// Ordering for repository mutations; absent in older sessions.
    var mutationRevision: UInt64? = nil
    /// Display-only speaker names keyed by speaker number; segments are never rewritten.
    var speakerNames: [Int: String]? = nil

    var isLesson: Bool { captureMode == .lesson }

    func speakerName(for speaker: Int) -> String {
        MioSpeakerLabel.displayName(for: speaker, names: speakerNames)
    }

    /// The speaker label to show above a segment: only where the speaker changes.
    func speakerLabel(at index: Int) -> String? {
        guard transcripts.indices.contains(index), let speaker = transcripts[index].speaker else { return nil }
        if index > 0, transcripts[index - 1].speaker == speaker { return nil }
        return speakerName(for: speaker)
    }

    init(
        id: UUID = UUID(),
        startedAt: Date = .now,
        endedAt: Date? = nil,
        transcripts: [TranscriptSegment] = [],
        events: [DiagnosticEvent] = [],
        batteryReadings: [BatteryReading] = [],
        backgroundIntervals: [BackgroundInterval] = [],
        title: String? = nil,
        manualNote: String? = nil,
        captureMode: MioCaptureMode? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcripts = transcripts
        self.events = events
        self.batteryReadings = batteryReadings
        self.backgroundIntervals = backgroundIntervals
        self.title = title
        self.manualNote = manualNote
        self.captureMode = captureMode
    }

    var mioDetectionCount: Int {
        transcripts.filter(\.containsMio).count
    }

    var interruptionCount: Int {
        events.filter { $0.kind == .interruption }.count
    }

    var validBatteryReadings: [BatteryReading] {
        batteryReadings.filter { $0.level >= 0 }
    }

    /// Positive means the battery level fell during the session.
    var batteryDrop: Float? {
        guard
            let first = validBatteryReadings.first?.level,
            let last = validBatteryReadings.last?.level
        else { return nil }
        return first - last
    }

    func duration(at now: Date = .now) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    func matches(searchText: String) -> Bool {
        let query = Self.normalized(searchText)
        guard !query.isEmpty else { return true }
        let transcriptText = transcripts.map(\.displayText).joined(separator: " ")
        let searchableText = Self.normalized(
            "\(title ?? "") \(manualNote ?? "") \(transcriptText)"
        )
        return searchableText.contains(query)
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

/// One register retains active, suspended and ended sessions when selection changes.
struct MioSessionRegister {
    var sessions: [MioSession] = []
    private var selectedID: UUID?

    var current: MioSession? {
        get { sessions.first { $0.id == selectedID } }
        set {
            selectedID = newValue?.id
            if let newValue { replace(newValue) }
        }
    }

    /// Live capture replaces the selected session for every segment, event and battery
    /// sample; an unchanged start time keeps its position without re-sorting the history.
    mutating func replace(_ session: MioSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            guard (session.mutationRevision ?? 0) >= (sessions[index].mutationRevision ?? 0) else { return }
            if sessions[index].startedAt == session.startedAt {
                sessions[index] = session
                return
            }
            sessions.remove(at: index)
        }
        sessions.insert(session, at: insertionIndex(for: session))
    }

    /// Sessions stay ordered newest first.
    private func insertionIndex(for session: MioSession) -> Int {
        sessions.firstIndex { $0.startedAt <= session.startedAt } ?? sessions.endIndex
    }

    mutating func remove(id: UUID) {
        sessions.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }
}

protocol MioCapturePipeline: AnyObject, Sendable {
    func start() async throws -> CaptureStartDetails
    func foreground() async
    func stop(discard: Bool) async
}

extension MioCapturePipeline {
    func stop() async { await stop(discard: false) }
}

struct MioCaptureHandlers: Sendable {
    let result: @Sendable (AudioChunk, TranscriptionReply, [TranscriptionWord]) async -> Void
    let status: @Sendable (String) -> Void
    let event: @Sendable (PipelineEvent) async -> Void
    let failure: @Sendable (Error) async -> Void
    var diagnostic: @Sendable (STTDiagnostic) async -> Void = { _ in }
}

enum PauseLength: Sendable {
    case thirtyMinutes
    case oneHour
    case untilResumed

    var interval: TimeInterval? {
        switch self {
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .untilResumed: nil
        }
    }

    var title: String {
        switch self {
        case .thirtyMinutes: "30 minuter"
        case .oneHour: "1 timme"
        case .untilResumed: "Tills jag startar igen"
        }
    }
}

enum PipelineEvent: Sendable {
    case connection(TranscriptionConnectionState, TranscriptionMetadata?)
    case captureGap(CaptureGap)
    case needsResume(String)
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(String)
    case mediaServicesReset
    /// The capture tried to restart the microphone by itself and iOS refused (for example
    /// because the app is in the background). The engine stays down and the gap stays open.
    case restartFailed(String)
}

/// Speaker labels are session-local numbers from the PC, never identities.
enum MioSpeakerLabel {
    static let range = 1...4
    static let maximumNameLength = 40

    static func defaultName(_ speaker: Int) -> String { "Talare \(speaker)" }

    static func displayName(for speaker: Int, names: [Int: String]?) -> String {
        names?[speaker] ?? defaultName(speaker)
    }

    /// A blank name, or the default label itself, removes the custom name.
    static func renamed(_ names: [Int: String]?, speaker: Int, to name: String) -> [Int: String]? {
        guard range.contains(speaker) else { return names }
        var result = names ?? [:]
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).joined(separator: " ")
            .prefix(maximumNameLength))
        if clean.isEmpty || clean == defaultName(speaker) {
            result[speaker] = nil
        } else {
            result[speaker] = clean
        }
        return result.isEmpty ? nil : result
    }
}

/// When Mio restarts the microphone by itself (user decision 2026-10-11, replacing the
/// 2026-09-29 rule). A pause or stop by the user always wins: the capture then no longer exists.
enum MioCaptureResumePolicy {
    enum Decision: Equatable, Sendable {
        /// Nothing to do: the user is not listening, or the interruption is still ongoing.
        case none
        /// Reactivate the audio session and restart the engine now.
        case restart
        /// iOS refused in the background: ask with a local notification and retry on foreground.
        case notifyUser
        /// iOS refused while Mio is on screen: pause visibly and let the user press Fortsätt.
        case askInApp
    }

    static func decision(userWantsListening: Bool, interruptionOngoing: Bool,
                         restartFailed: Bool, appIsActive: Bool) -> Decision {
        guard userWantsListening, !interruptionOngoing else { return .none }
        guard restartFailed else { return .restart }
        return appIsActive ? .askInApp : .notifyUser
    }

    /// Bounds automatic restarts so a route or configuration loop falls back to the user.
    static func allowsAutomaticRestart(previous: [TimeInterval], now: TimeInterval,
                                       limit: Int = 3, window: TimeInterval = 60) -> Bool {
        previous.filter { now - $0 < window }.count < limit
    }
}

/// Local notification requests for the resume fallback; text only, no transcript content.
enum MioResumeNotice: Equatable, Sendable {
    /// Ask for notification permission while the user is starting Mio on screen.
    case prepare
    /// Post "Tryck för att fortsätta lyssna".
    case post
    /// Remove a delivered notification after listening resumed or ended.
    case withdraw
}

enum MioError: LocalizedError {
    case microphoneDenied
    case invalidAudioStream
    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Mikrofonen är inte tillåten. Öppna iPhones inställningar och slå på mikrofonen för Mio."
        case .invalidAudioStream:
            "Mikrofonen levererar inte ljud. Kontrollera ljudvägen och tryck Fortsätt."
        }
    }
}
