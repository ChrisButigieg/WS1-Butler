import SwiftUI

@main
struct WS1ButlerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("WS1 Butler") {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        #if os(macOS)
        .defaultSize(width: 1360, height: 860)
        .windowToolbarStyle(.unified)
        #endif
    }
}
