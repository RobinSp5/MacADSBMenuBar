import Foundation

nonisolated protocol RouteFetching: Sendable {
    /// Returns RouteInfo for the callsign, or nil if no useful data is available.
    /// Throws ADSBError on transport/HTTP/decode failures.
    /// 404 is treated as "no data" and returns nil (not thrown).
    func route(forCallsign callsign: String) async throws -> RouteInfo?
}

nonisolated final class RouteService: RouteFetching {
    private let session: URLSession
    private let userAgent = "MenuBarADSB/1.0"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func route(forCallsign callsign: String) async throws -> RouteInfo? {
        let trimmed = callsign.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.adsbdb.com/v0/callsign/\(escaped)") else {
            throw ADSBError.transport
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ADSBError.transport
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299: break
            case 404: return nil
            case 429: throw ADSBError.rateLimited
            default: throw ADSBError.http(http.statusCode)
            }
        }

        let decoded: AdsbdbResponse
        do {
            decoded = try JSONDecoder().decode(AdsbdbResponse.self, from: data)
        } catch {
            throw ADSBError.decoding
        }

        return decoded.toRouteInfo()
    }
}

nonisolated private struct AdsbdbResponse: Decodable {
    let response: ResponsePayload?

    struct ResponsePayload: Decodable {
        let flightroute: FlightRoute?
    }

    struct FlightRoute: Decodable {
        let airline: Airline?
        let origin: Airport?
        let destination: Airport?
    }

    struct Airline: Decodable {
        let name: String?
    }

    struct Airport: Decodable {
        let iata_code: String?

        private enum CodingKeys: String, CodingKey { case iata_code }
    }

    func toRouteInfo() -> RouteInfo? {
        guard let route = response?.flightroute else { return nil }
        let airline = route.airline?.name
        let origin = route.origin?.iata_code
        let destination = route.destination?.iata_code
        if airline == nil && origin == nil && destination == nil { return nil }
        return RouteInfo(airline: airline, originIATA: origin, destinationIATA: destination)
    }
}
