import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

enum PassAlarmError: LocalizedError {
    case denied
    case tooLate

    var errorDescription: String? {
        switch self {
        case .denied: "Notification permission is not available for OrbitDeck."
        case .tooLate: "That pass is too close or already underway for the selected reminder time."
        }
    }
}

enum PassAlarmService {
    static func schedule(pass: PredictedPass, satellite: SatelliteRecord, observer: ObserverSite, leadMinutes: Int) async throws {
        let fire = pass.aos.addingTimeInterval(-Double(max(0, leadMinutes)) * 60.0)
        let interval = fire.timeIntervalSinceNow
        guard interval > 1 else { throw PassAlarmError.tooLate }
#if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else { throw PassAlarmError.denied }

        let content = UNMutableNotificationContent()
        content.title = "\(satellite.name) pass"
        content.body = "AOS in \(leadMinutes) min from \(observer.name); max elevation \(String(format: "%.0f", pass.maxElevation))°."
        content.sound = .default
        content.userInfo = ["norad": satellite.id, "aos": pass.aos.timeIntervalSince1970]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let id = identifier(satellite: satellite, pass: pass)
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
#else
        throw PassAlarmError.denied
#endif
    }

    static func cancel(pass: PredictedPass, satellite: SatelliteRecord) {
#if canImport(UserNotifications)
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [identifier(satellite: satellite, pass: pass)]
        )
#endif
    }

    private static func identifier(satellite: SatelliteRecord, pass: PredictedPass) -> String {
        "orbitdeck.pass.\(satellite.id).\(Int(pass.aos.timeIntervalSince1970))"
    }
}
