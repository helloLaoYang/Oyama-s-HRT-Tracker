import Foundation
import HRTEngine

struct AIRecordCorrection {
    enum Record: Equatable, Identifiable {
        case dose(DoseEvent)
        case lab(LabResult)

        var id: String {
            switch self {
            case .dose(let record): "dose-" + record.id
            case .lab(let record): "lab-" + record.id
            }
        }

        var time: Date {
            switch self {
            case .dose(let record): Date(trackerHours: record.timeH)
            case .lab(let record): Date(trackerHours: record.timeH)
            }
        }

        var value: Double {
            switch self {
            case .dose(let record):
                (record.extras[HistoryText.rateKey] ?? record.doseMG) / Self.patchCount(for: record)
            case .lab(let record): record.concValue
            }
        }

        var unit: String {
            switch self {
            case .dose(let record) where record.route == .patchApply:
                return correctionLabel(record.extras[HistoryText.rateKey] == nil ? "mg per patch" : "µg/day per patch")
            case .dose: return "mg"
            case .lab(let record): return LabText.unitText(record.unit)
            }
        }

        func isEditable(in mode: HRTMode, through date: Date) -> Bool {
            switch self {
            case .dose(let record):
                return !record.id.isEmpty && !record.id.lowercased().hasPrefix("hrt-plan-")
                    && record.route != .patchRemove
                    && TrackerRecordValidation.isHistorical(record.timeH, through: date)
                    && TrackerRecordValidation.isValidDose(record, mode: mode, original: record)
            case .lab(let record):
                return !record.id.isEmpty
                    && TrackerRecordValidation.isHistorical(record.timeH, through: date)
                    && TrackerRecordValidation.isValidLab(record, mode: mode, original: record)
            }
        }

        fileprivate func changingValue(to amount: Double, mode: HRTMode) -> TrackerRecordChange? {
            switch self {
            case .dose(let original):
                let total = amount * Self.patchCount(for: original)
                var next = original
                if original.route == .patchApply, original.extras[HistoryText.rateKey] != nil {
                    next.extras[HistoryText.rateKey] = total
                } else {
                    next.doseMG = total
                }
                guard next != original, TrackerRecordValidation.isValidDose(next, mode: mode, original: original)
                else { return nil }
                return .editDose(original: original, updated: next)
            case .lab(let original):
                var next = original
                next.concValue = amount
                guard next != original, TrackerRecordValidation.isValidLab(next, mode: mode, original: original)
                else { return nil }
                return .editLab(original: original, updated: next)
            }
        }

        private static func patchCount(for record: DoseEvent) -> Double {
            record.route == .patchApply ? Double(HistoryText.patchCount(record.extras)) : 1
        }
    }

    let record: Record
    let amount: Double
    let change: TrackerRecordChange

    init?(record: Record, amount: Double, mode: HRTMode, through date: Date) {
        guard amount.isFinite, amount > 0, amount != record.value, record.isEditable(in: mode, through: date),
              let change = record.changingValue(to: amount, mode: mode) else { return nil }
        self.record = record
        self.amount = amount
        self.change = change
    }

    static func extractionPrompt(statement: String, unit: String) -> String {
        """
        Extract the one exact replacement number stated in this request to correct a historical record.
        The selected record keeps its unit, \(unit). Return {"value":null} if the stated unit differs, \
        the user is asking what value to use, or the replacement is unclear.
        Otherwise output only an object like {"value":12.5}, with the stated number. Do not convert units.
        User's correction request: \(String(reflecting: statement))
        """
    }

    static func modelValue(_ reply: String, matching statement: String, unit: String,
                           decimalSeparator: String = ".") -> Double? {
        let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.utf8.count <= 128, usesRecordUnit(statement, unit: unit),
              let match = body.wholeMatch(of: #/\{[ \t\r\n]*"value"[ \t\r\n]*:[ \t\r\n]*((?:0|[1-9][0-9]*)(?:\.[0-9]+)?)[ \t\r\n]*\}/#),
              let value = Double(match.1), value.isFinite, value > 0,
              value == statedValue(statement, decimalSeparator: decimalSeparator) else { return nil }
        return value
    }

    static func usesRecordUnit(_ statement: String, unit: String) -> Bool {
        let stated = recognizedUnits(in: statement)
        return stated.isEmpty || stated == recognizedUnits(in: unit)
    }

    private static func recognizedUnits(in text: String) -> Set<String> {
        let normalized = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "μ", with: "u")
            .replacingOccurrences(of: "µ", with: "u")
        let matches = normalized.matches(of: #/([a-z]+|毫克|微克|纳克|皮克|克|毫升|纳摩尔|皮摩尔)(?:[ \t]*(?:\/|per[ \t]+)[ \t]*([a-z]+|天|日|贴)|每(天|日))?/#)
        return Set(matches.compactMap { match in
            guard let numerator = numerators[String(match.1)] else { return nil }
            guard let denominator = match.2 ?? match.3, denominator != "patch", denominator != "贴" else {
                return numerator
            }
            let canonicalDenominator = denominators[String(denominator)] ?? String(denominator)
            return "\(numerator)/\(canonicalDenominator)"
        })
    }

    private static let numerators = [
        "g": "g", "克": "g", "kg": "kg", "mg": "mg", "毫克": "mg", "milligram": "mg", "milligrams": "mg",
        "ug": "ug", "mcg": "ug", "微克": "ug", "microgram": "ug", "micrograms": "ug",
        "ng": "ng", "纳克": "ng", "pg": "pg", "皮克": "pg", "ml": "ml", "毫升": "ml", "ul": "ul", "iu": "iu",
        "nmol": "nmol", "纳摩尔": "nmol", "pmol": "pmol", "皮摩尔": "pmol",
    ]

    private static let denominators = ["d": "day", "days": "day", "天": "day", "日": "day"]

    static func statedValue(_ statement: String, decimalSeparator: String = ".") -> Double? {
        let matches = statement.matches(of: #/[-−+]?(?:[0-9]+(?:[.,][0-9]+)?|[.,][0-9]+)/#)
        guard matches.count == 1, let match = matches.first else { return nil }
        return enteredValue(String(match.output), decimalSeparator: decimalSeparator)
    }

    static func enteredValue(_ text: String, decimalSeparator: String = ".") -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard decimalSeparator == "." || !trimmed.contains(".") else { return nil }
        let normalized = trimmed.replacingOccurrences(of: decimalSeparator, with: ".")
        guard
              normalized.wholeMatch(of: #/(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?/#) != nil,
              let amount = Double(normalized), amount.isFinite, amount > 0 else { return nil }
        return amount
    }

    @MainActor
    func undoAfterSave(in store: TrackerStore) -> TrackerRecordChange? {
        // Capture the persisted revision so undo conflicts with subsequent changes to the record.
        switch change {
        case .editDose(let original, var intended):
            guard let saved = store.doses.first(where: { $0.id == intended.id }) else { return nil }
            intended.updatedAt = saved.updatedAt
            return saved == intended ? .editDose(original: saved, updated: original) : nil
        case .editLab(let original, var intended):
            guard let saved = store.labs.first(where: { $0.id == intended.id }) else { return nil }
            intended.updatedAt = saved.updatedAt
            intended.unit = intended.unit.lowercased()
            return saved == intended ? .editLab(original: saved, updated: original) : nil
        default:
            return nil
        }
    }
}

func correctionLabel(_ key: String.LocalizationValue) -> String {
    label(key, table: "AIRecordCorrection")
}
