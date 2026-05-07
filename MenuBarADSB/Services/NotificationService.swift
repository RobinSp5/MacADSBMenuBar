import Foundation
import UserNotifications

nonisolated protocol Notifying: Sendable {
    func notify(aircraft: Aircraft)
    func requestAuthorizationIfNeeded() async
}

nonisolated final class NotificationService: Notifying {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func notify(aircraft: Aircraft) {
        let content = UNMutableNotificationContent()
        content.title = aircraft.identifier
        var parts: [String] = []
        if let alt = aircraft.altitudeFt {
            let metres = Int((Double(alt) * 0.3048).rounded())
            parts.append("\(metres) m")
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 1
        let dist = f.string(from: NSNumber(value: aircraft.distanceKm)) ?? "\(aircraft.distanceKm)"
        parts.append("\(dist) km")
        content.body = parts.joined(separator: " · ")
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "adsb-\(aircraft.hex)",
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }
}
