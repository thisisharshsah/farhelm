import XCTest
@testable import CompanionBoard

/// The small Auto badge in the board's header is driven by
/// `BoardSettings.showsAutoBadge`, which the UI reads through
/// `BoardAutoBadge.shouldShow(for:)`. The rule is pinned here, away from
/// SwiftUI, so a change in how the badge is drawn cannot drift from what
/// turns it on.
final class BoardAutoBadgeTests: XCTestCase {
    func testTheBadgeShowsOnlyWhenAutoIsOn() {
        var settings = BoardSettings()
        XCTAssertFalse(settings.auto)
        XCTAssertFalse(settings.showsAutoBadge, "a new board has Auto off, so the badge is hidden")

        settings.auto = true
        XCTAssertTrue(settings.showsAutoBadge, "Auto on: the badge is shown")

        settings.auto = false
        XCTAssertFalse(settings.showsAutoBadge, "Auto off again: the badge is hidden again")
    }

    func testTheBadgeDoesNotFollowAnyOtherSetting() {
        // Autopilot, Supervisor Mode, Review Finished Runs and Own Branch
        // all vary independently of Auto; none of them lights the badge.
        var settings = BoardSettings(autopilot: true, reviewGate: true,
                                     advice: true, followsAdvice: true, copyPerTask: true, auto: false)
        XCTAssertFalse(settings.showsAutoBadge)
        settings.autopilot = false
        settings.followsAdvice = false
        settings.reviewGate = false
        settings.copyPerTask = false
        XCTAssertFalse(settings.showsAutoBadge)
        settings.auto = true
        XCTAssertTrue(settings.showsAutoBadge)
    }
}