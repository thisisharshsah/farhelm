import XCTest
@testable import Companion

final class AdvancedPaneLayoutTests: XCTestCase {
    private let gap: CGFloat = 6

    // MARK: - Three panes at three widths

    func testFullScreenShowsAllThreePanes() {
        let layout = AdvancedPaneLayout(
            available: 1440, gap: gap,
            boardOpen: true, detailOpen: true, chatOpen: true)
        XCTAssertNotNil(layout.board)
        XCTAssertNotNil(layout.detail)
        XCTAssertNotNil(layout.chat)
        XCTAssertFalse(layout.compact)
        XCTAssertGreaterThanOrEqual(layout.board!, AdvancedPaneLayout.boardMin)
        XCTAssertGreaterThanOrEqual(layout.detail!, AdvancedPaneLayout.detailMin)
        XCTAssertGreaterThanOrEqual(layout.chat!, AdvancedPaneLayout.chatMin)
        XCTAssertEqual(layout.total, 1440, accuracy: 0.001)
    }

    func testRegularWidthHidesBoardKeepsDetailAndChat() {
        // Three minimums + 2 gaps = 280+280+300+12 = 872. Use 800.
        let layout = AdvancedPaneLayout(
            available: 800, gap: gap,
            boardOpen: true, detailOpen: true, chatOpen: true)
        XCTAssertNil(layout.board, "Board should give way first")
        XCTAssertNotNil(layout.detail, "Detail stays when board gives way")
        XCTAssertNotNil(layout.chat, "Chat stays when board gives way")
        XCTAssertFalse(layout.compact)
        XCTAssertGreaterThanOrEqual(layout.detail!, AdvancedPaneLayout.detailMin)
        XCTAssertGreaterThanOrEqual(layout.chat!, AdvancedPaneLayout.chatMin)
        XCTAssertEqual(layout.total, 800, accuracy: 0.001)
    }

    func testCompactWidthShowsOnePane() {
        // Detail + chat + gap = 280+300+6 = 586. Use 480.
        let layout = AdvancedPaneLayout(
            available: 480, gap: gap,
            boardOpen: true, detailOpen: true, chatOpen: true)
        XCTAssertNil(layout.board)
        XCTAssertTrue(layout.compact)
        let shown = [layout.detail, layout.chat].compactMap { $0 }
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(layout.total, 480, accuracy: 0.001)
    }

    // MARK: - Board gives way first

    func testBoardIsTheOneHiddenWhenThreeDoNotFit() {
        let threshold = AdvancedPaneLayout.boardMin + AdvancedPaneLayout.detailMin
            + AdvancedPaneLayout.chatMin + 2 * gap
        let layout = AdvancedPaneLayout(
            available: threshold - 1, gap: gap,
            boardOpen: true, detailOpen: true, chatOpen: true)
        XCTAssertNil(layout.board, "The board is the one hidden")
        XCTAssertNotNil(layout.detail, "Detail stays")
        XCTAssertNotNil(layout.chat, "Chat stays")
    }

    // MARK: - Widths add up to available

    func testWidthsAddUpAtEverySize() {
        let widths: [CGFloat] = [400, 480, 600, 800, 1000, 1200, 1440, 1920]
        for w in widths {
            let layout = AdvancedPaneLayout(
                available: w, gap: gap,
                boardOpen: true, detailOpen: true, chatOpen: true)
            XCTAssertEqual(layout.total, w, accuracy: 0.001, "at \(w)")
            for pane in [layout.board, layout.detail, layout.chat].compactMap({ $0 }) {
                XCTAssertGreaterThan(pane, 0, "at \(w)")
            }
        }
    }

    // MARK: - Two panes

    func testBoardAndDetail() {
        let layout = AdvancedPaneLayout(
            available: 900, gap: gap,
            boardOpen: true, detailOpen: true, chatOpen: false)
        XCTAssertNotNil(layout.board)
        XCTAssertNotNil(layout.detail)
        XCTAssertNil(layout.chat)
        XCTAssertEqual(layout.total, 900, accuracy: 0.001)
    }

    func testDetailAndChat() {
        let layout = AdvancedPaneLayout(
            available: 700, gap: gap,
            boardOpen: false, detailOpen: true, chatOpen: true)
        XCTAssertNotNil(layout.detail)
        XCTAssertNotNil(layout.chat)
        XCTAssertNil(layout.board)
        XCTAssertEqual(layout.total, 700, accuracy: 0.001)
    }

    // MARK: - Single pane fills

    func testBoardAloneFills() {
        let layout = AdvancedPaneLayout(
            available: 500, gap: gap,
            boardOpen: true, detailOpen: false, chatOpen: false)
        XCTAssertEqual(layout.board, 500)
        XCTAssertNil(layout.detail)
        XCTAssertNil(layout.chat)
    }

    func testDetailAloneFills() {
        let layout = AdvancedPaneLayout(
            available: 400, gap: gap,
            boardOpen: false, detailOpen: true, chatOpen: false)
        XCTAssertEqual(layout.detail, 400)
    }

    // MARK: - Compact focus

    func testCompactFocusDetail() {
        let layout = AdvancedPaneLayout(
            available: 480, gap: gap,
            boardOpen: true, detailOpen: true, chatOpen: true,
            focus: .detail)
        XCTAssertNotNil(layout.detail)
        XCTAssertNil(layout.chat)
        XCTAssertTrue(layout.compact)
    }

    func testCompactFocusChat() {
        let layout = AdvancedPaneLayout(
            available: 480, gap: gap,
            boardOpen: true, detailOpen: true, chatOpen: true,
            focus: .chat)
        XCTAssertNil(layout.detail)
        XCTAssertNotNil(layout.chat)
        XCTAssertTrue(layout.compact)
    }

    // MARK: - Nothing open

    func testNoPanesOpen() {
        let layout = AdvancedPaneLayout(
            available: 1000, gap: gap,
            boardOpen: false, detailOpen: false, chatOpen: false)
        XCTAssertNil(layout.board)
        XCTAssertNil(layout.detail)
        XCTAssertNil(layout.chat)
        XCTAssertFalse(layout.compact)
    }

    // MARK: - Preferred widths are reached before filler grows

    func testDetailAndChatReachPreferredWidths() {
        let layout = AdvancedPaneLayout(
            available: 1440, gap: gap,
            boardOpen: true, detailOpen: true, chatOpen: true)
        XCTAssertGreaterThanOrEqual(layout.detail!, AdvancedPaneLayout.detailPreferred)
        XCTAssertGreaterThanOrEqual(layout.chat!, AdvancedPaneLayout.chatPreferred)
    }

    // MARK: - Exact threshold

    func testExactlyAtThresholdShowsAllThree() {
        let threshold = AdvancedPaneLayout.boardMin + AdvancedPaneLayout.detailMin
            + AdvancedPaneLayout.chatMin + 2 * gap
        let layout = AdvancedPaneLayout(
            available: threshold, gap: gap,
            boardOpen: true, detailOpen: true, chatOpen: true)
        XCTAssertNotNil(layout.board, "At the exact threshold, all three fit")
        XCTAssertNotNil(layout.detail)
        XCTAssertNotNil(layout.chat)
        XCTAssertEqual(layout.total, threshold, accuracy: 0.001)
    }
}