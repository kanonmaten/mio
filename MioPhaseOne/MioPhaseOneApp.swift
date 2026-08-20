import SwiftUI

@main
@MainActor
struct MioPhaseOneApp: App {
    @State private var model = PhaseOneViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
