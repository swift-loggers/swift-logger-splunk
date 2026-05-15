import Foundation
import LoggerRemote
import Testing

@testable import LoggerSplunk

/// Coverage for ``SplunkRemoteTransport`` as a `RemoteTransport`
/// conformer.
///
/// The suite drives the adapter through the seam-injected
/// ``RecordingSplunkEventTransport`` so each test fully scripts the
/// HTTP response (or the absence of one) and asserts the per-item
/// `Result` projection plus the engine-facing ``classify(_:)``
/// mapping. None of the tests touch the network.
@Suite("SplunkRemoteTransport batch dispatch")
struct SplunkRemoteTransportTests {
    private static let hecURLString = "https://splunk.example.test:8088/services/collector/event"
    private static let intakeURLString = "https://logs.example.test/splunk"

    private static func makeHECAdapter(
        transport: RecordingSplunkEventTransport,
        source: String? = "ios-app",
        sourcetype: String? = "_json",
        index: String? = "main"
    ) throws -> SplunkRemoteTransport {
        let url = try #require(URL(string: hecURLString))
        return SplunkRemoteTransport(
            endpoint: .hec(url: url, token: "test-token"),
            source: source,
            sourcetype: sourcetype,
            index: index,
            transport: transport
        )
    }

    private static func makeIntakeAdapter(
        transport: RecordingSplunkEventTransport,
        authorizationHeader: String? = "Bearer test"
    ) throws -> SplunkRemoteTransport {
        let url = try #require(URL(string: intakeURLString))
        return SplunkRemoteTransport(
            endpoint: .intake(url: url, authorizationHeader: authorizationHeader),
            source: nil,
            sourcetype: nil,
            index: nil,
            transport: transport
        )
    }

    private static func batchItem(_ payload: String) -> RemoteTransportBatchItem {
        RemoteTransportBatchItem(payloadBytes: Data(payload.utf8))
    }

    // MARK: request shape

    @Test(
        "sendBatch builds exactly one HEC request per call",
        .tags(.splk4)
    )
    func sendBatchBuildsOneRequest() async throws {
        let recorder = RecordingSplunkEventTransport()
        let adapter = try Self.makeHECAdapter(transport: recorder)
        let items = (1 ... 5).map { Self.batchItem(#"{"i":\#($0)}"#) }

        _ = try await adapter.sendBatch(items)

        #expect(recorder.sentCount == 1)
    }

    @Test(
        "Empty batch is a no-op: returns [] and dispatches no HEC request",
        .tags(.splk4, .splk5)
    )
    func emptyBatchIsNoOp() async throws {
        let recorder = RecordingSplunkEventTransport()
        let adapter = try Self.makeHECAdapter(transport: recorder)

        let results = try await adapter.sendBatch([])

        #expect(results.isEmpty)
        #expect(recorder.sentCount == 0)
    }

    @Test(
        "HEC request sends Authorization: Splunk <token> + JSON Content-Type",
        .tags(.splk12)
    )
    func hecRequestCarriesSplunkAuthAndJSONContentType() async throws {
        let recorder = RecordingSplunkEventTransport()
        let adapter = try Self.makeHECAdapter(transport: recorder)

        _ = try await adapter.sendBatch([Self.batchItem(#"{"i":1}"#)])

        let sent = try #require(recorder.sent.first)
        #expect(sent.headers["Authorization"] == "Splunk test-token")
        #expect(sent.headers["Content-Type"] == "application/json")
        #expect(sent.url.absoluteString == Self.hecURLString)
    }

    @Test(
        "Intake request passes Authorization header through verbatim",
        .tags(.splk13)
    )
    func intakeRequestCarriesVerbatimAuthorization() async throws {
        let recorder = RecordingSplunkEventTransport()
        let adapter = try Self.makeIntakeAdapter(
            transport: recorder,
            authorizationHeader: "Bearer xyz"
        )

        _ = try await adapter.sendBatch([Self.batchItem(#"{"i":1}"#)])

        let sent = try #require(recorder.sent.first)
        #expect(sent.headers["Authorization"] == "Bearer xyz")
        #expect(sent.headers["Content-Type"] == "application/json")
        #expect(sent.url.absoluteString == Self.intakeURLString)
    }

    @Test(
        "Intake with nil authorization header omits Authorization entirely",
        .tags(.splk13)
    )
    func intakeNilAuthorizationOmitsHeader() async throws {
        let recorder = RecordingSplunkEventTransport()
        let adapter = try Self.makeIntakeAdapter(
            transport: recorder,
            authorizationHeader: nil
        )

        _ = try await adapter.sendBatch([Self.batchItem(#"{"i":1}"#)])

        let sent = try #require(recorder.sent.first)
        #expect(sent.headers["Authorization"] == nil)
    }

    // MARK: per-item result cardinality + ordering

    @Test(
        "sendBatch returns exactly one Result per input item",
        .tags(.splk5)
    )
    func sendBatchReturnsOneResultPerInputItem() async throws {
        let recorder = RecordingSplunkEventTransport()
        let adapter = try Self.makeHECAdapter(transport: recorder)
        let items = (1 ... 7).map { Self.batchItem(#"{"i":\#($0)}"#) }

        let results = try await adapter.sendBatch(items)

        #expect(results.count == items.count)
    }

    @Test(
        "2xx HEC response resolves every input item to .success",
        .tags(.splk7)
    )
    func twoXXAllSuccess() async throws {
        let recorder = RecordingSplunkEventTransport()
        recorder.setResponseBody(Data(#"{"text":"Success","code":0}"#.utf8))
        let adapter = try Self.makeHECAdapter(transport: recorder)
        let items = (1 ... 3).map { Self.batchItem(#"{"i":\#($0)}"#) }

        let results = try await adapter.sendBatch(items)

        #expect(results.count == 3)
        for result in results {
            switch result {
            case .success: break
            case .failure: Issue.record("expected .success for 2xx response")
            }
        }
    }

    @Test(
        "Input ordering is preserved in the request body (events stacked in input order)",
        .tags(.splk6)
    )
    func inputOrderingPreservedInRequestBody() async throws {
        let recorder = RecordingSplunkEventTransport()
        let adapter = try Self.makeHECAdapter(
            transport: recorder,
            source: nil,
            sourcetype: nil,
            index: nil
        )
        let items = [
            Self.batchItem(#"{"i":1}"#),
            Self.batchItem(#"{"i":2}"#),
            Self.batchItem(#"{"i":3}"#)
        ]

        _ = try await adapter.sendBatch(items)

        let sent = try #require(recorder.sent.first)
        #expect(sent.body.last == 0x0A)
        let lines = sent.body
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { Data($0) }
        try #require(lines.count == 3)
        #expect(lines[0] == Data(#"{"event":{"i":1}}"#.utf8))
        #expect(lines[1] == Data(#"{"event":{"i":2}}"#.utf8))
        #expect(lines[2] == Data(#"{"event":{"i":3}}"#.utf8))
    }

    // MARK: classify -- HTTP status code mapping

    @Test(
        "classify: 408 -> .retryable",
        .tags(.splk9)
    )
    func classify408Retryable() {
        let outcome = SplunkRemoteTransport.classify(
            error: SplunkEventTransportError.unsuccessfulStatus(408)
        )
        #expect(outcome == .retryable(reason: .transportRejected))
    }

    @Test(
        "classify: 429 -> .retryable",
        .tags(.splk9)
    )
    func classify429Retryable() {
        let outcome = SplunkRemoteTransport.classify(
            error: SplunkEventTransportError.unsuccessfulStatus(429)
        )
        #expect(outcome == .retryable(reason: .transportRejected))
    }

    @Test(
        "classify: 5xx -> .retryable",
        .tags(.splk9)
    )
    func classify5xxRetryable() {
        for status in [500, 502, 503, 504, 599] {
            let outcome = SplunkRemoteTransport.classify(
                error: SplunkEventTransportError.unsuccessfulStatus(status)
            )
            #expect(
                outcome == .retryable(reason: .transportRejected),
                "expected .retryable for status \(status)"
            )
        }
    }

    @Test(
        "classify: 401 -> .terminal",
        .tags(.splk10)
    )
    func classify401Terminal() {
        let outcome = SplunkRemoteTransport.classify(
            error: SplunkEventTransportError.unsuccessfulStatus(401)
        )
        #expect(outcome == .terminal(reason: .transportRejected))
    }

    @Test(
        "classify: 403 -> .terminal",
        .tags(.splk10)
    )
    func classify403Terminal() {
        let outcome = SplunkRemoteTransport.classify(
            error: SplunkEventTransportError.unsuccessfulStatus(403)
        )
        #expect(outcome == .terminal(reason: .transportRejected))
    }

    @Test(
        "classify: 400 (other 4xx, neither 408 nor 429) -> .terminal",
        .tags(.splk10)
    )
    func classify400Terminal() {
        for status in [400, 404, 405, 409, 422] {
            let outcome = SplunkRemoteTransport.classify(
                error: SplunkEventTransportError.unsuccessfulStatus(status)
            )
            #expect(
                outcome == .terminal(reason: .transportRejected),
                "expected .terminal for status \(status)"
            )
        }
    }

    @Test(
        "classify: invalidResponse -> .retryable",
        .tags(.splk9)
    )
    func classifyInvalidResponseRetryable() {
        let outcome = SplunkRemoteTransport.classify(
            error: SplunkEventTransportError.invalidResponse
        )
        #expect(outcome == .retryable(reason: .transportRejected))
    }

    @Test(
        "classify: arbitrary network error -> .retryable",
        .tags(.splk9)
    )
    func classifyArbitraryErrorRetryable() {
        struct NetworkErrorStub: Error {}
        let outcome = SplunkRemoteTransport.classify(error: NetworkErrorStub())
        #expect(outcome == .retryable(reason: .transportRejected))
    }

    @Test(
        "classify: 3xx unknown status -> .retryable (fail-safe default)",
        .tags(.splk9)
    )
    func classifyUnknownStatusRetryable() {
        let outcome = SplunkRemoteTransport.classify(
            error: SplunkEventTransportError.unsuccessfulStatus(304)
        )
        #expect(outcome == .retryable(reason: .transportRejected))
    }

    // MARK: classify(_:) async surface

    @Test(
        "classify(.success(_)) -> .success",
        .tags(.splk11)
    )
    func classifySuccess() async {
        let recorder = RecordingSplunkEventTransport()
        let adapter = try? Self.makeHECAdapter(transport: recorder)
        let outcome = await adapter?.classify(
            .success(RemoteTransportResponse(responseBytes: Data()))
        )
        #expect(outcome == .success)
    }

    @Test(
        "Whole-batch throw resolves every item via classify(.failure(error))",
        .tags(.splk8)
    )
    func wholeBatchThrowProjectsThroughClassify() async throws {
        let recorder = RecordingSplunkEventTransport()
        recorder.setErrors([SplunkEventTransportError.unsuccessfulStatus(503)])
        let adapter = try Self.makeHECAdapter(transport: recorder)
        let items = (1 ... 3).map { Self.batchItem(#"{"i":\#($0)}"#) }

        await #expect(
            throws: SplunkEventTransportError.unsuccessfulStatus(503),
            performing: { _ = try await adapter.sendBatch(items) }
        )

        // SPLK-8 contract: the engine routes the whole-batch throw
        // through `classify(.failure(error))` for every active item.
        // Assert the per-item projection explicitly so the coverage
        // tag proves failure projection through the classifier, not
        // just that `sendBatch` threw.
        for _ in items {
            let outcome = await adapter.classify(
                .failure(SplunkEventTransportError.unsuccessfulStatus(503))
            )
            #expect(outcome == .retryable(reason: .transportRejected))
        }
    }
}
