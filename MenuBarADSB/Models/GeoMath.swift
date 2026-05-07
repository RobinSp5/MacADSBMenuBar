import Foundation

nonisolated enum GeoMath {
    /// Great-circle distance in kilometres between two points on Earth.
    static func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371.0 // Earth mean radius in km
        let dLat = (lat2 - lat1).toRadians
        let dLon = (lon2 - lon1).toRadians
        let a = sin(dLat / 2) * sin(dLat / 2)
              + cos(lat1.toRadians) * cos(lat2.toRadians)
              * sin(dLon / 2) * sin(dLon / 2)
        return 2 * R * asin(min(1, sqrt(a)))
    }

    /// Convert kilometres to nautical miles. 1 NM = 1.852 km exactly.
    static func kmToNM(_ km: Double) -> Double { km / 1.852 }

    /// Nautical-mile value to send to the adsb.lol /dist/ endpoint, given a desired km radius.
    /// We `ceil` so we slightly over-fetch and then filter client-side to the exact km radius.
    static func radiusKmToFetchNM(_ radiusKm: Double) -> Int {
        Int(ceil(kmToNM(radiusKm)))
    }
}

nonisolated extension Double {
    var toRadians: Double { self * .pi / 180.0 }
}
