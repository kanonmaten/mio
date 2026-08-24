import SwiftUI

@main
@MainActor
struct MioPhaseTwoApp: App {
    @State private var model = MioViewModel()
    @State private var contentModel = MioContentViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, contentModel: contentModel)
        }
    }
}
