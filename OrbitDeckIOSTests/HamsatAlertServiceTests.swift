import Testing
import Foundation
@testable import OrbitDeck

// MARK: - Test harness: a local stand-in for the hams.at POST /api/alerts endpoint
//
// hams.at has no sandbox/test API, so this harness reproduces the documented
// server contract locally: it authenticates the bearer token, applies the same
// required-field validation, and returns 201 / 401 / 422 responses shaped like the
// real service. Driving `HamsatAlertService` through it exercises request building,
// auth, validation and response parsing without ever touching the live site.
struct MockHamsatTransport: HamsatTransport {
    var acceptedKey = "TEST-KEY"

    // Captures the last request the client sent, for assertions.
    final class Capture: @unchecked Sendable { var request: URLRequest? }
    let capture = Capture()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capture.request = request
        let url = request.url ?? URL(string: "https://hams.at/api/alerts")!

        // Authentication (mirrors bearerAuth in the OpenAPI spec).
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(acceptedKey)" else {
            return (Self.errorBody(["Unauthenticated."]), Self.http(url, 401))
        }

        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]

        // Server-side validation of the documented required fields.
        var errors: [String] = []
        if (body["satellite_number"] as? Int) == nil { errors.append("satellite_number is required.") }
        if let call = body["callsign"] as? String { if call.count < 3 { errors.append("callsign is too short.") } }
        else { errors.append("callsign is required.") }
        if let grids = body["grids"] as? [String] {
            if grids.isEmpty || grids.count > 4 { errors.append("grids must contain 1 to 4 entries.") }
        } else { errors.append("grids is required.") }
        if body["max_at"] == nil { errors.append("max_at is required.") }
        if body["observer_lat"] == nil || body["observer_lon"] == nil { errors.append("observer position is required.") }
        if !errors.isEmpty { return (Self.errorBody(errors), Self.http(url, 422)) }

        // Success — echo an Alert wrapped in { "data": … }.
        let number = body["satellite_number"] as? Int ?? 0
        let callsign = (body["callsign"] as? String ?? "").uppercased()
        let alert: [String: Any] = [
            "data": [
                "id": "00000000-0000-0000-0000-000000000001",
                "url": "https://hams.at/alerts/00000000-0000-0000-0000-000000000001",
                "callsign": callsign,
                "grids": body["grids"] ?? [],
                "satellite": ["name": "MOCK-SAT", "number": number]
            ]
        ]
        return (try JSONSerialization.data(withJSONObject: alert), Self.http(url, 201))
    }

    private static func http(_ url: URL, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
    }
    private static func errorBody(_ messages: [String]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["errors": messages])) ?? Data()
    }
}

private func validRequest() -> HamsatAlertRequest {
    HamsatAlertRequest(
        satelliteNumber: 7530,          // AO-7
        observerLatitude: 38.9,
        observerLongitude: -77.0,
        maxAt: Date(timeIntervalSince1970: 1_770_000_000),
        callsign: "N8HM",
        grids: ["FM18"]
    )
}

// MARK: - Request building

@Suite struct HamsatRequestBuildingTests {
    @Test func buildsAuthorizedJSONRequest() throws {
        let request = try HamsatAlertService.makeRequest(validRequest(), apiKey: "TEST-KEY")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://hams.at/api/alerts")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TEST-KEY")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["satellite_number"] as? Int == 7530)
        #expect(body["callsign"] as? String == "N8HM")
        #expect(body["grids"] as? [String] == ["FM18"])
        // max_at is serialized as an internet date-time string.
        #expect((body["max_at"] as? String)?.contains("T") == true)
    }

    @Test func trimsAndUppercasesCallAndGrids() throws {
        var req = validRequest()
        req.callsign = "  n8hm  "
        req.grids = [" fm18 ", "fm19"]
        let request = try HamsatAlertService.makeRequest(req, apiKey: "TEST-KEY")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["callsign"] as? String == "N8HM")
        #expect(body["grids"] as? [String] == ["FM18", "FM19"])
    }

    @Test func includesOptionalFieldsWhenSet() throws {
        var req = validRequest()
        req.mode = "SSB"; req.mhz = 145.925; req.mhzDirection = "down"; req.comment = "CQ"; req.chatEnabled = false
        let request = try HamsatAlertService.makeRequest(req, apiKey: "TEST-KEY")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["mode"] as? String == "SSB")
        #expect(body["mhz"] as? Double == 145.925)
        #expect(body["mhz_direction"] as? String == "down")
        #expect(body["comment"] as? String == "CQ")
        #expect(body["chat_enabled"] as? Bool == false)
    }

    @Test func missingAPIKeyThrows() {
        #expect(throws: HamsatAlertError.missingAPIKey) {
            _ = try HamsatAlertService.makeRequest(validRequest(), apiKey: "   ")
        }
    }
}

// MARK: - Local validation

@Suite struct HamsatValidationTests {
    @Test func acceptsValidRequest() throws {
        try HamsatAlertService.validate(validRequest())
    }

    @Test func rejectsShortCallsign() {
        var req = validRequest(); req.callsign = "N8"
        #expect(throws: HamsatAlertError.self) { try HamsatAlertService.validate(req) }
    }

    @Test func rejectsEmptyAndOverfullGrids() {
        var none = validRequest(); none.grids = []
        #expect(throws: HamsatAlertError.self) { try HamsatAlertService.validate(none) }
        var tooMany = validRequest(); tooMany.grids = ["FM18", "FM19", "FN20", "FN21", "FN22"]
        #expect(throws: HamsatAlertError.self) { try HamsatAlertService.validate(tooMany) }
    }

    @Test func rejectsMalformedGridLength() {
        var req = validRequest(); req.grids = ["FM1"]
        #expect(throws: HamsatAlertError.self) { try HamsatAlertService.validate(req) }
    }

    @Test func rejectsOutOfRangeObserver() {
        var req = validRequest(); req.observerLatitude = 120
        #expect(throws: HamsatAlertError.self) { try HamsatAlertService.validate(req) }
    }

    @Test func rejectsOverlongComment() {
        var req = validRequest(); req.comment = String(repeating: "x", count: 51)
        #expect(throws: HamsatAlertError.self) { try HamsatAlertService.validate(req) }
    }
}

// MARK: - Response parsing

@Suite struct HamsatResponseParsingTests {
    private func response(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://hams.at/api/alerts")!, statusCode: code,
                        httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    @Test func parses201() throws {
        let json = """
        {"data":{"id":"abc","url":"https://hams.at/alerts/abc","callsign":"N8HM","satellite":{"name":"AO-7","number":7530}}}
        """.data(using: .utf8)!
        let alert = try HamsatAlertService.parseResponse(data: json, response: response(201))
        #expect(alert.id == "abc")
        #expect(alert.url == "https://hams.at/alerts/abc")
        #expect(alert.callsign == "N8HM")
        #expect(alert.satelliteName == "AO-7")
    }

    @Test func maps401ToUnauthorized() {
        let json = #"{"errors":["Unauthenticated."]}"#.data(using: .utf8)!
        #expect(throws: HamsatAlertError.unauthorized(["Unauthenticated."])) {
            _ = try HamsatAlertService.parseResponse(data: json, response: response(401))
        }
    }

    @Test func maps422ToValidation() {
        let json = #"{"errors":["callsign is too short."]}"#.data(using: .utf8)!
        #expect(throws: HamsatAlertError.validation(["callsign is too short."])) {
            _ = try HamsatAlertService.parseResponse(data: json, response: response(422))
        }
    }
}

// MARK: - End-to-end through the mock server

@Suite struct HamsatPostAlertTests {
    @Test func postsSuccessfullyThroughMock() async throws {
        let transport = MockHamsatTransport()
        let result = try await HamsatAlertService.postAlert(validRequest(), apiKey: "TEST-KEY", transport: transport)
        #expect(result.id == "00000000-0000-0000-0000-000000000001")
        #expect(result.callsign == "N8HM")
        #expect(result.satelliteName == "MOCK-SAT")
        // The client actually authorized and sent JSON.
        #expect(transport.capture.request?.value(forHTTPHeaderField: "Authorization") == "Bearer TEST-KEY")
    }

    @Test func wrongKeyIsRejectedByMock() async {
        let transport = MockHamsatTransport()
        await #expect(throws: HamsatAlertError.self) {
            _ = try await HamsatAlertService.postAlert(validRequest(), apiKey: "WRONG-KEY", transport: transport)
        }
    }

    @Test func localValidationShortCircuitsBeforeNetwork() async {
        let transport = MockHamsatTransport()
        var bad = validRequest(); bad.callsign = "X"
        await #expect(throws: HamsatAlertError.self) {
            _ = try await HamsatAlertService.postAlert(bad, apiKey: "TEST-KEY", transport: transport)
        }
        // The request never reached the transport.
        #expect(transport.capture.request == nil)
    }
}
