import Foundation
import LoggerRemote

/// `RemoteTransport` adapter that bridges `swift-logger-remote`'s
/// durable delivery engine to a Splunk HTTP Event Collector (HEC)
/// endpoint.
///
/// The adapter is **batch-aggregating**: every non-empty
/// ``RemoteTransport/sendBatch(_:)`` call builds **one** HEC HTTP
/// request carrying every input item, POSTs it through the injected
/// ``SplunkEventTransport`` seam, and projects the result back into
/// one `Result<RemoteTransportResponse, any Error>` per input item
/// in the same order as the input batch. An empty `items` array
/// returns `[]` and dispatches no HEC request. The remote engine
/// owns the durable queue, retry budget, batch rounds,
/// retained-artifact reuse, and acknowledgement-to-removal
/// lifecycle; the adapter stores only endpoint configuration,
/// envelope metadata, and the injected event transport handle.
///
/// ## HEC response model
///
/// Splunk HEC's `services/collector/event` endpoint returns a
/// **whole-request** status code and a single
/// `{"text":"Success","code":0}`-shaped envelope. The per-event
/// indexer-acknowledgement contract lives on the separate
/// `services/collector/ack` endpoint and is opt-in. This adapter
/// does **not** semantically parse or validate the response body
/// and does **not** consult the ACK endpoint, so a 2xx HEC reply
/// is the success signal for every active item in the batch round;
/// per-item results all succeed with identical opaque response
/// bytes for the batch round. Whole-request failures throw from
/// ``sendBatch(_:)`` so the engine routes the same failure through
/// ``classify(_:)`` for every active item in the batch round.
///
/// ## Ownership boundaries
///
/// `swift-logger-splunk` owns:
/// - HEC request framing from the ordered host-encoded event
///   payload bytes provided by the engine (one HEC envelope per
///   newline-delimited line, per Splunk's documented wire shape).
/// - HEC envelope metadata (`source`, `sourcetype`, `index`) stamped
///   on every event in the batch.
/// - HEC response classification by HTTP status code.
///
/// `swift-logger-remote` owns:
/// - The durable queue (`DurableRemoteQueue`).
/// - The retry budget and the batch-round dispatcher.
/// - The acknowledgement-to-removal lifecycle (no destructive
///   removal until the engine acknowledges a fully-resolved
///   non-empty flush pass).
/// - The retained export artifact and outstanding-batch reuse on
///   retryable continuations.
///
/// The adapter never re-implements those concerns; it would
/// duplicate state the engine already owns.
struct SplunkRemoteTransport: RemoteTransport {
    /// Target Splunk endpoint (direct HEC or intake gateway). Both
    /// cases are POSTed verbatim; the adapter does not guess or
    /// mutate the URL path.
    let endpoint: SplunkEndpoint

    /// HEC `source` field stamped on every event in the batch, or
    /// `nil` to omit. Splunk uses `source` to label the data
    /// origin (typically the application name).
    let source: String?

    /// HEC `sourcetype` field stamped on every event in the batch,
    /// or `nil` to omit. Splunk uses `sourcetype` to classify the
    /// event format and select a parser at index time.
    let sourcetype: String?

    /// HEC `index` field stamped on every event in the batch, or
    /// `nil` to omit. The HEC token's allowed-index list must
    /// include the named index or Splunk rejects the request with
    /// HTTP 400 / code 7 ("Incorrect index").
    let index: String?

    /// HTTP client seam used to dispatch the HEC request. The
    /// `URLSession`-backed initializer wires this to
    /// ``URLSessionSplunkEventTransport``; the seam-injecting
    /// initializer takes a custom transport so tests can record
    /// without touching the network.
    private let transport: any SplunkEventTransport

    /// Constructs an adapter that dispatches every HEC request
    /// through `URLSession`. The session defaults to `.shared` so
    /// callers can plug in a custom configuration (e.g. a
    /// per-process session with a tighter timeout) by injecting
    /// their own `URLSession`.
    init(
        endpoint: SplunkEndpoint,
        source: String? = nil,
        sourcetype: String? = nil,
        index: String? = nil,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.source = source
        self.sourcetype = sourcetype
        self.index = index
        transport = URLSessionSplunkEventTransport(session: urlSession)
    }

    /// Test-only initializer that swaps the HTTP seam for a custom
    /// ``SplunkEventTransport`` implementation. Marked `internal`
    /// because ``SplunkEventTransport`` is the package-internal
    /// transport contract; the public surface only exposes the
    /// `URLSession`-backed shape.
    init(
        endpoint: SplunkEndpoint,
        source: String?,
        sourcetype: String?,
        index: String?,
        transport: any SplunkEventTransport
    ) {
        self.endpoint = endpoint
        self.source = source
        self.sourcetype = sourcetype
        self.index = index
        self.transport = transport
    }

    /// Dispatches the input batch as one HEC request and returns
    /// one `Result` per input item in input order.
    ///
    /// **Whole-request success.** HEC's event endpoint returns a
    /// single 2xx status for the entire request and the adapter
    /// has no per-event result surface to consult, so every input
    /// item resolves to `.success` carrying the opaque response
    /// bytes Splunk returned.
    ///
    /// **Whole-request failure routing.** Anything that prevents
    /// the HEC request from completing with a valid 2xx
    /// transport response -- non-2xx status,
    /// network error, transport-level response-shape failure, request-build
    /// error -- throws from `sendBatch`. The engine treats the
    /// throw as a transport-level failure for every active item in
    /// the batch round and runs each item through ``classify(_:)``
    /// with `.failure(error)`.
    func sendBatch(
        _ items: [RemoteTransportBatchItem]
    ) async throws -> [Result<RemoteTransportResponse, any Error>] {
        // Empty active set: skip the HEC round-trip. Sending an
        // empty HEC body would be a spurious request and there is
        // nothing to project per-item against.
        guard !items.isEmpty else {
            return []
        }

        let body = try SplunkHECRequestBody.make(
            events: items.map(\.payloadBytes),
            source: source,
            sourcetype: sourcetype,
            index: index
        )

        var headers = ["Content-Type": "application/json"]
        if let authorization = endpoint.authorizationHeaderValue {
            headers["Authorization"] = authorization
        }

        // HTTP non-2xx, network, TLS, and DNS failures throw from
        // the SplunkEventTransport seam. We let those propagate so
        // the engine routes the whole batch through `classify(_:)`.
        let responseBody = try await transport.send(
            url: endpoint.requestURL,
            headers: headers,
            body: body
        )

        // HEC does not expose a per-event result on the
        // `services/collector/event` endpoint (per-event
        // indexer-acknowledgement is on the separate
        // `services/collector/ack` endpoint, opt-in and out of
        // M4 scope), so a 2xx response is the success signal for
        // every input item.
        let response = RemoteTransportResponse(responseBytes: responseBody)
        return items.map { _ in .success(response) }
    }

    /// Maps a per-item `Result` from ``sendBatch(_:)`` (or a
    /// whole-batch `.failure(error)` raised by a `sendBatch` throw)
    /// into a `RemoteDeliveryResult` the engine consumes.
    ///
    /// **Sink-owned.** The engine never inspects HTTP status or
    /// transport error types; the mapping below is the adapter's
    /// authoritative rule:
    ///
    /// - `.success(_)` -> `.success`.
    /// - `.failure(SplunkEventTransportError.unsuccessfulStatus(s))`
    ///   where `s == 408 || s == 429 || (500..<600).contains(s)`
    ///   -> `.retryable` (transient: request-timeout, HEC queue /
    ///   ACK channel backpressure, or server-side failure that
    ///   may clear on retry).
    /// - `.failure(SplunkEventTransportError.unsuccessfulStatus(s))`
    ///   where `(400..<500).contains(s)` and `s` is none of the
    ///   above -> `.terminal` (401 / 403 invalid or disabled
    ///   token, 400 incorrect index / invalid data format /
    ///   missing event field -- retrying with the same request
    ///   shape and credentials will not help).
    /// - `.failure(SplunkEventTransportError.invalidResponse)` ->
    ///   `.retryable` (usually transient proxy / TLS / connection
    ///   issue rather than permanent endpoint misconfiguration).
    /// - Any other `.failure(_)` (URLError, DNS, TLS, cancellation,
    ///   request-build error, …) -> `.retryable`.
    func classify(
        _ result: Result<RemoteTransportResponse, any Error>
    ) async -> RemoteDeliveryResult {
        switch result {
        case .success:
            return .success
        case let .failure(error):
            return Self.classify(error: error)
        }
    }

    /// Pure classification of an error value without mutating
    /// queue acknowledgement, export-file lifecycle, or retry
    /// lifecycle state. Split from ``classify(_:)`` so the test
    /// target can exercise the mapping table without
    /// constructing `Result.failure` wrappers per case.
    static func classify(error: any Error) -> RemoteDeliveryResult {
        if let transportError = error as? SplunkEventTransportError {
            switch transportError {
            case let .unsuccessfulStatus(status):
                if status == 408 || status == 429 || (500 ..< 600).contains(status) {
                    return .retryable(reason: .transportRejected)
                }
                if (400 ..< 500).contains(status) {
                    // Permanent rejection: auth failure (401 / 403),
                    // malformed request (400 invalid data format),
                    // missing required field (400 event field
                    // required), or routing failure (400 incorrect
                    // index) -- retrying with the same request
                    // shape and credentials will not help.
                    return .terminal(reason: .transportRejected)
                }
                // 3xx, 1xx, or unusual status codes outside the
                // documented HEC surface -- treat as transient
                // until the integration's actual semantics are
                // established. The default for an unexpected
                // HTTP status class is retryable rather than
                // terminal for forward compatibility, so a
                // transient gateway redirect or informational
                // status does not silently discard delivered
                // bytes.
                return .retryable(reason: .transportRejected)
            case .invalidResponse:
                return .retryable(reason: .transportRejected)
            }
        }
        return .retryable(reason: .transportRejected)
    }
}
