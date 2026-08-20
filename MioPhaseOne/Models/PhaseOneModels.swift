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
        case .unavailable: "Talstödet saknas"
        case .failed: "Testet avbröts"
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

struct SpeechSupportSnapshot: Sendable {
    var checkedAt: Date?
    var microphonePermission: MicrophonePermission = .notDetermined
    var speechTranscriberAvailable: Bool?
    var swedishLocaleIdentifier: String?
    var swedishModelInstalled: Bool?
    var dictationLocaleIdentifier: String?
    var dictationModelInstalled: Bool?
    var selectedEngine: LocalSpeechEngine?
    var details = "Kontrollerar telefonens stöd …"

    var swedishSupported: Bool? {
        guard checkedAt != nil else { return nil }
        return swedishLocaleIdentifier != nil || dictationLocaleIdentifier != nil
    }
}

enum LocalSpeechEngine: String, Codable, Sendable {
    case speechTranscriber
    case dictationTranscriber

    var title: String {
        switch self {
        case .speechTranscriber: "SpeechTranscriber (avancerad)"
        case .dictationTranscriber: "DictationTranscriber (lokal reservmotor)"
        }
    }
}

struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let audioStartedAt: Date
    let audioEndedAt: Date
    let text: String
    let containsMio: Bool
    let wasObservedInBackground: Bool
    let audioTimingIsValid: Bool

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        audioStartedAt: Date? = nil,
        audioEndedAt: Date? = nil,
        text: String,
        containsMio: Bool,
        wasObservedInBackground: Bool = false,
        audioTimingIsValid: Bool = true
    ) {
        self.id = id
        self.createdAt = createdAt
        self.audioStartedAt = audioStartedAt ?? createdAt
        self.audioEndedAt = audioEndedAt ?? audioStartedAt ?? createdAt
        self.text = text
        self.containsMio = containsMio
        self.wasObservedInBackground = wasObservedInBackground
        self.audioTimingIsValid = audioTimingIsValid
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

struct PhaseOneSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var transcripts: [TranscriptSegment]
    var events: [DiagnosticEvent]
    var batteryReadings: [BatteryReading]
    var backgroundIntervals: [BackgroundInterval]

    init(
        id: UUID = UUID(),
        startedAt: Date = .now,
        endedAt: Date? = nil,
        transcripts: [TranscriptSegment] = [],
        events: [DiagnosticEvent] = [],
        batteryReadings: [BatteryReading] = [],
        backgroundIntervals: [BackgroundInterval] = []
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcripts = transcripts
        self.events = events
        self.batteryReadings = batteryReadings
        self.backgroundIntervals = backgroundIntervals
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
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(String)
    case audioBuffersDropped(Int)
    case backendFallback(String)
    case mediaServicesReset
}

enum MioPhaseOneError: LocalizedError {
    case microphoneDenied
    case speechTranscriberUnavailable
    case swedishUnavailable
    case missingAudioFormat
    case invalidAudioStream

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Mikrofonen är inte tillåten. Öppna Inställningar > Integritet och säkerhet > Mikrofon och slå på Mio."
        case .speechTranscriberUnavailable:
            "Apples SpeechTranscriber finns inte på den här telefonen. Det är ett viktigt resultat från fas 1."
        case .swedishUnavailable:
            "Apples lokala talmotor erbjuder inte svenska på den här telefonen."
        case .missingAudioFormat:
            "iOS kunde inte hitta ett ljudformat som den svenska talmodellen kan använda."
        case .invalidAudioStream:
            "Ljudströmmen kunde inte kopplas till talmotorn."
        }
    }
}
