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
    @State private var storageMessage: String?

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
        _model = State(initialValue: capture)
        _contentModel = State(initialValue: content)
        _assistantModel = State(initialValue: assistant)
        _analysis = State(initialValue: analysis)
        _workflow = State(initialValue: MioWorkflowCoordinator(capture: capture, content: content,
                                                              assistant: assistant, analysis: analysis))
        _navigation = State(initialValue: navigation)
        _day = State(initialValue: day)
        MioSystemServices.shared.configureNotificationRouting { navigation.receive($0) }
        MioMetricKitSubscriber.shared.start()
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
