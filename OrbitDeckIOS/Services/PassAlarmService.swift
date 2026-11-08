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
        // Pass alarms take priority: free the activation reminders' slots first so the
        // alarm can't be dropped by a full 64-request queue, then re-budget the reminders
        // around it (whether or not the add succeeded).
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(activationPrefix) })
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        } catch {
            await rescheduleActivationReminders(requestPermission: false)
            throw error
        }
        await rescheduleActivationReminders(requestPermission: false)
#else
        throw PassAlarmError.denied
#endif
    }

    /// Whether a reminder is already pending for this exact pass.
    static func isScheduled(pass: PredictedPass, satellite: SatelliteRecord) async -> Bool {
#if canImport(UserNotifications)
        let id = identifier(satellite: satellite, pass: pass)
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.contains { $0.identifier == id }
#else
        return false
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

    // MARK: Activation reminders

    /// Lead times (minutes before the advertised start) for activation reminders.
    static let activationLeadMinutes = [60, 30, 10]
    /// iOS keeps at most 64 pending local notifications per app.
    static let pendingLimit = 64
    /// Slots activation reminders never take, so a new pass alarm always has room.
    static let passAlarmReserve = 8
    private static let activationPrefix = "orbitdeck.activation."

    /// Rebuild every activation reminder from the saved choices
    /// (`ActivationSkedStore.remindersKey`). Pass alarms and other notifications keep
    /// their slots; activation reminders fill what remains of the 64-request budget
    /// (less `passAlarmReserve`, kept free for pass alarms),
    /// soonest first, and later ones are picked up on a later reschedule (the
    /// Activations screen and every new pass alarm call this). Returns how many
    /// reminder notifications are pending and how many didn't fit.
    @discardableResult
    static func rescheduleActivationReminders(requestPermission: Bool = true,
                                              now: Date = Date()) async -> (scheduled: Int, deferred: Int) {
        let reminders = ActivationSkedStore.loadReminders(now: now)
        ActivationSkedStore.saveReminders(reminders)   // drop expired choices
#if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(activationPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        guard !reminders.isEmpty else { return (0, 0) }
        if requestPermission {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return (0, 0) }
        } else {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            else { return (0, 0) }
        }

        struct Candidate { let id: String; let fire: Date; let lead: Int; let reminder: ActivationReminder }
        var candidates: [Candidate] = []
        for reminder in reminders {
            for lead in activationLeadMinutes {
                let fire = reminder.start.addingTimeInterval(-Double(lead) * 60)
                guard fire.timeIntervalSince(now) > 1 else { continue }
                candidates.append(Candidate(id: "\(activationPrefix)\(reminder.key).\(lead)", fire: fire,
                                            lead: lead, reminder: reminder))
            }
        }
        candidates.sort { $0.fire < $1.fire }
        let others = pending.count - stale.count
        let budget = max(0, pendingLimit - passAlarmReserve - others)
        let chosen = candidates.prefix(budget)
        for c in chosen {
            let r = c.reminder
            let content = UNMutableNotificationContent()
            let call = r.callsign.isEmpty ? "Activation" : r.callsign
            content.title = "\(call) on \(r.satellite)"
            content.body = "Starts in \(c.lead) min" + (r.grid.isEmpty ? "" : " from \(r.grid)")
                + " (\(ODFormat.utcStamp(r.start)) UTC)."
            content.sound = .default
            content.userInfo = ["activation": r.key, "start": r.start.timeIntervalSince1970]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: c.fire.timeIntervalSince(now), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: c.id, content: content, trigger: trigger))
        }
        return (chosen.count, candidates.count - chosen.count)
#else
        return (0, 0)
#endif
    }
}
