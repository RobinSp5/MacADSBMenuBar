import XCTest
@testable import MenuBarADSB

final class ADSBServiceTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func mock200(json: String) {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, json.data(using: .utf8)!)
        }
    }

    func testAircraftNear_buildsCorrectURLAndDecodes() async throws {
        final class CaptureBox: @unchecked Sendable { var url: URL? }
        let capture = CaptureBox()
        MockURLProtocol.requestHandler = { request in
            capture.url = request.url
            let body = """
            { "ac": [{ "hex": "abc123", "lat": 50.0, "lon": 8.0 }],
              "msg": "No error", "now": 1 }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        let svc = ADSBService(session: MockURLProtocol.makeSession())
        let aircraft = try await svc.aircraftNear(lat: 50.0, lon: 8.0, radiusKm: 3.0)

        XCTAssertEqual(aircraft.count, 1)
        XCTAssertEqual(aircraft[0].hex, "abc123")

        // Spec §5.1: distNM = ceil(3.0 * 0.539957) = 2
        let url = try XCTUnwrap(capture.url)
        XCTAssertEqual(url.host, "api.adsb.lol")
        XCTAssertTrue(url.path.contains("/v2/lat/50.0/lon/8.0/dist/2"),
                      "Unexpected URL path: \(url.path)")
    }

    func testAircraftNear_sortsByAscendingDistance() async throws {
        // User at (50,8). Three aircraft at increasing distance.
        mock200(json: """
        { "ac": [
            { "hex": "ccc", "lat": 50.02, "lon": 8.0 },
            { "hex": "aaa", "lat": 50.001, "lon": 8.0 },
            { "hex": "bbb", "lat": 50.01, "lon": 8.0 }
          ], "msg": "No error", "now": 1 }
        """)

        let svc = ADSBService(session: MockURLProtocol.makeSession())
        let aircraft = try await svc.aircraftNear(lat: 50.0, lon: 8.0, radiusKm: 3.0)

        XCTAssertEqual(aircraft.map { $0.hex }, ["aaa", "bbb", "ccc"])
        XCTAssertLessThan(aircraft[0].distanceKm, aircraft[1].distanceKm)
        XCTAssertLessThan(aircraft[1].distanceKm, aircraft[2].distanceKm)
    }

    func testAircraftNear_filtersOutsideRadius() async throws {
        mock200(json: """
        { "ac": [
            { "hex": "in",  "lat": 50.001, "lon": 8.0 },
            { "hex": "out", "lat": 50.1,   "lon": 8.0 }
          ], "msg": "No error", "now": 1 }
        """)

        let svc = ADSBService(session: MockURLProtocol.makeSession())
        let aircraft = try await svc.aircraftNear(lat: 50.0, lon: 8.0, radiusKm: 3.0)

        XCTAssertEqual(aircraft.map { $0.hex }, ["in"])
    }

    func testAircraftNear_throwsRateLimitedOn429() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data())
        }
        let svc = ADSBService(session: MockURLProtocol.makeSession())
        do {
            _ = try await svc.aircraftNear(lat: 50.0, lon: 8.0, radiusKm: 3.0)
            XCTFail("Expected throw")
        } catch ADSBError.rateLimited {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testAircraftNear_throwsHTTPOn500() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data())
        }
        let svc = ADSBService(session: MockURLProtocol.makeSession())
        do {
            _ = try await svc.aircraftNear(lat: 50.0, lon: 8.0, radiusKm: 3.0)
            XCTFail("Expected throw")
        } catch ADSBError.http(500) {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testAircraftNear_throwsDecodingOnGarbage() async {
        mock200(json: "this is not json")
        let svc = ADSBService(session: MockURLProtocol.makeSession())
        do {
            _ = try await svc.aircraftNear(lat: 50.0, lon: 8.0, radiusKm: 3.0)
            XCTFail("Expected throw")
        } catch ADSBError.decoding {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}
