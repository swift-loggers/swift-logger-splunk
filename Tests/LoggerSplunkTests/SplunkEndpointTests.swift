import Foundation
import Testing

@testable import LoggerSplunk

@Suite("SplunkEndpoint")
struct SplunkEndpointTests {
    // MARK: requestURL

    @Test(
        "Direct HEC endpoint preserves the URL verbatim and never appends a path",
        .tags(.splk12)
    )
    func hecRequestURLIsVerbatim() throws {
        let url = try #require(URL(string: "https://splunk.example.com:8088/services/collector/event"))
        let endpoint = SplunkEndpoint.hec(url: url, token: "tok")

        #expect(endpoint.requestURL == url)
    }

    @Test(
        "Intake endpoint preserves the URL verbatim",
        .tags(.splk13)
    )
    func intakeRequestURLIsVerbatim() throws {
        let url = try #require(URL(string: "https://logs.example.com/splunk"))
        let endpoint = SplunkEndpoint.intake(
            url: url,
            authorizationHeader: "Bearer abc"
        )

        #expect(endpoint.requestURL == url)
    }

    // MARK: authorizationHeaderValue

    @Test(
        "Direct HEC endpoint produces a `Splunk <token>` Authorization value",
        .tags(.splk12)
    )
    func hecAuthorizationHeader() throws {
        let url = try #require(URL(string: "https://splunk.example.com:8088/services/collector/event"))
        let endpoint = SplunkEndpoint.hec(url: url, token: "abc123")

        #expect(endpoint.authorizationHeaderValue == "Splunk abc123")
    }

    @Test(
        "Intake endpoint passes the Authorization header through verbatim",
        .tags(.splk13)
    )
    func intakeAuthorizationHeaderPassthrough() throws {
        let url = try #require(URL(string: "https://logs.example.com"))

        let bearer = SplunkEndpoint.intake(
            url: url,
            authorizationHeader: "Bearer xyz"
        )
        #expect(bearer.authorizationHeaderValue == "Bearer xyz")

        let basic = SplunkEndpoint.intake(
            url: url,
            authorizationHeader: "Basic dXNlcjpwYXNz"
        )
        #expect(basic.authorizationHeaderValue == "Basic dXNlcjpwYXNz")

        let splunkPassthrough = SplunkEndpoint.intake(
            url: url,
            authorizationHeader: "Splunk tok-via-intake"
        )
        #expect(splunkPassthrough.authorizationHeaderValue == "Splunk tok-via-intake")
    }

    @Test(
        "Intake endpoint with nil header omits the Authorization header",
        .tags(.splk13)
    )
    func intakeNilAuthorizationOmitsHeader() throws {
        let url = try #require(URL(string: "https://logs.example.com"))
        let endpoint = SplunkEndpoint.intake(
            url: url,
            authorizationHeader: nil
        )

        #expect(endpoint.authorizationHeaderValue == nil)
    }

    // MARK: Equatable

    @Test("Equatable: same case + same associated values compare equal")
    func equatableSameCaseEqual() throws {
        let url = try #require(URL(string: "https://splunk.example.com:8088/services/collector/event"))
        let lhs = SplunkEndpoint.hec(url: url, token: "tok")
        let rhs = SplunkEndpoint.hec(url: url, token: "tok")

        #expect(lhs == rhs)
    }

    @Test("Equatable: different cases compare not-equal")
    func equatableCrossCaseNotEqual() throws {
        let url = try #require(URL(string: "https://splunk.example.com:8088/services/collector/event"))
        let hec = SplunkEndpoint.hec(url: url, token: "tok")
        let intake = SplunkEndpoint.intake(url: url, authorizationHeader: "Splunk tok")

        #expect(hec != intake)
    }
}
