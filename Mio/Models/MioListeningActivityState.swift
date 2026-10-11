import Foundation

/// Content state of the listening Live Activity. Compiled into both the app and the
/// MioWidgets extension, so it must stay Foundation-only. It carries no transcript text:
/// the Lock Screen shows only the phase, a system-rendered timer and the gap count.
struct MioListeningActivityState: Codable, Hashable, Sendable {
    enum Phase: String, Codable, Hashable, Sendable {
        case listening
        case interrupted
        case paused
    }

    var phase: Phase
    /// The session start; the system timer counts from here without app updates.
    var startedAt: Date
    /// Freezes the timer while paused.
    var pausedAt: Date?
    var gapCount: Int

    var isPaused: Bool { phase == .paused }

    var title: String {
        switch phase {
        case .listening: "Lyssnar"
        case .interrupted: "Avbrott"
        case .paused: "Pausad"
        }
    }

    var symbolName: String {
        switch phase {
        case .listening: "waveform"
        case .interrupted: "exclamationmark.triangle"
        case .paused: "pause.circle"
        }
    }

    var gapText: String? {
        if gapCount < 1 { return nil }
        return gapCount == 1 ? "1 avbrott i ljudet" : "\(gapCount) avbrott i ljudet"
    }
}
