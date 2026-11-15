import SwiftUI

/// The one place for settings (2026-11-15): a normal full-height sheet with a short top-level
/// list. It replaced the panel that slid in from the right edge. Opened by the gear button and
/// by the status chips on Fånga and in a lesson; closed with Klar or by pulling it down.
struct MioSettingsScreen: View {
    let model: MioViewModel
    let contentModel: MioContentViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MioSettingsView(model: model, contentModel: contentModel)
                .navigationTitle("Inställningar")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Klar") { dismiss() }
                            .accessibilityIdentifier("mio.settings.done")
                    }
                }
        }
        .tint(MioTheme.tint)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// One line of the top-level settings list: what it is, and its state at a glance.
struct MioSettingsRow: View {
    let title: String
    let symbol: String
    var value: String? = nil

    var body: some View {
        LabeledContent {
            if let value { Text(value).foregroundStyle(.secondary) }
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

/// The words for AI's state, shared by the settings list and the status chip.
@MainActor
enum MioAIStateText {
    static func describe(paired: Bool, enabled: Bool, analysis: MioAnalysisCoordinator, isSendingQuestion: Bool) -> String {
        if !paired { return "Inte parad" }
        if !enabled { return "Pausad" }
        if isSendingQuestion { return "Fråga skickad" }
        if let pausedUntil = analysis.pausedUntil, pausedUntil > .now {
            return "Fortsätter kl. \(pausedUntil.formatted(date: .omitted, time: .shortened))"
        }
        if analysis.isWorking { return "Arbetar" }
        if analysis.enabled { return "På" }
        return "Startar inte"
    }
}
