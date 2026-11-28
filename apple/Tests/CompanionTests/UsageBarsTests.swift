import XCTest
@testable import Companion
import CompanionBoard

final class UsageBarsTests: XCTestCase {
    func testTaskBarIsTokensOverEstimateCappedAtFull() {
        XCTAssertEqual(TokenBar.fraction(used: 50_000, estimate: 200_000), 0.25, accuracy: 0.0001)
        XCTAssertEqual(TokenBar.fraction(used: 200_000, estimate: 200_000), 1)
        XCTAssertEqual(TokenBar.fraction(used: 900_000, estimate: 200_000), 1)
        XCTAssertEqual(TokenBar.fraction(used: 10, estimate: nil), 0)
    }

    func testBarTurnsWarningPastOneTimesAndStuckPastThreeTimes() {
        XCTAssertEqual(TokenBar.level(used: 200_000, estimate: 200_000), .within)
        XCTAssertEqual(TokenBar.level(used: 200_001, estimate: 200_000), .over)
        XCTAssertEqual(TokenBar.level(used: 600_000, estimate: 200_000), .over)
        XCTAssertEqual(TokenBar.level(used: 600_001, estimate: 200_000), .runaway)
        XCTAssertEqual(TokenBar.level(used: 5, estimate: nil), .within)
        XCTAssertEqual(TokenBar.Level.over.tone, .caution)
    }

    func testPlanBarUsesTheFullestWindow() {
        let week = PlanLimit(id: "seven_day", name: "Week", used: 0.9, resets: nil)
        let hours = PlanLimit(id: "five_hour", name: "5 hours", used: 0.2, resets: nil)
        XCTAssertEqual(PlanBar.fullest([hours, week])?.id, "seven_day")
        XCTAssertEqual(PlanBar.tone(used: 0.9), .caution)
        XCTAssertEqual(PlanBar.tone(used: 1), .critical)
    }
}