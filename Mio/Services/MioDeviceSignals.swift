import AudioToolbox
import CoreHaptics
import Foundation
import UIKit

/// iOS-only readers and players behind the portable rules in `MioCapturePolicies` and
/// `MioDirectCommands`. No decisions are made here.
@MainActor
enum MioDeviceSignals {
    /// Battery monitoring is switched on by `MioViewModel`. Plugged in or full counts as charging.
    static func batteryStatus() -> MioBatteryStatus {
        let device = UIDevice.current
        return MioBatteryStatus(level: device.batteryLevel >= 0 ? device.batteryLevel : nil,
                                isCharging: device.batteryState == .charging || device.batteryState == .full,
                                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

/// Two short vibrations for saved, one long for not understood, only after direct address.
/// Respects the "Diskreta vibrationer" setting. On screen Core Haptics plays the pattern; in the
/// background (phone in a pocket, microphone running) iOS does not run Core Haptics, so the
/// system vibration is used instead: twice for saved, once for not understood. The capture
/// session allows haptics during recording (`setAllowHapticsAndSystemSoundsDuringRecording`).
@MainActor
enum MioDirectHaptics {
    private static var engine: CHHapticEngine?

    static func play(_ feedback: MioDirectFeedback) {
        guard UserDefaults.standard.object(forKey: "mio.feedback.haptics") as? Bool != false else { return }
        if UIApplication.shared.applicationState == .active, playPattern(feedback) { return }
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        guard feedback == .saved else { return }
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    private static func playPattern(_ feedback: MioDirectFeedback) -> Bool {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return false }
        do {
            let active = try engine ?? makeEngine()
            try active.start()
            let sharp = [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                         CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)]
            let events: [CHHapticEvent] = switch feedback {
            case .saved:
                [CHHapticEvent(eventType: .hapticTransient, parameters: sharp, relativeTime: 0),
                 CHHapticEvent(eventType: .hapticTransient, parameters: sharp, relativeTime: 0.18)]
            case .notUnderstood:
                [CHHapticEvent(eventType: .hapticContinuous, parameters: sharp, relativeTime: 0, duration: 0.6)]
            }
            try active.makePlayer(with: CHHapticPattern(events: events, parameters: [])).start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            engine = nil
            return false
        }
    }

    private static func makeEngine() throws -> CHHapticEngine {
        let created = try CHHapticEngine()
        created.playsHapticsOnly = true
        // iOS stops the engine when the app leaves the screen; the next call creates a new one.
        created.stoppedHandler = { _ in Task { @MainActor in MioDirectHaptics.engine = nil } }
        created.resetHandler = { Task { @MainActor in MioDirectHaptics.engine = nil } }
        engine = created
        return created
    }
}
