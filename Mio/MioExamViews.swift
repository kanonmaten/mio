import SwiftUI
import UIKit

/// Hem (fas 5): "Biologiprov om 3 dagar" from a week before each approved exam, with "Inför
/// provet" and, when the subject is missing, a way to pick it among her lesson subjects.
struct MioExamCountdownPanel: View {
    let countdown: [MioExamCountdown]
    let model: MioViewModel
    let contentModel: MioContentViewModel
    @Environment(MioAssistantViewModel.self) private var assistant
    @State private var choosingSubjectFor: MioExamPlan?

    var body: some View {
        if !countdown.isEmpty {
            MioSectionTitle("Prov")
            MioPanel {
                ForEach(countdown) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(entry.text, systemImage: "graduationcap")
                            .font(.headline)
                            .accessibilityIdentifier("mio.home.exam")
                        if entry.plan.exam.subject == nil {
                            Button("Välj ämne") { choosingSubjectFor = entry.plan }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                        } else {
                            MioExamPrepButton(subject: entry.plan.exam.subject ?? "", exam: entry.plan,
                                              sessions: model.allSessions, items: contentModel.items, records: assistant.analyses)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if entry.id != countdown.last?.id { Divider() }
                }
            }
            .sheet(item: $choosingSubjectFor) { plan in
                MioExamSubjectSheet(plan: plan, subjects: MioExamSubjects.known(in: model.allSessions), contentModel: contentModel)
            }
        }
    }
}

/// "Inför provet": copies the subject's exam hints and lesson notes since the previous exam.
struct MioExamPrepButton: View {
    let subject: String
    let exam: MioExamPlan?
    let sessions: [MioSession]
    let items: [MioContentItem]
    let records: [MioAnalysisRecord]
    @State private var copied: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                let prep = MioExamPrep.make(subject: subject, exam: exam, sessions: sessions, exams: MioExamPlan.all(in: items), now: .now)
                UIPasteboard.general.string = prep.text(records: records, exam: exam)
                copied = prep.lessons.count
                MioFeedback.success()
            } label: {
                Label("Inför provet", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(MioLessonSubject.clean(subject) == nil)
            .accessibilityIdentifier("mio.exam.prep")
            if let copied {
                Text(copied == 0 ? "Kopierat. Det finns inga lektioner i ämnet sedan förra provet."
                                 : "Kopierat: \(copied == 1 ? "1 lektion" : "\(copied) lektioner"). Klistra in där du pluggar.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// Picks the subject of an approved exam: one of her lesson subjects, or one she types.
struct MioExamSubjectSheet: View {
    let plan: MioExamPlan
    let subjects: [String]
    let contentModel: MioContentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(plan.title)
                } header: { Text("Prov") }
                if !subjects.isEmpty {
                    Section("Ämnen från dina lektioner") {
                        ForEach(subjects, id: \.self) { subject in
                            Button(subject) { Task { await save(subject) } }
                        }
                    }
                }
                Section {
                    TextField("Ämne, till exempel Biologi", text: $typed)
                        .submitLabel(.done)
                        .onSubmit { Task { await save(typed) } }
                    Button("Spara ämnet") { Task { await save(typed) } }
                        .disabled(MioLessonSubject.clean(typed) == nil)
                } header: { Text("Eller skriv ett") } footer: {
                    Text("Mio använder ämnet för nedräkningen och för att samla lektionerna inför provet.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .mioListGround()
            .navigationTitle("Välj ämne")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(saving)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func save(_ subject: String) async {
        guard MioLessonSubject.clean(subject) != nil else {
            error = "Skriv ett ämne på högst \(MioLessonSubject.maximumLength) tecken."
            return
        }
        saving = true
        defer { saving = false }
        let outcome = await contentModel.setExamSubject(id: plan.id, subject: subject)
        if outcome.isSuccess { dismiss() } else { error = outcome.message ?? "Ämnet sparades inte. Försök igen." }
    }
}

