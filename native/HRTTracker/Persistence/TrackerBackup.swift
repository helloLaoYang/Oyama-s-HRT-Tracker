import CoreFoundation
import Foundation
import HRTEngine

struct BackupCounts: Equatable {
    var added = 0
    var updated = 0
    var skipped = 0
    var invalid = 0
}

struct BackupPreview {
    let counts: BackupCounts
    let ignoredCategories: [String]
    let contents: BackupContents

    var added: Int { counts.added }
    var updated: Int { counts.updated }
    var skipped: Int { counts.skipped }
    var invalid: Int { counts.invalid }
}

enum TrackerBackupError: LocalizedError {
    case unsupported, encrypted, tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "This file is not a supported HRT Tracker backup.")
        case .encrypted: String(localized: "Open this encrypted backup in the web app and export a JSON copy to import.")
        case .tooLarge: String(localized: "The backup exceeds the supported size.")
        }
    }
}

struct BackupContents {
    struct ModeRecords {
        var doses: [DoseEvent] = []
        var labs: [LabResult] = []
        var plans: [(value: MedicationPlan, stamp: Double?)] = []
        var templates: [DoseTemplate] = []
    }

    var modes: [HRTMode: ModeRecords] = [:]
    var mode: HRTMode?
    var weight: Double?
    var birthYear: Int?
    var includesBirthYear = false
    var calibrationMethod: CalibrationMethod?
    var calibrationHistory: CalibrationHistoryMode?
    var ageModelEnabled: Bool?
    var weightUpdatedAt: Double?
    var birthYearUpdatedAt: Double?
    var modelSettingsUpdatedAt: Double?
    var showPrediction: Bool?
    var appearance: AppAppearance?
    var remindersEnabled: Bool?
    var snoozeMinutes: Int?
    var invalid = 0
    var ignoredCategories: Set<String> = []
}

enum TrackerBackup {
    static let nativeFormat = "hrt-tracker-native-backup"

    static func read(_ data: Data, fallbackMode: HRTMode, currentYear: Int) throws -> BackupContents {
        guard data.count <= 25_000_000 else { throw TrackerBackupError.tooLarge }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TrackerBackupError.unsupported
        }
        if object["encrypted"] as? Bool == true { throw TrackerBackupError.encrypted }
        let format = object["format"] as? String
        let version = number(object["formatVersion"])
        let native = format == nativeFormat && version == 1
        let complete = format == "oyama-hrt-complete-backup" && version == 1
        let meta = object["meta"] as? [String: Any]
        let web = format == nil && (meta?["version"] == nil ? object["events"] is [Any] : number(meta?["version"]) == 2)
        guard native || complete || web else { throw TrackerBackupError.unsupported }

        var result = BackupContents()
        let profile = native ? (object["profile"] as? [String: Any] ?? [:]) : object
        let preferences = object["preferences"] as? [String: Any] ?? [:]
        let model = (object["modelSettings"] as? [String: Any]) ?? (object["calibration"] as? [String: Any]) ?? profile
        result.mode = (profile[native ? "hrtMode" : "mode"] as? String).flatMap(HRTMode.init(rawValue:))
        result.weight = number(profile[native ? "weightKG" : "weight"]).flatMap {
            (20...400).contains($0) ? $0 : nil
        }
        if let raw = profile["birthYear"] {
            let year = integer(raw)
            result.birthYear = year.flatMap { (1900...currentYear).contains($0) ? $0 : nil }
            result.includesBirthYear = raw is NSNull || result.birthYear != nil
        }
        result.calibrationMethod = ((model["calibrationMethod"] ?? model["method"]) as? String)
            .map { ["average": "mipd", "adaptive": "ekf"][$0] ?? $0 }
            .flatMap(CalibrationMethod.init(rawValue:))
        result.calibrationHistory = ((model["calibrationHistoryMode"] ?? model["historyMode"]) as? String)
            .flatMap(CalibrationHistoryMode.init(rawValue:))
        result.ageModelEnabled = (model["ageModelEnabled"] ?? model["ageBeta"]) as? Bool
        result.weightUpdatedAt = stamp(profile["weightUpdatedAt"])
        result.birthYearUpdatedAt = stamp(profile["birthYearUpdatedAt"])
        result.modelSettingsUpdatedAt = stamp(profile["modelSettingsUpdatedAt"])
        result.showPrediction = (preferences["showPrediction"] ?? preferences["app-show-prediction"]) as? Bool
        result.appearance = ((preferences["theme"] ?? preferences["app-theme"]) as? String).flatMap(AppAppearance.init(rawValue:))
        result.remindersEnabled = preferences["remindersEnabled"] as? Bool
        result.snoozeMinutes = integer(preferences["snoozeMinutes"]).flatMap { [10, 15, 30, 60].contains($0) ? $0 : nil }
        if profile["pkParams"] is [String: Any] { result.ignoredCategories.insert(String(localized: "Custom PK parameters")) }

        var entryCount = 0
        if let modes = object["modes"] as? [String: Any] {
            for mode in HRTMode.allCases {
                guard let raw = modes[mode.rawValue] else { continue }
                guard let block = raw as? [String: Any] else { throw TrackerBackupError.unsupported }
                let contents = readMode(block, result: &result, entryCount: &entryCount)
                result.modes[mode] = contents
            }
        } else if web {
            let mode = result.mode ?? fallbackMode
            let contents = readMode(object, result: &result, entryCount: &entryCount)
            result.modes[mode] = contents
        } else {
            throw TrackerBackupError.unsupported
        }
        guard entryCount <= 20_000 else { throw TrackerBackupError.tooLarge }
        return result
    }

    static func write(_ backup: BackupContents, at date: Date) throws -> Data {
        let encoder = JSONEncoder()
        func encode<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: encoder.encode(value))
        }

        var blocks: [String: Any] = [:]
        for (mode, records) in backup.modes {
            blocks[mode.rawValue] = [
                "events": try encode(records.doses),
                "labResults": try encode(records.labs),
                "doseTemplates": records.templates.map { template in
                    var raw: [String: Any] = [
                        "id": template.id, "name": template.name, "route": template.route.rawValue,
                        "ester": template.ester, "doseMG": template.doseMG, "extras": template.extras,
                        "createdAt": template.createdAt,
                    ]
                    if let updatedAt = template.updatedAt { raw["updatedAt"] = updatedAt }
                    return raw
                },
                "plan": records.plans.map { entry in
                    let plan = entry.value
                    var raw: [String: Any] = [
                        "id": plan.id, "route": plan.route.rawValue, "ester": plan.ester, "doseMG": plan.doseMG,
                        "extras": plan.extras, "everyDays": plan.everyDays, "timesPerDay": plan.dosesPerDay,
                        "reminders": ["enabled": plan.remindersEnabled, "minutes": plan.reminderMinutes],
                    ]
                    if let anchor = plan.anchorTimeH { raw["anchorTimeH"] = anchor }
                    if let updatedAt = entry.stamp { raw["updatedAt"] = updatedAt }
                    return raw
                },
            ]
        }
        var profile: [String: Any] = [
            "hrtMode": backup.mode?.rawValue ?? "transfem", "weightKG": backup.weight ?? 70,
            "birthYear": backup.birthYear.map { $0 as Any } ?? NSNull(),
            "ageModelEnabled": backup.ageModelEnabled ?? false,
            "calibrationMethod": backup.calibrationMethod?.rawValue ?? "mipd",
            "calibrationHistoryMode": backup.calibrationHistory?.rawValue ?? "retrospective",
        ]
        if let at = backup.weightUpdatedAt { profile["weightUpdatedAt"] = at }
        if let at = backup.birthYearUpdatedAt { profile["birthYearUpdatedAt"] = at }
        if let at = backup.modelSettingsUpdatedAt { profile["modelSettingsUpdatedAt"] = at }
        return try JSONSerialization.data(withJSONObject: [
            "format": nativeFormat, "formatVersion": 1, "createdAt": ISO8601DateFormatter().string(from: date),
            "app": [
                "bundleId": Bundle.main.bundleIdentifier ?? "com.hellolaoyang.hrttracker",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0",
            ],
            "profile": profile, "modes": blocks, "preferences": [
                "theme": backup.appearance?.rawValue ?? "system", "showPrediction": backup.showPrediction ?? false,
                "remindersEnabled": backup.remindersEnabled ?? false, "snoozeMinutes": backup.snoozeMinutes ?? 15,
            ],
        ], options: [.prettyPrinted, .sortedKeys])
    }

    private static func readMode(
        _ raw: [String: Any], result: inout BackupContents, entryCount: inout Int
    ) -> BackupContents.ModeRecords {
        var mode = BackupContents.ModeRecords()
        if let quickDoses = raw["quickDoses"] as? [Any], !quickDoses.isEmpty {
            result.ignoredCategories.insert(String(localized: "Quick doses"))
        }
        if let supplies = raw["supplies"] as? [Any], !supplies.isEmpty {
            result.ignoredCategories.insert(String(localized: "Supplies"))
        }
        if let deletions = raw["deletions"] as? [String: [String: Any]],
           deletions.values.contains(where: { !$0.isEmpty }) {
            result.ignoredCategories.insert(String(localized: "Deleted record history"))
        }
        mode.doses = records(raw["events"], invalid: &result.invalid, count: &entryCount, parse: parseDose)
        mode.labs = records(raw["labResults"], invalid: &result.invalid, count: &entryCount, parse: parseLab)
        mode.templates = records(raw["doseTemplates"], invalid: &result.invalid, count: &entryCount, parse: parseTemplate)
        let planStamp = stamp(raw["planUpdatedAt"])
        mode.plans = records(raw["plan"], invalid: &result.invalid, count: &entryCount) { rawPlan in
            parsePlan(rawPlan).map { ($0, stamp(rawPlan["updatedAt"]) ?? planStamp) }
        }
        return mode
    }

    private static func records<T>(
        _ raw: Any?, invalid: inout Int, count: inout Int, parse: ([String: Any]) -> T?
    ) -> [T] {
        guard let raw else { return [] }
        guard let items = raw as? [Any] else { invalid += 1; return [] }
        count += items.count
        guard count <= 20_000 else { return [] }
        return items.compactMap {
            if let item = $0 as? [String: Any], let value = parse(item) { return value }
            invalid += 1
            return nil
        }
    }

    private static func parseDose(_ raw: [String: Any]) -> DoseEvent? {
        guard let fields = medication(raw), let time = timeHours(raw["timeH"]) else { return nil }
        return DoseEvent(
            id: fields.id, route: fields.route, timeH: time, doseMG: fields.dose, ester: fields.drug,
            extras: fields.extras, updatedAt: stamp(raw["updatedAt"])
        )
    }

    private static func parseLab(_ raw: [String: Any]) -> LabResult? {
        guard let id = id(raw["id"]), let time = timeHours(raw["timeH"]), let value = number(raw["concValue"]),
              value > 0, let unit = (raw["unit"] as? String)?.lowercased(),
              ["pg/ml", "pmol/l", "ng/dl", "nmol/l"].contains(unit) else { return nil }
        let assay = (raw["assay"] as? String).flatMap { ["lcms", "immuno", "chemi"].contains($0) ? $0 : nil }
        return LabResult(id: id, timeH: time, concValue: value, unit: unit, assay: assay, updatedAt: stamp(raw["updatedAt"]))
    }

    private static func parseTemplate(_ raw: [String: Any]) -> DoseTemplate? {
        guard let fields = medication(raw), let name = raw["name"] as? String else { return nil }
        return DoseTemplate(
            id: fields.id, name: name, route: fields.route, ester: fields.drug, doseMG: fields.dose,
            extras: fields.extras, createdAt: stamp(raw["createdAt"]) ?? 0, updatedAt: stamp(raw["updatedAt"])
        )
    }

    private static func parsePlan(_ raw: [String: Any]) -> MedicationPlan? {
        guard let fields = medication(raw), let cadence = number(raw["everyDays"]), (1...180).contains(cadence),
              let timesPerDay = integer(raw["timesPerDay"]), (1...8).contains(timesPerDay) else { return nil }
        let reminders = raw["reminders"] as? [String: Any]
        let minutes = (reminders?["minutes"] as? [Any])?.compactMap(integer).filter { (0..<1_440).contains($0) }
        return MedicationPlan(
            id: fields.id, route: fields.route, ester: fields.drug, doseMG: fields.dose, extras: fields.extras,
            everyDays: cadence, timesPerDay: timesPerDay, reminderMinutes: minutes ?? [540],
            remindersEnabled: reminders?["enabled"] as? Bool ?? true, anchorTimeH: timeHours(raw["anchorTimeH"])
        )
    }

    private static func medication(_ raw: [String: Any])
        -> (id: String, route: Route, drug: String, dose: Double, extras: [String: Double])? {
        guard let id = id(raw["id"]), let name = raw["route"] as? String, let route = Route(rawValue: name),
              let drug = raw["ester"] as? String,
              drug.range(of: #"^[A-Za-z0-9_]{1,24}$"#, options: .regularExpression) != nil,
              let dose = number(raw["doseMG"]), (0...10_000).contains(dose) else { return nil }
        let extras = (raw["extras"] as? [String: Any] ?? [:]).compactMapValues(number)
        return (id, route, drug, dose, extras)
    }

    private static func id(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !["__proto__", "constructor", "prototype"].contains(value) else { return nil }
        return value
    }

    private static func timeHours(_ raw: Any?) -> Double? {
        number(raw).flatMap { (0...1_500_000).contains($0) ? $0 : nil }
    }

    private static func stamp(_ raw: Any?) -> Double? {
        number(raw).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func integer(_ raw: Any?) -> Int? {
        number(raw).flatMap { Int(exactly: $0) }
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
}
