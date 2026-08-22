import FarhelmWatchUI
import SwiftUI

/// The watchOS app.
///
/// Deliberately three lines. Everything real is in `FarhelmWatchUI` and
/// `FarhelmWatchKit`, which are package targets — so they build and test on a Mac
/// with `swift test`, without a watch, a simulator, or a provisioning profile.
/// An app target that carried logic would be logic nothing could test.
@main
struct FarhelmWatchApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
