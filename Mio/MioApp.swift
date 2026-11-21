import SwiftUI
import UIKit

@main
@MainActor
struct MioApp: App {
    @State private var model: MioViewModel
    @State private var contentModel: MioContentViewModel
    @State private var assistantModel: MioAssistantViewModel
    @State private var analysis: MioAnalysisCoordinator
    @State private var workflow: MioWorkflowCoordinator
    @State private var navigation: MioNavigationCoordinator
    @State private var day: MioDayContext
    @State private var storageMessage: String?
    @State private var liveActivity: MioLiveActivityController
    @State private var lessonNotes: MioLessonNotesBackgroundTask

    init() {
        // Storage resolves off the main actor (one-time SwiftData migration); the view
        // models wait for it on their first repository call.
        let stores = MioStoreResolver.shared.deferred
        let capture = MioViewModel(repository: stores.sessions)
        let content = MioContentViewModel(repository: stores.content)
        let assistant = MioAssistantViewModel(repository: stores.assistant)
        let analysis = MioAnalysisCoordinator()
        let day = MioDayContext()
        let navigation = MioNavigationCoordinator(onDailyRoute: {
            day.refresh()
            day.select(day.referenceDate)
        })
        let workflow = MioWorkflowCoordinator(capture: capture, content: content,
                                              assistant: assistant, analysis: analysis, removesLegacyItems: true,
                                              storesAreDurable: { await !MioStoreResolver.shared.stores().isTemporary })
        _model = State(initialValue: capture)
        _contentModel = State(initialValue: content)
        _assistantModel = State(initialValue: assistant)
        _analysis = State(initialValue: analysis)
        _workflow = State(initialValue: workflow)
        _navigation = State(initialValue: navigation)
        _day = State(initialValue: day)
        MioSystemServices.shared.configureNotificationRouting({ navigation.receive($0) },
                                                              stillListening: { capture.confirmStillListening() })
        MioMetricKitSubscriber.shared.start()
        // Lock Screen presence: Live Activity with App Intent controls, and iOS's own
        // progress UI for lesson notes that continue after the user leaves the app.
        let liveActivity = MioLiveActivityController(capture: capture)
        let lessonNotes = MioLessonNotesBackgroundTask(capture: capture, analysis: analysis, assistant: assistant)
        _liveActivity = State(initialValue: liveActivity)
        _lessonNotes = State(initialValue: lessonNotes)
        workflow.onLessonNotesStarted = { lessonNotes.begin(sessionID: $0) }
        // Finished notes open the review sheet at once in the foreground; in the background a
        // notification with a generic text does, when she opens it (fas 3).
        workflow.onLessonNotesReady = { id in
            if UIApplication.shared.applicationState == .active {
                navigation.receive(.lessonReview(id))
            } else {
                Task { await MioSystemServices.shared.postLessonNotesReady(sessionID: id) }
            }
        }
        MioListeningControl.handler = { command in
            switch command {
            case .pause: await capture.pause(.untilResumed)
            case .resume: capture.beginListening()
            case .stop: await capture.stopListening()
            }
        }
        liveActivity.start()
        capture.onResumeNotice = { notice in
            Task { await MioSystemServices.shared.handleResumeNotice(notice) }
        }
        capture.onSilenceNotice = { notice in
            Task { await MioSystemServices.shared.handleSilenceNotice(notice) }
        }
        capture.batteryStatus = { MioDeviceSignals.batteryStatus() }
        capture.directFeedback = { MioDirectHaptics.play($0) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, contentModel: contentModel)
                .environment(assistantModel)
                .environment(analysis)
                .environment(workflow)
                .environment(navigation)
                .environment(day)
                .task { storageMessage = await MioStoreResolver.shared.stores().message }
                .alert("Datalagring", isPresented: Binding(get: { storageMessage != nil },
                                                          set: { if !$0 { storageMessage = nil } })) {
                    Button("OK", role: .cancel) { storageMessage = nil }
                } message: {
                    Text(storageMessage ?? "")
                }
        }
    }
}
