import Testing

/// Swift Testing tags for `Docs/Requirements.md` requirement IDs.
///
/// One tag per SPLK ID; tags without test references are retained
/// so the catalog stays 1:1 with the spec.
extension Tag {
    // MARK: Payload contract

    /// Lazy host-side encoding boundary; payload bytes are opaque
    /// pre-encoded JSON values.
    @Tag public static var splk1: Self
    /// HEC envelope construction stamps `source` / `sourcetype` /
    /// `index`, omits absent fields, sorts keys.
    @Tag public static var splk2: Self
    /// Newline-stacked HEC framing (events separated by `0x0A`,
    /// not a JSON array), one HEC envelope per newline-delimited
    /// line.
    @Tag public static var splk3: Self

    // MARK: `RemoteTransport.sendBatch(_:)` contract

    /// One HEC request per non-empty `sendBatch(_:)` call; empty
    /// `items` returns `[]` and dispatches no HEC request.
    @Tag public static var splk4: Self
    /// One result per input item.
    @Tag public static var splk5: Self
    /// Input-order preservation across results and request body.
    @Tag public static var splk6: Self
    /// 2xx success projection (active item / batch-round scope):
    /// every active item in the batch round resolves to `.success`
    /// carrying opaque response bytes.
    @Tag public static var splk7: Self
    /// Whole-batch failure projection: `sendBatch(_:)` throw routes
    /// through `classify(_:)` for every active item.
    @Tag public static var splk8: Self

    // MARK: Classification policy

    /// Retryable mapping: HTTP 408 / 429 / 5xx, `invalidResponse`,
    /// arbitrary errors, and unexpected statuses.
    @Tag public static var splk9: Self
    /// Terminal mapping: HTTP 401 / 403 and other HTTP 4xx.
    @Tag public static var splk10: Self
    /// Deterministic classification with no queue / export-state
    /// mutation; repeated `classify(_:)` invocations for the same
    /// result within a flush pass return the same decision.
    @Tag public static var splk11: Self

    // MARK: Endpoint trust model

    /// Direct HEC builds `Authorization: Splunk <token>`; URL sent
    /// verbatim.
    @Tag public static var splk12: Self
    /// Intake passes `Authorization` verbatim or omits when `nil`;
    /// URL sent verbatim.
    @Tag public static var splk13: Self

    // MARK: Engine lifecycle ownership

    /// Caller-driven flush lifecycle (public engine surface scope):
    /// `RemoteEngine.flush()` is caller-driven; no autonomous
    /// scheduler, platform lifecycle observer, or timer.
    @Tag public static var splk14: Self
    /// Retained outstanding batch reuse for the retained outstanding
    /// batch across flush passes; no fresh drain while an
    /// outstanding batch is retained.
    @Tag public static var splk15: Self
    /// Acknowledgement-to-removal lifecycle: ack only on pass-wide
    /// `.success` / `.terminal` resolution.
    @Tag public static var splk16: Self
}
