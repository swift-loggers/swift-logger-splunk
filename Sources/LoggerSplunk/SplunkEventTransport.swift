import Foundation

/// Internal HTTP seam used by the ``SplunkRemoteTransport`` adapter
/// that bridges Splunk HEC delivery onto `swift-logger-remote`'s
/// durable engine.
///
/// Callers produce the URL, headers, and body for one HTTP request
/// (the framed HEC payload for an entire batch of events); the seam
/// is responsible for the network round-trip and for returning the
/// response body so the adapter can decide whole-batch
/// classification.
///
/// `SplunkEventTransport` is **not** public API. The production
/// implementation is ``URLSessionSplunkEventTransport``; tests
/// inject a recorder that captures the request without touching the
/// network. The package exposes durable delivery through the
/// ``SplunkRemoteEngine/make(_:)`` factory, and neither path
/// requires the caller to wire a `SplunkEventTransport` directly.
protocol SplunkEventTransport: Sendable {
    /// Sends `body` as the HTTP body of a POST request to `url`
    /// with the supplied `headers`. Implementations should throw
    /// for transport-level request failures and non-2xx HTTP
    /// responses.
    ///
    /// - Returns: The response body. Empty when the server returns
    ///   no body; never `nil`.
    func send(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> Data
}

/// Errors the default ``URLSessionSplunkEventTransport`` raises
/// when the remote endpoint rejects an HEC payload. The conformance
/// to ``Equatable`` lets tests pin specific cases via
/// `#expect(throws: SplunkEventTransportError.<case>)` rather than
/// the looser `#expect(throws: SplunkEventTransportError.self)`.
enum SplunkEventTransportError: Error, Sendable, Equatable {
    /// The HTTP response returned a non-2xx status code. Classified
    /// by ``SplunkRemoteTransport`` per
    /// ``SplunkRemoteTransport/classify(_:)``: 408, 429, and 5xx
    /// map to retryable; 401, 403, and other 4xx map to terminal.
    case unsuccessfulStatus(Int)

    /// The HTTP response was missing or could not be inspected as
    /// an `HTTPURLResponse`. ``SplunkRemoteTransport/classify(_:)``
    /// treats this as retryable because it usually reflects a
    /// transient proxy / TLS / connection issue rather than a
    /// permanent endpoint misconfiguration.
    case invalidResponse
}

/// Production transport that POSTs the framed HEC body through
/// `URLSession`. Treated as `@unchecked Sendable` because
/// `URLSession` is documented thread-safe and is held immutably
/// here even though Foundation does not declare formal Sendable
/// conformance on the iOS 13 deployment target.
struct URLSessionSplunkEventTransport: SplunkEventTransport, @unchecked Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body

        let (responseBody, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SplunkEventTransportError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw SplunkEventTransportError.unsuccessfulStatus(http.statusCode)
        }
        return responseBody
    }
}
