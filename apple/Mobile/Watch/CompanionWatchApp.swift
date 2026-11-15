import CompanionKit
import SwiftUI

/// Companion on Apple Watch: how the task on your Mac is going, its plan,
/// the last reply, and Stop. Replies are dictated or picked. It reaches
/// the Mac through the iPhone.
@main
struct CompanionWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchView()
                .environment(model)
                .onAppear { model.activate() }
        }
    }
}
