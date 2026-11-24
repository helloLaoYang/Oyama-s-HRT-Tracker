import Foundation

public extension HRTEngine {
    /// Whether the default Web model can estimate a concentration from this entry.
    static func supportsConcentration(_ event: DoseEvent) -> Bool {
        guard event.route != .patchRemove, event.timeH.isFinite, event.doseMG.isFinite,
              let hormone = Hormone(ester: event.ester) else { return false }
        let model = RouteParameters.model(
            event, hormone: hormone, weightFactor: 1, birthYear: nil, parameters: .init(),
            wear: PatchWear.planned(event) ?? .greatestFiniteMagnitude
        )
        return model.deliversConcentration
    }

    /// Concentration units are pg/mL for E2, ng/mL for CPA, and ng/dL for testosterone.
    /// The grid contains the current time, each dose, and a denser set of samples after each dose.
    /// Pass synthetic doses separately so they cannot change the pairing of recorded patch removals.
    static func simulate(
        events: [DoseEvent], weight: Double, nowH: Double, birthYear: Int? = nil, throughH: Double? = nil,
        parameters: PKParameters = .init(), projectedEvents: [DoseEvent] = []
    ) -> Simulation? {
        guard weight.isFinite, weight > 0, nowH.isFinite else { return nil }
        let birthYear = plausibleBirthYear(birthYear, nowH: nowH)
        let recorded = modeledEvents(events)
        let events = recorded + modeledEvents(projectedEvents)
        let eventTimes = events.map(\.timeH)
        guard let first = eventTimes.min(), let last = eventTimes.max() else { return nil }
        let models = makeModels(events, recordedCount: recorded.count, weight: weight, birthYear: birthYear, parameters: parameters)
        let requestedEnd = throughH.flatMap { $0.isFinite ? $0 : nil }
        let start = first - 24
        let end = max(last + 24 * 14, nowH + 24, requestedEnd ?? -.infinity)
        let steps = Int(min(100_000, max(2_000, ceil(end - start))))
        let stepSize = (end - start) / Double(steps - 1)
        var times = Set((0..<steps).map { start + Double($0) * stepSize })
        times.formUnion(eventTimes)
        for model in models {
            for offset in [0.25, 0.5, 0.75, 1, 2, 4, 6, 8, 12, 24, 48] {
                if offset > model.lifetime { break }
                let time = model.dose.timeH + offset
                if start <= time && time <= end { times.insert(time) }
            }
        }
        if start <= nowH && nowH <= end { times.insert(nowH) }
        if let requestedEnd, start <= requestedEnd { times.insert(requestedEnd) }

        var points: [CurveSample] = []
        points.reserveCapacity(times.count)
        var active: [KineticModel] = []
        var next = 0
        var auc = 0.0
        for time in times.sorted() {
            while next < models.count && models[next].dose.timeH <= time {
                active.append(models[next])
                next += 1
            }
            var index = 0
            while index < active.count {
                if time - active[index].dose.timeH > active[index].lifetime {
                    active.swapAt(index, active.count - 1)
                    active.removeLast()
                } else {
                    index += 1
                }
            }
            let point = concentrations(active, at: time, weight: weight)
            if let previous = points.last {
                auc += 0.5 * (point.e2 + previous.e2) * (point.timeH - previous.timeH)
            }
            points.append(point)
        }
        return Simulation(points: points, auc: auc, nowH: nowH, throughH: requestedEnd, birthYear: birthYear, parameters: parameters)
    }

    /// Analytic concentration at one time without gridding or expiration of negligible tails.
    static func exactConcentration(
        events: [DoseEvent], weight: Double, at timeH: Double, birthYear: Int? = nil,
        parameters: PKParameters = .init(), projectedEvents: [DoseEvent] = []
    ) -> CurveSample? {
        guard weight.isFinite, weight > 0, timeH.isFinite else { return nil }
        let recorded = modeledEvents(events)
        let events = recorded + modeledEvents(projectedEvents)
        guard !events.isEmpty else { return nil }
        let plausibleYear = plausibleBirthYear(birthYear, nowH: timeH)
        let active = makeModels(events, recordedCount: recorded.count, weight: weight, birthYear: plausibleYear, parameters: parameters)
            .filter { $0.dose.timeH <= timeH }
        return concentrations(active, at: timeH, weight: weight)
    }

    private static func modeledEvents(_ events: [DoseEvent]) -> [DoseEvent] {
        events.filter {
            Hormone(ester: $0.ester) != nil && $0.timeH.isFinite && $0.doseMG.isFinite
        }
    }

    private static func plausibleBirthYear(_ year: Int?, nowH: Double) -> Int? {
        guard let year, year >= 1900 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let currentYear = calendar.component(.year, from: Date(timeIntervalSince1970: nowH * 3_600))
        return year <= currentYear ? year : nil
    }

    private static func makeModels(
        _ events: [DoseEvent], recordedCount: Int, weight: Double, birthYear: Int?, parameters: PKParameters
    ) -> [KineticModel] {
        let pairings = PatchWear.removals(for: events, recordedCount: recordedCount)
        let weightRatio = max(1, weight) / 70
        let weightFactor = pow(weightRatio, 0.75) / weightRatio
        return events.indices.sorted { events[$0].timeH < events[$1].timeH }.compactMap { index in
            let event = events[index]
            guard event.route != .patchRemove, let hormone = Hormone(ester: event.ester) else { return nil }
            let wear = pairings[index].map { $0 - event.timeH } ?? PatchWear.planned(event) ?? .greatestFiniteMagnitude
            return RouteParameters.model(event, hormone: hormone, weightFactor: weightFactor, birthYear: birthYear, parameters: parameters, wear: wear)
        }
    }

    private static func concentrations(_ models: [KineticModel], at timeH: Double, weight: Double) -> CurveSample {
        var e2 = 0.0
        var cpa = 0.0
        var testosterone = 0.0
        for model in models {
            let amount = model.amount(at: timeH)
            switch model.hormone {
            case .e2: e2 += amount
            case .cpa: cpa += amount
            case .testosterone: testosterone += amount
            }
        }
        return CurveSample(
            timeH: timeH,
            e2: e2 * 1e9 / (2 * weight * 1_000),
            cpa: cpa * 1e6 / (14 * weight * 1_000),
            testosterone: testosterone * 1e8 / (weight * 1_000)
        )
    }
}

// TS: src/domain/shared/patch.ts. Pair by event index so imported duplicate IDs remain distinct.
private enum PatchWear {
    static func planned(_ event: DoseEvent) -> Double? {
        guard let wear = event.extras["patchWearH"], wear.isFinite, wear > 0 else { return nil }
        return wear
    }

    static func removals(for events: [DoseEvent], recordedCount: Int) -> [Int: Double] {
        let recorded = events.prefix(recordedCount)
        let recordedRemovals = recorded.filter { $0.route == .patchRemove }
        var pairs = pair(events, applications: recorded.indices.filter { events[$0].route == .patchApply }, removals: recordedRemovals)
        let projectedRemovals = events.dropFirst(recordedCount).filter { $0.route == .patchRemove }
        if !projectedRemovals.isEmpty {
            // A hypothetical removal can end an available patch. Recorded matches already have a known end.
            let available = events.indices.filter { events[$0].route == .patchApply && pairs[$0] == nil }
            pairs.merge(pair(events, applications: available, removals: projectedRemovals)) { recorded, _ in recorded }
        }
        return pairs
    }

    private static func pair(_ events: [DoseEvent], applications: [Int], removals: [DoseEvent]) -> [Int: Double] {
        guard !removals.isEmpty else { return [:] }
        let applications = applications.sorted { comesFirst(events[$0], events[$1]) }
        let removals = removals.sorted { lhs, rhs in
            if lhs.timeH != rhs.timeH { return lhs.timeH < rhs.timeH }
            return rank(lhs) < rank(rhs)
        }
        var pairs: [Int: Double] = [:]
        var open: [Int] = []
        var next = 0

        for removal in removals {
            while next < applications.count && events[applications[next]].timeH <= removal.timeH - 1 {
                open.append(applications[next])
                next += 1
            }
            open.removeAll { index in
                let event = events[index]
                guard let wear = planned(event) else { return false }
                return event.timeH + wear + 24 < removal.timeH
            }
            let hormone = rank(removal)
            func fits(_ index: Int) -> Bool { hormone == 2 || rank(events[index]) == hormone }
            if let paired = open.firstIndex(where: fits) {
                pairs[open.remove(at: paired)] = removal.timeH
                continue
            }
            guard let last = applications[..<next].lastIndex(where: fits) else { continue }
            var first = last
            while first > 0 && events[applications[first - 1]].timeH == events[applications[last]].timeH {
                first -= 1
            }
            for index in applications[first...last] where fits(index) && pairs[index] == nil {
                let event = events[index]
                if removal.timeH > event.timeH + (planned(event) ?? 0) + 240 { continue }
                pairs[index] = removal.timeH
                break
            }
        }
        return pairs
    }

    private static func rank(_ event: DoseEvent) -> Int {
        switch Hormone(ester: event.ester) {
        case .e2: return 0
        case .testosterone: return 1
        default: return 2
        }
    }

    private static func comesFirst(_ lhs: DoseEvent, _ rhs: DoseEvent) -> Bool {
        if lhs.timeH != rhs.timeH { return lhs.timeH < rhs.timeH }
        let leftWear = planned(lhs) ?? .infinity
        let rightWear = planned(rhs) ?? .infinity
        if leftWear != rightWear { return leftWear < rightWear }
        if lhs.doseMG != rhs.doseMG { return lhs.doseMG < rhs.doseMG }
        let leftRelease = lhs.extras["releaseRateUGPerDay"] ?? 0
        let rightRelease = rhs.extras["releaseRateUGPerDay"] ?? 0
        if leftRelease != rightRelease { return leftRelease < rightRelease }
        if lhs.ester != rhs.ester { return lhs.ester < rhs.ester }
        return lhs.id < rhs.id
    }
}
