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
            let module = SpeechTranscriber(
                locale: speechLocale,
                preset: .timeIndexedProgressiveTranscription
            )
            let state = await assetState(for: [module])
            snapshot.advancedAssetStatus = state
            snapshot.swedishModelInstalled = state == .installed
            let reservedLocales = await AssetInventory.reservedLocales
            snapshot.advancedLocaleReserved = reservedLocales.contains { locale in
                locale.identifier(.bcp47) == speechLocale.identifier(.bcp47)
            }
            if shouldUseSpeechTranscriber(assetState: state) {
                snapshot.selectedEngine = .speechTranscriber
            }
        }

        if let dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            snapshot.dictationLocaleIdentifier = dictationLocale.identifier
            let module = makeResponsiveLongDictation(locale: dictationLocale)
            let state = await assetState(for: [module])
            snapshot.dictationAssetStatus = state
            snapshot.dictationModelInstalled = state == .installed
            if snapshot.selectedEngine == nil, state != .unsupported {
                snapshot.selectedEngine = .dictationTranscriber
            }
        }

        snapshot.checkedAt = .now
        switch snapshot.selectedEngine {
        case .speechTranscriber:
            snapshot.details = snapshot.swedishModelInstalled == true
                ? "SpeechAnalyzer använder SpeechTranscriber för svenska. Den nyare lokala modellasseten är installerad."
                : "SpeechTranscriber stöder svenska. Modellassetens status är \(snapshot.advancedAssetStatus?.title.lowercased() ?? "okänd")."
        case .dictationTranscriber:
            if snapshot.speechTranscriberAvailable == false {
                snapshot.details = "DictationTranscriber används. iOS anger att den nyare SpeechTranscriber-modulen inte är tillgänglig på enheten."
            } else if snapshot.swedishLocaleIdentifier == nil {
                snapshot.details = "DictationTranscriber används. SpeechTranscriber finns, men iOS erbjuder inte svenska för den på denna enhet. Det är inte samma sak som att en svensk modell bara saknar installation."
            } else if snapshot.swedishLocaleIdentifier != nil,
               snapshot.advancedAssetStatus != .installed {
                snapshot.details = "SpeechAnalyzer använder DictationTranscriber som fallback. SpeechTranscriber-asset: \(snapshot.advancedAssetStatus?.title.lowercased() ?? "okänd status")."
            } else {
                snapshot.details = snapshot.dictationModelInstalled == true
                    ? "SpeechAnalyzer använder DictationTranscriber för svenska och dess lokala modellasset är installerad."
                    : "DictationTranscriber stöder svenska. Modellassetens status är \(snapshot.dictationAssetStatus?.title.lowercased() ?? "okänd")."
            }
        case nil:
            snapshot.details = "Varken SpeechTranscriber eller DictationTranscriber erbjuder svenska på telefonen."
        }
        return snapshot
    }

    static func installAdvancedSwedishModel(
        status: @escaping (String) -> Void
    ) async throws -> Bool {
        guard SpeechTranscriber.isAvailable else {
            throw MioError.speechTranscriberUnavailable
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw MioError.swedishUnavailable
        }
        let module = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        return try await ensureAssets(
            for: [module],
            locale: locale,
            engineTitle: LocalSpeechEngine.speechTranscriber.title,
            status: status
        )
    }

    static func ensureAssets(
        for modules: [any SpeechModule],
        locale: Locale,
        engineTitle: String,
        status: @escaping (String) -> Void
    ) async throws -> Bool {
        let initialState = await assetState(for: modules)
        switch initialState {
        case .installed:
            return false
        case .unsupported:
            throw MioError.speechAssetUnsupported(engineTitle)
        case .downloading:
            status("iOS fortsätter hämta modellasseten för \(engineTitle), \(locale.identifier) …")
        case .supported:
            status("Reserverar modellasseten för \(engineTitle) på telefonen …")
        }

        // Although the installation request normally reserves a locale automatically,
        // doing it explicitly avoids starting an analyzer with an unallocated locale.
        _ = try await AssetInventory.reserve(locale: locale)
        try Task.checkCancellation()

        if let installation = try await AssetInventory.assetInstallationRequest(
            supporting: modules
        ) {
            status("Hämtar modellasseten för \(engineTitle). Behåll wifi och appen öppen …")
            try await installation.downloadAndInstall()
            try Task.checkCancellation()
        }

        let finalState = await assetState(for: modules)
        guard finalState == .installed else {
            throw MioError.speechAssetNotReady(
                "iOS-status är \(finalState.title.lowercased()). Systemet kan fortsätta försöka senare; prova igen med wifi."
            )
        }
        return initialState != .installed
    }

    static func assetState(for modules: [any SpeechModule]) async -> SpeechAssetState {
        switch await AssetInventory.status(forModules: modules) {
        case .supported: .supported
        case .downloading: .downloading
        case .installed: .installed
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }

    static func shouldUseSpeechTranscriber(assetState: SpeechAssetState) -> Bool {
        assetState == .installed
    }

    static func makeResponsiveLongDictation(locale: Locale) -> DictationTranscriber {
        let preset = DictationTranscriber.Preset.progressiveLongDictation
        return DictationTranscriber(
            locale: locale,
            contentHints: preset.contentHints,
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions.union([.frequentFinalization]),
            attributeOptions: preset.attributeOptions
        )
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
