import XCTest
@testable import Companion

final class WatchClaudeAppTests: XCTestCase {
    /// A restart rebuilds settings from storage, so the switch is read back
    /// from UserDefaults the same way AppSettings reads it at launch.
    @MainActor
    func testWatchingStaysOnAfterSettingsAreReloaded() {
        let settings = AppSettings.shared
        let before = settings.watchClaudeApp
        defer { settings.watchClaudeApp = before }

        settings.watchClaudeApp = true
        XCTAssertTrue(AppSettings.flag("watchClaudeApp", in: .standard))
    }
}
