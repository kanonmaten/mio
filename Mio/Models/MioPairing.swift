import Foundation

/// The PC pairing printed by `server/mio-pair` as compact JSON in one QR code, or typed in by hand.
/// Parsing is strict: the code carries secrets, so anything unexpected is rejected instead of guessed.
struct MioPairingPayload: Equatable, Sendable {
    let aiOrigin: URL
    let aiToken: String
    let transcriptionOrigin: URL?
    let transcriptionToken: String?

    static let maxBytes = 2_048
    private static let keys: Set<String> = ["mio", "aiURL", "aiToken", "transcriptionURL", "transcriptionToken"]

    enum ParseError: LocalizedError, Equatable {
        case notMioCode, unsupportedVersion, invalidAIAddress, invalidAIToken
        case invalidTranscriptionAddress, invalidTranscriptionToken, incompleteTranscription

        var errorDescription: String? {
            switch self {
            case .notMioCode: "Koden kommer inte från mio-pair. Visa en ny kod på datorn med mio-pair."
            case .unsupportedVersion: "Koden har en version som den här Mio-versionen inte känner igen. Uppdatera appen eller gatewayen."
            case .invalidAIAddress: "AI-adressen måste vara en HTTPS-adress utan sökväg, till exempel https://dator.tailnet.ts.net:8443."
            case .invalidAIToken, .invalidTranscriptionToken:
                "En token ska vara 32–256 bokstäver, siffror, bindestreck eller understreck. Använd aldrig Groq-nyckeln här."
            case .invalidTranscriptionAddress: "Transkriptionsadressen måste vara datorns HTTPS-adress i Tailscale, till exempel https://dator.tailnet.ts.net."
            case .incompleteTranscription: "Ange både adress och token för transkriptionen, eller lämna båda tomma."
            }
        }
    }

    /// The QR text from `mio-pair`. Unknown keys, wrong types and other versions are rejected.
    static func parse(_ text: String) throws -> Self {
        let data = Data(text.utf8)
        guard data.count <= maxBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["mio"] != nil else { throw ParseError.notMioCode }
        struct Version: Decodable { let mio: Int }
        guard let version = try? JSONDecoder().decode(Version.self, from: data) else { throw ParseError.notMioCode }
        guard version.mio == 1 else { throw ParseError.unsupportedVersion }
        guard Set(object.keys).isSubset(of: keys) else { throw ParseError.notMioCode }
        struct Wire: Decodable {
            let aiURL: String
            let aiToken: String
            let transcriptionURL: String?
            let transcriptionToken: String?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { throw ParseError.notMioCode }
        return try make(aiURL: wire.aiURL, aiToken: wire.aiToken,
                        transcriptionURL: wire.transcriptionURL, transcriptionToken: wire.transcriptionToken)
    }

    /// Manual fallback with four fields; empty transcription fields mean "no Pianissimo yet".
    static func manual(aiURL: String, aiToken: String, transcriptionURL: String, transcriptionToken: String) throws -> Self {
        func optional(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return try make(aiURL: aiURL.trimmingCharacters(in: .whitespacesAndNewlines),
                        aiToken: aiToken.trimmingCharacters(in: .whitespacesAndNewlines),
                        transcriptionURL: optional(transcriptionURL), transcriptionToken: optional(transcriptionToken))
    }

    private static func make(aiURL: String, aiToken: String, transcriptionURL: String?,
                             transcriptionToken: String?) throws -> Self {
        guard let ai = origin(aiURL, requireTailscale: false) else { throw ParseError.invalidAIAddress }
        guard isValidToken(aiToken) else { throw ParseError.invalidAIToken }
        switch (transcriptionURL, transcriptionToken) {
        case (nil, nil):
            return Self(aiOrigin: ai, aiToken: aiToken, transcriptionOrigin: nil, transcriptionToken: nil)
        case let (address?, token?):
            guard let transcription = origin(address, requireTailscale: true), transcription.port == nil else {
                throw ParseError.invalidTranscriptionAddress
            }
            guard isValidToken(token) else { throw ParseError.invalidTranscriptionToken }
            return Self(aiOrigin: ai, aiToken: aiToken, transcriptionOrigin: transcription, transcriptionToken: token)
        default:
            throw ParseError.incompleteTranscription
        }
    }

    /// An HTTPS origin without credentials, path, query or fragment. The host must be a
    /// lowercase-normalised DNS name with at least two labels; Pianissimo additionally
    /// stays on a Tailscale `.ts.net` name. Port 443 is dropped; other ports are kept.
    static func origin(_ address: String, requireTailscale: Bool) -> URL? {
        guard address.utf8.count <= 512, !address.contains(where: \.isWhitespace),
              var parts = URLComponents(string: address),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(), isValidHost(host),
              !requireTailscale || host.hasSuffix(".ts.net"),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        if let port = parts.port, !(1...65_535).contains(port) { return nil }
        parts.scheme = "https"; parts.host = host; parts.path = ""
        if parts.port == 443 { parts.port = nil }
        return parts.url
    }

    static func isValidHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    /// Same alphabet as the gateway and Pianissimo (`[A-Za-z0-9_-]{32,256}`); known provider-key
    /// prefixes are refused so a Groq or other provider key never ends up on the phone.
    static func isValidToken(_ token: String) -> Bool {
        let lowercased = token.lowercased()
        return (32...256).contains(token.utf8.count)
            && !["sk-", "sk_", "gsk_", "aiza"].contains(where: lowercased.hasPrefix)
            && token.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
            }
    }

    var hostName: String { aiOrigin.host ?? aiOrigin.absoluteString }
}

/// The persisted "AI on" choice. AI is on by default once the PC is paired; the quick pause
/// switch stores `false`. The value survives app restarts (user decision 2026-10-11).
enum MioAIPreference {
    static let enabledKey = "mio.ai.enabled"
    static let defaultEnabled = true
    /// Pre-pairing key ("Tillåt molnfrågor"); removed once on upgrade.
    static let legacyCloudEnabledKey = "mio.cloud.enabled"

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: enabledKey)
    }

    /// Whether automatic analysis should run: paired and not paused.
    static func shouldRun(paired: Bool, defaults: UserDefaults) -> Bool {
        paired && isEnabled(in: defaults)
    }
}

/// Text-free record of when automatic AI was on, so everyday text that was captured with AI on
/// but never reached the gateway (app closed, phone locked) can be sent on the next start
/// (user decision 2026-10-12). Only times are stored; never text or identifiers.
struct MioAIConsentLog: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case on, off, skipped }
    struct Entry: Codable, Equatable, Sendable {
        var kind: Kind
        var at: Date
        /// End of a `skipped` interval (a long quota pause whose text is deliberately not analysed).
        var until: Date?
    }

    static let key = "mio.ai.consentLog.v1"
    static let retention: TimeInterval = 24 * 3_600
    static let limit = 200
    /// How far back unsent everyday text is caught up after a restart.
    static let catchUpWindow: TimeInterval = 12 * 3_600

    var entries: [Entry] = []

    static func load(from defaults: UserDefaults) -> MioAIConsentLog {
        guard let data = defaults.data(forKey: key),
              let log = try? JSONDecoder().decode(MioAIConsentLog.self, from: data) else { return MioAIConsentLog() }
        return log
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    static func record(_ kind: Kind, at date: Date, until: Date? = nil, in defaults: UserDefaults) {
        var log = load(from: defaults)
        log.record(kind, at: date, until: until)
        log.save(to: defaults)
    }

    /// Whether the newest on/off entry says on.
    var isOn: Bool { entries.last { $0.kind != .skipped }?.kind == .on }

    mutating func record(_ kind: Kind, at date: Date, until: Date? = nil) {
        if kind != .skipped, isOn == (kind == .on), !entries.isEmpty { return }
        entries.append(Entry(kind: kind, at: date, until: kind == .skipped ? until : nil))
        entries.sort { $0.at < $1.at }
        trim(now: max(date, until ?? date))
    }

    /// Drops entries older than the retention but keeps the newest on/off state they describe.
    mutating func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let state = entries.last { $0.kind != .skipped && $0.at < cutoff }
        entries.removeAll { $0.at < cutoff && ($0.kind != .skipped || ($0.until ?? $0.at) < cutoff) }
        if let state, !entries.contains(state) { entries.insert(state, at: 0) }
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// Start of the consent interval covering `date`: the latest switch-on, moved past any
    /// skipped interval that ended before `date`. Nil when AI was off or the time was skipped.
    func consentStart(covering date: Date) -> Date? {
        guard let state = entries.last(where: { $0.kind != .skipped && $0.at <= date }), state.kind == .on else { return nil }
        var start = state.at
        for skip in entries where skip.kind == .skipped {
            let end = skip.until ?? skip.at
            if skip.at <= date, date < end { return nil }
            if end <= date, end > start { start = end }
        }
        return start
    }
}
