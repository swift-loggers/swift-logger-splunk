import Foundation

/// The destination a ``SplunkRemoteEngine`` POSTs Splunk HTTP Event
/// Collector (HEC) payloads to, plus the credentials needed to reach
/// it.
///
/// `SplunkEndpoint` has two cases that correspond to two distinct
/// deployment shapes; pick the one that matches your trust model.
///
/// ## Direct delivery — `.hec(url:token:)`
///
/// Direct delivery to a Splunk HTTP Event Collector. The adapter
/// POSTs the framed HEC body to `url` **verbatim** -- it does not
/// guess or mutate the URL path -- and sends the configured HEC
/// token in an `Authorization: Splunk <token>` header on every
/// request. Pass the full event-endpoint URL (typically
/// `https://<host>:8088/services/collector/event` on Splunk
/// Enterprise, or `https://http-inputs-<stack>.splunkcloud.com/services/collector/event`
/// on Splunk Cloud) so the adapter never silently picks an endpoint
/// path you did not authorize.
///
/// This mode is a supported, informed opt-in. **An HEC token
/// compiled into a client app binary is extractable**: anyone with
/// the binary can recover the token with standard reverse-engineering
/// tooling, so the Splunk indexer behind that token inherits the
/// trust level of the distribution channel. Direct mode is
/// appropriate for trial setups, smoke tests, internal-only apps,
/// prototypes, and any context where the operator has consciously
/// accepted that risk. For hardened production use cases the
/// recommended shape is ``intake(url:authorizationHeader:)`` (or
/// another intermediary you control), so the real HEC token never
/// ships with the client.
///
/// ## Consumer-owned intake / proxy — `.intake(url:authorizationHeader:)`
///
/// Delivery through a first-party intake / proxy / gateway endpoint
/// owned by the consumer. The adapter POSTs the framed HEC body to
/// `url` verbatim and lets the intake decide its own URL
/// conventions, indexing, rate limiting, and onward routing to
/// Splunk HEC.
///
/// `authorizationHeader` is sent verbatim as the value of the
/// `Authorization` request header. Bearer, Basic, custom gateway
/// tokens, or no auth are supported through this case because the
/// intake endpoint is consumer-owned. Pass `nil` to omit the
/// `Authorization` header entirely (for example, when the intake
/// runs on a private network and authenticates by transport-level
/// trust).
public enum SplunkEndpoint: Sendable, Equatable {
    /// Direct delivery to a Splunk HTTP Event Collector using an
    /// HEC token credential.
    ///
    /// - Parameters:
    ///   - url: The full HEC event-endpoint URL. The adapter POSTs
    ///     to this URL verbatim and does not append or mutate the
    ///     path; on Splunk Enterprise this is typically
    ///     `https://<host>:8088/services/collector/event`.
    ///   - token: The HEC token. Sent as
    ///     `Authorization: Splunk <token>` verbatim. Treat this
    ///     value as extractable when compiled into a client binary.
    case hec(url: URL, token: String)

    /// Delivery through a consumer-owned intake / proxy / gateway
    /// endpoint.
    ///
    /// - Parameters:
    ///   - url: The intake URL. The adapter sends to this URL
    ///     verbatim and does not mutate the path.
    ///   - authorizationHeader: The full value of the
    ///     `Authorization` header (for example `"Bearer abc"` or
    ///     `"Splunk <token>"`), or `nil` to omit the header
    ///     entirely.
    case intake(url: URL, authorizationHeader: String?)
}

extension SplunkEndpoint {
    /// The URL the adapter POSTs framed HEC bodies to. Both cases
    /// return the configured URL verbatim; the adapter never
    /// guesses or rewrites the path so a misconfigured base URL
    /// fails closed at the network round-trip instead of silently
    /// targeting a different endpoint than the caller expected.
    var requestURL: URL {
        switch self {
        case let .hec(url, _):
            return url
        case let .intake(url, _):
            return url
        }
    }

    /// The value the adapter sends in the `Authorization` request
    /// header, or `nil` to omit the header. Direct mode produces
    /// `"Splunk <token>"`; intake mode passes the consumer's
    /// header value through verbatim.
    var authorizationHeaderValue: String? {
        switch self {
        case let .hec(_, token):
            return "Splunk \(token)"
        case let .intake(_, header):
            return header
        }
    }
}
