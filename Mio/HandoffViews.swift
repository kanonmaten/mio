import EventKit
import EventKitUI
import SwiftUI
import UIKit

/// An event as the user approved it in Mio, before Calendar's own editor.
struct MioEventDraft: Equatable {
    var title: String
    var notes: String
    var url: URL?
    var start: Date
    var isAllDay: Bool
}

/// Calendar's own editor, prefilled. EventKitUI runs it outside Mio's process, so Mio needs no
/// calendar access and never reads the calendar; the user picks calendar and alert there.
@MainActor
struct CalendarHandoffComposer: UIViewControllerRepresentable {
    let draft: MioEventDraft
    var onCompletion: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        let store = context.coordinator.store
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        event.url = draft.url
        event.isAllDay = draft.isAllDay
        let start = draft.isAllDay ? Calendar.current.startOfDay(for: draft.start) : draft.start
        event.startDate = start
        // Calendar's own default length for a new event.
        event.endDate = draft.isAllDay ? start : start.addingTimeInterval(60 * 60)
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let store = EKEventStore()
        let parent: CalendarHandoffComposer

        init(parent: CalendarHandoffComposer) { self.parent = parent }

        nonisolated func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            let didSave = action == .saved
            // The delegate requirement is nonisolated; only the outcome crosses to UI state.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.parent.onCompletion(didSave)
                self.parent.dismiss()
            }
        }
    }
}

/// Apple's share sheet with plain text, for Notes (which has no API). Reports only whether the
/// user finished and which kind of app received it, never the note it ended up in.
@MainActor
struct MioShareSheet: UIViewControllerRepresentable {
    let text: String
    var onCompletion: (MioHandoffDestination?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        controller.completionWithItemsHandler = { activity, completed, _, _ in
            let destination: MioHandoffDestination? = completed
                ? (activity?.rawValue.contains("mobilenotes") == true ? .notes : .otherApp) : nil
            Task { @MainActor in onCompletion(destination) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
