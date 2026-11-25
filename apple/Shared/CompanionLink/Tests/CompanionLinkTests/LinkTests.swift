import CryptoKit
import XCTest
@testable import CompanionLink

/// The fixture farhelm-relay's tests check too (`seat_channel`), worked out
/// independently (Python's hmac, hashlib and cryptography): a key of the
/// bytes 00 01 02 … 1f, what it derives, and one frame sealed with it.
private enum Fixture {
    static let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    static let seat = "bZRSbJ7BIZBDW7LOkali4wTB-Ph68L9pVn3dyTs5QoE"
    static let channel = "c1-7YwB0LJANUUwgS1gjVCYMF"
    static let deviceToMac = "b1209f7beb2efa144cd222ee45f1fbda5491c971e572706fef3748a18148ce5a"
    static let macToDevice = "a99c9e74f20efade5f05c3db5e7a9fbb1141662e86abe0e73525b448d4b7f738"
    static let sender = "phone-1"
    static let nonce = "AAECAwQFBgcICQoL"
    static let plaintext = "{\"i\":0,\"k\":\"evt\",\"m\":\"M1\",\"n\":1,\"ts\":1794700000000,\"v\":1}\nhello"
    static let ciphertext = "YWaPK1x7ANyyEtZ3eTGPzZBHngAhVPt1HPe92NZc6sKHlE8Mst4XiGy3oMgDOQMI-2bwnR60aLKe9IDiturx6Ew-qhmJVLdttdpymEa3gg"
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

final class LinkKeyTests: XCTestCase {
    func testDerivesWhatTheFixtureSays() throws {
        let key = try XCTUnwrap(LinkKey(text: Fixture.key))
        XCTAssertEqual(key.text, Fixture.key)
        XCTAssertEqual(key.seat, Fixture.seat)
        XCTAssertEqual(key.channel, Fixture.channel)
        XCTAssertEqual(hex(LinkKey.bytes(of: key.sealing(.deviceToMac))), Fixture.deviceToMac)
        XCTAssertEqual(hex(LinkKey.bytes(of: key.sealing(.macToDevice))), Fixture.macToDevice)
    }

    func testRefusesWhatIsNotAKey() {
        XCTAssertNil(LinkKey(text: ""))
        XCTAssertNil(LinkKey(text: "short"))
        XCTAssertNil(LinkKey(text: Fixture.key + "AA"))
        XCTAssertNil(LinkKey(text: "!!" + Fixture.key.dropFirst(2)))
    }

    func testNewKeysDiffer() {
        XCTAssertNotEqual(LinkKey(), LinkKey())
        XCTAssertNotNil(LinkKey(text: LinkKey().text))
    }

    func testRelayAddresses() {
        XCTAssertEqual(RelayAddress.url(from: "farhelm-relay.aurovie.com")?.absoluteString, "wss://farhelm-relay.aurovie.com")
        XCTAssertEqual(RelayAddress.url(from: "https://relay.example.com/")?.absoluteString, "wss://relay.example.com")
        XCTAssertEqual(RelayAddress.url(from: " wss://relay.example.com:8443 ")?.absoluteString, "wss://relay.example.com:8443")
        XCTAssertEqual(RelayAddress.url(from: "http://192.168.1.4:7843")?.absoluteString, "ws://192.168.1.4:7843")
        XCTAssertNil(RelayAddress.url(from: ""))
        XCTAssertNil(RelayAddress.url(from: "ftp://relay.example.com"))
        let base = RelayAddress.url(from: "wss://relay.example.com")!
        XCTAssertEqual(RelayAddress.channel(Fixture.channel, at: base).absoluteString,
                       "wss://relay.example.com/v1/channel/\(Fixture.channel)")
    }
}

final class LinkWireTests: XCTestCase {
    private let key = LinkKey(text: Fixture.key)!

    func testOpensTheFixtureFrame() throws {
        let envelope = RelayEnvelope(channel: Fixture.channel, sender: Fixture.sender,
                                     nonce: Fixture.nonce, ciphertext: Fixture.ciphertext)
        let opened = try LinkWire.open(envelope, with: key.sealing(.deviceToMac))
        XCTAssertEqual(String(decoding: opened, as: UTF8.self), Fixture.plaintext)

        let frame = try LinkWire.unframe(opened)
        XCTAssertEqual(frame.header.k, .event)
        XCTAssertEqual(frame.header.m, "M1")
        XCTAssertEqual(String(decoding: frame.payload, as: UTF8.self), "hello")
    }

    func testFramesAsTheFixtureDoes() throws {
        let header = FrameHeader(message: "M1", part: 0, parts: 1, kind: .event, time: 1_794_700_000_000)
        let framed = try LinkWire.frame(header, Data("hello".utf8))
        XCTAssertEqual(String(decoding: framed, as: UTF8.self), Fixture.plaintext)
    }

    func testTheRelayCannotMoveAFrame() throws {
        let sealed = try LinkWire.seal(Data("say hi".utf8), with: key.sealing(.deviceToMac),
                                       channel: Fixture.channel, sender: "phone-1")
        XCTAssertEqual(try LinkWire.open(sealed, with: key.sealing(.deviceToMac)), Data("say hi".utf8))

        // Passed off as another device's, or as another channel's: refused.
        var other = sealed
        other.sender = "phone-2"
        XCTAssertThrowsError(try LinkWire.open(other, with: key.sealing(.deviceToMac)))
        other = sealed
        other.channel = "c1-AAAAAAAAAAAAAAAAAAAAAA"
        XCTAssertThrowsError(try LinkWire.open(other, with: key.sealing(.deviceToMac)))
        // Sent back the other way: refused.
        XCTAssertThrowsError(try LinkWire.open(sealed, with: key.sealing(.macToDevice)))
        // A different pairing: refused.
        XCTAssertThrowsError(try LinkWire.open(sealed, with: LinkKey().sealing(.deviceToMac)))
    }

    func testTheEnvelopeIsTheRelaysShape() throws {
        let sealed = try LinkWire.seal(Data(), with: key.sealing(.macToDevice), channel: Fixture.channel, sender: "mac")
        let text = try LinkWire.text(sealed)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["channel", "sender_id", "nonce", "ciphertext"])
        XCTAssertEqual(object["sender_id"], "mac")
    }

    func testALongMessageFitsTheRelay() throws {
        let body = Data(repeating: 7, count: LinkWire.partSize * 2 + 10)
        let parts = LinkWire.parts(of: body)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.count }, body.count)
        XCTAssertEqual(LinkWire.parts(of: Data()).count, 1)

        var header = FrameHeader(message: UUID().uuidString, part: 0, parts: 3, kind: .request)
        header.query = ["name": String(repeating: "x", count: 200)]
        let framed = try LinkWire.frame(header, parts[0])
        let sealed = try LinkWire.seal(framed, with: key.sealing(.deviceToMac),
                                       channel: Fixture.channel, sender: UUID().uuidString)
        let text = try LinkWire.text(sealed)
        // farhelm-relay's ceiling for one envelope.
        XCTAssertLessThan(text.utf8.count, 256 * 1024)
    }
}

final class LinkAssemblerTests: XCTestCase {
    private func frame(_ id: String, _ part: Int, of count: Int, _ bytes: String, to: String? = nil,
                       at time: Int64 = LinkClock.now()) -> Frame {
        var header = FrameHeader(message: id, part: part, parts: count, kind: .request, time: time)
        header.to = to
        if part == 0 { header.path = "/attach" }
        return Frame(header: header, payload: Data(bytes.utf8))
    }

    func testPutsPartsBackInOrderWhateverOrderTheyCome() {
        var assembler = LinkAssembler(me: "mac")
        XCTAssertNil(assembler.take(frame("A", 2, of: 3, "c"), from: "p")?.message)
        XCTAssertEqual(assembler.take(frame("A", 0, of: 3, "a"), from: "p")?.received, 2)
        let whole = assembler.take(frame("A", 1, of: 3, "b"), from: "p")?.message
        XCTAssertEqual(whole.map { String(decoding: $0.body, as: UTF8.self) }, "abc")
        XCTAssertEqual(whole?.header.path, "/attach")
        XCTAssertEqual(whole?.from, "p")
    }

    func testARepeatIsDropped() {
        var assembler = LinkAssembler(me: "mac")
        XCTAssertNotNil(assembler.take(frame("B", 0, of: 1, "once"), from: "p")?.message)
        XCTAssertNil(assembler.take(frame("B", 0, of: 1, "once"), from: "p"))
        // A part sent twice counts once.
        XCTAssertNotNil(assembler.take(frame("C", 0, of: 2, "x"), from: "p"))
        XCTAssertNil(assembler.take(frame("C", 0, of: 2, "x"), from: "p"))
    }

    func testStaleAndForeignFramesAreDropped() {
        var assembler = LinkAssembler(me: "mac")
        let old = LinkClock.now() - 6 * 60 * 1000
        XCTAssertNil(assembler.take(frame("D", 0, of: 1, "late", at: old), from: "p"))
        XCTAssertNil(assembler.take(frame("E", 0, of: 1, "x", to: "phone-2"), from: "p"))
        XCTAssertNotNil(assembler.take(frame("F", 0, of: 1, "x", to: "mac"), from: "p")?.message)
        XCTAssertNil(assembler.take(frame("G", 0, of: 0, "x"), from: "p"))
        XCTAssertNil(assembler.take(frame("H", 3, of: 2, "x"), from: "p"))
    }

    func testTheSameIdFromTwoDevicesIsTwoMessages() {
        var assembler = LinkAssembler(me: "mac")
        XCTAssertNotNil(assembler.take(frame("I", 0, of: 1, "x"), from: "phone-1")?.message)
        XCTAssertNotNil(assembler.take(frame("I", 0, of: 1, "x"), from: "phone-2")?.message)
    }
}

final class GateTests: XCTestCase {
    /// A ping's handler can be called twice (the pong, then an error when
    /// the socket is cancelled). The second answer must be dropped: a
    /// continuation resumed twice stops the app.
    func testOnlyTheFirstAnswerResumesTheWaiter() async throws {
        let gate = Gate<Int>()
        let value: Int = try await withCheckedThrowingContinuation { continuation in
            gate.hold(continuation)
            XCTAssertTrue(gate.finish(.success(1)))
            XCTAssertFalse(gate.finish(.failure(LinkError.closed)))
            XCTAssertFalse(gate.finish(.success(2)))
        }
        XCTAssertEqual(value, 1)
    }

    func testAnAnswerWithNobodyWaitingIsDropped() {
        XCTAssertFalse(Gate<Void>().finish(.success(())))
    }
}
