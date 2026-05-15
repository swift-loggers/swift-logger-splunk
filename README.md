# swift-logger-splunk

Splunk HTTP Event Collector (HEC) adapter for
[`swift-loggers`](https://github.com/swift-loggers), built on top of
[`swift-loggers/swift-logger-remote`](https://github.com/swift-loggers/swift-logger-remote).

`swift-logger-splunk` is the second concrete remote adapter on top
of `swift-logger-remote 0.1.0`, after
[`swift-logger-elastic 0.1.0`](https://github.com/swift-loggers/swift-logger-elastic).
The package is durable-only: it bridges Splunk HEC delivery onto
the shared `RemoteEngine` + `DurableRemoteQueue` lifecycle without
shipping a best-effort in-memory logger of its own.

`SplunkRemoteEngine` bridges HEC delivery onto
`swift-logger-remote`'s durable engine: a persistence-backed
`DurableRemoteQueue`, a batch-round retry budget over the
`RemoteTransport.sendBatch(_:)` primitive, a caller-driven
`flush()` lifecycle, retained export reuse across flush passes,
and the acknowledgement-to-removal lifecycle (no destructive
removal until the engine acknowledges a fully-resolved non-empty
flush pass). The internal Splunk transport builds **one HEC
request per non-empty dispatched batch round** (N events in one
HTTP request, newline-stacked with one HEC event envelope per
newline-delimited line, per Splunk's documented wire shape),
treats a 2xx HEC reply as success for every active item in the
batch round, and projects whole-request failures through
`RemoteTransport.classify(_:)` for every active item in the batch
round. The host wires `flush()` from its own lifecycle hooks
(background notifications, shutdown signals, periodic tasks).

> **`0.1.0` public API surface (final, locked):**
>
> - `SplunkRemoteEngine.make(_:)` -- the durable path. Returns a
>   `Wiring` carrying `DurableRemoteQueue` and `RemoteEngine`.
>   `Configuration` accepts `endpoint`, optional `source` /
>   `sourcetype` / `index` HEC envelope metadata,
>   `queueDirectory`, `exportDirectory`, `RemoteBatchPolicy`,
>   `RemoteRetryPolicy`, and an optional `URLSession` (defaults to
>   `.shared`).
> - `SplunkEndpoint`: direct Splunk HEC with an HEC token, or a
>   consumer-owned intake / proxy / gateway endpoint with an
>   arbitrary `Authorization` header (or none).

Requires Swift 6.0+. iOS 13.4, macOS 10.15.4, tvOS 13.4,
watchOS 6.2, visionOS 1. MIT licensed.

## Threat model

`swift-logger-splunk` ships two `SplunkEndpoint` cases. Pick the
one that matches your trust model.

### `.hec(url:token:)` -- direct delivery, informed opt-in

Direct mode POSTs to `url` verbatim with
`Authorization: Splunk <token>`. The adapter does **not** guess or
mutate the URL path: pass the full HEC event-endpoint URL
(typically `https://<host>:8088/services/collector/event` on
Splunk Enterprise, or
`https://http-inputs-<stack>.splunkcloud.com/services/collector/event`
on Splunk Cloud) so the adapter never silently targets a different
endpoint than the operator authorized.

This is a **supported informed opt-in**, not a prohibition. An HEC
token compiled into a client app binary is **extractable** even
when the app uses TLS: HTTPS protects the network hop, not secrets
embedded in the binary. Anyone with the binary can recover the
token with standard reverse-engineering tooling, and the Splunk
indexer behind that token inherits the trust level of the
distribution channel.

Direct mode is appropriate for trial setups, smoke tests against
Splunk Enterprise / Splunk Cloud, internal-only apps, prototypes,
throwaway exploration, and any context where the operator has
consciously accepted that risk. It is **not** the recommended
shape for an iOS or macOS app on the public App Store -- use
`.intake(...)` instead.

### `.intake(url:authorizationHeader:)` -- consumer-owned proxy / gateway

Intake mode POSTs to `url` verbatim (no path mutation) and sends
the consumer-supplied `Authorization` header value through
unchanged. Bearer, Basic, custom gateway tokens, or no auth are
supported through `.intake(url:authorizationHeader:)` because the
intake endpoint is consumer-owned. This is the recommended
hardened-production shape.

```
mobile / desktop client            first-party intake             Splunk HEC
-------------------------          ------------------             ----------
SplunkRemoteEngine.flush()   -->   your service              -->  indexer
  POST intake endpoint               - terminates client TLS         - real HEC token,
  HEC newline-stacked body           - authenticates the app           server-side
                                     - rate-limits / authorizes
                                     - stamps source/index, forwards
                                     - holds the real credential
```

The intake service owns authentication, index routing, rate
limiting, schema evolution, and duplicate-suppression policy. The
mobile client only needs to reach the intake URL; the HEC token
that talks to Splunk never has to leave the server.

If you control the entire trust boundary (for example, a back-end
Swift service running inside the same VPC as the indexer), pick
whichever case matches what you actually configured: `.hec` if
the URL is the HEC event endpoint and you set the token; `.intake`
with `authorizationHeader: nil` if the URL is your in-VPC sidecar
that authenticates by network position.

## Installation

Add this package, the core
[`swift-loggers/swift-logger`](https://github.com/swift-loggers/swift-logger)
package (`LoggerLibrary`), and
[`swift-loggers/swift-logger-remote`](https://github.com/swift-loggers/swift-logger-remote)
to your `Package.swift`. All three release-lock to `0.1.0` through
SwiftPM's `.upToNextMinor(from: "0.1.0")` requirement. The `LoggerLibrary`
product re-exports the core abstractions and the companion adapters
and is the recommended import for consumer code.

```swift
// In your Package.swift:
let package = Package(
    name: "MyApp",
    dependencies: [
        .package(
            url: "https://github.com/swift-loggers/swift-logger-splunk.git",
            .upToNextMinor(from: "0.1.0")
        ),
        .package(
            url: "https://github.com/swift-loggers/swift-logger.git",
            .upToNextMinor(from: "0.1.0")
        ),
        .package(
            url: "https://github.com/swift-loggers/swift-logger-remote.git",
            .upToNextMinor(from: "0.1.0")
        )
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "LoggerSplunk", package: "swift-logger-splunk"),
                .product(name: "LoggerLibrary", package: "swift-logger"),
                .product(name: "LoggerRemote", package: "swift-logger-remote")
            ]
        )
    ]
)
```

## Durable delivery with `SplunkRemoteEngine`

`SplunkRemoteEngine.make(_:)` returns a `Wiring` carrying a
`DurableRemoteQueue` and a `RemoteEngine` from
`swift-logger-remote`. Hosts enqueue pre-encoded HEC event payload
bytes onto the queue and call `engine.flush()` from their own
lifecycle hooks; the engine drives batch rounds against the
internal Splunk transport, applies the configured retry budget,
and acknowledges (removes delivered queue payload bytes) only
when every recovered entry across the pass resolves as `.success`
or `.terminal`.

**Payload contract.** `DurableRemoteQueue.enqueue(_:)` admits a
`RemoteDeliveryEntry` whose `payload` is **opaque pre-encoded
bytes**. For this Splunk wiring those bytes are the **single HEC
`event` payload value** -- the literal substitution for
`<payload>` in:

    {"event": <payload>, "source": "...", "sourcetype": "...", "index": "..."}

Neither the engine nor the internal Splunk transport encodes
upstream log records on the caller's behalf. The transport's only
payload responsibility is to wrap each event value in the HEC
envelope (stamping the configuration's `source`, `sourcetype`,
and `index` fields) and frame the request body as
newline-stacked HEC events with one HEC event envelope per
newline-delimited line, per Splunk's documented wire shape. Event
payload bytes MUST be a valid one-line JSON value with no literal
newlines outside JSON string escapes because the transport frames
one event envelope per newline-delimited line;
`JSONSerialization.data(withJSONObject:)` produces newline-free
JSON by default.

### Recommended: intake / proxy mode

```swift
import Foundation
import LoggerRemote
import LoggerSplunk

let queueDirectory = URL(fileURLWithPath: "/tmp/swift-logger-splunk/queue")
let exportDirectory = URL(fileURLWithPath: "/tmp/swift-logger-splunk/exports")

let configuration = SplunkRemoteEngine.Configuration(
    endpoint: .intake(
        url: URL(string: "https://logs.example.com/splunk")!,
        authorizationHeader: "Bearer demo-app-token"
    ),
    source: "ios-app",
    sourcetype: "_json",
    index: "main",
    queueDirectory: queueDirectory,
    exportDirectory: exportDirectory,
    batchPolicy: try RemoteBatchPolicy.make(
        maxEntryCount: 100,
        maxByteCount: 64 * 1024
    ),
    retryPolicy: try RemoteRetryPolicy.make(
        maxAttempts: 3,
        backoff: .exponential(
            initialSeconds: 0.5, multiplier: 2, capSeconds: 8
        )
    )
)
let wiring = SplunkRemoteEngine.make(configuration)

let eventBytes = try JSONSerialization.data(
    withJSONObject: ["message": "hello, splunk", "level": "info"]
)
try await wiring.queue.enqueue(RemoteDeliveryEntry(
    identifier: 1,
    payload: eventBytes
))
_ = try await wiring.engine.flush()
```

### Direct HEC mode (trial / smoke / internal)

```swift
import Foundation
import LoggerRemote
import LoggerSplunk

let queueDirectory = URL(fileURLWithPath: "/tmp/swift-logger-splunk/queue")
let exportDirectory = URL(fileURLWithPath: "/tmp/swift-logger-splunk/exports")
let hecToken = "your-hec-token"

let directConfiguration = SplunkRemoteEngine.Configuration(
    endpoint: .hec(
        url: URL(string: "https://splunk.example.com:8088/services/collector/event")!,
        token: hecToken
    ),
    source: "ios-app",
    sourcetype: "_json",
    index: "main",
    queueDirectory: queueDirectory,
    exportDirectory: exportDirectory,
    batchPolicy: try RemoteBatchPolicy.make(
        maxEntryCount: 100, maxByteCount: 64 * 1024
    ),
    retryPolicy: try RemoteRetryPolicy.make(
        maxAttempts: 3,
        backoff: .exponential(
            initialSeconds: 0.5, multiplier: 2, capSeconds: 8
        )
    )
)
let directWiring = SplunkRemoteEngine.make(directConfiguration)
_ = directWiring
```

The adapter sends to the configured URL verbatim with
`Authorization: Splunk <token>`. Read the threat-model note above
before shipping a binary that contains an HEC token.

### Custom URLSession

`SplunkRemoteEngine.Configuration` accepts an optional
`urlSession: URLSession` parameter (defaults to
`URLSession.shared`) so consumers can hand the adapter a
pre-configured session without subclassing or swapping the
transport. Pass a custom `URLSession` when the deployment
requires certificate pinning, mTLS, enterprise proxy configuration,
custom trust handling, or a controlled timeout policy. The
session only controls the underlying network round-trip; it does
not influence retry, batching, or acknowledgement, which stay
owned by `swift-logger-remote`'s engine.

## Response model

Splunk HEC's `services/collector/event` endpoint returns a
**whole-request** status code and a single
`{"text":"Success","code":0}`-shaped envelope. Per-event
indexer-acknowledgement is opt-in and lives on a separate
endpoint (`services/collector/ack`). `swift-logger-splunk` does
not semantically parse or validate the response body and does not
consult the ACK endpoint, so:

- A 2xx HEC reply resolves every active item in the batch round
  to `.success` with the opaque response bytes Splunk returned.
- HTTP 408 (request timeout), 429 (HEC queue or ACK channel
  at capacity), 5xx (server error), network / DNS / TLS / timeout
  / invalid-response transport failures, and unexpected HTTP
  status classes classify as **retryable** for forward
  compatibility.
- HTTP 401 (token required or invalid authorization), 403 (token
  disabled or invalid token), and other 4xx (400 invalid data
  format / incorrect index / missing event field, 404, 405, 409,
  422, ...) classify as **terminal**.

## Non-goals

`swift-logger-splunk 0.1.0` deliberately ships no:

- best-effort in-memory `SplunkLogger`; the package intentionally
  focuses on the durable remote path only.
- autonomous scheduler (`flush()` is caller-driven).
- platform lifecycle observer (host code wires `flush()` from
  whatever lifecycle hooks it cares about).
- SDK / RUM integration (`swift-logger-splunk` is HTTP-only, no
  Splunk SDKs or Real User Monitoring backends).
- query / search API (this package writes events; reading is out
  of scope).
- direct mobile-safe token claims (the HEC token is extractable
  from any client binary that holds it; use `.intake(...)` for
  hardened production deployments).

## License

MIT. See [LICENSE](LICENSE).
