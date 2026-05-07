import Foundation

nonisolated struct ADSBResponse: Decodable {
    let ac: [Aircraft]
}

nonisolated struct Aircraft: Equatable {
    let hex: String
    let callsign: String?
    let registration: String?
    let typeCode: String?
    let altitudeFt: Int?
    let groundSpeedKt: Double?
    let trackDeg: Double?
    let lat: Double
    let lon: Double
    var distanceKm: Double = 0  // populated by ADSBService after decoding
    var airline: String? = nil
    var originIATA: String? = nil
    var destinationIATA: String? = nil

    /// Best display identifier per spec §5.8: callsign → registration → uppercased hex.
    var identifier: String {
        if let cs = callsign, !cs.isEmpty { return cs }
        if let r = registration, !r.isEmpty { return r }
        return hex.uppercased()
    }
}

nonisolated extension Aircraft: Decodable {
    private enum CodingKeys: String, CodingKey {
        case hex, flight, r, t, alt_baro, gs, track, lat, lon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hex = try c.decode(String.self, forKey: .hex)

        let rawFlight = try c.decodeIfPresent(String.self, forKey: .flight)
        let trimmed = rawFlight?.trimmingCharacters(in: .whitespaces)
        self.callsign = (trimmed?.isEmpty ?? true) ? nil : trimmed

        self.registration = try c.decodeIfPresent(String.self, forKey: .r)
        self.typeCode = try c.decodeIfPresent(String.self, forKey: .t)

        // alt_baro can be Int or the literal string "ground".
        if let altInt = try? c.decodeIfPresent(Int.self, forKey: .alt_baro) {
            self.altitudeFt = altInt
        } else if let altStr = try? c.decodeIfPresent(String.self, forKey: .alt_baro),
                  altStr.lowercased() == "ground" {
            self.altitudeFt = 0
        } else {
            self.altitudeFt = nil
        }

        self.groundSpeedKt = try c.decodeIfPresent(Double.self, forKey: .gs)
        self.trackDeg = try c.decodeIfPresent(Double.self, forKey: .track)
        self.lat = try c.decode(Double.self, forKey: .lat)
        self.lon = try c.decode(Double.self, forKey: .lon)
        self.distanceKm = 0
    }
}

nonisolated extension Aircraft {
    init(hex: String, callsign: String?, registration: String?, typeCode: String?,
         altitudeFt: Int?, groundSpeedKt: Double?, trackDeg: Double?,
         lat: Double, lon: Double,
         airline: String? = nil, originIATA: String? = nil, destinationIATA: String? = nil) {
        self.hex = hex
        self.callsign = callsign
        self.registration = registration
        self.typeCode = typeCode
        self.altitudeFt = altitudeFt
        self.groundSpeedKt = groundSpeedKt
        self.trackDeg = trackDeg
        self.lat = lat
        self.lon = lon
        self.distanceKm = 0
        self.airline = airline
        self.originIATA = originIATA
        self.destinationIATA = destinationIATA
    }
}

nonisolated struct RouteInfo: Equatable, Sendable {
    let airline: String?
    let originIATA: String?
    let destinationIATA: String?
}

nonisolated extension Aircraft {
    /// Human-readable representation of a single field for display, or nil if no value.
    func formattedValue(for field: DisplayField) -> String? {
        switch field {
        case .airline:
            return airline
        case .route:
            return formattedRoute
        case .aircraftType:
            return typeCode
        case .altitude:
            return altitudeFt.map { formatThousands(Int((Double($0) * 0.3048).rounded())) + " m" }
        case .speed:
            return groundSpeedKt.map { formatThousands(Int(($0 * 1.852).rounded())) + " km/h" }
        case .distance:
            return formattedDistance
        case .heading:
            return formattedHeading
        }
    }

    private var formattedRoute: String? {
        switch (originIATA, destinationIATA) {
        case (nil, nil): return nil
        case (let o?, let d?): return "\(o) → \(d)"
        case (let o?, nil): return "\(o) →"
        case (nil, let d?): return "→ \(d)"
        }
    }

    private var formattedDistance: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 1
        let s = f.string(from: NSNumber(value: distanceKm)) ?? "\(distanceKm)"
        return "\(s) km"
    }

    private var formattedHeading: String? {
        guard let track = trackDeg else { return nil }
        let dirs = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        let idx = ((Int(track / 45.0 + 0.5)) % 8 + 8) % 8
        return dirs[idx]
    }

    private func formatThousands(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
