import XCTest
@testable import CompanionKit

final class PairingTests: XCTestCase {
    func testParsesAPairingLink() throws {
        let link = "companion://pair?v=1&id=ABC&name=Harsh%E2%80%99s%20Mac&port=7345&hosts=mac.local,192.168.1.4,100.101.2.3&token=k2m4p6q8r9"
        let mac = try XCTUnwrap(PairingLink.parse(link))
        XCTAssertEqual(mac.id, "ABC")
        XCTAssertEqual(mac.name, "Harsh\u{2019}s Mac")
        XCTAssertEqual(mac.port, 7345)
        XCTAssertEqual(mac.hosts, ["mac.local", "192.168.1.4", "100.101.2.3"])
        XCTAssertEqual(mac.token, "k2m4p6q8r9")
    }

    func testRejectsOtherLinks() {
        XCTAssertNil(PairingLink.parse("https://example.com"))
        XCTAssertNil(PairingLink.parse("companion://pair?id=A&port=1&hosts=a"))          // no token
        XCTAssertNil(PairingLink.parse("companion://pair?id=A&port=0&hosts=a&token=t"))  // bad port
        XCTAssertNil(PairingLink.parse("companion://pair?id=A&port=80&hosts=&token=t"))  // no address
    }

    func testLastWorkingHostIsTriedFirst() {
        let mac = PairedMac(id: "A", name: "Mac", port: 1, hosts: ["a", "b", "c"], token: "t", lastHost: "c")
        XCTAssertEqual(mac.hostsToTry, ["c", "a", "b"])
    }

    func testDecodesAFeedUpdate() throws {
        let json = """
        {"full":true,"meta":{"chat":"C","title":"T","status":"Ready","agentRunning":true,"agentStatus":"Reading x","replying":false,"mac":"M"},
         "order":["1"],"changed":[{"id":"1","me":"hi","reply":"hello","model":"m","error":"","image":false,"streaming":true,"working":true,
         "date":1700000000,"steps":[{"kind":"run","title":"ls","failed":false}],"plan":[{"text":"Read","state":"doing"}]}]}
        """
        let update = try JSONDecoder().decode(FeedUpdate.self, from: Data(json.utf8))
        XCTAssertTrue(update.meta.agentRunning)
        XCTAssertEqual(update.changed.first?.steps.first?.title, "ls")
        XCTAssertEqual(update.changed.first?.plan.first?.state, .doing)
    }
}
