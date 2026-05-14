import Foundation
import Testing

@testable import LoggerSplunk

@Suite("SplunkHECRequestBody framing")
struct SplunkHECRequestBodyTests {
    private static func makeEventBytes(_ message: String) -> Data {
        Data(#"{"msg":"\#(message)"}"#.utf8)
    }

    @Test(
        "Single event with all metadata produces the documented HEC envelope",
        .tags(.splk2, .splk3)
    )
    func singleEventWithAllMetadata() throws {
        let body = try SplunkHECRequestBody.make(
            events: [Self.makeEventBytes("hello")],
            source: "ios-app",
            sourcetype: "_json",
            index: "main"
        )

        let expected = Data(
            #"{"event":{"msg":"hello"},"index":"main","source":"ios-app","sourcetype":"_json"}"#
                .utf8
        ) + Data([0x0A])
        #expect(body == expected)
    }

    @Test(
        "Multiple events stacked one after the other separated by newlines",
        .tags(.splk3)
    )
    func multipleEventsAreNewlineStacked() throws {
        let body = try SplunkHECRequestBody.make(
            events: [
                Self.makeEventBytes("one"),
                Self.makeEventBytes("two"),
                Self.makeEventBytes("three")
            ],
            source: "ios-app",
            sourcetype: nil,
            index: nil
        )

        let lines = body.split(separator: 0x0A, omittingEmptySubsequences: true)
        #expect(lines.count == 3)
        #expect(body.last == 0x0A)
    }

    @Test(
        "Empty event array produces empty body",
        .tags(.splk3)
    )
    func emptyEventsProduceEmptyBody() throws {
        let body = try SplunkHECRequestBody.make(
            events: [],
            source: "ios-app",
            sourcetype: "_json",
            index: "main"
        )

        #expect(body.isEmpty)
    }

    @Test(
        "All nil metadata omits the suffix entirely (event-only envelope)",
        .tags(.splk2)
    )
    func allNilMetadataOmitsSuffix() throws {
        let body = try SplunkHECRequestBody.make(
            events: [Self.makeEventBytes("hello")],
            source: nil,
            sourcetype: nil,
            index: nil
        )

        let expected = Data(#"{"event":{"msg":"hello"}}"#.utf8) + Data([0x0A])
        #expect(body == expected)
    }

    @Test(
        "Partial metadata omits only the nil fields",
        .tags(.splk2)
    )
    func partialMetadataOmitsNilFields() throws {
        let body = try SplunkHECRequestBody.make(
            events: [Self.makeEventBytes("hello")],
            source: "ios-app",
            sourcetype: nil,
            index: nil
        )

        let expected = Data(
            #"{"event":{"msg":"hello"},"source":"ios-app"}"#.utf8
        ) + Data([0x0A])
        #expect(body == expected)
    }

    @Test(
        "Metadata fields containing JSON-special characters are JSON-string encoded",
        .tags(.splk2)
    )
    func metadataEscapingHandled() throws {
        let body = try SplunkHECRequestBody.make(
            events: [Self.makeEventBytes("hello")],
            source: #"ios "test" app"#,
            sourcetype: nil,
            index: nil
        )

        // `JSONSerialization` escapes the embedded quotes; the
        // envelope remains valid JSON regardless of the input.
        let bodyWithoutTrailingNewline = body.dropLast()
        let parsed = try JSONSerialization.jsonObject(
            with: bodyWithoutTrailingNewline
        ) as? [String: Any]
        #expect(parsed?["source"] as? String == #"ios "test" app"#)
    }

    @Test(
        "Event payload bytes appear verbatim inside the envelope",
        .tags(.splk1, .splk2)
    )
    func eventPayloadIsAppendedVerbatim() throws {
        let payload = Data(#"{"deeply":{"nested":[1,2,3]}}"#.utf8)
        let body = try SplunkHECRequestBody.make(
            events: [payload],
            source: nil,
            sourcetype: nil,
            index: nil
        )

        let expected = Data(#"{"event":"#.utf8) + payload + Data([0x7D, 0x0A])
        #expect(body == expected)
    }
}
