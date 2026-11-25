import Foundation
import HRTEngine

enum MedicationPack: Codable, Hashable, Sendable {
    case vial(ml: Double, mgPerMl: Double)
    case pill(mg: Double)
    case pump(mg: Double)
    case sachet(mg: Double)
    case patch(rate: Double?)
    case bulk

    enum Kind: String, Codable, Sendable {
        case vial, pill, pump, sachet, patch, bulk

        static func choices(for route: Route) -> [Self] {
            switch route {
            case .injection: [.vial, .bulk]
            case .oral, .sublingual: [.pill, .bulk]
            case .gel: [.pump, .sachet, .bulk]
            case .patchApply: [.patch]
            default: [.bulk]
            }
        }

        func defaultPack(pillStrength: Double = 2) -> MedicationPack {
            switch self {
            case .vial: .vial(ml: 5, mgPerMl: 40)
            case .pill: .pill(mg: pillStrength)
            case .pump: .pump(mg: 1.25)
            case .sachet: .sachet(mg: 1.5)
            case .patch: .patch(rate: nil)
            case .bulk: .bulk
            }
        }
    }

    var kind: Kind {
        switch self {
        case .vial: .vial
        case .pill: .pill
        case .pump: .pump
        case .sachet: .sachet
        case .patch: .patch
        case .bulk: .bulk
        }
    }

    var unitMG: Double {
        switch self {
        case let .vial(ml, mgPerMl): ml * mgPerMl
        case let .pill(mg), let .pump(mg), let .sachet(mg): mg
        case .patch, .bulk: 1
        }
    }

    var isValid: Bool {
        if case let .patch(rate?) = self { return rate.isFinite && rate > 0 }
        if case let .vial(ml, mgPerMl) = self {
            guard ml.isFinite, mgPerMl.isFinite, ml > 0, mgPerMl > 0 else { return false }
        }
        return unitMG.isFinite && unitMG > 0
    }

    private enum CodingKeys: String, CodingKey {
        case kind, ml, mgPerMl, mg, releaseRateUGPerDay
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .vial:
            self = try .vial(ml: values.decode(Double.self, forKey: .ml),
                             mgPerMl: values.decode(Double.self, forKey: .mgPerMl))
        case .pill: self = try .pill(mg: values.decode(Double.self, forKey: .mg))
        case .pump: self = try .pump(mg: values.decode(Double.self, forKey: .mg))
        case .sachet: self = try .sachet(mg: values.decode(Double.self, forKey: .mg))
        case .patch: self = .patch(rate: try values.decodeIfPresent(Double.self, forKey: .releaseRateUGPerDay))
        case .bulk: self = .bulk
        }
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "Invalid pack strength")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        switch self {
        case let .vial(ml, mgPerMl):
            try values.encode(ml, forKey: .ml)
            try values.encode(mgPerMl, forKey: .mgPerMl)
        case let .pill(mg), let .pump(mg), let .sachet(mg):
            try values.encode(mg, forKey: .mg)
        case let .patch(rate):
            try values.encodeIfPresent(rate, forKey: .releaseRateUGPerDay)
        case .bulk:
            break
        }
    }
}

struct MedicationSupply: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var route: Route
    var ester: String
    var pack: MedicationPack
    var count: Double
    /// Epoch milliseconds from which medication records are deducted.
    var startedAt: Double
    var purchase: StockPurchase?
    var recounts: [StockRecount]?
    var archivedAt: Double?

    init(id: String = UUID().uuidString.lowercased(), route: Route, ester: String,
         pack: MedicationPack, count: Double, startedAt: Double) {
        self.id = id
        self.route = route
        self.ester = ester
        self.pack = pack
        self.count = count
        self.startedAt = startedAt
    }

    var isValid: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !["__proto__", "constructor", "prototype"].contains(id) &&
            ester.range(of: #"^[A-Za-z0-9_]{1,24}$"#, options: .regularExpression) != nil &&
            pack.isValid && count.isFinite && count >= 0 && (count * pack.unitMG).isFinite &&
            startedAt.isFinite && startedAt > 0 && (purchase?.isValid ?? true) &&
            (recounts ?? []).allSatisfy { $0.at.isFinite && $0.at >= startedAt && $0.count >= 0 && ($0.count * pack.unitMG).isFinite } &&
            (archivedAt.map { $0.isFinite && $0 >= startedAt } ?? true)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            route: try values.decode(Route.self, forKey: .route),
            ester: try values.decode(String.self, forKey: .ester),
            pack: try values.decode(MedicationPack.self, forKey: .pack),
            count: try values.decode(Double.self, forKey: .count),
            startedAt: try values.decode(Double.self, forKey: .startedAt)
        )
        purchase = try values.decodeIfPresent(StockPurchase.self, forKey: .purchase)
        recounts = try values.decodeIfPresent([StockRecount].self, forKey: .recounts)
        archivedAt = try values.decodeIfPresent(Double.self, forKey: .archivedAt)
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .count, in: values, debugDescription: "Invalid inventory record")
        }
    }
}

struct InventoryStockStatus: Identifiable {
    let supply: MedicationSupply
    let remaining: Double
    let dailyUse: Double?
    let runOutH: Double?

    var id: String { supply.id }
    var remainingUnits: Double { remaining / supply.pack.unitMG }

    var remainingVials: (whole: Double, openedMG: Double) {
        let whole = (remainingUnits + 1e-9).rounded(.down)
        return (whole, max(0, remaining - whole * supply.pack.unitMG))
    }

    init(supply: MedicationSupply, remaining: Double, regimens: [MedicationPlan], nowH: Double) {
        self.supply = supply
        self.remaining = remaining
        let rate = regimens.lazy.filter { $0.route == supply.route && $0.ester == supply.ester }.reduce(0.0) {
            $0 + stockQuantity(route: $1.route, doseMG: $1.doseMG, extras: $1.extras) * Double($1.dosesPerDay) / $1.everyDays
        }
        let perDay = rate.isFinite && rate > 0 ? rate : nil
        dailyUse = perDay
        let projected = perDay.map { nowH + (remaining / $0) * 24 }
        runOutH = projected.flatMap { $0.isFinite ? $0 : nil }
    }

    func isLow(leadDays: Int, nowH: Double) -> Bool {
        dailyUse != nil && (remaining <= 0 || (runOutH.map { $0 - nowH < Double(leadDays) * 24 } ?? false))
    }
}

enum InventoryRegimens {
    private struct Signature: Hashable {
        let route: Route
        let ester: String
        let extras: [Double?]

        init(_ event: DoseEvent) {
            route = event.route
            ester = event.ester
            extras = ["sublingualTier", "sublingualTheta", "gelSite", "releaseRateUGPerDay"].map { event.extras[$0] }
        }
    }

    private struct DoseCluster {
        var mean: Double
        var history: [DoseEvent]
    }

    private struct InferredRegimen {
        let plan: MedicationPlan
        let last: Double
        let since: Double
        let next: Double
        let hormone: String
    }

    static func current(events: [DoseEvent], plans: [MedicationPlan], nowH: Double) -> [MedicationPlan] {
        guard plans.isEmpty else { return plans }
        // Match the Web inventory's six-week regimen detection, including small drift in logged amounts.
        let groups = Dictionary(grouping: events.filter { $0.route != .patchRemove }, by: Signature.init)
        let recentThreshold = nowH - 42 * 24
        let inferred = groups.values.flatMap { group -> [InferredRegimen] in
            let ordered = group.sorted { $0.timeH < $1.timeH }
            let past = ordered.filter { $0.timeH <= nowH }
            return clusters(from: past).compactMap { cluster in
                let recent = cluster.history.filter { $0.timeH >= recentThreshold }
                guard recent.count >= 3, let last = cluster.history.last else { return nil }
                let gaps = zip(recent, recent.dropFirst()).map { $1.timeH - $0.timeH }.sorted()
                let mid = gaps.count / 2
                let usualGap = gaps.count.isMultiple(of: 2) ? (gaps[mid - 1] + gaps[mid]) / 2 : gaps[mid]
                let intervalH = usualGap >= 24 ? usualGap.rounded() : (usualGap * 2).rounded() / 2
                let lapseH = intervalH * 2.5 + 12
                guard intervalH > 1, nowH - last.timeH <= lapseH else { return nil }
                var sinceH = last.timeH
                for event in cluster.history.dropLast().reversed() {
                    if sinceH - event.timeH > lapseH { break }
                    sinceH = event.timeH
                }
                let next = ordered.first { $0.timeH > nowH && similarAmount($0.doseMG, last.doseMG) }
                let plan = MedicationPlan(
                    id: last.id, route: last.route, ester: last.ester, doseMG: last.doseMG,
                    extras: last.extras, everyDays: intervalH / 24, remindersEnabled: false
                )
                return InferredRegimen(plan: plan, last: last.timeH, since: sinceH,
                    next: next?.timeH ?? last.timeH + intervalH, hormone: hormone(for: last.ester))
            }
        }
        let lastStartByHormone = Dictionary(inferred.map { ($0.hormone, $0.since) }, uniquingKeysWith: max)
        return inferred.filter { (lastStartByHormone[$0.hormone] ?? $0.since) <= $0.last }
            .sorted { $0.next < $1.next }.map(\.plan)
    }

    private static func clusters(from events: [DoseEvent]) -> [DoseCluster] {
        var clusters: [DoseCluster] = []
        for event in events {
            let best = clusters.indices.filter { similarAmount(event.doseMG, clusters[$0].mean) }.min {
                abs(event.doseMG - clusters[$0].mean) < abs(event.doseMG - clusters[$1].mean)
            }
            if let best {
                clusters[best].history.append(event)
                clusters[best].mean += (event.doseMG - clusters[best].mean) / Double(clusters[best].history.count)
            } else {
                clusters.append(DoseCluster(mean: event.doseMG, history: [event]))
            }
        }
        return clusters
    }

    private static func similarAmount(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= 0.1 * max(a, b)
    }

    private static func hormone(for ester: String) -> String {
        switch ester {
        case "T", "TC", "TE", "TU": "T"
        case "E2", "EB", "EV", "EC", "EN", "EU", "BICA": "E2"
        case "CPA", "SPIRO", "MPA", "LEUP", "TRIP": "AA"
        case "RLX": "SERM"
        default: "other"
        }
    }
}
