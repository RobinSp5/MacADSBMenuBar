import Foundation

nonisolated protocol AircraftFetching: Sendable {
    func aircraftNear(lat: Double, lon: Double, radiusKm: Double) async throws -> [Aircraft]
}

nonisolated enum ADSBError: Error, Equatable {
    case http(Int)
    case decoding
    case transport
    case rateLimited
}

nonisolated final class ADSBService: AircraftFetching {
    private let session: URLSession
    private let userAgent = "MenuBarADSB/1.0"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func aircraftNear(lat: Double, lon: Double, radiusKm: Double) async throws -> [Aircraft] {
        let nm = GeoMath.radiusKmToFetchNM(radiusKm)
        let urlString = "https://api.adsb.lol/v2/lat/\(lat)/lon/\(lon)/dist/\(nm)"
        guard let url = URL(string: urlString) else { throw ADSBError.transport }

        var request = URLRequest(url: url)
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
            case 429: throw ADSBError.rateLimited
            default: throw ADSBError.http(http.statusCode)
            }
        }

        let decoded: ADSBResponse
        do {
            decoded = try JSONDecoder().decode(ADSBResponse.self, from: data)
        } catch {
            throw ADSBError.decoding
        }

        // Compute distance, filter to exact radius, sort ascending.
        let withDistance = decoded.ac.map { aircraft -> Aircraft in
            var ac = aircraft
            ac.distanceKm = GeoMath.haversineKm(
                lat1: lat, lon1: lon,
                lat2: aircraft.lat, lon2: aircraft.lon
            )
            return ac
        }
        let filtered = withDistance.filter { $0.distanceKm <= radiusKm }
        return filtered.sorted { $0.distanceKm < $1.distanceKm }
    }
}
