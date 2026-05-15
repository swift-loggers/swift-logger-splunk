import Foundation

/// Internal helper that frames a batch of host-encoded event
/// payloads into the wire shape Splunk HTTP Event Collector (HEC)
/// expects: a sequence of JSON objects whose `event` field carries
/// the host's payload bytes, sibling envelope fields carry the
/// shared metadata, and each object is separated from the next by
/// a single `0x0A` newline. Splunk's documentation describes the
/// shape as "stacked one after the other, and not in a JSON
/// array."
///
/// The helper does **no event encoding itself**; it only frames
/// bytes the host-side encoder produced. Each input element is a
/// single JSON value (object, quoted string, number, …) that
/// becomes the literal substitution for `<payload>` in:
///
///     {"event": <payload>, "index": "...", "source": "...", "sourcetype": "..."}
///
/// Bytes must not carry literal newlines (`0x0A`) outside JSON
/// string escapes; HEC framing separates events by newline and a
/// stray newline inside an event would split the wire shape.
/// `JSONSerialization.data(withJSONObject:)` produces newline-free
/// JSON by default, which is the recommended way for hosts to
/// produce these bytes.
enum SplunkHECRequestBody {
    /// Builds the framed HEC request body for `events` and the
    /// envelope metadata fields the caller chose to stamp on every
    /// event in this batch.
    ///
    /// Layout per event:
    ///
    ///     {"event":<event_bytes>,<sorted metadata key/value pairs>}\n
    ///
    /// The metadata fragment is built once per call and re-appended
    /// for every event; absent fields are omitted entirely so the
    /// wire shape carries no `null` values.
    ///
    /// Capacity is reserved exactly when every per-event byte sum
    /// fits inside `Int`; the helper falls back to the `Data`
    /// default growth strategy on overflow so a pathological
    /// caller cannot trap the process inside `reserveCapacity`.
    /// The returned bytes are identical regardless of which path
    /// the reservation takes.
    ///
    /// - Parameters:
    ///   - events: Ordered host-encoded event payload bytes. Each
    ///     element MUST be a valid one-line JSON value; the helper
    ///     does not validate the bytes.
    ///   - source: HEC `source` field stamped on every event in
    ///     the batch, or `nil` to omit. Sent verbatim, JSON-string
    ///     encoded so embedded quotes and backslashes cannot break
    ///     framing.
    ///   - sourcetype: HEC `sourcetype` field stamped on every
    ///     event in the batch, or `nil` to omit.
    ///   - index: HEC `index` field stamped on every event in the
    ///     batch, or `nil` to omit. The HEC token must allow the
    ///     named index or Splunk rejects the request with HTTP
    ///     400 / code 7 ("Incorrect index").
    /// - Returns: The framed HEC request body bytes.
    /// - Throws: Whatever `JSONSerialization.data(withJSONObject:)`
    ///   raises when encoding the metadata fragment, plus
    ///   ``SplunkHECRequestBodyError/malformedMetadataEnvelope(byteCount:)``
    ///   when the envelope encoder returns a payload too short to
    ///   carry the outer-brace pair the fragment extractor
    ///   requires. The adapter routes any throw through
    ///   ``SplunkRemoteTransport/sendBatch(_:)`` as a whole-batch
    ///   failure.
    static func make(
        events: [Data],
        source: String?,
        sourcetype: String?,
        index: String?
    ) throws -> Data {
        let metadataFragment = try makeMetadataFragment(
            source: source,
            sourcetype: sourcetype,
            index: index
        )
        var body = Data()
        if let capacity = reservedTotalCapacity(
            events: events,
            fragmentCount: metadataFragment.count
        ) {
            body.reserveCapacity(capacity)
        }
        for event in events {
            body.append(openingPrefix)
            body.append(event)
            body.append(metadataFragment)
            body.append(trailingClosing)
        }
        return body
    }

    /// `{"event":` literal prepended to each event's payload bytes.
    /// Stored as `Data` so the hot path appends bytes directly.
    private static let openingPrefix = Data(#"{"event":"#.utf8)

    /// Closing brace + newline appended after the envelope's
    /// metadata fragment. HEC framing requires exactly one newline
    /// between stacked events; the trailing newline on the last
    /// event is harmless because HEC tolerates the trailing
    /// separator.
    private static let trailingClosing = Data([0x7D, 0x0A])

    /// Computes the exact `Int` capacity needed for the framed
    /// body, or `nil` when the per-event arithmetic overflows
    /// `Int`. Every intermediate sum is checked through
    /// `addingReportingOverflow` so a pathological caller (event
    /// payload byte counts that sum past `Int.max`) cannot reach
    /// `reserveCapacity` with a wrapped value or trap the
    /// process.
    ///
    /// - Parameters:
    ///   - events: Ordered host-encoded event payload bytes.
    ///   - fragmentCount: Byte length of the metadata fragment
    ///     stamped on every event in the batch.
    /// - Returns: The exact body byte count when every sum fits in
    ///   `Int`, otherwise `nil` so the caller can skip
    ///   `reserveCapacity` entirely and let `Data` grow under its
    ///   default strategy.
    private static func reservedTotalCapacity(
        events: [Data],
        fragmentCount: Int
    ) -> Int? {
        let (perEventWithoutBody, fragmentOverflow) = openingPrefix.count
            .addingReportingOverflow(fragmentCount)
        if fragmentOverflow {
            return nil
        }
        let (perEventFixed, trailingOverflow) = perEventWithoutBody
            .addingReportingOverflow(trailingClosing.count)
        if trailingOverflow {
            return nil
        }
        var total = 0
        for event in events {
            let (eventChunk, chunkOverflow) = event.count
                .addingReportingOverflow(perEventFixed)
            if chunkOverflow {
                return nil
            }
            let (next, totalOverflow) = total.addingReportingOverflow(eventChunk)
            if totalOverflow {
                return nil
            }
            total = next
        }
        return total
    }

    /// Builds the `,"index":"...","source":"...","sourcetype":"..."`
    /// fragment re-appended after every event. Keys are sorted
    /// alphabetically (via `JSONSerialization`'s `.sortedKeys`) so
    /// the wire shape is deterministic across calls; HEC ignores
    /// envelope key order so the choice is for test determinism
    /// only. The fragment is empty when all three metadata fields
    /// are `nil`.
    ///
    /// The implementation lets `JSONSerialization` build a normal
    /// `{...}` envelope from the populated fields, then strips
    /// the outer braces and prepends `,` so the bytes can be
    /// glued onto `{"event":<bytes>` and a following `}`.
    ///
    /// - Throws: Whatever `JSONSerialization.data(withJSONObject:)`
    ///   raises on the populated metadata object, plus
    ///   ``SplunkHECRequestBodyError/malformedMetadataEnvelope(byteCount:)``
    ///   if the encoder ever returns fewer than two bytes (no
    ///   outer-brace pair to strip).
    private static func makeMetadataFragment(
        source: String?,
        sourcetype: String?,
        index: String?
    ) throws -> Data {
        var object: [String: String] = [:]
        if let source {
            object["source"] = source
        }
        if let sourcetype {
            object["sourcetype"] = sourcetype
        }
        if let index {
            object["index"] = index
        }
        guard !object.isEmpty else {
            return Data()
        }
        let encoded = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        // `encoded` is `{"index":"...","source":"...","sourcetype":"..."}`.
        // We want the same key/value pairs as a comma-prefixed
        // fragment that can be glued onto `{"event":<bytes>` and
        // a following `}`. Drop the outer braces and prepend `,`.
        // A non-empty `object` should always produce at least
        // `{}` (and in practice more) from `JSONSerialization`,
        // but a future Foundation regression that returned a
        // payload shorter than the outer-brace pair would trap
        // `subdata(in:)` with an empty `1..<n-1` range. Fail
        // closed with a thrown error so the adapter routes it as
        // a whole-batch failure instead.
        guard encoded.count >= 2 else {
            throw SplunkHECRequestBodyError
                .malformedMetadataEnvelope(byteCount: encoded.count)
        }
        var fragment = Data()
        fragment.reserveCapacity(encoded.count)
        fragment.append(0x2C) // ','
        fragment.append(encoded.subdata(in: 1 ..< encoded.count - 1))
        return fragment
    }
}

/// Errors `SplunkHECRequestBody` raises when the metadata
/// fragment encoder produces an envelope whose framing
/// assumptions break.
enum SplunkHECRequestBodyError: Error, Sendable, Equatable {
    /// `JSONSerialization` returned a metadata envelope shorter
    /// than the outer `{}` brace pair the fragment extractor
    /// requires (`byteCount < 2`). The fragment cannot be
    /// derived; ``SplunkRemoteTransport/sendBatch(_:)`` routes
    /// the throw through ``SplunkRemoteTransport/classify(_:)``
    /// as a whole-batch failure for every active item.
    case malformedMetadataEnvelope(byteCount: Int)
}
