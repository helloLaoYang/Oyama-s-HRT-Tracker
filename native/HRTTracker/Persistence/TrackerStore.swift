import Foundation
import HRTEngine
import Observation
import SwiftData

@MainActor
@Observable
final class TrackerStore {
    static let schema = Schema([
        DoseRecord.self, LabRecord.self, MedicationPlanRecord.self, DoseTemplateRecord.self, TrackerProfileRecord.self
    ])

    @ObservationIgnored private let context: ModelContext
    let isDemo: Bool
    private(set) var now: Date
    private(set) var persistenceError: String?
    private var profile = TrackerProfileRecord()
    private var doseRecords: [DoseRecord] = []
    private var labRecords: [LabRecord] = []
    private var planRecords: [MedicationPlanRecord] = []
    private var templateRecords: [DoseTemplateRecord] = []

    init(context: ModelContext, demo: Bool = false) {
        self.context = context
        isDemo = demo
        now = demo ? Self.demoDate : Date()
        context.autosaveEnabled = false
        do {
            try reload()
            let savedProfiles = try context.fetch(FetchDescriptor<TrackerProfileRecord>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            ))
            if let savedProfile = savedProfiles.first {
                profile = savedProfile
            } else {
                context.insert(profile)
                if isDemo { seedDemo() }
                try context.save()
                try reload()
            }
        } catch {
            context.rollback()
            persistenceError = "Could not open the local HRT Tracker store."
        }
    }

    var mode: HRTMode {
        get { HRTMode(rawValue: profile.modeRaw) ?? .transfem }
        set { updateProfile { profile.modeRaw = newValue.rawValue } }
    }

    var weight: Double {
        get { profile.weight }
        set {
            guard newValue.isFinite, (20...400).contains(newValue), newValue != profile.weight else { return }
            updateProfile {
                profile.weight = newValue
                profile.weightUpdatedAt = stamp
            }
        }
    }

    var birthYear: Int? {
        get { profile.birthYear }
        set {
            if let newValue, !(1900...calendar.component(.year, from: now)).contains(newValue) { return }
            guard newValue != profile.birthYear else { return }
            updateProfile {
                profile.birthYear = newValue
                profile.birthYearUpdatedAt = stamp
            }
        }
    }

    var ageModelEnabled: Bool {
        get { profile.ageModelEnabled }
        set {
            updateProfile {
                profile.ageModelEnabled = newValue
                profile.modelSettingsUpdatedAt = stamp
            }
        }
    }

    var showPrediction: Bool {
        get { profile.showPrediction }
        set { updateProfile { profile.showPrediction = newValue } }
    }

    var appearance: AppAppearance {
        get { AppAppearance(rawValue: profile.appearanceRaw) ?? .system }
        set { updateProfile { profile.appearanceRaw = newValue.rawValue } }
    }

    var calibrationMethod: CalibrationMethod {
        get { CalibrationMethod(rawValue: profile.calibrationMethodRaw) ?? .mipd }
        set {
            updateProfile {
                profile.calibrationMethodRaw = newValue.rawValue
                profile.modelSettingsUpdatedAt = stamp
            }
        }
    }

    var calibrationHistory: CalibrationHistoryMode {
        get { CalibrationHistoryMode(rawValue: profile.calibrationHistoryRaw) ?? .retrospective }
        set {
            updateProfile {
                profile.calibrationHistoryRaw = newValue.rawValue
                profile.modelSettingsUpdatedAt = stamp
            }
        }
    }

    var remindersEnabled: Bool {
        get { profile.remindersEnabled }
        set { updateProfile { profile.remindersEnabled = newValue } }
    }

    var snoozeMinutes: Int {
        get { profile.snoozeMinutes }
        set {
            guard [10, 15, 30, 60].contains(newValue) else { return }
            updateProfile { profile.snoozeMinutes = newValue }
        }
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = isDemo
            ? (TimeZone(identifier: "Asia/Shanghai") ?? .current)
            : .autoupdatingCurrent
        return calendar
    }

    var nowH: Double { now.timeIntervalSince1970 / 3_600 }

    func refreshClock() {
        if !isDemo { now = Date() }
    }

    var doses: [DoseEvent] {
        doseRecords.filter { $0.modeRaw == mode.rawValue }.compactMap(\.value).sorted { $0.timeH > $1.timeH }
    }

    var labs: [LabResult] {
        labRecords.filter { $0.modeRaw == mode.rawValue }.map(\.value).sorted { $0.timeH > $1.timeH }
    }

    var plans: [MedicationPlan] {
        planRecords.filter { $0.modeRaw == mode.rawValue }.sorted { $0.ordinal < $1.ordinal }.compactMap(\.value)
    }

    var templates: [DoseTemplate] {
        templateRecords.filter { $0.modeRaw == mode.rawValue }.compactMap(\.value).sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func saveDose(_ dose: DoseEvent) -> Bool { saveDoses([dose]) }

    @discardableResult
    func saveDoses(_ doses: [DoseEvent]) -> Bool {
        let mode = self.mode
        let at = stamp
        return trySave {
            var byID = Dictionary(doseRecords.filter { $0.modeRaw == mode.rawValue }.map { ($0.uuid, $0) },
                                  uniquingKeysWith: { first, _ in first })
            for dose in doses {
                if let existing = byID[dose.id] {
                    existing.update(dose, updatedAt: at)
                } else {
                    let record = DoseRecord(mode: mode, value: dose, updatedAt: at)
                    byID[dose.id] = record
                    context.insert(record)
                }
            }
        }
    }

    @discardableResult
    func deleteDose(_ id: String) -> Bool { deleteDoses([id]) }

    @discardableResult
    func deleteDoses(_ ids: [String]) -> Bool {
        let ids = Set(ids)
        return trySave {
            doseRecords.filter { $0.modeRaw == mode.rawValue && ids.contains($0.uuid) }.forEach { context.delete($0) }
        }
    }

    @discardableResult
    func saveLab(_ lab: LabResult) -> Bool { saveLabs([lab]) }

    @discardableResult
    func saveLabs(_ labs: [LabResult]) -> Bool {
        let mode = self.mode
        let at = stamp
        return trySave {
            var byID = Dictionary(labRecords.filter { $0.modeRaw == mode.rawValue }.map { ($0.uuid, $0) },
                                  uniquingKeysWith: { first, _ in first })
            for lab in labs {
                if let existing = byID[lab.id] {
                    existing.update(lab, updatedAt: at)
                } else {
                    let record = LabRecord(mode: mode, value: lab, updatedAt: at)
                    byID[lab.id] = record
                    context.insert(record)
                }
            }
        }
    }

    @discardableResult
    func deleteLab(_ id: String) -> Bool { deleteLabs([id]) }

    @discardableResult
    func deleteLabs(_ ids: [String]) -> Bool {
        let ids = Set(ids)
        return trySave {
            labRecords.filter { $0.modeRaw == mode.rawValue && ids.contains($0.uuid) }.forEach { context.delete($0) }
        }
    }

    @discardableResult
    func clearLabs() -> Bool { deleteLabs(labs.map(\.id)) }

    @discardableResult
    func savePlan(_ plan: MedicationPlan) -> Bool {
        guard plan.everyDays.isFinite, (1...180).contains(plan.everyDays), (1...8).contains(plan.timesPerDay),
              plan.reminderMinutes.allSatisfy({ (0..<1_440).contains($0) }) else { return false }
        return trySave {
            let records = planRecords.filter { $0.modeRaw == mode.rawValue }
            if let existing = records.first(where: { $0.uuid == plan.id }) {
                existing.update(plan, updatedAt: stamp)
            } else {
                let ordinal = (records.map(\.ordinal).max() ?? -1) + 1
                context.insert(MedicationPlanRecord(mode: mode, value: plan, ordinal: ordinal, updatedAt: stamp))
            }
        }
    }

    @discardableResult
    func deletePlan(_ id: String) -> Bool {
        trySave {
            planRecords.filter { $0.modeRaw == mode.rawValue && $0.uuid == id }.forEach { context.delete($0) }
        }
    }

    @discardableResult
    func saveTemplate(_ template: DoseTemplate) -> Bool {
        trySave {
            if let existing = templateRecords.first(where: { $0.modeRaw == mode.rawValue && $0.uuid == template.id }) {
                existing.update(template, updatedAt: stamp)
            } else {
                context.insert(DoseTemplateRecord(mode: mode, value: template, updatedAt: stamp))
            }
        }
    }

    @discardableResult
    func deleteTemplate(_ id: String) -> Bool {
        trySave {
            templateRecords.filter { $0.modeRaw == mode.rawValue && $0.uuid == id }.forEach { context.delete($0) }
        }
    }

    func planStatus(_ plan: MedicationPlan) -> MedicationPlanStatus {
        let today = calendar.startOfDay(for: now)
        let matching = matchingDoses(for: plan)
        let done = matching.prefix { $0 >= today }.count
        if done >= plan.dosesPerDay { return .taken }
        if plan.everyDays > 1 {
            let next = matching.first.map { calendar.startOfDay(for: $0.addingTimeInterval(plan.everyDays * 86_400)) }
                ?? plan.anchorTimeH.map { calendar.startOfDay(for: Date(timeIntervalSince1970: $0 * 3_600)) }
            if let next, next > today { return .rest(next: next) }
        }
        return .due(done: done, total: plan.dosesPerDay)
    }

    func isTaken(_ plan: MedicationPlan) -> Bool { planStatus(plan) == .taken }

    func nextScheduledTime(_ plan: MedicationPlan) -> Date? {
        let today = calendar.startOfDay(for: now)
        let minutes = plan.reminderMinutes.sorted()
        switch planStatus(plan) {
        case let .due(done, _):
            let minute = minutes.dropFirst(done).first ?? plan.reminderMinute
            return scheduledTime(on: today, minute: minute).map { max(now, $0) }
        case let .rest(next):
            return scheduledTime(on: next, minute: plan.reminderMinute)
        case .taken:
            let nextDay: Date?
            if plan.everyDays <= 1 {
                nextDay = calendar.date(byAdding: .day, value: 1, to: today)
            } else {
                nextDay = matchingDoses(for: plan).first.map {
                    calendar.startOfDay(for: $0.addingTimeInterval(plan.everyDays * 86_400))
                }
            }
            return nextDay.flatMap { scheduledTime(on: $0, minute: plan.reminderMinute) }
        }
    }

    @discardableResult
    func complete(_ plan: MedicationPlan) -> DoseEvent? {
        guard !isTaken(plan) else { return nil }
        let event = DoseEvent(route: plan.route, timeH: nowH, doseMG: plan.doseMG, ester: plan.ester, extras: plan.extras)
        return saveDose(event) ? event : nil
    }

    private func matchingDoses(for plan: MedicationPlan) -> [Date] {
        doses.filter { $0.route == plan.route && $0.ester == plan.ester && $0.timeH <= nowH }
            .map { Date(timeIntervalSince1970: $0.timeH * 3_600) }
    }

    private func scheduledTime(on date: Date, minute: Int) -> Date? {
        guard (0..<1_440).contains(minute) else { return nil }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: date)
    }

    private var stamp: Double { (isDemo ? now : Date()).timeIntervalSince1970 * 1_000 }

    private func updateProfile(_ change: () -> Void) {
        _ = trySave(refresh: false) {
            change()
            profile.updatedAt = stamp
        }
    }

    private func reload() throws {
        let doses = try context.fetch(FetchDescriptor<DoseRecord>())
        let labs = try context.fetch(FetchDescriptor<LabRecord>())
        let plans = try context.fetch(FetchDescriptor<MedicationPlanRecord>())
        let templates = try context.fetch(FetchDescriptor<DoseTemplateRecord>())
        doseRecords = doses
        labRecords = labs
        planRecords = plans
        templateRecords = templates
    }

    private func trySave(refresh: Bool = true, _ change: () -> Void) -> Bool {
        do {
            try persist(refresh: refresh, change)
            return true
        } catch {
            return false
        }
    }

    private func persist(refresh: Bool = true, _ change: () -> Void) throws {
        change()
        do {
            try context.save()
        } catch {
            context.rollback()
            persistenceError = "Could not save the change."
            throw error
        }
        if refresh {
            do {
                try reload()
            } catch {
                persistenceError = "Changes were saved. Reopen the app to refresh the records."
                return
            }
        }
        persistenceError = nil
    }

    func exportBackup() throws -> Data {
        var snapshot = BackupContents()
        snapshot.mode = mode
        snapshot.weight = weight
        snapshot.birthYear = birthYear
        snapshot.calibrationMethod = calibrationMethod
        snapshot.calibrationHistory = calibrationHistory
        snapshot.ageModelEnabled = ageModelEnabled
        snapshot.weightUpdatedAt = profile.weightUpdatedAt
        snapshot.birthYearUpdatedAt = profile.birthYearUpdatedAt
        snapshot.modelSettingsUpdatedAt = profile.modelSettingsUpdatedAt
        snapshot.showPrediction = showPrediction
        snapshot.appearance = appearance
        snapshot.remindersEnabled = remindersEnabled
        snapshot.snoozeMinutes = snoozeMinutes

        for mode in HRTMode.allCases {
            let rawMode = mode.rawValue
            snapshot.modes[mode] = BackupContents.ModeRecords(
                doses: doseRecords.filter { $0.modeRaw == rawMode }.compactMap(\.value).sorted { $0.timeH > $1.timeH },
                labs: labRecords.filter { $0.modeRaw == rawMode }.map(\.value).sorted { $0.timeH > $1.timeH },
                plans: planRecords.filter { $0.modeRaw == rawMode }.sorted { $0.ordinal < $1.ordinal }.compactMap { row in
                    row.value.map { ($0, row.updatedAt) }
                },
                templates: templateRecords.filter { $0.modeRaw == rawMode }.compactMap(\.value)
                    .sorted { $0.createdAt > $1.createdAt }
            )
        }
        return try TrackerBackup.write(snapshot, at: now)
    }

    func previewBackup(_ data: Data) throws -> BackupPreview {
        let contents = try TrackerBackup.read(data, fallbackMode: mode, currentYear: calendar.component(.year, from: now))
        return BackupPreview(
            counts: reconcileBackup(contents, apply: false),
            ignoredCategories: contents.ignoredCategories.sorted(),
            contents: contents
        )
    }

    @discardableResult
    func importBackup(_ preview: BackupPreview) throws -> BackupCounts {
        var counts = BackupCounts()
        try persist {
            counts = reconcileBackup(preview.contents, apply: true)
            importProfile(preview.contents)
        }
        return counts
    }

    private func reconcileBackup(_ backup: BackupContents, apply: Bool) -> BackupCounts {
        var counts = BackupCounts(invalid: backup.invalid)
        for mode in HRTMode.allCases {
            guard let incoming = backup.modes[mode] else { continue }
            let rawMode = mode.rawValue
            let currentDoses = Dictionary(doseRecords.filter { $0.modeRaw == rawMode }.map { ($0.uuid, $0) },
                                          uniquingKeysWith: { first, _ in first })
            mergeBackupRecords(incoming.doses, existing: currentDoses, id: \.id, incomingStamp: \.updatedAt,
                               localStamp: \.updatedAt, counts: &counts, apply: apply) { dose, previous in
                if let previous {
                    previous.update(dose, updatedAt: dose.updatedAt)
                } else {
                    context.insert(DoseRecord(mode: mode, value: dose, updatedAt: dose.updatedAt))
                }
            }
            let currentLabs = Dictionary(labRecords.filter { $0.modeRaw == rawMode }.map { ($0.uuid, $0) },
                                         uniquingKeysWith: { first, _ in first })
            mergeBackupRecords(incoming.labs, existing: currentLabs, id: \.id, incomingStamp: \.updatedAt,
                               localStamp: \.updatedAt, counts: &counts, apply: apply) { lab, previous in
                if let previous {
                    previous.update(lab, updatedAt: lab.updatedAt)
                } else {
                    context.insert(LabRecord(mode: mode, value: lab, updatedAt: lab.updatedAt))
                }
            }
            let localPlans = planRecords.filter { $0.modeRaw == rawMode }
            let currentPlans = Dictionary(localPlans.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
            var ordinal = (localPlans.map(\.ordinal).max() ?? -1) + 1
            mergeBackupRecords(incoming.plans, existing: currentPlans, id: { $0.value.id }, incomingStamp: { $0.stamp },
                               localStamp: \.updatedAt, counts: &counts, apply: apply) { entry, previous in
                if let previous {
                    previous.update(entry.value, updatedAt: entry.stamp)
                } else {
                    context.insert(MedicationPlanRecord(mode: mode, value: entry.value, ordinal: ordinal, updatedAt: entry.stamp))
                    ordinal += 1
                }
            }
            let currentTemplates = Dictionary(templateRecords.filter { $0.modeRaw == rawMode }.map { ($0.uuid, $0) },
                                              uniquingKeysWith: { first, _ in first })
            mergeBackupRecords(incoming.templates, existing: currentTemplates, id: \.id, incomingStamp: \.updatedAt,
                               localStamp: \.updatedAt, counts: &counts, apply: apply) { template, previous in
                if let previous {
                    previous.update(template, updatedAt: template.updatedAt)
                } else {
                    context.insert(DoseTemplateRecord(mode: mode, value: template, updatedAt: template.updatedAt))
                }
            }
        }
        return counts
    }

    private func mergeBackupRecords<Incoming, Existing>(
        _ incoming: [Incoming], existing: [String: Existing], id: (Incoming) -> String,
        incomingStamp: (Incoming) -> Double?, localStamp: (Existing) -> Double?,
        counts: inout BackupCounts, apply: Bool, write: (Incoming, Existing?) -> Void
    ) {
        var knownIDs: Set<String> = []
        for item in incoming {
            let key = id(item)
            guard knownIDs.insert(key).inserted else { counts.skipped += 1; continue }
            if let previous = existing[key] {
                guard let newStamp = incomingStamp(item), let previousStamp = localStamp(previous),
                      newStamp > previousStamp else { counts.skipped += 1; continue }
                if apply { write(item, previous) }
                counts.updated += 1
            } else {
                if apply { write(item, nil) }
                counts.added += 1
            }
        }
    }

    private func importProfile(_ backup: BackupContents) {
        func shouldTake(_ incoming: Double?, over local: Double?) -> Bool {
            guard let local else { return true }
            guard let incoming else { return false }
            return incoming > local
        }
        if let weight = backup.weight, shouldTake(backup.weightUpdatedAt, over: profile.weightUpdatedAt) {
            profile.weight = weight
            profile.weightUpdatedAt = backup.weightUpdatedAt ?? stamp
        }
        if backup.includesBirthYear, shouldTake(backup.birthYearUpdatedAt, over: profile.birthYearUpdatedAt) {
            profile.birthYear = backup.birthYear
            profile.birthYearUpdatedAt = backup.birthYearUpdatedAt ?? stamp
        }
        if (backup.calibrationMethod != nil || backup.calibrationHistory != nil || backup.ageModelEnabled != nil),
           shouldTake(backup.modelSettingsUpdatedAt, over: profile.modelSettingsUpdatedAt) {
            if let method = backup.calibrationMethod { profile.calibrationMethodRaw = method.rawValue }
            if let history = backup.calibrationHistory { profile.calibrationHistoryRaw = history.rawValue }
            if let enabled = backup.ageModelEnabled { profile.ageModelEnabled = enabled }
            profile.modelSettingsUpdatedAt = backup.modelSettingsUpdatedAt ?? stamp
        }
        if profile.updatedAt == 0 {
            if let mode = backup.mode { profile.modeRaw = mode.rawValue }
            if let appearance = backup.appearance { profile.appearanceRaw = appearance.rawValue }
            if let showPrediction = backup.showPrediction { profile.showPrediction = showPrediction }
            if let remindersEnabled = backup.remindersEnabled { profile.remindersEnabled = remindersEnabled }
            if let snoozeMinutes = backup.snoozeMinutes { profile.snoozeMinutes = snoozeMinutes }
        }
        profile.updatedAt = stamp
    }

    // 2026-11-24 09:41:00 in Asia/Shanghai. The demo clock is independent of the device time zone.
    private static let demoDate = Date(timeIntervalSince1970: 1_795_484_460)

    private func seedDemo() {
        let formatter = ISO8601DateFormatter()
        func hours(_ local: String) -> Double {
            formatter.date(from: local + ":00+08:00")!.timeIntervalSince1970 / 3_600
        }
        let patchExtras: [String: Double] = ["releaseRateUGPerDay": 100, "patchWearH": 48, "patchCount": 2]
        let patches = ["2026-11-18T09:06", "2026-11-20T08:57", "2026-11-22T09:02"]
        let cpa = ["2026-11-21T08:20", "2026-11-22T08:35", "2026-11-23T08:30"]
        let feminineDoses = patches.map {
            DoseEvent(route: .patchApply, timeH: hours($0), doseMG: 0, ester: "E2", extras: patchExtras)
        } + cpa.map {
            DoseEvent(route: .oral, timeH: hours($0), doseMG: 6.25, ester: "CPA")
        }
        let masculineDose = DoseEvent(route: .injection, timeH: hours("2026-11-20T09:00"), doseMG: 50, ester: "TC")
        for dose in feminineDoses { context.insert(DoseRecord(mode: .transfem, value: dose, updatedAt: nil)) }
        context.insert(DoseRecord(mode: .transmasc, value: masculineDose, updatedAt: nil))
        let feminineLabs = [
            LabResult(timeH: hours("2026-11-23T08:35"), concValue: 92, unit: "pg/ml", assay: "lcms"),
            LabResult(timeH: hours("2026-11-19T08:48"), concValue: 84, unit: "pg/ml", assay: "immuno"),
        ]
        let masculineLab = LabResult(timeH: hours("2026-11-22T08:30"), concValue: 512, unit: "ng/dl", assay: "lcms")
        for lab in feminineLabs { context.insert(LabRecord(mode: .transfem, value: lab, updatedAt: nil)) }
        context.insert(LabRecord(mode: .transmasc, value: masculineLab, updatedAt: nil))

        let patchPlan = MedicationPlan(route: .patchApply, ester: "E2", doseMG: 0, extras: patchExtras, everyDays: 2)
        let cpaPlan = MedicationPlan(route: .oral, ester: "CPA", doseMG: 6.25, reminderMinutes: [510])
        let injectionPlan = MedicationPlan(route: .injection, ester: "TC", doseMG: 50, everyDays: 7)
        context.insert(MedicationPlanRecord(mode: .transfem, value: patchPlan, ordinal: 0, updatedAt: nil))
        context.insert(MedicationPlanRecord(mode: .transfem, value: cpaPlan, ordinal: 1, updatedAt: nil))
        context.insert(MedicationPlanRecord(mode: .transmasc, value: injectionPlan, ordinal: 0, updatedAt: nil))
        profile.remindersEnabled = true
    }
}
