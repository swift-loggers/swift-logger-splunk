import Foundation
import Testing

@testable import LoggerSplunk

/// Production ``URLSessionSplunkEventTransport`` coverage through a
/// `URLProtocol`-backed `URLSession`. The rest of the test target
/// injects ``RecordingSplunkEventTransport`` and never exercises
/// the real `URLSession` data-task path, so this suite pins the
/// status-code-to-``SplunkEventTransportError`` mapping that
/// ``SplunkRemoteTransport/classify(_:)`` ultimately consumes.
///
/// The stub `URLProtocol` shares a single static script field
/// across instances because `URLProtocol` does not let callers
/// supply per-request state, so the suite is marked `.serialized`
/// to keep each test's script from racing the next.
@Suite("URLSessionSplunkEventTransport status mapping", .serialized)
struct URLSessionSplunkEventTransportTests {
    @Test(
        "HTTP 401 throws SplunkEventTransportError.unsuccessfulStatus(401)",
        .tags(.splk10)
    )
    func http401ThrowsUnsuccessfulStatus() async throws {
        let session = try Self.makeStubbedSession(script: .httpStatus(401))
        let transport = URLSessionSplunkEventTransport(session: session)
        let url = try #require(URL(string: Self.url))

        await #expect(
            throws: SplunkEventTransportError.unsuccessfulStatus(401),
            performing: {
                _ = try await transport.send(url: url, headers: [:], body: Data())
            }
        )
    }

    @Test(
        "HTTP 503 throws SplunkEventTransportError.unsuccessfulStatus(503)",
        .tags(.splk9)
    )
    func http503ThrowsUnsuccessfulStatus() async throws {
        let session = try Self.makeStubbedSession(script: .httpStatus(503))
        let transport = URLSessionSplunkEventTransport(session: session)
        let url = try #require(URL(string: Self.url))

        await #expect(
            throws: SplunkEventTransportError.unsuccessfulStatus(503),
            performing: {
                _ = try await transport.send(url: url, headers: [:], body: Data())
            }
        )
    }

    @Test(
        "Non-HTTP URLResponse throws SplunkEventTransportError.invalidResponse",
        .tags(.splk9)
    )
    func nonHTTPResponseThrowsInvalidResponse() async throws {
        let session = try Self.makeStubbedSession(script: .nonHTTPResponse)
        let transport = URLSessionSplunkEventTransport(session: session)
        let url = try #require(URL(string: Self.url))

        await #expect(
            throws: SplunkEventTransportError.invalidResponse,
            performing: {
                _ = try await transport.send(url: url, headers: [:], body: Data())
            }
        )
    }

    @Test(
        "Production transport sends POST with supplied headers and body bytes",
        .tags(.splk12)
    )
    func transportSendsPOSTWithSuppliedHeadersAndBody() async throws {
        let expectedBody = Data(#"{"event":{"i":1}}"#.utf8)
        let session = try Self.makeStubbedSession(script: .success(Data()))
        let transport = URLSessionSplunkEventTransport(session: session)
        let url = try #require(URL(string: Self.url))

        _ = try await transport.send(
            url: url,
            headers: [
                "Authorization": "Splunk test-token",
                "Content-Type": "application/json"
            ],
            body: expectedBody
        )

        let method = try #require(StubURLProtocol.capturedMethod)
        let headers = try #require(StubURLProtocol.capturedHeaders)
        #expect(method == "POST")
        #expect(headers["Authorization"] == "Splunk test-token")
        #expect(headers["Content-Type"] == "application/json")
        #expect(StubURLProtocol.capturedBody == expectedBody)
    }

    @Test(
        "HTTP 200 returns the response body verbatim",
        .tags(.splk7)
    )
    func http200ReturnsResponseBodyVerbatim() async throws {
        let expectedBody = Data(#"{"text":"Success","code":0}"#.utf8)
        let session = try Self.makeStubbedSession(script: .success(expectedBody))
        let transport = URLSessionSplunkEventTransport(session: session)
        let url = try #require(URL(string: Self.url))

        let body = try await transport.send(url: url, headers: [:], body: Data())

        #expect(body == expectedBody)
    }

    private static let url = "https://splunk.example.test:8088/services/collector/event"

    private static func makeStubbedSession(script: StubScript) throws -> URLSession {
        StubURLProtocol.script = script
        StubURLProtocol.resetCapture()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// Scripted response shape the stub `URLProtocol` plays back when
/// `URLSession` asks it to fulfil the request.
enum StubScript: Sendable {
    /// Reply with an `HTTPURLResponse` carrying the given status
    /// code and no body. Drives the `SplunkEventTransportError
    /// .unsuccessfulStatus(_:)` mapping.
    case httpStatus(Int)
    /// Reply with a base `URLResponse` (not an `HTTPURLResponse`).
    /// Drives the `SplunkEventTransportError.invalidResponse`
    /// mapping the transport applies when the response cannot be
    /// inspected as HTTP.
    case nonHTTPResponse
    /// Reply with an `HTTPURLResponse(200)` carrying the given body
    /// bytes. Drives the 2xx success branch.
    case success(Data)
}

/// Test-only `URLProtocol` that fulfils every request from a
/// scripted `StubScript`. `URLSession` instantiates one of these
/// per request, so the script lives on the type as static state;
/// the enclosing suite is `.serialized` to keep concurrent tests
/// from overwriting each other's script in flight.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var script: StubScript = .success(Data())

    /// Captured HTTP method on the last `startLoading()` request,
    /// or `nil` if no request has been intercepted since the last
    /// `resetCapture()`. Read from the test after `send(_:)`
    /// returns to assert the production transport built the
    /// expected request shape.
    nonisolated(unsafe) static var capturedMethod: String?
    /// Captured `URLRequest.allHTTPHeaderFields` snapshot on the
    /// last intercepted request, or `nil` when no request has been
    /// captured. Tests read this to assert headers passed through
    /// the seam.
    nonisolated(unsafe) static var capturedHeaders: [String: String]?
    /// Captured request body bytes, drained inside
    /// `startLoading()` so a later read from the test thread does
    /// not race the consumed `httpBodyStream` URLSession may have
    /// installed.
    nonisolated(unsafe) static var capturedBody: Data = .init()

    static func resetCapture() {
        capturedMethod = nil
        capturedHeaders = nil
        capturedBody = Data()
    }

    override static func canInit(with _: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.captureRequest(request)
        guard let client else {
            return
        }
        guard let url = request.url else {
            client.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch Self.script {
        case let .httpStatus(status):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            ) else {
                client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        case .nonHTTPResponse:
            let response = URLResponse(
                url: url,
                mimeType: "application/octet-stream",
                expectedContentLength: 0,
                textEncodingName: nil
            )
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        case let .success(body):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            ) else {
                client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// Captures the HTTP method, headers, and body bytes from the
    /// request URLSession handed to this protocol so the test can
    /// assert the production transport's request shape after
    /// `send(_:)` returns. The body is drained immediately because
    /// URLSession may move a caller-supplied `httpBody` onto
    /// `httpBodyStream`, which would be consumed by the time the
    /// test thread reads it back.
    private static func captureRequest(_ request: URLRequest) {
        capturedMethod = request.httpMethod
        capturedHeaders = request.allHTTPHeaderFields
        if let direct = request.httpBody {
            capturedBody = direct
        } else if let stream = request.httpBodyStream {
            capturedBody = drain(stream)
        } else {
            capturedBody = Data()
        }
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }
}
