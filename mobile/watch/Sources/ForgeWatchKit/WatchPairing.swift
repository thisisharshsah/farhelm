import Foundation
import ForgeCrypto

/// The watch's half of the pairing handshake with the phone.
///
/// The watch generates its own keypair and sends only the **public** half over
/// WatchConnectivity. The phone claims a pairing code on its behalf and sends
/// back the relay coordinates. The secret never leaves the wrist — not over the
/// link, not through the phone's memory, not into a backup.
///
/// The message shapes mirror `mobile/src/watch/bridge.ts`. They are plain
/// dictionaries because that is what `WCSession.sendMessage` takes.
public enum WatchPairing {
    public struct Result: Sendable, Equatable {
        public let pairing: Pairing
    }

    public enum PairingError: Error, LocalizedError, Equatable {
        case refused(String)
        case malformedReply

        public var errorDescription: String? {
            switch self {
            case .refused(let message): return message
            case .malformedReply: return "The phone sent something unreadable."
            }
        }
    }

    /// The message to send. Generates a fresh identity and returns it alongside,
    /// because only the caller can hold the secret until the reply arrives.
    public static func request() -> (message: [String: Any], identity: Identity) {
        let identity = Identity.generate()
        return (
            ["kind": "pair-request", "public_key": identity.publicKey],
            identity
        )
    }

    /// Turn the phone's reply into a pairing, or explain what went wrong.
    ///
    /// The identity is supplied by the caller — it is the one this watch just
    /// generated, and the phone never saw its secret half.
    public static func complete(
        reply: [String: Any],
        identity: Identity
    ) throws -> Pairing {
        if reply["kind"] as? String == "pair-failed" {
            throw PairingError.refused(
                reply["message"] as? String ?? "The phone could not reach the runner."
            )
        }

        guard
            reply["kind"] as? String == "pair-response",
            let relayURL = reply["relay_url"] as? String,
            let channel = reply["channel"] as? String,
            let runnerPublicKey = reply["runner_public_key"] as? String,
            let deviceID = reply["device_id"] as? String,
            !relayURL.isEmpty
        else { throw PairingError.malformedReply }

        // Validate the runner's key now. A malformed one stored here would only
        // show up as "nothing ever decrypts", long after the cause.
        guard (try? Base64URL.decode(runnerPublicKey))?.count == 32 else {
            throw PairingError.malformedReply
        }

        return Pairing(
            relayURL: relayURL,
            channel: channel,
            runnerPublicKey: runnerPublicKey,
            deviceID: deviceID,
            secret: identity.toSecret()
        )
    }
}
