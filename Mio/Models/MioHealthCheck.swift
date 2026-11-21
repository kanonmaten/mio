import Foundation

/// "Kontrollera allt" and the settings line "Allt fungerar"/"Något är fel" (fas 6) read the same
/// rows from the same inputs, so they can never disagree. The inputs are what Mio already knows
/// (permissions, the last gateway check, Pianissimo's connection state, AI's state); only the
/// page's own "Kontrollera igen" makes new network calls.
enum MioHealthItem: String, CaseIterable, Sendable {
    case microphone, notifications, reminders, tailscale, computer, pianissimo, ai

    var title: String {
        switch self {
        case .microphone: "Mikrofon"
        case .notifications: "Notiser"
        case .reminders: "Påminnelser"
        case .tailscale: "Tailscale"
        case .computer: "Datorn"
        case .pianissimo: "Pianissimo"
        case .ai: "AI"
        }
    }
}

enum MioPermissionState: Equatable, Sendable {
    case granted, denied, notDetermined
}

/// What the last contact with a service on the PC showed.
enum MioReachability: Equatable, Sendable {
    /// Not checked during this launch.
    case unknown
    case reachable
    /// No answer at all: Tailscale off, the PC asleep or off.
    case unreachable
    /// It answered but did not accept this phone: pair again.
    case refused
    /// It answered with something Mio cannot use (wrong version, misconfigured).
    case incompatible
}

enum MioHealthAction: Equatable, Sendable {
    /// iPhone's Settings for Mio, where a denied permission is changed.
    case openSettings
    /// Ask for a permission that has never been asked for.
    case requestPermission
    case pair
    case openTailscale
    case checkAgain
    case resumeAI
}

enum MioHealthState: Equatable, Sendable {
    case ok, problem, unknown
}

struct MioHealthRow: Identifiable, Equatable, Sendable {
    let item: MioHealthItem
    let state: MioHealthState
    /// One sentence in plain Swedish.
    let detail: String
    let action: MioHealthAction?
    var id: MioHealthItem { item }

    var actionTitle: String? {
        switch action {
        case .openSettings: "Öppna Inställningar"
        case .requestPermission: "Tillåt"
        case .pair: "Para datorn"
        case .openTailscale: "Öppna Tailscale"
        case .checkAgain: "Kontrollera igen"
        case .resumeAI: "Slå på AI"
        case nil: nil
        }
    }
}

struct MioHealthInputs: Equatable, Sendable {
    var microphone: MioPermissionState = .notDetermined
    var notifications: MioPermissionState = .notDetermined
    var reminders: MioPermissionState = .notDetermined
    var paired = false
    /// The AI gateway, from the last `/v2/status` check.
    var gateway: MioReachability = .unknown
    /// Pianissimo, from the transcription connection state.
    var pianissimo: MioReachability = .unknown
    var aiEnabled = true
    /// AI is paired, on and running without an error.
    var aiWorking = false
}

enum MioHealthCheck {
    /// Pianissimo's connection state as a reachability. "Åtgärd krävs" answered but could not be
    /// used; "Ansluter" is not a result yet.
    static func reachability(_ state: TranscriptionConnectionState) -> MioReachability {
        switch state {
        case .connected: .reachable
        case .offline: .unreachable
        case .actionRequired: .incompatible
        case .unchecked, .connecting: .unknown
        }
    }

    static func rows(_ inputs: MioHealthInputs) -> [MioHealthRow] {
        [
            permission(.microphone, inputs.microphone,
                       ok: "Mio får använda mikrofonen.",
                       denied: "Mio får inte använda mikrofonen. Tillåt den i Inställningar.",
                       ask: "Mio har inte frågat om mikrofonen än."),
            permission(.notifications, inputs.notifications,
                       ok: "Mio får visa notiser.",
                       denied: "Mio får inte visa notiser. Tillåt dem i Inställningar.",
                       ask: "Mio har inte frågat om notiser än."),
            permission(.reminders, inputs.reminders,
                       ok: "Mio får använda Påminnelser.",
                       denied: "Mio får inte använda Påminnelser. Tillåt det i Inställningar.",
                       ask: "Mio har inte frågat om Påminnelser än."),
            tailscale(inputs),
            computer(inputs),
            pianissimo(inputs),
            ai(inputs)
        ]
    }

    /// "Allt fungerar" only when every row is green; a row not checked yet never counts as an
    /// error, so the line says "Kontrollera allt" until a check has run.
    static func summary(_ rows: [MioHealthRow]) -> (state: MioHealthState, text: String) {
        if rows.contains(where: { $0.state == .problem }) { return (.problem, "Något är fel") }
        if rows.allSatisfy({ $0.state == .ok }) { return (.ok, "Allt fungerar") }
        return (.unknown, "Kontrollera allt")
    }

    private static func permission(_ item: MioHealthItem, _ state: MioPermissionState,
                                   ok: String, denied: String, ask: String) -> MioHealthRow {
        switch state {
        case .granted: MioHealthRow(item: item, state: .ok, detail: ok, action: nil)
        case .denied: MioHealthRow(item: item, state: .problem, detail: denied, action: .openSettings)
        case .notDetermined: MioHealthRow(item: item, state: .problem, detail: ask, action: .requestPermission)
        }
    }

    /// Tailscale has no API; it is working when either service on the PC answered, and the likely
    /// cause when neither did.
    private static func tailscale(_ inputs: MioHealthInputs) -> MioHealthRow {
        guard inputs.paired else {
            return MioHealthRow(item: .tailscale, state: .problem, detail: "Datorn är inte parad än.", action: .pair)
        }
        let answers: Set<MioReachability> = [.reachable, .refused, .incompatible]
        if answers.contains(inputs.gateway) || answers.contains(inputs.pianissimo) {
            return MioHealthRow(item: .tailscale, state: .ok, detail: "Telefonen når datorn via Tailscale.", action: nil)
        }
        if inputs.gateway == .unreachable || inputs.pianissimo == .unreachable {
            return MioHealthRow(item: .tailscale, state: .problem,
                                detail: "Telefonen når inte datorn. Slå på Tailscale och kontrollera igen.", action: .openTailscale)
        }
        return MioHealthRow(item: .tailscale, state: .unknown, detail: "Inte kontrollerat än.", action: .checkAgain)
    }

    private static func computer(_ inputs: MioHealthInputs) -> MioHealthRow {
        guard inputs.paired else {
            return MioHealthRow(item: .computer, state: .problem, detail: "Datorn är inte parad än.", action: .pair)
        }
        switch inputs.gateway {
        case .reachable:
            return MioHealthRow(item: .computer, state: .ok, detail: "Datorn svarar.", action: nil)
        case .refused:
            return MioHealthRow(item: .computer, state: .problem,
                                detail: "Datorn känner inte igen telefonen. Para om den.", action: .pair)
        case .incompatible:
            return MioHealthRow(item: .computer, state: .problem,
                                detail: "Mio på datorn behöver uppdateras. Kör install.sh på datorn.", action: .checkAgain)
        case .unreachable:
            return MioHealthRow(item: .computer, state: .problem,
                                detail: "Datorn svarar inte. Kontrollera att den är på och vaken.", action: .checkAgain)
        case .unknown:
            return MioHealthRow(item: .computer, state: .unknown, detail: "Inte kontrollerat än.", action: .checkAgain)
        }
    }

    private static func pianissimo(_ inputs: MioHealthInputs) -> MioHealthRow {
        guard inputs.paired else {
            return MioHealthRow(item: .pianissimo, state: .problem, detail: "Datorn är inte parad än.", action: .pair)
        }
        switch inputs.pianissimo {
        case .reachable:
            return MioHealthRow(item: .pianissimo, state: .ok, detail: "Talet blir text på datorn.", action: nil)
        case .refused:
            return MioHealthRow(item: .pianissimo, state: .problem,
                                detail: "Pianissimo känner inte igen telefonen. Para om datorn.", action: .pair)
        case .incompatible:
            return MioHealthRow(item: .pianissimo, state: .problem,
                                detail: "Pianissimo behöver ses över på datorn. Starta om datorn och kontrollera igen.", action: .checkAgain)
        case .unreachable:
            return MioHealthRow(item: .pianissimo, state: .problem,
                                detail: "Pianissimo svarar inte. Kontrollera att datorn är på och kontrollera igen.", action: .checkAgain)
        case .unknown:
            return MioHealthRow(item: .pianissimo, state: .unknown, detail: "Inte kontrollerat än.", action: .checkAgain)
        }
    }

    private static func ai(_ inputs: MioHealthInputs) -> MioHealthRow {
        guard inputs.paired else {
            return MioHealthRow(item: .ai, state: .problem, detail: "Para datorn för att använda AI.", action: .pair)
        }
        guard inputs.aiEnabled else {
            return MioHealthRow(item: .ai, state: .problem, detail: "AI är pausad.", action: .resumeAI)
        }
        if inputs.gateway == .unknown && !inputs.aiWorking {
            return MioHealthRow(item: .ai, state: .unknown, detail: "Inte kontrollerat än.", action: .checkAgain)
        }
        guard inputs.aiWorking, inputs.gateway != .unreachable, inputs.gateway != .refused else {
            return MioHealthRow(item: .ai, state: .problem,
                                detail: "AI kan inte arbeta just nu. Kontrollera datorn och försök igen.", action: .checkAgain)
        }
        return MioHealthRow(item: .ai, state: .ok, detail: "AI är på och fungerar.", action: nil)
    }
}

/// "Skicka felrapport" (fas 6): text-free diagnostics for the share sheet. Versions, states,
/// counts and error codes only; never a transcript, title, note, subject, address or token.
struct MioErrorReport: Sendable {
    var appVersion: String
    var build: String
    var system: String
    var createdAt: Date
    var rows: [MioHealthRow]
    var sessionCount: Int
    var contentCount: Int
    var suggestionCount: Int
    var signingDaysLeft: Int?
    var backup: MioBackupAttempt?
    /// Operation, outcome and status codes from the diagnostics journal, newest first.
    var recentEvents: [String] = []

    var text: String {
        var lines = [
            "Felrapport från Mio",
            "Skapad: \(MioErrorReport.timestamp(createdAt))",
            "Mio \(appVersion) (\(build)), \(system)",
            "",
            "Kontroller:"
        ]
        lines += rows.map { "- \($0.item.rawValue): \($0.state)" }
        lines += [
            "",
            "Antal: \(sessionCount) sessioner, \(contentCount) poster, \(suggestionCount) förslag",
            "Signering: \(signingDaysLeft.map { "\($0) dagar kvar" } ?? "okänd")",
            "Säkerhetskopia: \(backup.map { "\(MioErrorReport.timestamp($0.at)) \($0.failure ?? "ok")" } ?? "inget försök")"
        ]
        if !recentEvents.isEmpty {
            lines += ["", "Senaste anrop:"] + recentEvents.prefix(20).map { "- " + $0 }
        }
        lines += ["", "Rapporten innehåller ingen text från dina sessioner, poster eller förslag."]
        return lines.joined(separator: "\n")
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}

/// The diagnostics journal as report lines: operation, outcome, HTTP status and gateway code only.
enum MioErrorReportEvents {
    static func lines(_ events: [MioDiagnosticEvent]) -> [String] {
        events.sorted { $0.startedAt > $1.startedAt }.prefix(20).map { event in
            [event.operation.rawValue, event.outcome.rawValue, event.httpStatus.map(String.init), event.gatewayCode?.rawValue]
                .compactMap { $0 }.joined(separator: " ")
        }
    }
}

/// Fas 6: every error text is one sentence and one action in plain Swedish. Mio's own errors
/// already are; an error from iOS or Foundation may be English or technical, so its text is never
/// shown and a plain action takes its place.
enum MioErrorText {
    static let fallbackAction = "Försök igen, och skicka en felrapport under Inställningar → Kontrollera allt om det upprepas."
    static let fallbackSentence = "Något gick fel. " + fallbackAction

    static func isMioError(_ error: Error) -> Bool {
        let name = String(describing: type(of: error))
        return name.hasPrefix("Mio") || name.hasPrefix("Transcription")
    }

    /// The action after "Kunde inte …": Mio's own sentence, or the plain fallback.
    static func action(for error: Error) -> String {
        guard isMioError(error), let text = (error as? LocalizedError)?.errorDescription, !text.isEmpty else { return fallbackAction }
        return text
    }

    /// A whole message for a bare error: Mio's own sentence, or "Något gick fel" with the action.
    static func sentence(for error: Error) -> String {
        guard isMioError(error), let text = (error as? LocalizedError)?.errorDescription, !text.isEmpty else { return fallbackSentence }
        return text
    }
}
