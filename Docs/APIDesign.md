# API design -- `swift-logger-splunk 0.1.0`

`swift-logger-splunk` is a durable-only Splunk HTTP Event
Collector (HEC) adapter that bridges Splunk delivery onto
`swift-logger-remote`'s `RemoteEngine` + `DurableRemoteQueue`
engine surface. It is the second concrete remote adapter built on
top of `swift-logger-remote 0.1.0`, after `swift-logger-elastic`.
It proves that the shared remote engine works for a non-Elastic HTTP
sink whose request / response model is **not** Elasticsearch
`_bulk`.

## Public surface

```text
public enum SplunkEndpoint: Sendable, Equatable {
    case hec(url: URL, token: String)
    case intake(url: URL, authorizationHeader: String?)
}

public enum SplunkRemoteEngine {
    public struct Wiring: Sendable {
        public let queue: DurableRemoteQueue
        public let engine: RemoteEngine
    }

    public struct Configuration: Sendable {
        public let endpoint: SplunkEndpoint
        public let source: String?
        public let sourcetype: String?
        public let index: String?
        public let queueDirectory: URL
        public let exportDirectory: URL
        public let batchPolicy: RemoteBatchPolicy
        public let retryPolicy: RemoteRetryPolicy
        public let urlSession: URLSession
    }

    public static func make(_ configuration: Configuration) -> Wiring
}
```

The package exposes **nothing else** as `public`. The internal
`SplunkRemoteTransport`, `SplunkEventTransport`,
`URLSessionSplunkEventTransport`, `SplunkEventTransportError`,
and `SplunkHECRequestBody` types are package-internal and not
part of the API surface.

## Splunk endpoint trust model

`SplunkEndpoint` ships two cases that correspond to two distinct
deployment shapes. Pick the one that matches your trust model.

### `.hec(url:token:)`

Direct delivery to a Splunk HEC event endpoint. The adapter POSTs
to `url` **verbatim** -- it does not append, mutate, or guess
the URL path -- and sends `Authorization: Splunk <token>` on
every request. Pass the full HEC event-endpoint URL so the
adapter never silently targets a different endpoint than the
operator authorized.

An HEC token compiled into a client app binary is **extractable**.
HTTPS protects the network hop, not secrets embedded in the
binary; anyone with the binary can recover the token with
standard reverse-engineering tooling. The Splunk indexer behind
that token inherits the trust level of the distribution channel.
Direct mode is appropriate for trial setups, internal-only apps,
prototypes, smoke tests, and any context where the operator has
consciously accepted that risk. For hardened production
deployments use `.intake(...)`.

### `.intake(url:authorizationHeader:)`

Delivery through a consumer-owned intake / proxy / gateway
endpoint. The adapter POSTs to `url` verbatim and sends the
consumer-supplied `Authorization` header value through unchanged
(Bearer, Basic, custom gateway tokens, or no auth when
`authorizationHeader` is `nil`). The intake service owns
authentication, index routing, rate limiting, schema evolution,
and duplicate-suppression policy; the real HEC token never has
to leave the server.

## HEC request framing

`SplunkHECRequestBody` (internal) builds the HEC request body
from the ordered event payload bytes the engine hands the
transport for one batch round:

```
{"event":<event_bytes_1>,"index":"...","source":"...","sourcetype":"..."}\n
{"event":<event_bytes_2>,"index":"...","source":"...","sourcetype":"..."}\n
...
```

The layout matches Splunk's documented event format: HEC accepts
multiple events per request "stacked one after the other, and
not in a JSON array", with one HEC event envelope per
newline-delimited line, separated by `0x0A` newlines. The metadata
fragment is built once per call and re-appended for every event;
absent fields are omitted entirely so the wire shape carries no
`null` values. Metadata keys are sorted alphabetically for
deterministic wire output (HEC ignores envelope key order; sort
is for test determinism).

`Content-Type` is `application/json`. `Authorization` is set
when the endpoint provides it (`Splunk <token>` for `.hec`, the
caller's verbatim header for `.intake`); omitted when
`.intake(authorizationHeader: nil)`.

## `RemoteTransport.sendBatch(_:)` cardinality and ordering

`SplunkRemoteTransport.sendBatch(_:)` builds **exactly one** HEC
HTTP request per non-empty call (the active batch becomes one
body). An empty `items` array returns `[]` without dispatching a
HEC request. The returned result array has exactly `items.count`
entries; the result at index `i` corresponds to `items[i]`. The
engine fails closed with
`RemoteEngineError.transportBatchInvalid(expected:actual:)` if
that count contract breaks.

### 2xx success

Splunk HEC's `services/collector/event` endpoint returns a
whole-request 2xx status when the request is accepted; per-event
indexer-acknowledgement lives on the separate
`services/collector/ack` endpoint, is opt-in, and is **out of M4
scope**. The adapter does not semantically parse or validate the
response body beyond transport-level success/failure classification
and does not consult the ACK endpoint, so a 2xx reply resolves every
input item to `.success` carrying the opaque response bytes Splunk
returned.

### Whole-request failure

Anything that prevents the HEC request from completing as 2xx
(non-2xx status, network error, transport-level response-shape
failures, request-build error) throws from
`sendBatch(_:)`. The engine treats the throw as a transport-level
failure for every active item in the batch round and runs each item
through
`classify(_:)` with the same `.failure(error)` value.

## Classification policy

`SplunkRemoteTransport.classify(_:)` is sink-owned. The engine
never inspects HTTP status or transport error types. The mapping
table:

| Input | Mapping |
| ----- | ------- |
| `.success(_)` | `.success` |
| HTTP 408 / 429 / 5xx | `.retryable(.transportRejected)` |
| HTTP 401 / 403 | `.terminal(.transportRejected)` |
| Other HTTP 4xx (400 / 404 / 405 / 409 / 422 / ...) | `.terminal(.transportRejected)` |
| `SplunkEventTransportError.invalidResponse` | `.retryable(.transportRejected)` |
| Unexpected HTTP status classes from the HEC endpoint | `.retryable(.transportRejected)` for forward compatibility (fail-safe default) |
| Any other error (URLError, DNS, TLS, cancellation, request-build, ...) | `.retryable(.transportRejected)` |

Classification is deterministic for the same adapter
implementation and transport result within a flush pass. It does
not mutate queue acknowledgement state or export-file lifecycle
state directly or indirectly.

The 408 / 429 / 5xx -> retryable mapping reflects Splunk's
documented HEC error codes:

- HTTP 429 / HEC code 26 ("HEC queue is at capacity and cannot
  process any more requests") and HTTP 429 / HEC code 27 ("HEC
  ACK channel is at capacity and cannot process any more
  requests") are backpressure signals; the engine's retry budget
  is the right place to drain them.
- HTTP 500 / HEC code 8 ("Internal server error") and HTTP 503 /
  HEC code 9 ("Server is busy") are transient by definition.
- HTTP 408 is a transport-level timeout signal (not in Splunk's
  enumerated HEC code table, but a documented general response
  for the request-timeout class).

401 / 403 / 400 -> terminal reflects:

- HTTP 401 / HEC code 2 ("Token is required") and HTTP 401 / HEC
  code 3 ("Invalid authorization") -- retrying with the same
  credential will not help.
- HTTP 403 / HEC code 1 ("Token disabled") and HTTP 403 / HEC
  code 4 ("Invalid token") -- same.
- HTTP 400 / HEC codes 5 / 6 / 7 / 12 / 13 / ... ("No data",
  "Invalid data format", "Incorrect index", "Event field is
  required", "Event field cannot be blank", ...) -- retrying
  with the same request shape will not help.

## Remote-engine lifecycle ownership

`swift-logger-splunk` owns:

- HEC envelope construction from the ordered host-encoded event
  payload bytes provided by the engine (newline-delimited body with
  one HEC envelope per line).
- HEC envelope metadata (`source`, `sourcetype`, `index`) stamped
  on every event in the batch.
- HEC response classification by HTTP status code.

`swift-logger-remote` owns:

- The durable queue (`DurableRemoteQueue`).
- Batch-round retry budget and the batch-round dispatcher.
- Retained export artifact reuse on retryable continuations across
  flush passes.
- Acknowledgement-to-removal lifecycle (no destructive removal
  until the engine acknowledges a fully-resolved non-empty flush
  pass).

The adapter never re-implements those concerns. The engine is
caller-driven: it owns no timer, no platform lifecycle observer,
no autonomous scheduler. Hosts wire `flush()` calls from their
own lifecycle hooks or scheduling infrastructure.

## Why retry / ACK / persistence stay in `swift-logger-remote`

Putting retry, persistence, and acknowledgement into every
adapter would duplicate the state the engine already owns and
would risk sink-specific lifecycle drift, diverging the contract
across sinks (one adapter would acknowledge under different
conditions than another). This adapter demonstrates
that the shared remote engine remains sink-neutral across different
HTTP wire protocols. By reusing the engine across a non-Elastic
HTTP sink, both adapters share the same lifecycle contract despite
different HTTP wire formats, so the engine's behaviour stays
sink-neutral and the sink-specific code stays narrow.
