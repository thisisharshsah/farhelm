import Foundation
import Testing

@testable import ForgeCrypto
@testable import ForgeWatchKit

@Suite("watch pairing")
struct WatchPairingTests {
    @Test("sends only the public key")
    func sendsOnlyPublicKey() {
        let (message, identity) = WatchPairing.request()

        #expect(message["kind"] as? String == "pair-request")
        #expect(message["public_key"] as? String == identity.publicKey)
        // The one property that matters: nothing in the message can be used to
        // approve anything. The secret stays on the wrist.
        #expect(message.count == 2)
        #expect(!message.values.contains { ($0 as? String) == identity.toSecret() })
    }

    @Test("keeps the locally generated secret when the phone replies")
    func keepsSecret() throws {
        let (_, identity) = WatchPairing.request()
        let runner = Identity.generate()

        let pairing = try WatchPairing.complete(
            reply: [
                "kind": "pair-response",
                "relay_url": "wss://relay.test",
                "channel": "forge-abc",
                "runner_public_key": runner.publicKey,
                "device_id": "watch-1",
            ],
            identity: identity
        )

        #expect(pairing.secret == identity.toSecret())
        #expect(pairing.deviceID == "watch-1")
        #expect(pairing.runnerPublicKey == runner.publicKey)

        // And the stored secret really is this watch's key.
        #expect(try Identity.fromSecret(pairing.secret).publicKey == identity.publicKey)
    }

    @Test("surfaces the phone's refusal verbatim")
    func surfacesRefusal() {
        let (_, identity) = WatchPairing.request()
        #expect(throws: WatchPairing.PairingError.refused("pairing code already used")) {
            try WatchPairing.complete(
                reply: ["kind": "pair-failed", "message": "pairing code already used"],
                identity: identity
            )
        }
    }

    @Test("rejects a reply missing the relay")
    func rejectsNoRelay() {
        let (_, identity) = WatchPairing.request()
        #expect(throws: WatchPairing.PairingError.malformedReply) {
            try WatchPairing.complete(
                reply: [
                    "kind": "pair-response",
                    "relay_url": "",
                    "channel": "c",
                    "runner_public_key": Identity.generate().publicKey,
                    "device_id": "w",
                ],
                identity: identity
            )
        }
    }

    @Test("rejects a malformed runner key before storing anything")
    func rejectsBadRunnerKey() {
        let (_, identity) = WatchPairing.request()
        #expect(throws: WatchPairing.PairingError.malformedReply) {
            try WatchPairing.complete(
                reply: [
                    "kind": "pair-response",
                    "relay_url": "wss://r",
                    "channel": "c",
                    "runner_public_key": Base64URL.encode([UInt8](repeating: 0, count: 16)),
                    "device_id": "w",
                ],
                identity: identity
            )
        }
    }

    @Test("gives every watch a distinct key")
    func distinctKeys() {
        // A shared key across watches would make `decided_via` ambiguous and
        // unpairing one revoke them all.
        #expect(WatchPairing.request().identity.publicKey != WatchPairing.request().identity.publicKey)
    }
}

@Suite("wire format")
struct WireFormatTests {
    @Test("encodes a decision the way the runner reads it")
    func decisionShape() throws {
        let data = try JSONEncoder().encode(
            Command.decide(approvalID: "a1", decision: .approved))
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Field names come from `forge_runner::commands::Command`; a rename here
        // is a silent no-op on the runner, which just ignores the envelope.
        #expect(json["type"] as? String == "decide")
        #expect(json["approval_id"] as? String == "a1")
        #expect(json["decision"] as? String == "approved")
    }

    @Test("encodes a snapshot request as a bare tag")
    func snapshotShape() throws {
        let data = try JSONEncoder().encode(Command.snapshot)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "snapshot")
        #expect(json.count == 1)
    }

    @Test("decodes a fleet the runner would send")
    func decodesFleet() throws {
        let json = """
            {
              "sessions": [{
                "id": "s1", "repo_name": "payments-api", "machine_name": "laptop",
                "agent": "claude_code", "status": "awaiting_approval", "is_live": true,
                "plan": {"total": 7, "settled": 2, "current_ordinal": 3, "current_title": "Patch retry backoff"},
                "budget": {"cap_usd": 5.0, "spent_usd": 1.25, "pct": 0.25, "state": "ok"},
                "started_at": 1785369600000, "ended_at": null, "awaiting_approval_id": "a1"
              }],
              "pending_approvals": [{
                "id": "a1", "session_id": "s1", "tool": "Bash",
                "payload": "git push --force origin main", "risk": "destructive",
                "decision": null, "decided_via": null,
                "requested_at": 1785369600000, "decided_at": null,
                "repo_name": "payments-api", "allows_watch_decision": false,
                "budget": {"cap_usd": 5.0, "spent_usd": 1.25, "pct": 0.25, "state": "ok"}
              }],
              "today_usd": 1.25, "cache_hit_ratio": 0.82
            }
            """
        let fleet = try JSONDecoder().decode(FleetView.self, from: Data(json.utf8))

        #expect(fleet.sessions.first?.status == .awaitingApproval)
        #expect(fleet.sessions.first?.plan?.currentTitle == "Patch retry backoff")
        #expect(fleet.pendingApprovals.first?.allowsWatchDecision == false)
        #expect(fleet.todayUSD == 1.25)
    }

    @Test("decodes each event the runner publishes")
    func decodesEvents() throws {
        let decoder = JSONDecoder()
        #expect(
            try decoder.decode(
                ServerEvent.self,
                from: Data(#"{"type":"session_upsert","session_id":"s1"}"#.utf8))
                == .sessionUpsert(sessionID: "s1"))
        #expect(
            try decoder.decode(
                ServerEvent.self,
                from: Data(#"{"type":"budget_alert","session_id":"s1","pct":0.8,"hard_stop":false}"#.utf8))
                == .budgetAlert(sessionID: "s1", pct: 0.8, hardStop: false))
        #expect(
            try decoder.decode(
                ServerEvent.self,
                from: Data(#"{"type":"command_error","message":"nope"}"#.utf8))
                == .commandError(message: "nope"))
    }

    @Test("treats an unknown event as unknown rather than failing")
    func toleratesNewEvents() throws {
        // The runner will grow events this build has never heard of. Refusing to
        // decode one would break the whole stream over a field nobody reads.
        let event = try JSONDecoder().decode(
            ServerEvent.self, from: Data(#"{"type":"something_new","extra":1}"#.utf8))
        #expect(event == .unknown("something_new"))
    }

    @Test("ignores fields this build does not know about")
    func toleratesNewFields() throws {
        let json = """
            {"sessions": [], "pending_approvals": [], "today_usd": 0.0,
             "cache_hit_ratio": 0.0, "something_added_later": {"a": 1}}
            """
        let fleet = try JSONDecoder().decode(FleetView.self, from: Data(json.utf8))
        #expect(fleet.sessions.isEmpty)
    }
}
