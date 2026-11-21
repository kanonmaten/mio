import SwiftUI
import UIKit

/// The calm view during a lesson (user decision 2026-11-19): time, a quiet listening dot and how
/// many exam hints and homework the teacher seems to have mentioned so far. The transcript is one
/// tap away. The counts are local word cues (`MioLessonCues`), never AI.
struct MioLessonCalmView: View {
    let model: MioViewModel
    let session: MioSession
    @State private var showTranscript = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cues = MioLessonCues(session: session)
        MioPanel {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title ?? "Lektion")
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                listeningDot
            }
            Text(elapsed)
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .accessibilityLabel("Lektionen har pågått \(spokenElapsed)")
            HStack(spacing: 16) {
                Label(cues.examText, systemImage: "star")
                Label(cues.homeworkText, systemImage: "book.closed")
            }
            .font(.subheadline.weight(.medium))
            .accessibilityElement(children: .combine)
            Text("Hittills, räknat på orden i lektionen. Anteckningarna kommer när du har avslutat lektionen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Visa transkriptet", systemImage: "text.alignleft") { showTranscript = true }
                .buttonStyle(.glass)
                .frame(minHeight: 44)
        }
        .sheet(isPresented: $showTranscript) {
            MioLessonTranscriptSheet(model: model, sessionID: session.id)
        }
    }

    private var isListening: Bool { model.runState == .listening }

    private var listeningDot: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isListening ? MioTheme.tint : Color.secondary)
                .frame(width: 10, height: 10)
                .opacity(isListening && !reduceMotion ? 0.85 : 1)
                .accessibilityHidden(true)
            Text(isListening ? "Lyssnar" : model.runState.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var seconds: Int { max(0, Int(model.duration)) }

    private var elapsed: String {
        let hours = seconds / 3_600, minutes = (seconds % 3_600) / 60, rest = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%02d:%02d", minutes, rest)
    }

    private var spokenElapsed: String {
        let hours = seconds / 3_600, minutes = (seconds % 3_600) / 60
        return hours > 0 ? "\(hours) timmar och \(minutes) minuter" : "\(minutes) minuter"
    }
}

/// The lesson's transcript so far, on a plain reading surface, with speaker labels.
struct MioLessonTranscriptSheet: View {
    let model: MioViewModel
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let session = model.session(id: sessionID) {
                    if session.transcripts.isEmpty {
                        Text(model.runState == .listening ? "Väntar på tal …" : "Ingen färdig text ännu.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(session.transcripts.enumerated()), id: \.element.id) { index, segment in
                        VStack(alignment: .leading, spacing: 4) {
                            if let label = session.speakerLabel(at: index) {
                                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Text(segment.displayText).textSelection(.enabled)
                        }
                    }
                    if !model.liveTranscript.isEmpty {
                        Text(model.liveTranscript).italic().foregroundStyle(.secondary)
                            .accessibilityLabel("Pågående tolkning: \(model.liveTranscript)")
                    }
                } else {
                    Text("Lektionen finns inte längre.")
                }
            }
            .navigationTitle("Transkript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Klar") { dismiss() } } }
        }
    }
}

/// The review sheet when a lesson's notes are done (fas 3): the AI's subject suggestion to
/// confirm or change, and the lesson's proposals with their date field filled in or empty and
/// Ja or Nej for each. Nothing is saved until she says Ja.
struct MioLessonReviewSheet: View {
    let sessionID: UUID
    let model: MioViewModel
    let content: MioContentViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(MioAssistantViewModel.self) private var assistant
    @State private var subject = ""
    @State private var subjectError: String?
    @State private var loadedSubject = false
    @State private var savingSubject = false
    @State private var subjectSaved = false

    var body: some View {
        NavigationStack {
            Form {
                if let session = model.session(id: sessionID) {
                    let review = MioLessonReviewContent(session: session, suggestions: assistant.suggestions,
                                                        records: assistant.analyses.filter { $0.sessionID == sessionID })
                    Section {
                        Text("Anteckningarna från \(session.title ?? "lektionen") är klara. Granska förslagen nedan; inget sparas förrän du väljer Ja.")
                            .font(.subheadline)
                    }
                    subjectSection(review)
                    if !review.examHints.isEmpty {
                        Section("Viktigt till provet") {
                            ForEach(Array(review.examHints.enumerated()), id: \.offset) { _, hint in
                                Text(hint.text)
                            }
                        }
                    }
                    Section {
                        if review.suggestions.isEmpty {
                            Text("Lektionen gav inga förslag på läxor eller händelser.").foregroundStyle(.secondary)
                        }
                        ForEach(review.suggestions) { suggestion in
                            MioLessonReviewRow(suggestion: suggestion, content: content, sessionModel: model)
                        }
                    } header: {
                        Text("Förslag från lektionen")
                    } footer: {
                        Text("Ja på en läxa skickar den till Påminnelser med datumet ovan. Ja på en händelse öppnar Kalender. Nej tar bort förslaget; transkriptet ändras inte.")
                    }
                    Section {
                        NavigationLink("Visa hela anteckningen") {
                            LessonDetailView(sessionID: sessionID, model: model, content: content)
                        }
                    }
                } else {
                    Text("Lektionen finns inte längre.")
                }
            }
            .mioListGround()
            .navigationTitle("Granska lektionen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Klar") { dismiss() } } }
            .onAppear { MioSystemServices.shared.withdrawLessonNotesReady(sessionID: sessionID) }
        }
    }

    /// Text that cannot be a subject must never clear the saved one.
    private var subjectTooLong: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && MioLessonSubject.clean(subject) == nil
    }

    @ViewBuilder
    private func subjectSection(_ review: MioLessonReviewContent) -> some View {
        Section {
            TextField("Ämne, till exempel Biologi", text: $subject)
                .textInputAutocapitalization(.sentences)
                .onAppear {
                    guard !loadedSubject else { return }
                    subject = review.initialSubject
                    loadedSubject = true
                }
                .onChange(of: subject) { _, _ in subjectSaved = false }
            if let suggestion = review.subjectSuggestion, review.confirmedSubject == nil {
                Text("AI föreslår ”\(suggestion)”. Ändra om det inte stämmer.").font(.footnote).foregroundStyle(.secondary)
            }
            Button(subjectSaved ? "Ämnet är sparat" : "Spara ämnet") {
                Task {
                    savingSubject = true
                    subjectSaved = await model.setLessonSubject(sessionID: sessionID, subject: subject)
                    subjectError = subjectSaved ? nil : (model.errorMessage ?? "Ämnet sparades inte. Försök igen.")
                    savingSubject = false
                }
            }
            .disabled(savingSubject || MioLessonSubject.clean(subject) == review.confirmedSubject || subjectTooLong)
            if subjectTooLong { Text("Skriv högst \(MioLessonSubject.maximumLength) tecken.").font(.footnote).foregroundStyle(.secondary) }
            if let subjectError { Text(subjectError).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Ämne")
        } footer: {
            Text("Mio använder ämnet för att samla lektioner inför provet.")
        }
    }
}

/// One proposal in the review sheet: the date field is filled in when the AI heard a safe day and
/// empty otherwise; Ja and Nej act on it directly.
private struct MioLessonReviewRow: View {
    let suggestion: MioSuggestion
    let content: MioContentViewModel
    let sessionModel: MioViewModel
    @Environment(MioWorkflowCoordinator.self) private var workflow
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var busy = false
    @State private var outcome: MioOperationOutcome?
    @State private var showCalendar = false
    @State private var showEditor = false

    init(suggestion: MioSuggestion, content: MioContentViewModel, sessionModel: MioViewModel) {
        self.suggestion = suggestion
        self.content = content
        self.sessionModel = sessionModel
        _hasDate = State(initialValue: MioLessonReviewContent.hasPrefilledDate(suggestion))
        _date = State(initialValue: suggestion.scheduledAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(suggestion.kind.title, systemImage: suggestion.kind.symbolName)
                .font(.caption).foregroundStyle(.secondary)
            Text(suggestion.title).font(.headline)
            if !suggestion.body.isEmpty {
                Text(suggestion.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
            }
            if hasDate {
                DatePicker(isAllDay ? "Datum" : "Datum och tid", selection: $date,
                           displayedComponents: isAllDay ? .date : [.date, .hourAndMinute])
                if suggestion.kind == .task {
                    Button("Ta bort datumet", role: .destructive) { hasDate = false }
                        .font(.footnote).buttonStyle(.borderless)
                }
            } else {
                Button("Lägg till datum", systemImage: "calendar.badge.plus") { hasDate = true }
                    .buttonStyle(.borderless)
            }
            HStack(spacing: 12) {
                // Explicit styles keep each button its own tap target inside the Form row.
                Button(yesTitle) { approve() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !canApprove)
                Button("Nej", role: .destructive) { reject() }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                Spacer(minLength: 0)
                Button("Ändra") { showEditor = true }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
            }
            if let message = outcome?.message { Text(message).font(.footnote).foregroundStyle(.red) }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                SuggestionReviewView(suggestion: suggestion, contentModel: content, sessionModel: sessionModel)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Stäng") { showEditor = false } } }
            }
        }
        .sheet(isPresented: $showCalendar) {
            CalendarHandoffComposer(draft: MioEventDraft(title: suggestion.title, notes: suggestion.body, url: link,
                                                         start: date, isAllDay: isAllDay)) { saved in
                guard saved else { return }
                Task {
                    busy = true
                    outcome = await workflow.recordHandoff(id: suggestion.id, kind: .plan, title: suggestion.title, destination: .calendar)
                    if outcome?.isSuccess == true { MioFeedback.success() }
                    busy = false
                }
            }
        }
    }

    private var isAllDay: Bool { suggestion.isAllDay == true || suggestion.needsDateConfirmation == true }
    /// A plan needs a day for Calendar; a homework reminder may go without one.
    private var canApprove: Bool { suggestion.kind != .plan || hasDate }
    private var yesTitle: String { suggestion.kind == .plan ? "Ja, till Kalender" : "Ja, till Påminnelser" }
    private var link: URL? {
        suggestion.sessionID.flatMap { MioLink.session($0, proposal: suggestion.id) } ?? MioLink.proposal(suggestion.id)
    }

    private func approve() {
        outcome = nil
        if suggestion.kind == .plan { showCalendar = true; return }
        Task {
            busy = true
            defer { busy = false }
            // The date she sees next to Ja is the date that is sent (user decision 2026-11-19).
            let result = await workflow.sendToReminders(id: suggestion.id, expectedRevision: suggestion.reviewRevision,
                                                        title: suggestion.title, notes: suggestion.body,
                                                        dueDate: hasDate ? date : nil, hasTime: hasDate && !isAllDay,
                                                        listID: UserDefaults.standard.string(forKey: MioReminderPort.lastListKey))
            outcome = result
            if result.isSuccess { MioFeedback.success() }
        }
    }

    private func reject() {
        Task {
            busy = true
            outcome = await workflow.rejectSuggestion(id: suggestion.id)
            busy = false
        }
    }
}
