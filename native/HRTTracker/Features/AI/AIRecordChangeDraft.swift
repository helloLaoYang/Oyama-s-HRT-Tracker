import Foundation
import HRTEngine

struct AIRecordChangeDraft: Identifiable {
    enum Candidate: Equatable, Identifiable {
        case dose(DoseEvent)
        case lab(LabResult)

        var id: String {
            switch self {
            case .dose(let record): "dose-" + record.id
            case .lab(let record): "lab-" + record.id
            }
        }

        var reference: AIRecordReference {
            switch self {
            case .dose(let record): .dose(record.id)
            case .lab(let record): .lab(record.id)
            }
        }

        var date: Date {
            switch self {
            case .dose(let record): Date(trackerHours: record.timeH)
            case .lab(let record): Date(trackerHours: record.timeH)
            }
        }
    }

    enum GelSite: String, CaseIterable {
        case arm, thigh, scrotal

        var value: Double {
            switch self {
            case .arm: 0
            case .thigh: 1
            case .scrotal: 2
            }
        }

        var title: String {
            switch self {
            case .arm: HistoryText.localized("Arm")
            case .thigh: HistoryText.localized("Thigh")
            case .scrotal: HistoryText.localized("Scrotal")
            }
        }
    }

    let id = UUID()
    let mode: HRTMode
    let calendar: Calendar
    let arguments: AIRecordChangeArguments
    let candidates: [Candidate]
    private let historyEnd: Date

    private(set) var selectedID: String?
    var time: Date?
    private(set) var route: Route?
    var drug: String?
    var amountText = ""
    var unit: String?
    var patchCountText = ""
    var wearDaysText = ""
    var assay: String?
    var gelSite: GelSite?
    var holdMinutesText = ""
    var confirmedAnalyte: Bool

    init(arguments: AIRecordChangeArguments, snapshot: AIInsightSnapshot, reference: AIRecordReference?,
         calendar: Calendar) {
        self.arguments = arguments
        mode = snapshot.mode
        self.calendar = calendar
        historyEnd = snapshot.capturedInterval?.upperBound ?? .now
        confirmedAnalyte = arguments.analyte != nil || arguments.operation == .editLab
        switch arguments.operation {
        case .addDose, .addLab:
            candidates = []
        case .editDose:
            candidates = snapshot.doses.filter { $0.timeH.isFinite && !$0.id.lowercased().hasPrefix("hrt-plan-") }
                .map(Candidate.dose)
        case .editLab:
            candidates = snapshot.labs.filter { $0.timeH.isFinite }.map(Candidate.lab)
        }
        select(Self.initialTarget(arguments: arguments, reference: reference, candidates: candidates,
                                  calendar: calendar)?.id)
    }

    var isEditing: Bool { arguments.operation == .editDose || arguments.operation == .editLab }
    var isLab: Bool { arguments.operation == .addLab || arguments.operation == .editLab }
    var selected: Candidate? { candidates.first { $0.id == selectedID } }

    var expectedAnalyte: String { mode == .transfem ? "estradiol" : "total_testosterone" }
    var analyteTitle: String { LabText.localized(mode == .transfem ? "Estradiol" : "Total testosterone") }
    var analyteMismatch: Bool {
        guard isLab, let proposed = Self.normalized(arguments.analyte) else { return false }
        return proposed != expectedAnalyte
    }

    var availableDrugCodes: [String] {
        guard let route else { return [] }
        return TrackerRecordValidation.drugs(for: route, mode: mode)
    }

    var availableUnits: [String] {
        if isLab { return TrackerRecordValidation.labUnits(mode) }
        return route == .patchApply ? ["mg", "ug/day"] : ["mg"]
    }

    var availableAssays: [String] {
        let standard = TrackerRecordValidation.labAssays
        guard let original = originalLab?.assay, !standard.contains(original) else { return standard }
        return standard + [original]
    }

    var keepsOriginalHold: Bool {
        guard route == .sublingual, let original = originalDose, original.route == .sublingual,
              holdMinutesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              arguments.holdMinutes == nil else { return false }
        return original.extras[HistoryText.thetaKey] != nil || original.extras[HistoryText.tierKey] != nil
    }

    private var originalDose: DoseEvent? {
        guard case .dose(let value) = selected else { return nil }
        return value
    }

    private var originalLab: LabResult? {
        guard case .lab(let value) = selected else { return nil }
        return value
    }

    mutating func select(_ candidateID: String?) {
        selectedID = candidateID
        if let requested = arguments.occurredAt {
            time = Self.timestamp(requested).flatMap { $0 <= historyEnd ? $0 : nil }
        } else {
            time = selected?.date
        }
        if isLab {
            updateLabFields()
        } else {
            updateDoseFields()
        }
    }

    mutating func chooseRoute(_ value: Route?) {
        guard route != value else { return }
        route = value
        drug = drug.flatMap { availableDrugCodes.contains($0) ? $0 : nil }
        amountText = ""
        unit = nil
        patchCountText = ""
        wearDaysText = ""
        gelSite = nil
        holdMinutesText = ""
    }

    mutating func chooseUnit(_ value: String?) {
        if unit != nil, unit != value { amountText = "" }
        unit = value
    }

    func change(parameters: PKParameters, now: Date) -> TrackerRecordChange? {
        guard let time, !isEditing || selected != nil else { return nil }
        let originalTime = originalDose?.timeH ?? originalLab?.timeH
        let timeH = selected?.date == time ? originalTime ?? time.trackerHours : time.trackerHours
        guard TrackerRecordValidation.isHistorical(timeH, through: now) else { return nil }
        let recordID: String
        switch selected?.reference {
        case .dose(let id), .lab(let id): recordID = id
        default: recordID = id.uuidString.lowercased()
        }
        if isLab {
            guard confirmedAnalyte, !analyteMismatch, let unit, availableUnits.contains(unit),
                  let value = Self.number(amountText), TrackerRecordValidation.labValueIsValid(value),
                  let assay, availableAssays.contains(assay) else { return nil }
            let recordedUnit = originalLab.flatMap { Self.unit($0.unit) == unit ? $0.unit : nil } ?? unit
            let record = LabResult(id: recordID, timeH: timeH, concValue: value, unit: recordedUnit,
                                   assay: assay.isEmpty ? nil : assay, updatedAt: originalLab?.updatedAt)
            if let original = originalLab {
                return original == record ? nil : .editLab(original: original, updated: record)
            }
            return .addLab(record)
        }
        guard let route, let drug, availableDrugCodes.contains(drug),
              let dose = doseValues(route: route, parameters: parameters) else { return nil }
        let record = DoseEvent(id: recordID, route: route, timeH: timeH, doseMG: dose.amount, ester: drug,
                               extras: dose.extras, updatedAt: originalDose?.updatedAt)
        if let original = originalDose {
            return original == record ? nil : .editDose(original: original, updated: record)
        }
        return .addDose(record)
    }

    func reference(for change: TrackerRecordChange) -> AIRecordReference {
        switch change {
        case .addDose(let record), .editDose(_, let record): .dose(record.id)
        case .addLab(let record), .editLab(_, let record): .lab(record.id)
        }
    }

    private mutating func updateLabFields() {
        let previousUnit = Self.unit(originalLab?.unit)
        unit = arguments.unit == nil ? previousUnit : Self.unit(arguments.unit)
        if arguments.amount != nil, arguments.unit == nil { unit = nil }
        amountText = Self.numberText(arguments.amount ?? (unit == previousUnit ? originalLab?.concValue : nil))
        assay = Self.normalized(arguments.assay) ?? originalLab?.assay ?? ""
        if let unit, !availableUnits.contains(unit) { self.unit = nil }
        if let assay, !availableAssays.contains(assay) { self.assay = nil }
    }

    private mutating func updateDoseFields() {
        let original = originalDose
        route = arguments.route.map { raw in
            Route.allCases.first { $0.rawValue.lowercased() == Self.normalized(raw) }
        } ?? original?.route
        let preservesRoute = route != nil && route == original?.route
        let previous = preservesRoute ? original : nil
        let oldAmount = previous.map(Self.amountPerDose)
        let oldUnit = previous.map(Self.doseUnit)
        unit = arguments.unit == nil ? oldUnit : Self.unit(arguments.unit)
        if arguments.amount != nil, arguments.unit == nil { unit = nil }
        amountText = Self.numberText(arguments.amount ?? (unit == oldUnit ? oldAmount : nil))
        if let unit, !availableUnits.contains(unit) { self.unit = nil }
        let proposedDrug = Self.normalized(arguments.drug)?.uppercased() ?? original?.ester
        drug = proposedDrug.flatMap { availableDrugCodes.contains($0) ? $0 : nil }
        let oldCount = previous.flatMap { $0.route == .patchApply ? HistoryText.patchCount($0.extras) : nil }
        patchCountText = (arguments.patchCount ?? oldCount).map(String.init) ?? ""
        wearDaysText = Self.numberText(arguments.wearDays ?? previous?.extras[HistoryText.wearKey].map { $0 / 24 })
        if let proposed = Self.normalized(arguments.gelSite) {
            gelSite = GelSite(rawValue: proposed)
        } else if let site = previous?.extras[HistoryText.siteKey] {
            gelSite = GelSite.allCases.first { $0.value == site }
        } else {
            gelSite = nil
        }
        holdMinutesText = Self.numberText(arguments.holdMinutes)
    }

    private func doseValues(route: Route, parameters: PKParameters) -> (amount: Double, extras: [String: Double])? {
        if route == .patchRemove { return (0, [:]) }
        guard let value = Self.number(amountText), let unit, availableUnits.contains(unit) else { return nil }
        let original = originalDose.flatMap { $0.route == route ? $0 : nil }
        var amount = value
        var extras = original?.extras ?? [:]
        if route == .patchApply {
            guard let count = Int(patchCountText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let patch = TrackerRecordValidation.patchDose(perPatch: value, count: count,
                                                                isReleaseRate: unit == "ug/day") else { return nil }
            if let original, Self.amountPerDose(original) == value, Self.doseUnit(original) == unit,
               HistoryText.patchCount(original.extras) == count {
                amount = original.doseMG
            } else {
                extras.removeValue(forKey: HistoryText.rateKey)
                extras.removeValue(forKey: HistoryText.countKey)
                extras.merge(patch.extras, uniquingKeysWith: { _, proposed in proposed })
                amount = patch.amount
            }
            if wearDaysText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                extras.removeValue(forKey: HistoryText.wearKey)
            } else {
                guard let days = Self.number(wearDaysText),
                      let hours = TrackerRecordValidation.patchWearHours(days: days) else { return nil }
                let oldHours = original?.extras[HistoryText.wearKey]
                extras[HistoryText.wearKey] = oldHours.map { $0 / 24 == days ? $0 : hours } ?? hours
            }
        } else {
            guard TrackerRecordValidation.doseAmountIsValid(value) else { return nil }
        }
        if route == .gel {
            guard let gelSite else { return nil }
            extras[HistoryText.siteKey] = gelSite.value
        }
        if route == .sublingual && !keepsOriginalHold {
            guard let minutes = Self.number(holdMinutesText),
                  let theta = TrackerRecordValidation.sublingualTheta(minutes: minutes, parameters: parameters) else { return nil }
            extras.removeValue(forKey: HistoryText.tierKey)
            extras[HistoryText.thetaKey] = theta
        }
        return (amount, extras)
    }

    private static func initialTarget(arguments: AIRecordChangeArguments, reference: AIRecordReference?,
                                      candidates: [Candidate], calendar: Calendar) -> Candidate? {
        let time = timestamp(arguments.targetAt)
        if arguments.recordRef != nil {
            guard let reference, let candidate = candidates.first(where: { $0.reference == reference }) else { return nil }
            guard let time else { return arguments.targetAt == nil ? candidate : nil }
            return calendar.isDate(candidate.date, equalTo: time, toGranularity: .minute) ? candidate : nil
        }
        guard let time else { return nil }
        let matches = candidates.filter { calendar.isDate($0.date, equalTo: time, toGranularity: .minute) }
        return matches.count == 1 ? matches[0] : nil
    }

    static func unitTitle(_ code: String) -> String {
        code == "ug/day" ? "µg/day" : LabText.unitText(code)
    }

    private static func doseUnit(_ dose: DoseEvent) -> String {
        if dose.route == .patchApply, dose.extras[HistoryText.rateKey] != nil { return "ug/day" }
        return "mg"
    }

    private static func amountPerDose(_ dose: DoseEvent) -> Double {
        if dose.route == .patchApply {
            return (dose.extras[HistoryText.rateKey] ?? dose.doseMG) / Double(HistoryText.patchCount(dose.extras))
        }
        return dose.doseMG
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func unit(_ value: String?) -> String? {
        guard let value = normalized(value) else { return nil }
        switch value {
        case "µg/day", "μg/day", "mcg/day": return "ug/day"
        default: return value
        }
    }

    private static func numberText(_ value: Double?) -> String { value.map { String($0) } ?? "" }

    private static func number(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    private static func timestamp(_ value: String?) -> Date? {
        guard let value, value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(\.\d{1,3})?(Z|[+-]\d{2}:\d{2})$"#,
                                     options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mmXXXXX"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
