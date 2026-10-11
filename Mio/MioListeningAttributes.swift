import ActivityKit
import AppIntents
import Foundation

// Compiled into both the app and the MioWidgets extension. Nothing here may touch the
// app's capture types; the app installs MioListeningControl.handler at launch.

struct MioListeningAttributes: ActivityAttributes {
    typealias ContentState = MioListeningActivityState

    var sessionID: UUID
    var isLesson: Bool
}

enum MioListeningCommand: Sendable {
    case pause
    case resume
    case stop
}

/// LiveActivityIntent runs perform() in the app process, so only the app's handler is
/// ever called; the extension compiles the intents for its buttons but never runs them.
@MainActor
enum MioListeningControl {
    static var handler: (@MainActor (MioListeningCommand) async -> Void)?

    static func perform(_ command: MioListeningCommand) async {
        await handler?(command)
    }
}

struct MioPauseListeningIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pausa Mio"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await MioListeningControl.perform(.pause)
        return .result()
    }
}

struct MioResumeListeningIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Fortsätt Mio"
    static let isDiscoverable = false
    // iOS does not let a background app start microphone capture, so resuming opens Mio.
    static let supportedModes: IntentModes = .foreground(.immediate)

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await MioListeningControl.perform(.resume)
        return .result()
    }
}

struct MioStopListeningIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stoppa Mio"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await MioListeningControl.perform(.stop)
        return .result()
    }
}
