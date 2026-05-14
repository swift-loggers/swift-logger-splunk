import Foundation

@testable import LoggerSplunk

/// Test transport that captures every `send` call without touching
/// the network. Used by the Splunk adapter tests to assert the URL,
/// headers, and body the production transport would have sent.
final class RecordingSplunkEventTransport: SplunkEventTransport, @unchecked Sendable {
    struct Sent: Sendable {
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    private let lock = NSLock()
    private var stored: [Sent] = []
    private var scriptedErrors: [any Error] = []
    private var defaultResponseBody: Data = .init()

    /// A defensive snapshot of every successfully captured call.
    /// Failed sends are not recorded here; only the calls that
    /// returned successfully appear in this list.
    var sent: [Sent] {
        withLock { stored.map { $0 } }
    }

    /// Number of successfully captured sends. Cheap accessor that
    /// avoids the defensive copy of the entire `sent` array.
    var sentCount: Int {
        withLock { stored.count }
    }

    /// Schedules a deterministic queue of errors. The first
    /// scheduled send throws `errors[0]`, the second `errors[1]`,
    /// and so on. After the queue drains, subsequent sends record
    /// normally.
    func setErrors(_ errors: [any Error]) {
        withLock { scriptedErrors = errors }
    }

    /// Sets the default response body returned by every successful
    /// future send. Defaults to empty `Data`.
    func setResponseBody(_ data: Data) {
        withLock { defaultResponseBody = data }
    }

    func send(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> Data {
        let outcome: SendOutcome = withLock {
            if !scriptedErrors.isEmpty {
                let error = scriptedErrors.removeFirst()
                return .scriptedFailure(error)
            }
            stored.append(Sent(url: url, headers: headers, body: body))
            return .success(defaultResponseBody)
        }
        switch outcome {
        case let .scriptedFailure(error):
            throw error
        case let .success(responseBody):
            return responseBody
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private enum SendOutcome {
        case success(Data)
        case scriptedFailure(any Error)
    }
}
