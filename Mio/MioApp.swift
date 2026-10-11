import SwiftUI

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
    @State private var liveActivity: MioLiveActivityController
    @State private var lessonNotes: MioLessonNotesBackgroundTask

    init() {
        let capture = MioViewModel()
        let content = MioContentViewModel()
        let assistant = MioAssistantViewModel()
        let analysis = MioAnalysisCoordinator()
        let day = MioDayContext()
        let navigation = MioNavigationCoordinator(onDailyRoute: {
            day.refresh()
            day.select(day.referenceDate)
        })
        let workflow = MioWorkflowCoordinator(capture: capture, content: content,
                                              assistant: assistant, analysis: analysis)
        _model = State(initialValue: capture)
        _contentModel = State(initialValue: content)
        _assistantModel = State(initialValue: assistant)
        _analysis = State(initialValue: analysis)
        _workflow = State(initialValue: workflow)
        _navigation = State(initialValue: navigation)
        _day = State(initialValue: day)
        MioSystemServices.shared.configureNotificationRouting { navigation.receive($0) }
        // Lock Screen presence: Live Activity with App Intent controls, and iOS's own
        // progress UI for lesson notes that continue after the user leaves the app.
        let liveActivity = MioLiveActivityController(capture: capture)
        let lessonNotes = MioLessonNotesBackgroundTask(capture: capture, analysis: analysis, assistant: assistant)
        _liveActivity = State(initialValue: liveActivity)
        _lessonNotes = State(initialValue: lessonNotes)
        workflow.onLessonNotesStarted = { lessonNotes.begin(sessionID: $0) }
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
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, contentModel: contentModel)
                .environment(assistantModel)
                .environment(analysis)
                .environment(workflow)
                .environment(navigation)
                .environment(day)
        }
    }
}
