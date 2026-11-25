import Foundation

/// One WebSocket to the relay, on one channel, opened with the seat.
final class RelaySocket: @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    /// One session for every relay socket: each socket is a task on it.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    init(url: URL, seat: String) {
        var request = URLRequest(url: url)
        request.setValue(seat, forHTTPHeaderField: LinkWire.seatHeader)
        request.timeoutInterval = 20
        task = Self.session.webSocketTask(with: request)
        // A frame is under 256 KiB; this leaves room and still bounds memory.
        task.maximumMessageSize = 1 << 20
    }

    /// Opens it, returning once the relay has let it in (it answers a ping).
    func open(timeout: TimeInterval) async throws {
        task.resume()
        do {
            try await ping(timeout: timeout)
        } catch {
            // Refused before the upgrade: the relay says why with a status.
            if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
                throw LinkError.refused(status)
            }
            throw error
        }
    }

    func ping(timeout: TimeInterval) async throws {
        let task = task
        try await LinkTimeout.run(seconds: timeout) {
            // URLSession can call a ping's handler more than once: with
            // the pong, and again with an error when the socket is
            // cancelled or the network goes. Resuming a continuation
            // twice stops the app (it did, four times by 2026-11-25), so
            // only the first answer counts.
            let gate = Gate<Void>()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.hold(continuation)
                task.sendPing { error in
                    gate.finish(error.map { .failure($0) } ?? .success(()))
                }
            }
        }
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    /// The next text frame. Throws once the socket is closed.
    func receive() async throws -> String {
        while true {
            switch try await task.receive() {
            case .string(let text):
                return text
            case .data:
                continue
            @unknown default:
                continue
            }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// Runs an operation with a deadline, without waiting on an operation that
/// will not stop (a ping on a dead network never answers).
enum LinkTimeout {
    static func run<T: Sendable>(seconds: TimeInterval,
                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = Gate<T>()
        return try await withCheckedThrowingContinuation { continuation in
            gate.hold(continuation)
            let work = Task {
                do {
                    let value = try await operation()
                    gate.finish(.success(value))
                } catch {
                    gate.finish(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                if gate.finish(.failure(LinkError.timedOut)) { work.cancel() }
            }
        }
    }
}

/// A continuation resumed once, by whichever finishes first.
final class Gate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func hold(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let held = continuation
        continuation = nil
        lock.unlock()
        guard let held else { return false }
        held.resume(with: result)
        return true
    }
}
