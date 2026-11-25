import Foundation
import HRTEngine

func stockInputNumber(_ input: String, locale: Locale) -> Double? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let number = text.wholeMatch(of: .localizedDouble(locale: locale))?.output ?? Double(text)
    return number.flatMap { $0.isFinite ? $0 : nil }
}

enum StockCurrency: String, Codable, CaseIterable, Sendable {
    case CNY, HKD, TWD, USD, EUR, JPY

    var scale: Int { self == .JPY ? 1 : 100 }
    var fractionDigits: Int { self == .JPY ? 0 : 2 }
}

struct StockPurchase: Codable, Equatable, Sendable {
    static let maxMinor = 9_007_199_254_740_991
    var unitsPerPack: Double
    var packCount: Double
    var totalMinor: Int?
    var currency: StockCurrency

    var isValid: Bool {
        unitsPerPack > 0 && packCount > 0 && (unitsPerPack * packCount).isFinite && unitsPerPack * packCount > 0 &&
            (totalMinor.map { (0...Self.maxMinor).contains($0) } ?? true)
    }

    var unitPrice: Decimal? {
        totalMinor.map { Decimal($0) / Decimal(currency.scale) / Decimal(unitsPerPack) / Decimal(packCount) }
    }

    static func minorAmount(_ input: String, currency: StockCurrency, locale: Locale) -> Int? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let amount = text.wholeMatch(of: .localizedDecimal(locale: locale))?.output ??
                text.wholeMatch(of: .localizedDecimal(locale: Locale(identifier: "en_US_POSIX")))?.output else { return nil }
        let scaled = amount * Decimal(currency.scale)
        guard scaled >= 0, scaled <= Decimal(maxMinor) else { return nil }
        let minor = NSDecimalNumber(decimal: scaled).intValue
        return scaled == Decimal(minor) ? minor : nil
    }
}

struct StockRecount: Codable, Equatable, Sendable {
    var at: Double
    var count: Double
}

func stockQuantity(route: Route, doseMG: Double, extras: [String: Double]) -> Double {
    route == .patchApply ? Double(max(1, extras["patchCount"].flatMap { Int(exactly: $0) } ?? 1)) : doseMG
}

struct StockAllocation {
    let supply: MedicationSupply
    let units: Double
    var cost: Decimal? { supply.purchase?.unitPrice.map { $0 * Decimal(units) } }
}

struct StockUse: Identifiable {
    let dose: DoseEvent
    let choices: [MedicationSupply]
    let selected: MedicationSupply?
    let needsSpecification: Bool
    let missingStock: Bool
    let parts: [StockAllocation]

    var id: String { dose.id }
    var complete: Bool { !needsSpecification && !missingStock && parts.allSatisfy { $0.cost != nil } }
}

struct InventoryLedger {
    private(set) var remaining: [String: Double]
    private(set) var uses: [StockUse] = []

    init(supplies: [MedicationSupply], events: [DoseEvent], nowH: Double) {
        let ordered = supplies.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        let groups = Dictionary(grouping: ordered) { $0.route.rawValue + "|" + $0.ester }
        let byID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        remaining = byID.mapValues { $0.count * $0.pack.unitMG }
        let counts = ordered.flatMap { supply in
            (supply.recounts ?? []).enumerated().map { index, count in
                (time: count.at / 3_600_000, id: supply.id, index: index, remaining: count.count * supply.pack.unitMG)
            }
        }.sorted { ($0.time, $0.id, $0.index) < ($1.time, $1.id, $1.index) }
        var nextCount = 0
        // A physical count at the same instant as a dose observes the balance after that dose.
        func applyCounts(before time: Double, inclusive: Bool, to remaining: inout [String: Double]) {
            while nextCount < counts.count {
                let count = counts[nextCount]
                guard count.time < time || (inclusive && count.time == time) else { break }
                remaining[count.id] = count.remaining
                nextCount += 1
            }
        }
        for dose in events.filter({ $0.route != .patchRemove && $0.timeH <= nowH }).sorted(by: { ($0.timeH, $0.id) < ($1.timeH, $1.id) }) {
            var needed = stockQuantity(route: dose.route, doseMG: dose.doseMG, extras: dose.extras)
            guard needed > 0 else { continue }
            applyCounts(before: dose.timeH, inclusive: false, to: &remaining)
            let lots = (groups[dose.route.rawValue + "|" + dose.ester] ?? []).filter { lot in
                lot.startedAt / 3_600_000 <= dose.timeH && (lot.archivedAt.map { dose.timeH <= $0 / 3_600_000 } ?? true)
            }
            var choices: [MedicationSupply] = []
            for lot in lots where remaining[lot.id, default: 0] > 0 && !choices.contains(where: { $0.pack == lot.pack }) {
                choices.append(lot)
            }
            let selected: MedicationSupply?
            if let id = dose.inventorySupplyId {
                selected = byID[id].flatMap { $0.route == dose.route && $0.ester == dose.ester ? $0 : nil }
                if let selected, !choices.contains(where: { $0.pack == selected.pack }) { choices.append(selected) }
            } else {
                selected = choices.count == 1 ? choices.first : nil
            }
            // An imported dose can reference a lot missing from this device. Confirm its
            // specification before pricing it against any newly supplied replacement.
            let ambiguous = selected == nil && !choices.isEmpty
            var parts: [StockAllocation] = []
            if let selected {
                for lot in lots where lot.pack == selected.pack {
                    let take = min(needed, remaining[lot.id, default: 0])
                    guard take > 0 else { continue }
                    parts.append(StockAllocation(supply: lot, units: take / lot.pack.unitMG))
                    let left = remaining[lot.id, default: 0]
                    let rest = left - take
                    remaining[lot.id] = rest <= left.ulp * 4 ? 0 : rest
                    needed -= take
                    if needed <= 0 { break }
                }
            }
            let tolerance = stockQuantity(route: dose.route, doseMG: dose.doseMG, extras: dose.extras) * 1e-12
            uses.append(StockUse(dose: dose, choices: choices, selected: selected, needsSpecification: ambiguous,
                                 missingStock: !ambiguous && needed > tolerance, parts: parts))
        }
        applyCounts(before: nowH, inclusive: true, to: &remaining)
    }
}

enum MedicationCostRange: String, CaseIterable {
    case today, last7, last30, all

    func start(now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .last7: return calendar.date(byAdding: .day, value: -6, to: today)
        case .last30: return calendar.date(byAdding: .day, value: -29, to: today)
        case .all: return nil
        }
    }
}
