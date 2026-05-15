# Requirements -- `swift-logger-splunk 0.1.0`

This document locks the requirement IDs (`SPLK-*`) that
`swift-logger-splunk 0.1.0` ships and tests against. Each ID is
mapped to its enforcing test in
[`Tests/LoggerSplunkTests/CoverageMap.md`](../Tests/LoggerSplunkTests/CoverageMap.md).

## Payload contract

### `SPLK-1` Lazy host-side encoding boundary

`DurableRemoteQueue.enqueue(_:)` admits a `RemoteDeliveryEntry`
whose `payload` is **opaque pre-encoded bytes**. For this Splunk
wiring those bytes are the **single HEC `event` payload value**
(the literal substitution for `<payload>` in
`{"event": <payload>, ...}`). Neither the engine nor the
internal Splunk transport encodes upstream host log records on
the caller's behalf. Event payload bytes MUST be a valid
one-line JSON value with no literal newlines outside JSON string
escapes.

### `SPLK-2` HEC envelope construction

The transport wraps each event payload value in the HEC envelope
and stamps the configured `source` / `sourcetype` / `index`
fields on every event in the batch. Absent fields are omitted
entirely (no `null` values on the wire). Metadata keys are
sorted alphabetically for deterministic wire output. Metadata
field values are JSON-string encoded so embedded quotes,
backslashes, and other JSON-special characters cannot break the
envelope.

### `SPLK-3` Newline-stacked HEC framing

The HEC request body stacks events one after the other,
separated by a single `0x0A` newline, per Splunk's documented
event format ("stacked one after the other, and not in a JSON
array"), with one HEC envelope per newline-delimited line.

## `RemoteTransport.sendBatch(_:)` contract

### `SPLK-4` One HEC request per non-empty `sendBatch(_:)` call

The transport builds exactly one HEC HTTP request per non-empty
`sendBatch(_:)` call. The active batch is the request body; no
per-event request is issued. An empty `items` array returns `[]`
without dispatching a HEC request.

### `SPLK-5` One result per input item

The returned result array has exactly `items.count` entries.

### `SPLK-6` Input-order preservation

The result at index `i` corresponds to `items[i]`. Likewise the
events in the request body appear in input order so a downstream
indexer can correlate by position.

### `SPLK-7` 2xx success projection

Splunk HEC's `services/collector/event` endpoint returns a
whole-request status for the current batch round; per-event
indexer-acknowledgement lives on a separate endpoint
(`services/collector/ack`) and is out of M4 scope. The adapter
performs transport-level success/failure classification only and
does not semantically parse or validate the response body, so a 2xx
HEC reply resolves every input item to `.success` carrying the
opaque response bytes Splunk returned.

### `SPLK-8` Whole-batch failure projection

Anything that prevents a 2xx HEC response (non-2xx status,
network error, transport-level response-shape failure (for example,
non-HTTP responses), request-build error) throws from
`sendBatch(_:)`. The engine routes the throw through `classify(_:)`
for every active item in the batch round.

## Classification policy

### `SPLK-9` Retryable mapping

HTTP 408 / 429 / 5xx, `SplunkEventTransportError.invalidResponse`,
and arbitrary errors (URLError, DNS, TLS, cancellation, ...)
classify as `.retryable(.transportRejected)`. Unexpected HTTP
status classes also classify as retryable for forward compatibility
(fail-safe default).

### `SPLK-10` Terminal mapping

HTTP 401 / 403 and other HTTP 4xx (400 / 404 / 405 / 409 / 422 /
...) classify as `.terminal(.transportRejected)`.

### `SPLK-11` Deterministic classification

`classify(_:)` is deterministic for the same adapter
implementation and transport result within a flush pass. It does
not mutate queue acknowledgement state or export-file lifecycle
state directly or indirectly. Repeated classification invocations
for the same result within a flush pass MUST return the same
decision.

## Endpoint trust model

### `SPLK-12` Direct HEC token threat model

`.hec(url:token:)` POSTs to `url` verbatim with
`Authorization: Splunk <token>`. The HEC token is extractable
from any client binary that holds it; production iOS / macOS apps
should route through `.intake(...)` instead.

### `SPLK-13` Intake authorization passthrough

`.intake(url:authorizationHeader:)` sends the consumer-supplied
`Authorization` header value through unchanged when non-`nil`,
and omits the header entirely when `nil`. The intake URL is sent
verbatim.

## Engine lifecycle ownership

### `SPLK-14` Caller-driven flush lifecycle

The package installs no autonomous scheduler, no platform
lifecycle observer, and no timer. `RemoteEngine.flush()` is
caller-driven; hosts wire `flush()` from their own lifecycle
hooks or scheduling infrastructure (background notifications,
shutdown signals, periodic tasks).

### `SPLK-15` Retained outstanding batch reuse

A `.retryable` outcome anywhere in a flush pass keeps the
queue's outstanding batch retained. The next `flush()` reuses
the retained drained bytes through the engine's outstanding-reuse
path for the retained outstanding batch across flush passes; no
fresh queue drain runs while an outstanding batch is retained.

### `SPLK-16` Acknowledgement-to-removal lifecycle

`RemoteEngine.flush()` acknowledges (removes the delivered queue
payload bytes) only when every recovered entry across the pass
resolves as `.success` or `.terminal`. A pass-wide
`.terminal`-only resolution still acknowledges (the classifier
declared the entries permanently failed; removing those bytes is
forward progress, not data loss).

## Non-goals

`swift-logger-splunk 0.1.0` deliberately ships no:

- best-effort in-memory `SplunkLogger` (durable-only M4 scope).
- autonomous scheduler or timer.
- platform lifecycle observer.
- SDK / RUM integration (HTTP-only).
- query / search API.
- direct mobile-safe token claims.
- per-event indexer-acknowledgement via `services/collector/ack`.
