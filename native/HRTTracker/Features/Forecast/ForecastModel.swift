import Foundation
import HRTEngine

struct ForecastDraft: Identifiable, Equatable, Sendable {
    let id: Int
    var plan: MedicationPlan
    var start: Date
    var replacesCurrent: Bool

    var isValid: Bool {
        plan.route == .patchApply ? plan.doseMG > 0 || (plan.extras["releaseRateUGPerDay"] ?? 0) > 0 : plan.doseMG > 0
    }
}

struct ForecastRegimen: Equatable, Sendable {
    let schedule: ScheduledMedication
    let matchingHistory: [Double]

    static func current(events: [DoseEvent], plans: [ScheduledMedication], now: Double) -> [Self] {
        func matches(_ event: DoseEvent, _ plan: MedicationPlan) -> Bool {
            event.route == plan.route && event.ester == plan.ester
        }

        let recent = events.filter { $0.timeH <= now && $0.timeH >= now - 42 * 24 && $0.route != .patchRemove }
        let explicit = plans.map { schedule -> Self in
            let fixed = events.filter { matches($0, schedule.plan) }.map(\.timeH)
            let latestFuture = fixed.filter { $0 > now }.max()
            let interval = schedule.plan.everyDays * 24 / Double(schedule.plan.dosesPerDay)
            let adjusted = ScheduledMedication(plan: schedule.plan,
                first: latestFuture.map { max(schedule.first, $0 + interval) } ?? schedule.first,
                timeZone: schedule.timeZone)
            return Self(schedule: adjusted, matchingHistory: fixed.filter { $0 <= now && $0 >= now - 42 * 24 }.sorted())
        }
        if !explicit.isEmpty { return explicit.sorted { $0.schedule.first < $1.schedule.first } }
        let inferred = Dictionary(grouping: recent, by: fingerprint).values.compactMap { group -> Self? in
            let doses = group.sorted { $0.timeH < $1.timeH }
            guard doses.count >= 3, let last = doses.last else { return nil }
            let times = doses.map(\.timeH)
            let gaps = zip(times, times.dropFirst()).map { $1 - $0 }.sorted()
            let mid = gaps.count / 2
            let typical = gaps.count.isMultiple(of: 2) ? (gaps[mid - 1] + gaps[mid]) / 2 : gaps[mid]
            let interval = typical >= 24 ? typical.rounded() : (typical * 2).rounded() / 2
            guard interval > 1, now - last.timeH <= interval * 2.5 + 12 else { return nil }
            let maximum = events.lazy.filter { $0.timeH > now && fingerprint($0) == fingerprint(last) }.map(\.timeH).max()
            let next = (maximum ?? last.timeH) + interval
            let first = next + max(0, ceil((now - next) / interval)) * interval
            let plan = MedicationPlan(id: last.id, route: last.route, ester: last.ester, doseMG: last.doseMG,
                                      extras: last.extras, everyDays: interval / 24, remindersEnabled: false)
            return Self(schedule: ScheduledMedication(plan: plan, first: first), matchingHistory: times)
        }
        return inferred.sorted {
            ($0.schedule.first, $0.schedule.plan.id) < ($1.schedule.first, $1.schedule.plan.id)
        }
    }

    private static func fingerprint(_ dose: DoseEvent) -> String {
        let keys = ["sublingualTier", "sublingualTheta", "gelSite", "releaseRateUGPerDay"]
        return ([dose.route.rawValue, dose.ester, String(dose.doseMG)]
            + keys.map { dose.extras[$0].map { String($0) } ?? "" }).joined(separator: "|")
    }

    var adherence: (missRate: Double, timingSpread: Double) {
        let gaps = zip(matchingHistory, matchingHistory.dropFirst()).map { $1 - $0 }
        let plan = schedule.plan
        let interval = plan.everyDays * 24 / Double(plan.dosesPerDay)
        guard !gaps.isEmpty, interval > 0 else { return (0, 0) }
        let counts = gaps.map { max(1, ($0 / interval).rounded()) }
        let offsets = zip(gaps, counts).map { $0 - $1 * interval }
        let mean = offsets.reduce(0, +) / Double(offsets.count)
        let variance = offsets.reduce(0) { $0 + pow($1 - mean, 2) } / Double(offsets.count)
        return (min(0.5, max(0, 1 - Double(gaps.count) / counts.reduce(0, +))), sqrt(variance / 2))
    }
}

struct ForecastRequest: Equatable, Sendable {
    let timeline: TimelineRequest
    let weeks: Int
    let drafts: [ForecastDraft]
    let regimens: [ForecastRegimen]
}

struct OutcomeBandPoint: Sendable {
    let hour: Double
    let low: Double
    let high: Double
}

struct ForecastMetrics: Sendable {
    let trough: Double
    let peak: Double
    let average: Double
    let inTarget: Double?

    init?(_ points: [PlotPoint], target: ClosedRange<Double>?) {
        guard points.count >= 2, let first = points.first, let last = points.last, last.hour > first.hour else { return nil }
        trough = points.map(\.value).min() ?? 0
        peak = points.map(\.value).max() ?? 0
        let span = last.hour - first.hour
        var area = 0.0
        var inside = 0.0
        for (start, end) in zip(points, points.dropFirst()) {
            let midpoint = (start.value + end.value) / 2
            let duration = end.hour - start.hour
            area += midpoint * duration
            if target?.contains(midpoint) == true { inside += duration }
        }
        average = area / span
        inTarget = target.map { _ in inside / span }
    }
}

struct ForecastOutcome: Identifiable, Sendable {
    let id: Int
    let expected: [PlotPoint]
    let band: [OutcomeBandPoint]
    let metrics: ForecastMetrics?
    let steadyHour: Double?
    let runs: Int
}

struct ForecastResult: Sendable {
    let series: ConcentrationSeries
    let now: Double
    let end: Double
    let history: [PlotPoint]
    let outcomes: [ForecastOutcome]
    let missRate: Double
    let timingSpread: Double

    static func calculate(_ input: ForecastRequest) -> Self? {
        let request = input.timeline
        let now = request.now
        let end = now + Double(input.weeks * 7 * 24)
        let series: ConcentrationSeries = request.mode == .transfem ? .e2 : .testosterone
        let actual = request.events
        let recorded = HRTEngine.simulate(events: actual, weight: request.weight, nowH: now,
                                          birthYear: request.birthYear, parameters: request.parameters)
        let calibration = recorded.flatMap { request.calibration(for: $0, events: actual) }
        let history = recorded.map {
            TimelineModel.plotPoints($0, in: (now - 14 * 24)...now, series: series, calibration: calibration)
        } ?? []
        let primary = input.regimens.filter { regimen in
            let plan = regimen.schedule.plan
            return series.canPlot(DoseEvent(route: plan.route, timeH: now, doseMG: plan.doseMG,
                                           ester: plan.ester, extras: plan.extras))
        }.max { $0.schedule.plan.everyDays < $1.schedule.plan.everyDays }
        let habits = primary?.adherence ?? (0, 0)
        let projected = input.regimens.flatMap { $0.schedule.events(through: end, prefix: "baseline") }
        let cases: [ForecastDraft?] = [nil] + input.drafts.map(Optional.some)
        let outcomes = cases.compactMap { draft -> ForecastOutcome? in
            guard !Task.isCancelled else { return nil }
            if let draft, !draft.isValid || draft.start.trackerHours > end { return nil }
            let start = draft.map { max(now, $0.start.trackerHours) } ?? primary?.matchingHistory.first ?? now
            let replaced: (DoseEvent) -> Bool = { event in
                draft?.replacesCurrent == true && event.timeH >= start && series.matches(event)
            }
            let fixed = actual.filter { !replaced($0) }
            let added = draft.map { ScheduledMedication(plan: $0.plan, first: start)
                .events(through: end, prefix: "forecast-\($0.id)") } ?? []
            let future = projected.filter { !replaced($0) } + added
            let cycle = max(24, (draft?.plan.everyDays ?? primary?.schedule.plan.everyDays ?? 1) * 24)
            return outcome(id: draft?.id ?? 0, request: request, series: series, fixed: fixed, future: future,
                           start: start, end: end, calibration: calibration, habits: habits, cycle: cycle)
        }
        guard !Task.isCancelled, !outcomes.isEmpty else { return nil }
        return Self(series: series, now: now, end: end, history: history, outcomes: outcomes,
                    missRate: habits.0, timingSpread: habits.1)
    }

    private static func outcome(
        id: Int, request: TimelineRequest, series: ConcentrationSeries, fixed: [DoseEvent], future: [DoseEvent],
        start: Double, end: Double, calibration: Calibration?, habits: (missRate: Double, timingSpread: Double),
        cycle: Double
    ) -> ForecastOutcome? {
        let events = fixed + future
        guard events.contains(where: series.canPlot),
              let simulation = HRTEngine.simulate(events: fixed, weight: request.weight, nowH: request.now,
                                                 birthYear: request.birthYear, throughH: end, parameters: request.parameters,
                                                 projectedEvents: future) else { return nil }
        let scenarioCalibration = request.calibration(for: simulation, events: fixed, projectedEvents: future)
        let window = request.now...end
        let expected = TimelineModel.plotPoints(simulation, in: window, series: series,
                                               calibration: scenarioCalibration, limit: 700)
        let statStart = max(request.now, end - max(7 * 24, cycle))
        let stats = TimelineModel.plotPoints(simulation, in: statStart...end, series: series,
                                            calibration: scenarioCalibration, limit: .max)
        let metrics = ForecastMetrics(stats, target: series.target)
        let steadyHour = steadyState(simulation, start: start, end: end, cycle: cycle,
                                     series: series, calibration: scenarioCalibration)
        let sigma = log1p(max(0, calibration?.fitErrPct ?? 0) / 100)
        let hasPosterior = scenarioCalibration?.factorSD(at: request.now) != nil
        guard hasPosterior || sigma > 0 || (habits.missRate > 0 || habits.timingSpread > 0) && !future.isEmpty else {
            return ForecastOutcome(id: id, expected: expected, band: [], metrics: metrics, steadyHour: steadyHour, runs: 1)
        }

        let grid = Array(stride(from: request.now, through: end, by: 1))
        let deviations = hasPosterior ? grid.map { scenarioCalibration?.factorSD(at: $0) ?? sigma } :
                                        Array(repeating: sigma, count: grid.count)
        var perHour = grid.map { _ in [Double]() }
        let recent = fixed.filter { $0.timeH >= request.now - 120 * 24 }
        var random = ForecastNoise(seed: UInt64(id + 1) + UInt64(max(0, request.now.rounded(.down))))
        var runs = 0
        for _ in 0..<48 {
            guard !Task.isCancelled else { return nil }
            let draw = random.normal()
            let shifted = future.compactMap { event -> DoseEvent? in
                guard random.uniform() >= habits.missRate else { return nil }
                var event = event
                let jitter = habits.timingSpread * random.normal()
                event.timeH = max(request.now, event.timeH + min(cycle / 3, max(-cycle / 3, jitter)))
                return event
            }
            guard let run = HRTEngine.simulate(events: recent, weight: request.weight, nowH: request.now,
                                               birthYear: request.birthYear, throughH: end, parameters: request.parameters,
                                               projectedEvents: shifted) else { continue }
            for (index, hour) in grid.enumerated() {
                if let sample = run.value(at: hour) {
                    perHour[index].append(series.value(sample, calibration: scenarioCalibration) * exp(deviations[index] * draw))
                }
            }
            runs += 1
        }
        let band: [OutcomeBandPoint] = runs < 24 ? [] : zip(grid, perHour).compactMap { hour, values in
            let ordered = values.sorted()
            guard !ordered.isEmpty else { return nil }
            func percentile(_ fraction: Double) -> Double {
                let offset = Double(ordered.count - 1) * fraction
                let low = Int(offset), high = Int(ceil(offset))
                return ordered[low] + (ordered[high] - ordered[low]) * (offset - Double(low))
            }
            return OutcomeBandPoint(hour: hour, low: percentile(0.1), high: percentile(0.9))
        }
        return ForecastOutcome(id: id, expected: expected, band: band, metrics: metrics, steadyHour: steadyHour, runs: runs)
    }

    private static func steadyState(
        _ simulation: Simulation, start: Double, end: Double, cycle: Double,
        series: ConcentrationSeries, calibration: Calibration?
    ) -> Double? {
        guard start + cycle * 2 <= end else { return nil }
        let snapshots = stride(from: start, through: end - cycle, by: cycle).compactMap { hour -> (Double, ForecastMetrics)? in
            let points = TimelineModel.plotPoints(simulation, in: hour...(hour + cycle), series: series,
                                                 calibration: calibration, limit: .max)
            return ForecastMetrics(points, target: nil).map { (hour + cycle, $0) }
        }
        guard let last = snapshots.last?.1 else { return nil }
        return snapshots.dropLast().first { _, sample in
            abs(sample.trough - last.trough) <= 0.05 * max(last.trough, 1e-9) &&
            abs(sample.peak - last.peak) <= 0.05 * max(last.peak, 1e-9)
        }?.0
    }
}

private struct ForecastNoise {
    var seed: UInt64

    mutating func uniform() -> Double {
        seed = 2_862_933_555_777_941_757 &* seed &+ 3_037_000_493
        return (Double(seed >> 12) + 0.5) / 4_503_599_627_370_496
    }

    mutating func normal() -> Double {
        let first = uniform()
        return sqrt(-2 * log(first)) * cos(2 * .pi * uniform())
    }
}
