import XCTest
@testable import Companion

final class ChatPageActionTests: XCTestCase {
    private let turnID = UUID()
    private var turnString: String { turnID.uuidString }

    private func decode(_ kind: String) -> ChatPageAction? {
        ChatPageAction(json: ["kind": kind, "turn": turnString])
    }

    func testDecodesCopy() { XCTAssertEqual(decode("copy"), .copy(turn: turnID)) }
    func testDecodesReadAloud() { XCTAssertEqual(decode("readAloud"), .readAloud(turn: turnID)) }
    func testDecodesThumbsUp() { XCTAssertEqual(decode("thumbsUp"), .thumbsUp(turn: turnID)) }
    func testDecodesThumbsDown() { XCTAssertEqual(decode("thumbsDown"), .thumbsDown(turn: turnID)) }
    func testDecodesRegenerate() { XCTAssertEqual(decode("regenerate"), .regenerate(turn: turnID)) }
    func testDecodesEdit() { XCTAssertEqual(decode("edit"), .edit(turn: turnID)) }
    func testDecodesDelete() { XCTAssertEqual(decode("delete"), .delete(turn: turnID)) }
    func testDecodesOpenWork() { XCTAssertEqual(decode("openWork"), .openWork(turn: turnID)) }
    func testDecodesCloseWork() { XCTAssertEqual(decode("closeWork"), .closeWork(turn: turnID)) }

    func testUnknownKindRefused() {
        XCTAssertNil(decode("teleport"))
        XCTAssertNil(decode(""))
    }

    func testMalformedPayloadsRefused() {
        XCTAssertNil(ChatPageAction(json: "copy"))
        XCTAssertNil(ChatPageAction(json: 7))
        XCTAssertNil(ChatPageAction(json: NSNull()))
        XCTAssertNil(ChatPageAction(json: [String: Any]()))
        XCTAssertNil(ChatPageAction(json: ["kind": "copy"]))
        XCTAssertNil(ChatPageAction(json: ["kind": "copy", "turn": "not-a-uuid"]))
        XCTAssertNil(ChatPageAction(json: ["turn": turnString]))
        XCTAssertNil(ChatPageAction(json: ["kind": 7, "turn": turnString]))
        XCTAssertNil(ChatPageAction(json: ["kind": "copy", "turn": 7]))
    }

    func testTurnIDMatchesPayload() {
        guard let action = decode("copy") else { return XCTFail("decode failed") }
        XCTAssertEqual(action.turnID, turnID)
    }

    func testKindRoundTripsThroughName() {
        let expected: [(String, ChatPageAction)] = [
            ("copy", .copy(turn: turnID)),
            ("readAloud", .readAloud(turn: turnID)),
            ("thumbsUp", .thumbsUp(turn: turnID)),
            ("thumbsDown", .thumbsDown(turn: turnID)),
            ("regenerate", .regenerate(turn: turnID)),
            ("edit", .edit(turn: turnID)),
            ("delete", .delete(turn: turnID)),
            ("openWork", .openWork(turn: turnID)),
            ("closeWork", .closeWork(turn: turnID)),
        ]
        for (name, action) in expected {
            XCTAssertEqual(action.kind, name)
            XCTAssertEqual(ChatPageAction(json: ["kind": name, "turn": turnString]), action)
        }
    }
}