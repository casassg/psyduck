import SwiftUI

@main
struct GHPRsApp: App {
    var body: some Scene {
        WindowGroup("Pull Requests") {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1280, height: 720)
    }
}
