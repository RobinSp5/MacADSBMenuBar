import XCTest
@testable import MenuBarADSB

final class RouteServiceTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("Fixture \(name).json not found")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    private func mock200(data: Data) {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, data)
        }
    }

    func testRoute_fullPayload() async throws {
        let data = try loadFixture("route-full")
        mock200(data: data)
        let svc = RouteService(session: MockURLProtocol.makeSession())
        let info = try await svc.route(forCallsign: "DLH441")
        XCTAssertEqual(info?.airline, "Lufthansa")
        XCTAssertEqual(info?.originIATA, "FRA")
        XCTAssertEqual(info?.destinationIATA, "MUC")
    }

    func testRoute_partialPayload() async throws {
        let data = try loadFixture("route-partial")
        mock200(data: data)
        let svc = RouteService(session: MockURLProtocol.makeSession())
        let info = try await svc.route(forCallsign: "PRIVATE1")
        XCTAssertNil(info?.airline)
        XCTAssertEqual(info?.originIATA, "FRA")
        XCTAssertNil(info?.destinationIATA)
    }

    func testRoute_unknownCallsignReturns404Nil() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, "{\"response\":\"unknown callsign\"}".data(using: .utf8)!)
        }
        let svc = RouteService(session: MockURLProtocol.makeSession())
        let info = try await svc.route(forCallsign: "UNKNOWN")
        XCTAssertNil(info)
    }

    func testRoute_throwsRateLimitedOn429() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data())
        }
        let svc = RouteService(session: MockURLProtocol.makeSession())
        do {
            _ = try await svc.route(forCallsign: "X")
            XCTFail("Expected throw")
        } catch ADSBError.rateLimited {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testRoute_throwsHTTPOn500() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data())
        }
        let svc = RouteService(session: MockURLProtocol.makeSession())
        do {
            _ = try await svc.route(forCallsign: "X")
            XCTFail("Expected throw")
        } catch ADSBError.http(500) {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testRoute_throwsDecodingOnGarbage() async {
        mock200(data: "not json".data(using: .utf8)!)
        let svc = RouteService(session: MockURLProtocol.makeSession())
        do {
            _ = try await svc.route(forCallsign: "X")
            XCTFail("Expected throw")
        } catch ADSBError.decoding {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testRoute_buildsGetRequestWithCallsignInPath() async throws {
        final class CaptureBox: @unchecked Sendable { var url: URL? }
        let capture = CaptureBox()
        MockURLProtocol.requestHandler = { request in
            capture.url = request.url
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            let body = "{\"response\":{\"flightroute\":{\"callsign\":\"DLH441\"}}}"
            return (response, body.data(using: .utf8)!)
        }
        let svc = RouteService(session: MockURLProtocol.makeSession())
        _ = try await svc.route(forCallsign: "DLH441")

        let url = try XCTUnwrap(capture.url)
        XCTAssertEqual(url.host, "api.adsbdb.com")
        XCTAssertEqual(url.path, "/v0/callsign/DLH441")
    }
}
