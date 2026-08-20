import SwiftUI
import UIKit

struct ContentView: View {
    @Bindable var model: PhaseOneViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    StatusHeader(model: model)
                    ControlsCard(model: model)

                    if let errorMessage = model.errorMessage {
                        ErrorCard(message: errorMessage, openSettings: model.openAppSettings)
                    }

                    CapabilityCard(model: model)
                    PrivacyCard()

                    if let session = model.currentSession {
                        LiveTranscriptCard(model: model, session: session)
                        SessionStatisticsCard(model: model, session: session)
                        EvidenceCard(session: session)
                        TranscriptCard(session: session)
                        DiagnosticCard(session: session)
                        DataCard(
                            model: model,
                            showDeleteConfirmation: $showDeleteConfirmation
                        )
                    } else {
                        FirstRunCard()
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Mio · Fas 1")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await model.bootstrap()
            }
            .onChange(of: scenePhase) { _, newPhase in
                model.handleScenePhase(newPhase)
            }
            .confirmationDialog(
                "Radera all fas 1-data?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Radera permanent", role: .destructive) {
                    Task { await model.deleteAllData() }
                }
                Button("Avbryt", role: .cancel) {}
            } message: {
                Text("Tidsstämplad text, batterimätningar och händelseloggar tas bort från telefonen.")
            }
        }
    }
}

private struct StatusHeader: View {
    let model: PhaseOneViewModel

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))
                    .frame(width: 96, height: 96)
                Image(systemName: statusSymbol)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: model.runState == .listening)
            }

            Text(model.runState.title)
                .font(.title2.bold())
            Text(model.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if model.runState == .paused, let remaining = model.pauseRemainingText {
                Label("Planerad fortsättning om \(remaining)", systemImage: "timer")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch model.runState {
        case .listening: .green
        case .paused, .preparing, .stopping, .interrupted: .orange
        case .failed, .unavailable: .red
        case .off: .secondary
        }
    }

    private var statusSymbol: String {
        switch model.runState {
        case .listening: "waveform.and.mic"
        case .paused: "pause.fill"
        case .interrupted: "phone.down.fill"
        case .preparing: "hourglass"
        case .stopping: "stop.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .unavailable: "iphone.slash"
        case .off: "mic.slash.fill"
        }
    }
}

private struct ControlsCard: View {
    let model: PhaseOneViewModel

    var body: some View {
        Card {
            VStack(spacing: 12) {
                switch model.runState {
                case .off, .failed, .unavailable:
                    PrimaryActionButton(title: "Starta fas 1-test", symbol: "mic.fill", color: .green) {
                        model.beginListening()
                    }

                case .preparing:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Förbereder lokal talmotor …")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    Button("Avbryt — håll Mio avstängd", role: .destructive) {
                        model.cancelPreparation()
                    }
                    .buttonStyle(.bordered)

                case .stopping:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Stänger mikrofon och talmotor säkert …")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()

                case .listening:
                    PrimaryActionButton(title: "Stoppa Mio", symbol: "stop.fill", color: .red) {
                        Task { await model.stopListening() }
                    }

                    Menu {
                        Button("30 minuter") {
                            Task { await model.pause(.thirtyMinutes) }
                        }
                        Button("1 timme") {
                            Task { await model.pause(.oneHour) }
                        }
                        Button("Tills jag startar igen") {
                            Task { await model.pause(.untilResumed) }
                        }
                    } label: {
                        Label("Pausa Mio", systemImage: "pause.circle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    }

                case .paused:
                    PrimaryActionButton(title: "Fortsätt lyssna", symbol: "play.fill", color: .green) {
                        model.beginListening()
                    }
                    Button(role: .destructive) {
                        Task { await model.stopListening() }
                    } label: {
                        Label("Avsluta testet", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                case .interrupted:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Väntar på att iOS avslutar ljudavbrottet …")
                            .font(.subheadline.weight(.semibold))
                    }
                    Button(role: .destructive) {
                        Task { await model.stopListening() }
                    } label: {
                        Label("Stoppa Mio", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

private struct CapabilityCard: View {
    let model: PhaseOneViewModel

    var body: some View {
        Card(title: "Telefonens stöd", symbol: "checklist") {
            VStack(spacing: 0) {
                CheckRow(
                    title: "iOS 26 eller senare",
                    detail: "Telefonen kör iOS \(UIDevice.current.systemVersion)",
                    result: isIOS26OrLater
                )
                Divider()
                CheckRow(
                    title: "Mikrofon",
                    detail: model.support.microphonePermission.title,
                    result: microphoneResult
                )
                Divider()
                CheckRow(
                    title: "Avancerad talmotor",
                    detail: advancedSpeechDetail,
                    result: model.support.swedishLocaleIdentifier != nil
                )
                Divider()
                CheckRow(
                    title: "Svensk lokal reservmotor",
                    detail: dictationDetail,
                    result: model.support.dictationLocaleIdentifier != nil
                )
                Divider()
                CheckRow(
                    title: "Vald motor",
                    detail: model.support.selectedEngine?.title ?? "Ingen svensk motor hittades",
                    result: model.support.selectedEngine != nil
                )
                Divider()
                CheckRow(
                    title: "Bakgrundsljud",
                    detail: "Projektet innehåller Apples audio-bakgrundsläge",
                    result: true
                )

                Text(model.support.details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)

                Button {
                    Task { await model.refreshSupport() }
                } label: {
                    if model.isRefreshingSupport {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Kontrollera igen", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .padding(.top, 12)
            }
        }
    }

    private var isIOS26OrLater: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    private var microphoneResult: Bool? {
        switch model.support.microphonePermission {
        case .granted: true
        case .denied, .restricted: false
        case .notDetermined: nil
        }
    }

    private var advancedSpeechDetail: String {
        if model.support.speechTranscriberAvailable == false {
            return "SpeechTranscriber saknas på enheten"
        }
        if let locale = model.support.swedishLocaleIdentifier {
            return "Svenska \(locale) · \(model.support.swedishModelInstalled == true ? "installerad" : "hämtas vid start")"
        }
        return "Finns, men svenska hittades inte"
    }

    private var dictationDetail: String {
        if let locale = model.support.dictationLocaleIdentifier {
            return "Svenska \(locale) · \(model.support.dictationModelInstalled == true ? "installerad" : "hämtas vid start")"
        }
        return model.support.checkedAt == nil ? "Kontrollerar …" : "Svenska hittades inte"
    }
}

private struct PrivacyCard: View {
    var body: some View {
        Card(title: "Integritet i fas 1", symbol: "hand.raised.fill") {
            VStack(alignment: .leading, spacing: 10) {
                PrivacyLine(symbol: "iphone", text: "Tal till text sker med Apples lokala motor på telefonen.")
                PrivacyLine(symbol: "waveform.slash", text: "Mikrofonljud bearbetas tillfälligt i minnet men sparas aldrig som ljudfil.")
                PrivacyLine(symbol: "cloud.slash", text: "Ingen OpenAI-nyckel finns i appen och inget skickas till OpenAI.")
                PrivacyLine(symbol: "mic.slash", text: "Stoppa eller pausa stänger AVAudioEngine och mikrofonens ljudsession.")
                PrivacyLine(symbol: "person.2.slash", text: "Testa kontrollerat. Spela inte in andra, en lektion eller en arbetsplats utan tydligt tillstånd och enligt lokala regler.")
            }
        }
    }
}

private struct LiveTranscriptCard: View {
    let model: PhaseOneViewModel
    let session: PhaseOneSession

    var body: some View {
        Card(title: "Live-test", symbol: "quote.bubble") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Säg till exempel: “I dag testar vi procent. Mio, kom ihåg att provet är på fredag.”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !model.liveTranscript.isEmpty {
                    Text(model.liveTranscript)
                        .italic()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Pågående tolkning: \(model.liveTranscript)")
                } else if let latest = session.transcripts.last {
                    Text(latest.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Text(model.runState == .listening ? "Väntar på tal …" : "Ingen färdig text ännu.")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }

                Label(
                    "Mio upptäckt \(session.mioDetectionCount) \(session.mioDetectionCount == 1 ? "gång" : "gånger")",
                    systemImage: session.mioDetectionCount > 0 ? "checkmark.circle.fill" : "ear"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(session.mioDetectionCount > 0 ? .green : .secondary)
            }
        }
    }
}

private struct SessionStatisticsCard: View {
    let model: PhaseOneViewModel
    let session: PhaseOneSession

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        Card(title: "Mätningar", symbol: "gauge.with.dots.needle.67percent") {
            LazyVGrid(columns: columns, spacing: 10) {
                Metric(title: "Tid", value: durationText, symbol: "clock")
                Metric(title: "Textdelar", value: "\(session.transcripts.count)", symbol: "text.alignleft")
                Metric(title: "Mio", value: "\(session.mioDetectionCount)", symbol: "waveform.badge.mic")
                Metric(title: "Avbrottshändelser", value: "\(session.interruptionCount)", symbol: "phone.arrow.down.left")
                Metric(title: "Batteriprover", value: "\(session.batteryReadings.count)", symbol: "battery.75percent")
                Metric(title: "Batteriskillnad", value: model.batteryDropText, symbol: "chart.line.downtrend.xyaxis")
            }
        }
    }

    private var durationText: String {
        let seconds = Int(model.duration)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
            : String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

private struct EvidenceCard: View {
    let session: PhaseOneSession

    var body: some View {
        Card(title: "Bevis från telefonen", symbol: "doc.text.magnifyingglass") {
            VStack(spacing: 0) {
                EvidenceRow(
                    title: "Svensk text skapad",
                    passed: !session.transcripts.isEmpty,
                    pendingText: "Säg några meningar"
                )
                Divider()
                EvidenceRow(
                    title: "Ordet Mio upptäckt",
                    passed: session.mioDetectionCount > 0,
                    pendingText: "Säg Mio tydligt i en mening"
                )
                Divider()
                EvidenceRow(
                    title: "Bakgrund/låst skärm loggad",
                    passed: session.transcripts.contains(where: \.wasObservedInBackground),
                    pendingText: "Lås telefonen och säg en testmening"
                )
                Divider()
                EvidenceRow(
                    title: "Batteri över tid",
                    passed: session.batteryReadings.count >= 2,
                    pendingText: "Minst två mätningar behövs"
                )
            }
        }
    }
}

private struct TranscriptCard: View {
    let session: PhaseOneSession

    var body: some View {
        Card(title: "Tidsstämplad text", symbol: "text.document") {
            if session.transcripts.isEmpty {
                Text("Här visas färdiga lokala textdelar.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(session.transcripts.suffix(20).reversed())) { segment in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(segment.createdAt.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if segment.containsMio {
                                    Text("MIO")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.green.opacity(0.12), in: Capsule())
                                }
                                if segment.wasObservedInBackground {
                                    Text("BAKGRUND")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.blue)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.12), in: Capsule())
                                }
                                Spacer()
                            }
                            Text(segment.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 10)
                        if segment.id != session.transcripts.suffix(20).first?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct DiagnosticCard: View {
    let session: PhaseOneSession

    var body: some View {
        Card(title: "Händelselogg", symbol: "list.bullet.rectangle") {
            if session.events.isEmpty {
                Text("Inga händelser ännu.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(session.events.suffix(24).reversed())) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: eventSymbol(event.kind))
                                .foregroundStyle(eventColor(event.kind))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.createdAt.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(event.message)
                                    .font(.subheadline)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func eventSymbol(_ kind: DiagnosticEventKind) -> String {
        switch kind {
        case .info: "info.circle"
        case .lifecycle: "iphone"
        case .interruption: "phone.down"
        case .routeChange: "airpodsmax"
        case .wakeWord: "waveform.badge.mic"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private func eventColor(_ kind: DiagnosticEventKind) -> Color {
        switch kind {
        case .wakeWord: .green
        case .warning, .interruption: .orange
        case .error: .red
        default: .secondary
        }
    }
}

private struct DataCard: View {
    let model: PhaseOneViewModel
    @Binding var showDeleteConfirmation: Bool

    var body: some View {
        Card(title: "Testfil och radering", symbol: "externaldrive") {
            VStack(spacing: 12) {
                Text("Exportfilen innehåller texten och diagnostiken ovan, aldrig råljud. Radera-knappen tar bort appens data och lokala temp-exporter, men kan inte återkalla filer som redan delats eller sparats någon annanstans.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let exportURL = model.exportURL {
                    ShareLink(item: exportURL) {
                        Label("Dela testfil", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        Task { await model.prepareExport() }
                    } label: {
                        if model.isPreparingExport {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Skapa testfil", systemImage: "doc.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canManageData)
                }

                Button("Radera all fas 1-data", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .disabled(!canManageData)
            }
        }
    }

    private var canManageData: Bool {
        model.runState == .off || model.runState == .failed || model.runState == .unavailable
    }
}

private struct FirstRunCard: View {
    var body: some View {
        Card(title: "Så gör ni första testet", symbol: "1.circle") {
            VStack(alignment: .leading, spacing: 9) {
                Text("1. Tryck Starta och tillåt mikrofonen.")
                Text("2. Säg svenska meningar och ordet Mio.")
                Text("3. Lås telefonen i minst fem minuter och fortsätt prata ibland.")
                Text("4. Lås upp, kontrollera texten och kör gärna i en timme för batterimätning.")
                Text("5. Stoppa och dela testfilen med er själva.")
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ErrorCard: View {
    let message: String
    let openSettings: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Något behöver åtgärdas", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.subheadline)
                if message.localizedCaseInsensitiveContains("mikrofon") {
                    Button("Öppna Mios inställningar", action: openSettings)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Card<Content: View>: View {
    let title: String?
    let symbol: String?
    let content: Content

    init(
        title: String? = nil,
        symbol: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: symbol ?? "circle")
                    .font(.headline)
            }
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct PrimaryActionButton: View {
    let title: String
    let symbol: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(.white)
                .background(color, in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
    }
}

private struct CheckRow: View {
    let title: String
    let detail: String
    let result: Bool?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch result {
        case true: "checkmark.circle.fill"
        case false: "xmark.circle.fill"
        case nil: "questionmark.circle.fill"
        }
    }

    private var color: Color {
        switch result {
        case true: .green
        case false: .red
        case nil: .secondary
        }
    }
}

private struct PrivacyLine: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.blue)
        }
    }
}

private struct Metric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(12)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EvidenceRow: View {
    let title: String
    let passed: Bool
    let pendingText: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(passed ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if !passed {
                    Text(pendingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 9)
    }
}
