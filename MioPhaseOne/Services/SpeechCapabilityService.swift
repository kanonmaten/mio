import AVFoundation
import Speech

enum SpeechCapabilityService {
    static let requestedLocale = Locale(identifier: "sv-SE")

    static func inspect() async -> SpeechSupportSnapshot {
        var snapshot = SpeechSupportSnapshot()
        snapshot.microphonePermission = microphonePermission
        snapshot.speechTranscriberAvailable = SpeechTranscriber.isAvailable

        if SpeechTranscriber.isAvailable,
           let speechLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            snapshot.swedishLocaleIdentifier = speechLocale.identifier
            let installedLocales = await SpeechTranscriber.installedLocales
            snapshot.swedishModelInstalled = installedLocales.contains { locale in
                locale.identifier(.bcp47) == speechLocale.identifier(.bcp47)
            }
            snapshot.selectedEngine = .speechTranscriber
        }

        if let dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            snapshot.dictationLocaleIdentifier = dictationLocale.identifier
            let installedLocales = await DictationTranscriber.installedLocales
            snapshot.dictationModelInstalled = installedLocales.contains { locale in
                locale.identifier(.bcp47) == dictationLocale.identifier(.bcp47)
            }
            if snapshot.selectedEngine == nil {
                snapshot.selectedEngine = .dictationTranscriber
            }
        }

        snapshot.checkedAt = .now
        switch snapshot.selectedEngine {
        case .speechTranscriber:
            snapshot.details = snapshot.swedishModelInstalled == true
                ? "Svenska stöds av Apples avancerade lokala talmotor och modellen är installerad."
                : "Svenska stöds av Apples avancerade lokala talmotor. Modellen hämtas vid start."
        case .dictationTranscriber:
            snapshot.details = snapshot.dictationModelInstalled == true
                ? "Svenska stöds via Apples lokala dikteringsmotor och modellen är installerad."
                : "Svenska stöds via Apples lokala dikteringsmotor. Modellen hämtas vid start."
        case nil:
            snapshot.details = "Varken SpeechTranscriber eller DictationTranscriber erbjuder svenska på telefonen."
        }
        return snapshot
    }

    static var microphonePermission: MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }

    static func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }
}
