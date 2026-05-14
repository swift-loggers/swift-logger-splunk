import Foundation
import LoggerRemote

/// Factory namespace that wires the Splunk-side `RemoteTransport`
/// adapter to the engine surface exposed by `swift-logger-remote`.
///
/// Hosts that opt into durable Splunk HTTP Event Collector (HEC)
/// delivery call ``make(_:)`` once during startup to build the
/// `RemoteEngine` + `DurableRemoteQueue` pair backing HEC-bound log
/// delivery. Each subsequent host-driven `flush()` runs one
/// batch-round dispatch pass through the internal Splunk
/// `RemoteTransport` adapter; the engine owns the durable queue,
/// retry budget, batch rounds, retained-artifact reuse, and the
/// acknowledgement-to-removal lifecycle.
///
/// The factory deliberately stays narrow: it returns the
/// `RemoteEngine` actor plus its backing `DurableRemoteQueue` so
/// the caller can `enqueue(_:)` directly without re-deriving the
/// queue handle from the engine. Hosts wire `flush()` calls from
/// their own lifecycle hooks (background notifications, shutdown
/// signals, periodic tasks); the factory installs no platform
/// observer of its own.
///
/// ## Payload contract
///
/// `DurableRemoteQueue.enqueue(_:)` admits a `RemoteDeliveryEntry`
/// whose `payload` is **opaque pre-encoded bytes**. For this Splunk
/// wiring those bytes are the **one HEC event payload value** --
/// the literal substitution for `<payload>` in:
///
///     {"event": <payload>, "source": "...", "sourcetype": "...", "index": "..."}
///
/// The engine and the internal Splunk transport never encode
/// upstream-host log records on the caller's behalf. Hosts (or a
/// thin encoder helper on the host side) build the JSON event value
/// for each entry before `enqueue`; the transport wraps each value
/// in the HEC envelope (stamping the configuration's `source`,
/// `sourcetype`, and `index` fields) and frames the body as
/// newline-stacked HEC events.
///
/// Event payload bytes MUST be a valid one-line JSON value with no
/// embedded `0x0A` newlines outside JSON string escapes; HEC
/// framing separates events by newline.
/// `JSONSerialization.data(withJSONObject:)` produces newline-free
/// JSON by default.
public enum SplunkRemoteEngine {
    /// Wiring carried by ``make(_:)`` so the caller has both the
    /// `RemoteEngine` actor that runs the flush pass and the
    /// `DurableRemoteQueue` handle that admits new entries through
    /// `enqueue(_:)`. The transport instance is held by the engine
    /// internally and is intentionally not surfaced here so the
    /// factory's public shape stays narrow.
    public struct Wiring: Sendable {
        /// Durable queue handle the caller uses to enqueue
        /// pre-encoded HEC event payloads through
        /// `DurableRemoteQueue.enqueue(_:)`.
        public let queue: DurableRemoteQueue

        /// Engine actor the caller drives through
        /// `RemoteEngine.flush()` from a host-owned lifecycle
        /// hook.
        public let engine: RemoteEngine
    }

    /// Caller-facing configuration for the durable Splunk wiring.
    ///
    /// The struct stays plain-data so hosts that already manage
    /// their own configuration objects can map their fields onto
    /// this contract without re-deriving engine policy types.
    public struct Configuration: Sendable {
        /// Target Splunk endpoint (direct HEC or intake gateway).
        /// Both cases are POSTed verbatim; the adapter does not
        /// guess or mutate the URL path.
        public let endpoint: SplunkEndpoint

        /// HEC `source` field stamped on every event in the batch,
        /// or `nil` to omit. Splunk uses `source` to label the
        /// data origin (typically the application name).
        public let source: String?

        /// HEC `sourcetype` field stamped on every event in the
        /// batch, or `nil` to omit. Splunk uses `sourcetype` to
        /// classify the event format and select a parser at index
        /// time.
        public let sourcetype: String?

        /// HEC `index` field stamped on every event in the batch,
        /// or `nil` to omit. The HEC token's allowed-index list
        /// must include the named index or Splunk rejects the
        /// request with HTTP 400 / code 7 ("Incorrect index").
        public let index: String?

        /// Host-owned queue directory. Persistence-backed durable
        /// queue lives here; the engine never deletes the
        /// directory itself, only the persistence layer it owns.
        public let queueDirectory: URL

        /// Host-owned scratch directory the engine writes
        /// byte-stable exports into during `flush()`. Must be
        /// engine-exclusive (no other process or actor touches
        /// the files inside).
        public let exportDirectory: URL

        /// Batch boundary policy: max entry count and max byte
        /// count the batching engine respects per dispatched HEC
        /// round.
        public let batchPolicy: RemoteBatchPolicy

        /// Per-entry retry budget and backoff schedule. The
        /// engine applies the policy across batch rounds within
        /// one flush pass.
        public let retryPolicy: RemoteRetryPolicy

        /// URLSession the transport dispatches through. Hosts
        /// that want a custom timeout, connection limit, or proxy
        /// configuration inject their own session here.
        public let urlSession: URLSession

        /// Builds a configuration for the durable Splunk wiring.
        ///
        /// - Parameters:
        ///   - endpoint: Target Splunk endpoint (direct HEC or
        ///     intake gateway).
        ///   - source: HEC `source` field stamped on every event
        ///     in the batch, or `nil` to omit. Defaults to `nil`.
        ///   - sourcetype: HEC `sourcetype` field stamped on
        ///     every event in the batch, or `nil` to omit.
        ///     Defaults to `nil`.
        ///   - index: HEC `index` field stamped on every event
        ///     in the batch, or `nil` to omit. Defaults to `nil`.
        ///   - queueDirectory: Host-owned queue directory.
        ///   - exportDirectory: Host-owned engine-exclusive
        ///     scratch directory for byte-stable flush exports.
        ///   - batchPolicy: Validated batch boundary policy.
        ///   - retryPolicy: Validated retry budget and backoff
        ///     schedule.
        ///   - urlSession: URLSession the transport dispatches
        ///     through. Defaults to `.shared`.
        public init(
            endpoint: SplunkEndpoint,
            source: String? = nil,
            sourcetype: String? = nil,
            index: String? = nil,
            queueDirectory: URL,
            exportDirectory: URL,
            batchPolicy: RemoteBatchPolicy,
            retryPolicy: RemoteRetryPolicy,
            urlSession: URLSession = .shared
        ) {
            self.endpoint = endpoint
            self.source = source
            self.sourcetype = sourcetype
            self.index = index
            self.queueDirectory = queueDirectory
            self.exportDirectory = exportDirectory
            self.batchPolicy = batchPolicy
            self.retryPolicy = retryPolicy
            self.urlSession = urlSession
        }
    }

    /// Builds the `RemoteEngine` + `DurableRemoteQueue` +
    /// `SplunkRemoteTransport` wiring from `configuration`.
    /// Pure factory: no I/O, no side effects beyond constructing
    /// the actor instances. Queue persistence touches disk only
    /// when the returned queue or engine is later used.
    ///
    /// - Parameter configuration: Validated configuration carrying
    ///   the endpoint, envelope metadata, queue/export directories,
    ///   batch / retry policies, and the URLSession the transport
    ///   should dispatch through.
    /// - Returns: A ``Wiring`` carrying the queue handle for
    ///   `enqueue(_:)` and the engine actor for `flush()`.
    public static func make(_ configuration: Configuration) -> Wiring {
        let transport = SplunkRemoteTransport(
            endpoint: configuration.endpoint,
            source: configuration.source,
            sourcetype: configuration.sourcetype,
            index: configuration.index,
            urlSession: configuration.urlSession
        )
        return wire(configuration: configuration, transport: transport)
    }

    /// Test-only factory that swaps the HTTP seam for a custom
    /// ``SplunkEventTransport`` implementation. Marked `internal`
    /// because ``SplunkEventTransport`` is the package-internal
    /// transport contract; the public surface only exposes the
    /// `URLSession`-backed shape through ``make(_:)``.
    static func make(
        _ configuration: Configuration,
        eventTransport: any SplunkEventTransport
    ) -> Wiring {
        let transport = SplunkRemoteTransport(
            endpoint: configuration.endpoint,
            source: configuration.source,
            sourcetype: configuration.sourcetype,
            index: configuration.index,
            transport: eventTransport
        )
        return wire(configuration: configuration, transport: transport)
    }

    private static func wire(
        configuration: Configuration,
        transport: SplunkRemoteTransport
    ) -> Wiring {
        let queue = DurableRemoteQueue(directory: configuration.queueDirectory)
        let engine = RemoteEngine(
            queue: queue,
            exportDirectory: configuration.exportDirectory,
            transport: transport,
            batchPolicy: configuration.batchPolicy,
            retryPolicy: configuration.retryPolicy
        )
        return Wiring(queue: queue, engine: engine)
    }
}
