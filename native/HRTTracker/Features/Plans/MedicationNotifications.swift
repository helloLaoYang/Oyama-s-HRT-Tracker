import Foundation
import HRTEngine
import OSLog
import UserNotifications

@MainActor
enum MedicationNotifications {
    nonisolated private static let prefix = "dose."
    private static let requestLimit = 48
    private static let calendarLookaheadDays = 14
    private static let isDemoLaunch = ProcessInfo.processInfo.arguments.contains("--demo")
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HRTTracker", category: "MedicationNotifications"
    )

    private static var refreshTask: Task<Void, Never>?

    /// The user setting is the only entry point that can show the system permission prompt.
    static func authorize() async -> Bool {
        guard !isDemoLaunch else { return false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus != .notDetermined {
            return isAllowed(settings.authorizationStatus)
        }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func refresh(for store: TrackerStore) async {
        guard !isDemoLaunch, !store.isDemo, !Task.isCancelled else { return }
        // Serialize changes to the shared pending queue. A refresh that was
        // superseded cannot add requests after its replacement has reconciled.
        let previous = refreshTask
        previous?.cancel()
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await reconcile(store)
        }
        refreshTask = task
        await task.value
    }

    private static func isAllowed(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    private static func reconcile(_ store: TrackerStore) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests()
        guard !Task.isCancelled else { return }

        let owned = pending.filter { $0.identifier.hasPrefix(prefix) }
        guard store.remindersEnabled, isAllowed(settings.authorizationStatus) else {
            if !owned.isEmpty { center.removePendingNotificationRequests(withIdentifiers: owned.map(\.identifier)) }
            return
        }

        let now = Date()
        let calendar = store.calendar
        let otherCount = pending.count - owned.count
        let capacity = max(0, min(requestLimit, 64 - otherCount))
        let candidates = reminders(for: store, now: now)
        let desired = Array(candidates.prefix(capacity))
        let desiredIDs = Set(desired.map(\.identifier))
        let obsolete = owned.filter { !desiredIDs.contains($0.identifier) }.map(\.identifier)
        if !obsolete.isEmpty { center.removePendingNotificationRequests(withIdentifiers: obsolete) }

        let oldByID = Dictionary(owned.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        for reminder in desired {
            guard !Task.isCancelled else { return }
            guard reminder.date > Date() else { continue }
            let request = makeRequest(reminder, calendar: calendar)
            if let old = oldByID[reminder.identifier],
               old.content.title == request.content.title,
               old.content.body == request.content.body,
               (old.trigger as? UNCalendarNotificationTrigger)?.dateComponents
                   == (request.trigger as? UNCalendarNotificationTrigger)?.dateComponents {
                continue
            }
            do {
                try await center.add(request)
            } catch {
                logger.warning("Could not add a medication notification to the pending queue.")
            }
        }
    }

    private struct Reminder {
        let plan: MedicationPlan
        let date: Date

        var identifier: String {
            let epochMinute = Int(floor(date.timeIntervalSince1970 / 60))
            return "\(MedicationNotifications.prefix)\(plan.id).\(epochMinute)"
        }
    }

    private static func reminders(for store: TrackerStore, now: Date) -> [Reminder] {
        let calendar = store.calendar
        guard let end = calendar.date(byAdding: .day, value: calendarLookaheadDays, to: now) else { return [] }
        let today = calendar.startOfDay(for: now)
        let lastDay = calendar.startOfDay(for: end)
        let logged = store.doses.compactMap { dose -> (dose: DoseEvent, time: Date)? in
            let seconds = dose.timeH * 3_600
            guard seconds.isFinite, seconds <= now.timeIntervalSince1970 else { return nil }
            return (dose, Date(timeIntervalSince1970: seconds))
        }

        return store.plans.flatMap { plan -> [Reminder] in
            guard plan.remindersEnabled, plan.everyDays.isFinite, (1...180).contains(plan.everyDays) else { return [] }
            let times = plan.reminderMinutes.filter { (0..<1_440).contains($0) }.sorted()
            guard let firstTime = times.first else { return [] }
            let taken = logged.filter { $0.dose.route == plan.route && $0.dose.ester == plan.ester }.map(\.time)
            if plan.everyDays == 1 {
                let completedToday = store.completedDailyPlanSlots(plan, at: now)
                let minutes = Array(times.prefix(plan.dosesPerDay))
                var reminders: [Reminder] = []
                var day = today
                while day <= lastDay {
                    let remaining = day == today
                        ? minutes.enumerated().filter { !completedToday.contains($0.offset) }.map(\.element)
                        : minutes
                    for minute in Set(remaining).sorted() {
                        if let time = date(on: day, minute: minute, calendar: calendar), time > now, time <= end {
                            reminders.append(Reminder(plan: plan, date: time))
                        }
                    }
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                }
                return reminders
            }

            return repeatingReminders(
                for: plan, lastTaken: taken.max(), minute: firstTime,
                today: today, now: now, end: end, calendar: calendar
            )
        }.sorted {
            $0.date == $1.date ? $0.identifier < $1.identifier : $0.date < $1.date
        }
    }

    private static func repeatingReminders(
        for plan: MedicationPlan, lastTaken: Date?, minute: Int,
        today: Date, now: Date, end: Date, calendar: Calendar
    ) -> [Reminder] {
        let days = plan.everyDays
        let seconds = days * 86_400
        let wholeDays = days.rounded(.down) == days ? Int(days) : nil
        let anchor = plan.anchorTimeH
            .flatMap { value -> Date? in
                let seconds = value * 3_600
                return seconds.isFinite ? Date(timeIntervalSince1970: seconds) : nil
            } ?? date(on: today, minute: minute, calendar: calendar) ?? today
        func next(after value: Date) -> Date? {
            if let wholeDays { return calendar.date(byAdding: .day, value: wholeDays, to: value) }
            return value.addingTimeInterval(seconds)
        }

        var reference = lastTaken.flatMap(next) ?? anchor
        // Advance old plans directly to this window. Keep whole-day plans on
        // calendar dates and fractional schedules on their exact hour cadence.
        if reference < today {
            if let wholeDays {
                let since = calendar.dateComponents([.day], from: calendar.startOfDay(for: reference), to: today).day ?? 0
                let advance = (since / wholeDays) * wholeDays
                reference = calendar.date(byAdding: .day, value: advance, to: reference) ?? reference
            } else {
                let cycles = floor(today.timeIntervalSince(reference) / seconds)
                reference = reference.addingTimeInterval(cycles * seconds)
            }
        }

        var reminders: [Reminder] = []
        let lastDay = calendar.startOfDay(for: end)
        while calendar.startOfDay(for: reference) <= lastDay {
            let day = calendar.startOfDay(for: reference)
            if let time = date(on: day, minute: minute, calendar: calendar), time > now, time <= end {
                reminders.append(Reminder(plan: plan, date: time))
            }
            guard let later = next(after: reference), later > reference else { break }
            reference = later
        }
        return reminders
    }

    private static func date(on day: Date, minute: Int, calendar: Calendar) -> Date? {
        guard let time = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day),
              calendar.isDate(time, inSameDayAs: day) else { return nil }
        return time
    }

    private static func makeRequest(_ reminder: Reminder, calendar: Calendar) -> UNNotificationRequest {
        let plan = reminder.plan
        let content = UNMutableNotificationContent()
        content.title = label("Medication reminders")
        content.body = trackerDrugName(plan.ester) + " · " + planDoseCaption(plan)
        content.threadIdentifier = plan.id
        content.userInfo = ["planItemID": plan.id, "scheduledAtH": reminder.date.timeIntervalSince1970 / 3_600]
        content.sound = .default
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.date)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger)
    }
}
