import ForgeWatchUI
import SwiftUI

/// The watchOS app.
///
/// Deliberately three lines. Everything real is in `ForgeWatchUI` and
/// `ForgeWatchKit`, which are package targets — so they build and test on a Mac
/// with `swift test`, without a watch, a simulator, or a provisioning profile.
/// An app target that carried logic would be logic nothing could test.
@main
struct RelayForgeWatchApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
