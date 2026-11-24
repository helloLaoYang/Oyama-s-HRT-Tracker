import Foundation
import HRTEngine

enum TrackerRecordChange {
    case addDose(DoseEvent)
    case editDose(original: DoseEvent, updated: DoseEvent)
    case addLab(LabResult)
    case editLab(original: LabResult, updated: LabResult)
}

enum TrackerRecordChangeResult: Equatable {
    case saved, alreadySaved, conflict, invalid, failed
}

enum TrackerRecordValidation {
    static let labAssays = ["", "lcms", "immuno", "chemi"]
    static let patchCounts = 1...10
    static let sublingualTiers = 0...3
    static let gelSites = 0...2

    static func drugs(for route: Route, mode: HRTMode) -> [String] {
        if mode == .transmasc {
            switch route {
            case .injection: return ["TC", "TE", "TU"]
            case .oral, .sublingual: return ["TU"]
            case .sc: return ["T", "TC", "TE"]
            default: return ["T"]
            }
        }
        switch route {
        case .injection: return ["EB", "EV", "EC", "EN", "EU", "LEUP", "TRIP"]
        case .oral: return ["E2", "EV", "CPA", "SPIRO", "BICA", "MPA", "RLX"]
        case .sublingual: return ["E2", "EV"]
        default: return ["E2"]
        }
    }

    static func labUnits(_ mode: HRTMode) -> [String] {
        mode == .transfem ? ["pg/ml", "pmol/l"] : ["ng/dl", "nmol/l"]
    }

    static func doseAmountIsValid(_ amount: Double) -> Bool {
        amount.isFinite && amount > 0 && amount <= 10_000
    }

    static func labValueIsValid(_ value: Double) -> Bool {
        value.isFinite && value > 0
    }

    static func patchDose(perPatch: Double, count: Int, isReleaseRate: Bool)
        -> (amount: Double, extras: [String: Double])? {
        guard patchCounts.contains(count) else { return nil }
        let total = perPatch * Double(count)
        guard doseAmountIsValid(total) else { return nil }
        var extras: [String: Double] = [:]
        if count > 1 { extras[HistoryText.countKey] = Double(count) }
        if isReleaseRate { extras[HistoryText.rateKey] = total }
        return (isReleaseRate ? 0 : total, extras)
    }

    static func patchWearHours(days: Double) -> Double? {
        let hours = days * 24
        return hours.isFinite && hours > 0 ? hours : nil
    }

    static func sublingualTheta(minutes: Double, parameters: PKParameters) -> Double? {
        guard minutes.isFinite, minutes >= 1 else { return nil }
        let theta = HRTEngine.sublingualTheta(fromHoldMinutes: minutes, parameters: parameters)
        return (0...1).contains(theta) ? theta : nil
    }

    static func isHistorical(_ time: Double, through date: Date) -> Bool {
        time.isFinite && time >= 0 && time <= date.trackerHours
    }

    static func isValidDose(_ value: DoseEvent, mode: HRTMode, original: DoseEvent?) -> Bool {
        guard value.doseMG.isFinite, value.extras.values.allSatisfy(\.isFinite),
              drugs(for: value.route, mode: mode).contains(value.ester) else { return false }
        let patchKeys: Set<String> = [HistoryText.rateKey, HistoryText.countKey, HistoryText.wearKey]
        let sublingualKeys: Set<String> = [HistoryText.thetaKey, HistoryText.tierKey]
        let routeKeys = patchKeys.union(sublingualKeys).union([HistoryText.siteKey])
        let activeKeys: Set<String>
        switch value.route {
        case .patchRemove:
            return value.doseMG == 0 && value.extras.isEmpty
        case .patchApply:
            activeKeys = patchKeys
            if let rate = value.extras[HistoryText.rateKey] {
                guard value.doseMG == 0, doseAmountIsValid(rate) else { return false }
            } else if !doseAmountIsValid(value.doseMG) {
                return false
            }
            if let count = value.extras[HistoryText.countKey], !isOption(count, in: patchCounts) { return false }
            if let wear = value.extras[HistoryText.wearKey], wear <= 0 { return false }
        case .sublingual:
            activeKeys = sublingualKeys
            guard doseAmountIsValid(value.doseMG) else { return false }
            if let theta = value.extras[HistoryText.thetaKey] {
                guard (0...1).contains(theta), value.extras[HistoryText.tierKey] == nil else { return false }
            } else {
                guard let tier = value.extras[HistoryText.tierKey], isOption(tier, in: sublingualTiers) else { return false }
            }
        case .gel:
            activeKeys = [HistoryText.siteKey]
            guard doseAmountIsValid(value.doseMG), let site = value.extras[HistoryText.siteKey],
                  isOption(site, in: gelSites) else { return false }
        default:
            activeKeys = []
            guard doseAmountIsValid(value.doseMG) else { return false }
        }
        return value.extras.allSatisfy { key, field in
            if routeKeys.contains(key) { return activeKeys.contains(key) }
            return original?.route == value.route && original?.extras[key] == field
        }
    }

    static func isValidLab(_ value: LabResult, mode: HRTMode, original: LabResult?) -> Bool {
        return labValueIsValid(value.concValue)
            && labUnits(mode).contains(value.unit.lowercased())
            && (labAssays.contains(value.assay ?? "") || original?.assay == value.assay)
    }

    private static func isOption(_ value: Double, in options: ClosedRange<Int>) -> Bool {
        guard let option = Int(exactly: value) else { return false }
        return options.contains(option)
    }
}
