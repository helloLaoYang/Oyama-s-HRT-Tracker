import Foundation
import HRTEngine
import SwiftData

enum AppAppearance: String, CaseIterable, Identifiable, Codable {
    case system, light, dark, mono

    var id: String { rawValue }
}

struct MedicationPlan: Identifiable, Equatable, Sendable {
    var id: String
    var route: Route
    var ester: String
    var doseMG: Double
    var extras: [String: Double]
    var everyDays: Double
    var timesPerDay: Int
    var reminderMinutes: [Int]
    var remindersEnabled: Bool
    var anchorTimeH: Double?

    init(
        id: String = UUID().uuidString.lowercased(), route: Route, ester: String,
        doseMG: Double, extras: [String: Double] = [:], everyDays: Double = 1, timesPerDay: Int = 1,
        reminderMinutes: [Int] = [540], remindersEnabled: Bool = true, anchorTimeH: Double? = nil
    ) {
        self.id = id
        self.route = route
        self.ester = ester
        self.doseMG = doseMG
        self.extras = extras
        self.everyDays = everyDays
        self.timesPerDay = timesPerDay
        self.reminderMinutes = reminderMinutes
        self.remindersEnabled = remindersEnabled
        self.anchorTimeH = anchorTimeH
    }

    var reminderMinute: Int {
        get { reminderMinutes.first ?? 540 }
        set {
            if reminderMinutes.isEmpty { reminderMinutes.append(newValue) }
            else { reminderMinutes[0] = newValue }
        }
    }

    var dosesPerDay: Int { everyDays <= 1 ? max(1, timesPerDay) : 1 }
}

struct DoseTemplate: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var route: Route
    var ester: String
    var doseMG: Double
    var extras: [String: Double]
    var createdAt: Double
    var updatedAt: Double?

    init(
        id: String = UUID().uuidString.lowercased(), name: String, route: Route, ester: String,
        doseMG: Double, extras: [String: Double] = [:],
        createdAt: Double = Date().timeIntervalSince1970 * 1_000, updatedAt: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.route = route
        self.ester = ester
        self.doseMG = doseMG
        self.extras = extras
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum MedicationPlanStatus: Equatable {
    case due(done: Int, total: Int)
    case taken
    case rest(next: Date)
}

@Model
final class DoseRecord {
    var uuid: String = ""
    var modeRaw: String = "transfem"
    var routeRaw: String = "oral"
    var ester: String = ""
    var timeH: Double = 0
    var doseMG: Double = 0
    var extrasData: Data?
    var updatedAt: Double?

    init(mode: HRTMode, value: DoseEvent, updatedAt: Double?) {
        modeRaw = mode.rawValue
        uuid = value.id
        update(value, updatedAt: updatedAt)
    }

    var value: DoseEvent? {
        guard let route = Route(rawValue: routeRaw) else { return nil }
        return DoseEvent(
            id: uuid, route: route, timeH: timeH, doseMG: doseMG, ester: ester,
            extras: decodeRecord([String: Double].self, from: extrasData) ?? [:], updatedAt: updatedAt
        )
    }

    func update(_ value: DoseEvent, updatedAt: Double?) {
        routeRaw = value.route.rawValue
        ester = value.ester
        timeH = value.timeH
        doseMG = value.doseMG
        extrasData = encodeRecord(value.extras)
        self.updatedAt = updatedAt
    }
}

@Model
final class LabRecord {
    var uuid: String = ""
    var modeRaw: String = "transfem"
    var timeH: Double = 0
    var concValue: Double = 0
    var unit: String = "pg/ml"
    var assay: String?
    var updatedAt: Double?

    init(mode: HRTMode, value: LabResult, updatedAt: Double?) {
        modeRaw = mode.rawValue
        uuid = value.id
        update(value, updatedAt: updatedAt)
    }

    var value: LabResult {
        LabResult(id: uuid, timeH: timeH, concValue: concValue, unit: unit, assay: assay, updatedAt: updatedAt)
    }

    func update(_ value: LabResult, updatedAt: Double?) {
        timeH = value.timeH
        concValue = value.concValue
        unit = value.unit.lowercased()
        assay = value.assay
        self.updatedAt = updatedAt
    }
}

@Model
final class MedicationPlanRecord {
    var uuid: String = ""
    var modeRaw: String = "transfem"
    var routeRaw: String = "patchApply"
    var ester: String = ""
    var doseMG: Double = 0
    var extrasData: Data?
    var everyDays: Double = 1
    var timesPerDay: Int = 1
    var reminderMinutesData: Data?
    var remindersEnabled: Bool = true
    var anchorTimeH: Double?
    var ordinal: Int = 0
    var updatedAt: Double?

    init(mode: HRTMode, value: MedicationPlan, ordinal: Int, updatedAt: Double?) {
        modeRaw = mode.rawValue
        uuid = value.id
        self.ordinal = ordinal
        update(value, updatedAt: updatedAt)
    }

    var value: MedicationPlan? {
        guard let route = Route(rawValue: routeRaw) else { return nil }
        return MedicationPlan(
            id: uuid, route: route, ester: ester, doseMG: doseMG,
            extras: decodeRecord([String: Double].self, from: extrasData) ?? [:],
            everyDays: everyDays, timesPerDay: timesPerDay,
            reminderMinutes: decodeRecord([Int].self, from: reminderMinutesData) ?? [540],
            remindersEnabled: remindersEnabled, anchorTimeH: anchorTimeH
        )
    }

    func update(_ value: MedicationPlan, updatedAt: Double?) {
        routeRaw = value.route.rawValue
        ester = value.ester
        doseMG = value.doseMG
        extrasData = encodeRecord(value.extras)
        everyDays = value.everyDays
        timesPerDay = value.dosesPerDay
        reminderMinutesData = encodeRecord(value.reminderMinutes)
        remindersEnabled = value.remindersEnabled
        anchorTimeH = value.anchorTimeH
        self.updatedAt = updatedAt
    }
}

@Model
final class DoseTemplateRecord {
    var uuid: String = ""
    var modeRaw: String = "transfem"
    var name: String = ""
    var routeRaw: String = "oral"
    var ester: String = ""
    var doseMG: Double = 0
    var extrasData: Data?
    var createdAt: Double = 0
    var updatedAt: Double?

    init(mode: HRTMode, value: DoseTemplate, updatedAt: Double?) {
        modeRaw = mode.rawValue
        uuid = value.id
        update(value, updatedAt: updatedAt)
    }

    var value: DoseTemplate? {
        guard let route = Route(rawValue: routeRaw) else { return nil }
        return DoseTemplate(
            id: uuid, name: name, route: route, ester: ester, doseMG: doseMG,
            extras: decodeRecord([String: Double].self, from: extrasData) ?? [:],
            createdAt: createdAt, updatedAt: updatedAt
        )
    }

    func update(_ value: DoseTemplate, updatedAt: Double?) {
        name = value.name
        routeRaw = value.route.rawValue
        ester = value.ester
        doseMG = value.doseMG
        extrasData = encodeRecord(value.extras)
        createdAt = value.createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class MedicationSupplyRecord {
    var uuid: String = ""
    var modeRaw: String = "transfem"
    var content: Data?
    var updatedAt: Double?

    init(mode: HRTMode, value: MedicationSupply, updatedAt: Double?) {
        modeRaw = mode.rawValue
        update(value, updatedAt: updatedAt)
    }

    var value: MedicationSupply? { decodeRecord(MedicationSupply.self, from: content) }

    func update(_ value: MedicationSupply, updatedAt: Double?) {
        uuid = value.id
        content = encodeRecord(value)
        self.updatedAt = updatedAt
    }
}

@Model
final class TrackerProfileRecord {
    var modeRaw: String = "transfem"
    var weight: Double = 70
    var birthYear: Int?
    var ageModelEnabled: Bool = false
    var calibrationMethodRaw: String = "mipd"
    var calibrationHistoryRaw: String = "retrospective"
    var showPrediction: Bool = false
    var appearanceRaw: String = "system"
    var remindersEnabled: Bool = false
    var snoozeMinutes: Int = 15
    var weightUpdatedAt: Double?
    var birthYearUpdatedAt: Double?
    var modelSettingsUpdatedAt: Double?
    var pkOverridesData: Data?
    var pkParamsUpdatedAt: Double?
    var supplyLeadDays: Int?
    var updatedAt: Double = 0

    var pkOverrides: [String: Double] {
        get { decodeRecord([String: Double].self, from: pkOverridesData) ?? [:] }
        set { pkOverridesData = newValue.isEmpty ? nil : encodeRecord(newValue) }
    }

    init() {}
}

private func encodeRecord<T: Encodable>(_ value: T) -> Data? {
    try? JSONEncoder().encode(value)
}

private func decodeRecord<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
    guard let data else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}
