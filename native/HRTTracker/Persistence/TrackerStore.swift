import CryptoKit
import Foundation
import HRTEngine
import Observation
import SwiftData

@MainActor
@Observable
final class TrackerStore {
    static let schema = Schema([
        DoseRecord.self, LabRecord.self, MedicationPlanRecord.self, DoseTemplateRecord.self,
        MedicationSupplyRecord.self, TrackerProfileRecord.self
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
    private var supplyRecords: [MedicationSupplyRecord] = []

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
            persistenceError = label("Cannot open tracker data")
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

    var pkOverrides: [String: Double] { profile.pkOverrides }

    var pkParameters: PKParameters { PKParameters(overrides: pkOverrides) }

    @discardableResult
    func savePKOverrides(_ values: [String: Double]) -> Bool {
        let next = PKParameters.normalizedOverrides(values)
        guard next != pkOverrides else { return true }
        return trySave(refresh: false) {
            profile.pkOverrides = next
            profile.pkParamsUpdatedAt = stamp
            profile.updatedAt = stamp
        }
    }

    var supplyLeadDays: Int {
        get { profile.supplyLeadDays ?? 14 }
        set {
            guard (1...3650).contains(newValue), newValue != supplyLeadDays else { return }
            updateProfile { profile.supplyLeadDays = newValue }
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

    var supplies: [MedicationSupply] {
        supplyRecords.filter { $0.modeRaw == mode.rawValue }.compactMap(\.value).sorted {
            if $0.startedAt == $1.startedAt { return $0.id < $1.id }
            return $0.startedAt > $1.startedAt
        }
    }

    func plannedStock(route: Route, ester: String) -> String? {
        let matching = plans.filter { $0.route == route && $0.ester == ester }
        guard !matching.isEmpty else { return nil }
        let specs = InventorySpecifications(supplies)
        let lots = matching.compactMap { plan in plan.inventorySupplyId.flatMap { specs.byID[$0] } }
        guard lots.count == matching.count, let first = lots.first,
              lots.allSatisfy({ $0.specification == first.specification }),
              first.canSupply(route, ester) else { return nil }
        return first.id
    }

    @discardableResult
    func saveSupply(_ supply: MedicationSupply, forDoseID: String? = nil) -> Bool {
        guard supply.isValid else { return false }
        refreshClock()
        return trySave {
            if let record = supplyRecords.first(where: { $0.modeRaw == mode.rawValue && $0.uuid == supply.id }) {
                record.update(supply, updatedAt: stamp)
            } else {
                context.insert(MedicationSupplyRecord(mode: mode, value: supply, updatedAt: stamp))
            }
            if let forDoseID, let row = doseRecords.first(where: { $0.modeRaw == mode.rawValue && $0.uuid == forDoseID }),
               let dose = row.value, supply.canSupply(dose.route, dose.ester),
               supply.matchesStrength(route: dose.route, extras: dose.extras) != false, supply.startedAt / 3_600_000 <= dose.timeH {
                row.inventorySupplyId = supply.id
                row.updatedAt = stamp
            }
        }
    }

    @discardableResult
    func deleteSupply(_ id: String) -> Bool {
        guard var supply = supplies.first(where: { $0.id == id }), supply.archivedAt == nil else { return false }
        supply.archivedAt = max(supply.startedAt, (isDemo ? now : Date()).timeIntervalSince1970 * 1_000)
        return saveSupply(supply)
    }

    @discardableResult
    func saveDose(_ dose: DoseEvent) -> Bool { saveDoses([dose]) }

    @discardableResult
    func saveDoses(_ doses: [DoseEvent]) -> Bool {
        let mode = self.mode
        let at = stamp
        refreshClock()
        let incoming = Set(doses.map(\.id))
        let lots = supplies
        var assignments: [String: String] = [:]
        if !lots.isEmpty {
            let ledger = InventoryLedger(supplies: lots, events: self.doses.filter { !incoming.contains($0.id) } + doses, nowH: nowH)
            for use in ledger.uses where incoming.contains(use.id) {
                assignments[use.id] = use.selected?.id
            }
        }
        return trySave {
            var byID = Dictionary(doseRecords.filter { $0.modeRaw == mode.rawValue }.map { ($0.uuid, $0) },
                                  uniquingKeysWith: { first, _ in first })
            for var dose in doses {
                if dose.inventorySupplyId == nil { dose.inventorySupplyId = assignments[dose.id] }
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
        var plan = plan
        if plan.inventorySupplyId == nil { plan.inventorySupplyId = InventorySpecifications(supplies).selected(plan)?.id }
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
        let matching = matchingPlanDoses(plan, through: now)
        let done = planOccurrences(plan, on: today, matching: matching).filter(\.completed).count
        if done >= plan.dosesPerDay { return .taken }
        if let next = nextPlanDay(plan, matching: matching), next > today { return .rest(next: next) }
        return .due(done: done, total: plan.dosesPerDay)
    }

    func isTaken(_ plan: MedicationPlan) -> Bool { planStatus(plan) == .taken }

    func nextScheduledTime(_ plan: MedicationPlan) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch planStatus(plan) {
        case .due:
            return planOccurrences(plan, on: today, matching: matchingPlanDoses(plan, through: now))
                .first(where: { !$0.completed }).map { max(now, $0.scheduledAt) }
        case let .rest(next):
            return scheduledTime(on: next, minute: plan.reminderMinute)
        case .taken:
            let nextDay: Date?
            if plan.everyDays <= 1 {
                nextDay = calendar.date(byAdding: .day, value: 1, to: today)
            } else {
                nextDay = nextPlanDay(plan, matching: matchingPlanDoses(plan, through: now))
            }
            return nextDay.flatMap { scheduledTime(on: $0, minute: plan.reminderMinute) }
        }
    }

    @discardableResult
    func complete(_ plan: MedicationPlan) -> DoseEvent? {
        guard let current = plans.first(where: { $0.id == plan.id }), current == plan else { return nil }
        let recordedAt = isDemo ? now : Date()
        let day = calendar.startOfDay(for: recordedAt)
        let matching = matchingPlanDoses(plan, through: recordedAt)
        guard let occurrence = planOccurrences(plan, on: day, matching: matching).first(where: { !$0.completed }) else {
            return nil
        }
        let event = plannedDose(plan, occurrenceID: occurrence.id, recordedAt: recordedAt)
        if !isDemo { now = recordedAt }
        return saveDose(event) ? event : nil
    }

    func watchPlanOccurrences(at date: Date) -> [WatchDoseOccurrence] {
        let day = calendar.startOfDay(for: date)
        let versions = watchPlanVersions
        return plans.flatMap { plan -> [WatchDoseOccurrence] in
            let matching = matchingPlanDoses(plan, through: date)
            let slots = planOccurrences(plan, on: day, matching: matching)
            if let next = nextPlanDay(plan, matching: matching), next > day, !slots.contains(where: \.completed) {
                return []
            }
            let title = plan.route == .patchApply && plan.ester == "E2"
                ? label("Replace estradiol patch") : trackerDrugName(plan.ester)
            let action: WatchDoseAction
            switch plan.route {
            case .patchApply: action = .replacePatch
            case .oral, .sublingual: action = .take
            case .injection, .sc: action = .inject
            default: action = .record
            }
            return slots.map {
                WatchDoseOccurrence(id: $0.id, version: versions[plan.id] ?? "initial", title: title, detail: planDoseCaption(plan),
                                    scheduledAt: $0.scheduledAt, action: action, completed: $0.completed)
            }
        }.sorted { ($0.scheduledAt, $0.id) < ($1.scheduledAt, $1.id) }
    }

    func recordWatchDose(_ command: WatchDoseCommand) -> WatchDoseResult {
        let receivedAt = isDemo ? now : Date()
        guard command.recordedAt.timeIntervalSince1970 >= 0, command.recordedAt <= receivedAt else { return .stale }
        let day = calendar.startOfDay(for: command.recordedAt)
        let versions = watchPlanVersions
        for plan in plans where versions[plan.id] == command.version {
            let matching = matchingPlanDoses(plan, through: receivedAt)
            let slots = planOccurrences(plan, on: day, matching: matching)
            guard let occurrence = slots.first(where: { $0.id == command.occurrenceID }) else { continue }
            if occurrence.completed { return .alreadyRecorded }
            let previous = matching.filter { $0.timeH < day.trackerHours }
            if let next = nextPlanDay(plan, matching: previous), next > day { return .stale }
            let event = plannedDose(plan, occurrenceID: occurrence.id, recordedAt: command.recordedAt)
            if !isDemo { now = receivedAt }
            return saveDose(event) ? .recorded : .retry
        }
        return .stale
    }

    func completedDailyPlanSlots(_ plan: MedicationPlan, at date: Date) -> Set<Int> {
        let day = calendar.startOfDay(for: date)
        let slots = planOccurrences(plan, on: day, matching: matchingPlanDoses(plan, through: date))
        return Set(slots.compactMap { $0.completed ? $0.index : nil })
    }

    private struct PlanOccurrence {
        let id: String
        let index: Int
        let scheduledAt: Date
        let completed: Bool
    }

    private static let plannedDosePrefix = "hrt-plan-"

    private func planOccurrences(_ plan: MedicationPlan, on day: Date, matching: [DoseEvent]) -> [PlanOccurrence] {
        let calendar = calendar
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = dayComponents.year, let month = dayComponents.month, let dayNumber = dayComponents.day,
              let end = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
        let dayKey = "\(year)-\(month)-\(dayNumber)"
        let rawMode = mode.rawValue
        let ids = Set(doseRecords.lazy.filter { $0.modeRaw == rawMode }.map(\.uuid))
        let minutes = plan.reminderMinutes.sorted()
        var unassigned = matching.count {
            !$0.id.hasPrefix(Self.plannedDosePrefix) && $0.timeH >= day.trackerHours && $0.timeH < end.trackerHours
        }
        return (0..<plan.dosesPerDay).compactMap { slot in
            let minute = slot < minutes.count ? minutes[slot] : plan.reminderMinute
            guard let scheduled = scheduledTime(on: day, minute: minute) else { return nil }
            // Both devices name the same plan/day/slot without adding fields to existing dose records.
            let material = "\(rawMode):\(dayKey):\(slot):\(plan.id)"
            let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
            let id = Self.plannedDosePrefix + digest
            let recorded = ids.contains(id)
            let completed = recorded || unassigned > 0
            if !recorded && completed { unassigned -= 1 }
            return PlanOccurrence(id: id, index: slot, scheduledAt: scheduled, completed: completed)
        }
    }

    var watchPlanVersions: [String: String] {
        let rawMode = mode.rawValue
        return Dictionary(planRecords.lazy.filter { $0.modeRaw == rawMode }.map { row in
            (row.uuid, row.updatedAt.map { String($0.bitPattern, radix: 16) } ?? "initial")
        }, uniquingKeysWith: { first, _ in first })
    }

    private func matchingPlanDoses(_ plan: MedicationPlan, through date: Date) -> [DoseEvent] {
        let cutoff = date.trackerHours
        return doses.filter { $0.route == plan.route && $0.ester == plan.ester && $0.timeH <= cutoff }
    }

    private func nextPlanDay(_ plan: MedicationPlan, matching: [DoseEvent]) -> Date? {
        guard plan.everyDays > 1 else { return nil }
        let calendar = calendar
        if let lastDose = matching.first {
            let time = Date(trackerHours: lastDose.timeH)
            let next = Int(exactly: plan.everyDays).flatMap { calendar.date(byAdding: .day, value: $0, to: time) }
                ?? time.addingTimeInterval(plan.everyDays * 86_400)
            return calendar.startOfDay(for: next)
        }
        return plan.anchorTimeH.map { calendar.startOfDay(for: Date(trackerHours: $0)) }
    }

    private func plannedDose(_ plan: MedicationPlan, occurrenceID: String, recordedAt: Date) -> DoseEvent {
        DoseEvent(id: occurrenceID, route: plan.route, timeH: recordedAt.trackerHours, doseMG: plan.doseMG,
                  ester: plan.ester, extras: plan.extras, inventorySupplyId: plan.inventorySupplyId)
    }

    private func scheduledTime(on date: Date, minute: Int) -> Date? {
        let calendar = calendar
        guard (0..<1_440).contains(minute),
              let time = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: date),
              calendar.isDate(time, inSameDayAs: date) else { return nil }
        return time
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
        let supplies = try context.fetch(FetchDescriptor<MedicationSupplyRecord>())
        doseRecords = doses
        labRecords = labs
        planRecords = plans
        templateRecords = templates
        supplyRecords = supplies
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
        snapshot.pkOverrides = pkOverrides
        snapshot.pkParamsUpdatedAt = profile.pkParamsUpdatedAt
        snapshot.supplyLeadDays = supplyLeadDays
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
                    .sorted { $0.createdAt > $1.createdAt },
                supplies: supplyRecords.filter { $0.modeRaw == rawMode }.compactMap { row in
                    row.value.map { ($0, row.updatedAt) }
                }.sorted { $0.value.id < $1.value.id }
            )
        }
        return try TrackerBackup.write(snapshot, at: now)
    }

    func previewBackup(_ data: Data) throws -> BackupPreview {
        let contents = try TrackerBackup.read(data, fallbackMode: mode, currentYear: calendar.component(.year, from: now))
        var settings: [String] = []
        if let overrides = contents.pkOverrides, overrides != pkOverrides,
           shouldTake(contents.pkParamsUpdatedAt, over: profile.pkParamsUpdatedAt) {
            settings.append(label("Drug parameters"))
        }
        if (contents.calibrationMethod != nil && contents.calibrationMethod != calibrationMethod ||
            contents.calibrationHistory != nil && contents.calibrationHistory != calibrationHistory ||
            contents.ageModelEnabled != nil && contents.ageModelEnabled != ageModelEnabled),
           shouldTake(contents.modelSettingsUpdatedAt, over: profile.modelSettingsUpdatedAt) {
            settings.append(label("Model settings"))
        }
        if let leadDays = contents.supplyLeadDays, leadDays != supplyLeadDays, profile.supplyLeadDays == nil {
            settings.append(label("Inventory warning period"))
        }
        return BackupPreview(
            counts: reconcileBackup(contents, apply: false),
            ignoredCategories: contents.ignoredCategories.sorted(),
            settingsToImport: settings,
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
            let currentSupplies = Dictionary(supplyRecords.filter { $0.modeRaw == rawMode }.map { ($0.uuid, $0) },
                                             uniquingKeysWith: { first, _ in first })
            mergeBackupRecords(incoming.supplies, existing: currentSupplies, id: { $0.value.id },
                               incomingStamp: { $0.stamp }, localStamp: \.updatedAt, counts: &counts, apply: apply) { entry, previous in
                if let previous {
                    previous.update(entry.value, updatedAt: entry.stamp)
                } else {
                    context.insert(MedicationSupplyRecord(mode: mode, value: entry.value, updatedAt: entry.stamp))
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

    private func shouldTake(_ incoming: Double?, over local: Double?) -> Bool {
        guard let local else { return true }
        guard let incoming else { return false }
        return incoming > local
    }

    private func importProfile(_ backup: BackupContents) {
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
        if let overrides = backup.pkOverrides, shouldTake(backup.pkParamsUpdatedAt, over: profile.pkParamsUpdatedAt) {
            profile.pkOverrides = overrides
            profile.pkParamsUpdatedAt = backup.pkParamsUpdatedAt ?? stamp
        }
        if let leadDays = backup.supplyLeadDays, profile.supplyLeadDays == nil {
            profile.supplyLeadDays = leadDays
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
