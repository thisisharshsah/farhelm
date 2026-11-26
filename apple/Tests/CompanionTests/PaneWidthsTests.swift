import XCTest
@testable import Companion

final class PaneWidthsTests: XCTestCase {
    private let gap: CGFloat = 8
    /// Compact, regular and full screen widths from the design's size rules.
    private let windows: [CGFloat] = [480, 540, 800, 1000, 1440, 1920]

    private func sidebar() -> PaneWidths.Pane {
        .init(id: "sidebar", wanted: 236, least: 170, rank: 0)
    }

    /// Board mode: sidebar, board in the middle, chat on the right.
    private func board() -> [PaneWidths.Pane] {
        [sidebar(),
         .init(id: "board", wanted: 620, least: 520, rank: 2, fills: true),
         .init(id: "chat", wanted: 400, least: 300, rank: 1)]
    }

    /// Chat mode with the browser or details open beside it.
    private func chat(side: CGFloat) -> [PaneWidths.Pane] {
        [sidebar(),
         .init(id: "chat", wanted: 560, least: 320, rank: 2, fills: true),
         .init(id: "side", wanted: side, least: 320, rank: 1)]
    }

    func testPanesNeverAddUpPastTheWindow() {
        for window in windows {
            for panes in [board(), chat(side: 460), chat(side: 300), [sidebar()]] {
                let layout = PaneWidths(window: window, gap: gap, panes: panes)
                XCTAssertLessThanOrEqual(layout.total, window + 0.001, "window \(window), \(panes.map(\.id))")
                for id in panes.map(\.id) where layout.shows(id) {
                    XCTAssertGreaterThan(layout.width(id), 0)
                }
            }
        }
    }

    func testFullWidthShowsEveryPaneAndUsesTheWholeWindow() {
        let layout = PaneWidths(window: 1440, gap: gap, panes: board())
        XCTAssertTrue(layout.shows("sidebar"))
        XCTAssertTrue(layout.shows("board"))
        XCTAssertTrue(layout.shows("chat"))
        XCTAssertEqual(layout.total, 1440, accuracy: 0.001)
        XCTAssertEqual(layout.width("sidebar"), 236, accuracy: 0.001)
        XCTAssertEqual(layout.width("chat"), 400, accuracy: 0.001)
    }

    func testRegularWidthPutsTheSidebarAwayFirst() {
        // 170 + 520 + 300 and four gaps is 1022: no room for all three.
        let layout = PaneWidths(window: 1000, gap: gap, panes: board())
        XCTAssertFalse(layout.shows("sidebar"))
        XCTAssertTrue(layout.shows("board"))
        XCTAssertTrue(layout.shows("chat"))
        XCTAssertLessThanOrEqual(layout.total, 1000 + 0.001)
    }

    func testCompactWidthKeepsOnlyTheMostImportantPane() {
        let layout = PaneWidths(window: 480, gap: gap, panes: board())
        XCTAssertEqual(layout.widths.keys.sorted(), ["board"])
        XCTAssertEqual(layout.width("board"), 480 - 2 * gap, accuracy: 0.001)
    }

    func testFrameIsClampedToTheVisibleFrame() {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
        // Past the right edge and wider than the screen.
        let wide = PaneWidths.clamp(CGRect(x: 600, y: 100, width: 1800, height: 700), to: visible)
        XCTAssertTrue(visible.contains(wide))
        XCTAssertEqual(wide.width, 1440)
        // Past the right edge but fits: moved in, size kept.
        let moved = PaneWidths.clamp(CGRect(x: 1200, y: 100, width: 800, height: 700), to: visible)
        XCTAssertTrue(visible.contains(moved))
        XCTAssertEqual(moved.size, CGSize(width: 800, height: 700))
        XCTAssertEqual(moved.maxX, visible.maxX)
        // Taller than the screen and under the Dock.
        let tall = PaneWidths.clamp(CGRect(x: 100, y: 0, width: 600, height: 1200), to: visible)
        XCTAssertTrue(visible.contains(tall))
        // Already inside: unchanged.
        let inside = CGRect(x: 100, y: 200, width: 600, height: 500)
        XCTAssertEqual(PaneWidths.clamp(inside, to: visible), inside)
    }
}