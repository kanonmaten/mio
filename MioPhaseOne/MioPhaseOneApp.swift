import SwiftUI

@main
@MainActor
struct MioPhaseOneApp: App {
    @State private var model = PhaseOneViewModel()
    @State private var contentModel = MioContentViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, contentModel: contentModel)
        }
    }
}
