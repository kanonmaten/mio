import SwiftUI

@main
@MainActor
struct MioApp: App {
    @State private var model = MioViewModel()
    @State private var contentModel = MioContentViewModel()
    @State private var assistantModel = MioAssistantViewModel()
    @State private var analysis = MioAnalysisCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, contentModel: contentModel)
                .environment(assistantModel)
                .environment(analysis)
        }
    }
}
