import XCTest
@testable import Companion

@MainActor
final class ChatPageMessageTests: XCTestCase {
    private final class Received { var actions: [ChatPageAction] = [] }

    func testReceiveCallsDispatchForEveryCase() {
        let box = Received()
        let coordinator = ChatDocumentPane.Coordinator(onAction: { @MainActor action in
            box.actions.append(action)
        })
        let turn = UUID()
        let actions: [ChatPageAction] = [
            .copy(turn: turn), .readAloud(turn: turn), .thumbsUp(turn: turn),
            .thumbsDown(turn: turn), .regenerate(turn: turn), .edit(turn: turn),
            .delete(turn: turn), .openWork(turn: turn), .closeWork(turn: turn),
        ]
        for action in actions { coordinator.receive(action) }
        XCTAssertEqual(box.actions, actions)
        XCTAssertEqual(coordinator.receivedActions, actions)
    }

    func testOpenAndCloseWorkMaintainsSet() {
        let coordinator = ChatDocumentPane.Coordinator(onAction: { @MainActor _ in })
        let a = UUID()
        let b = UUID()
        coordinator.receive(.openWork(turn: a))
        coordinator.receive(.openWork(turn: b))
        XCTAssertEqual(coordinator.workOpen, [a, b])
        coordinator.receive(.closeWork(turn: a))
        XCTAssertEqual(coordinator.workOpen, [b])
    }

    /// Nothing that fails to decode reaches the coordinator; its state
    /// and the app handler are left alone.
    func testMalformedPayloadsDecodeToNilAndRunNothing() {
        let box = Received()
        let coordinator = ChatDocumentPane.Coordinator(onAction: { @MainActor action in
            box.actions.append(action)
        })
        let before = coordinator.workOpen
        let payloads: [Any] = [
            "copy",
            7,
            NSNull(),
            [String: Any](),
            ["kind": "openWork"],
            ["kind": "openWork", "turn": "not-a-uuid"],
            ["kind": "unknown", "turn": UUID().uuidString],
            ["turn": UUID().uuidString],
        ]
        for payload in payloads {
            if let action = ChatPageAction(json: payload) {
                XCTFail("Expected to refuse \(payload), decoded as \(action)")
            }
        }
        XCTAssertTrue(box.actions.isEmpty)
        XCTAssertEqual(coordinator.workOpen, before)
        XCTAssertTrue(coordinator.receivedActions.isEmpty)
    }
}