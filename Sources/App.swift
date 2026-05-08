import SwiftUI

@main
struct PsyDuckApp: App {
    var body: some Scene {
        WindowGroup("PsyDuck") {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1280, height: 720)
    }
}
