import Foundation
import HRTEngine

enum ConcentrationSeries: String, Sendable {
    case e2, cpa, testosterone

    var name: String {
        switch self {
        case .e2: label("Estradiol")
        case .cpa: label("Cyproterone acetate")
        case .testosterone: label("Testosterone")
        }
    }

    var unit: String {
        switch self {
        case .e2: "pg/mL"
        case .cpa: "ng/mL"
        case .testosterone: "ng/dL"
        }
    }

    var target: ClosedRange<Double>? {
        switch self {
        case .e2: 100...200
        case .testosterone: 300...1000
        case .cpa: nil
        }
    }

    var comparisonRange: ClosedRange<Double>? {
        switch self {
        case .e2: 10...1000
        case .testosterone: 30...3000
        case .cpa: nil
        }
    }

    var axisFloor: Double {
        switch self {
        case .e2: 20
        case .testosterone: 100
        case .cpa: 1
        }
    }

    func matches(_ event: DoseEvent) -> Bool {
        switch self {
        case .e2: ["E2", "EB", "EV", "EC", "EN", "EU"].contains(event.ester)
        case .cpa: event.ester == "CPA"
        case .testosterone: ["T", "TC", "TE", "TU"].contains(event.ester)
        }
    }

    func canPlot(_ event: DoseEvent) -> Bool {
        matches(event) && HRTEngine.supportsConcentration(event)
    }

    func value(_ sample: CurveSample, calibration: Calibration?) -> Double {
        switch self {
        case .e2: sample.e2 * (calibration?.factor(at: sample.timeH) ?? 1)
        case .cpa: sample.cpa
        case .testosterone: sample.testosterone
        }
    }

    func measuredValue(_ lab: LabResult) -> Double? {
        let normalized = lab.unit.lowercased()
        switch self {
        case .e2:
            if normalized == "pg/ml" { return lab.concValue }
            if normalized == "pmol/l" { return lab.concValue / 3.671 }
        case .testosterone:
            if normalized == "ng/dl" { return lab.concValue }
            if normalized == "nmol/l" { return lab.concValue * 28.842 }
            if normalized == "ng/ml" { return lab.concValue * 100 }
        case .cpa:
            return nil
        }
        return nil
    }

    func formatted(_ value: Double) -> String {
        let precision = self == .cpa ? 2 : 1
        return value.formatted(.number.precision(.fractionLength(precision)))
    }
}

struct ScheduledMedication: Equatable, Sendable {
    let plan: MedicationPlan
    let first: Double
    var timeZone: TimeZone = .current

    func events(through limit: Double, prefix: String) -> [DoseEvent] {
        let interval = max(1.0 / 60, plan.everyDays * 24)
        let origin = Date(trackerHours: first)
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let offsets: [Double]
        if plan.everyDays == 1, plan.reminderMinutes.count > 1 {
            let startOfDay = calendar.startOfDay(for: origin).trackerHours
            let minutes = plan.reminderMinutes.sorted()
            offsets = minutes.map { minute in
                let hours = startOfDay + Double(minute) / 60 - first
                return hours >= -0.00001 ? max(0, hours) : hours + 24
            }
        } else {
            offsets = [0]
        }
        return offsets.enumerated().flatMap { index, offset in
            let start = first + offset
            guard start <= limit else { return [DoseEvent]() }
            return stride(from: start, through: limit, by: interval).prefix(1000).enumerated().map { count, time in
                DoseEvent(id: "\(prefix)-\(plan.id)-\(index)-\(count)", route: plan.route, timeH: time,
                          doseMG: plan.doseMG, ester: plan.ester, extras: plan.extras)
            }
        }
    }
}

enum TrackerChartRange: CaseIterable, Sendable {
    case week, month, all

    var hours: Double? {
        switch self {
        case .week: 168
        case .month: 720
        case .all: nil
        }
    }
}

struct TimelineRequest: Equatable, Sendable {
    let events: [DoseEvent]
    let labs: [LabResult]
    let mode: HRTMode
    let weight: Double
    let birthYear: Int?
    let method: CalibrationMethod
    let history: CalibrationHistoryMode
    let scheduled: [ScheduledMedication]
    let now: Double
    let range: TrackerChartRange
}

struct PlotPoint: Sendable {
    let hour: Double
    let value: Double
}

struct TimelineTrace: Sendable {
    let kind: ConcentrationSeries
    let past: [PlotPoint]
    let future: [PlotPoint]
    let doses: [PlotPoint]
    let measurements: [PlotPoint]
}

struct TimelineModel: Sendable {
    let now: Double
    let window: ClosedRange<Double>
    let traces: [TimelineTrace]
    let recorded: Simulation
    let projected: Simulation?
    let calibration: Calibration?
    let projectedCalibration: Calibration?
    let futureUsesPlan: Bool
    let futureUsesRecords: Bool

    func value(_ series: ConcentrationSeries, at hour: Double) -> Double? {
        let usesProjection = hour > now && projected != nil
        let simulation = usesProjection ? projected ?? recorded : recorded
        if let first = simulation.points.first, hour < first.timeH { return 0 }
        return simulation.value(at: hour).map { series.value($0, calibration: usesProjection ? projectedCalibration : calibration) }
    }

    static func calculate(_ request: TimelineRequest) -> Self? {
        let now = request.now
        guard !Task.isCancelled, let recorded = HRTEngine.simulate(
            events: request.events, weight: request.weight, nowH: now, birthYear: request.birthYear
        ), let modelEnd = recorded.points.last?.timeH else { return nil }
        let first = min(now, request.events.map(\.timeH).min() ?? now) - 24
        let span = request.range.hours ?? modelEnd - first
        let chartStart = max(first, min(now - span / 2, modelEnd - span))
        let chartEnd = min(modelEnd, chartStart + span)
        let calibration = request.calibration(for: recorded, events: request.events)
        guard !Task.isCancelled else { return nil }
        let scheduled = request.scheduled.flatMap { $0.events(through: chartEnd, prefix: "timeline") }
            .filter(HRTEngine.supportsConcentration)
        let projected = scheduled.isEmpty ? nil : HRTEngine.simulate(
            events: request.events, weight: request.weight, nowH: now,
            birthYear: request.birthYear, throughH: chartEnd, projectedEvents: scheduled
        )
        let projectedCalibration = projected.flatMap {
            request.calibration(for: $0, events: request.events, projectedEvents: scheduled)
        }
        let series: [ConcentrationSeries] = request.mode == .transmasc ? [.testosterone] : [.e2, .cpa]
        let window = chartStart...chartEnd
        let traces = series.compactMap { kind -> TimelineTrace? in
            let doses = request.events.filter(kind.canPlot)
            guard !doses.isEmpty || scheduled.contains(where: kind.canPlot) else { return nil }

            let past = plotPoints(recorded, in: chartStart...now, series: kind, calibration: calibration)
            var future = plotPoints(projected ?? recorded, in: now...chartEnd, series: kind,
                                    calibration: projected == nil ? calibration : projectedCalibration)
            if let last = past.last, !future.isEmpty { future[0] = last }
            return TimelineTrace(
                kind: kind, past: past, future: future,
                doses: doses.compactMap { dose in
                    guard window.contains(dose.timeH),
                          let value = (dose.timeH > now ? projected ?? recorded : recorded).value(at: dose.timeH)
                    else { return nil }
                    let fit = dose.timeH > now && projected != nil ? projectedCalibration : calibration
                    return PlotPoint(hour: dose.timeH, value: kind.value(value, calibration: fit))
                },
                measurements: request.labs.compactMap { lab in
                    guard window.contains(lab.timeH), let value = kind.measuredValue(lab) else { return nil }
                    return PlotPoint(hour: lab.timeH, value: value)
                }
            )
        }
        return Self(now: now, window: window, traces: traces, recorded: recorded, projected: projected,
                    calibration: calibration, projectedCalibration: projectedCalibration, futureUsesPlan: !scheduled.isEmpty,
                    futureUsesRecords: request.events.contains {
                        $0.timeH > now && window.contains($0.timeH) && HRTEngine.supportsConcentration($0)
                    })
    }

    static func plotPoints(
        _ model: Simulation, in window: ClosedRange<Double>,
        series: ConcentrationSeries, calibration: Calibration? = nil, limit: Int = 440
    ) -> [PlotPoint] {
        var points = model.points.filter { $0.timeH > window.lowerBound && $0.timeH < window.upperBound }
        if let first = model.value(at: window.lowerBound) {
            points.insert(CurveSample(timeH: window.lowerBound, e2: window.lowerBound < model.points[0].timeH ? 0 : first.e2,
                                      cpa: window.lowerBound < model.points[0].timeH ? 0 : first.cpa,
                                      testosterone: window.lowerBound < model.points[0].timeH ? 0 : first.testosterone), at: 0)
        }
        if let last = model.value(at: window.upperBound) {
            points.append(CurveSample(timeH: window.upperBound, e2: last.e2, cpa: last.cpa, testosterone: last.testosterone))
        }
        let values = points.map { PlotPoint(hour: $0.timeH, value: series.value($0, calibration: calibration)) }
        return preserveExtrema(values, limit: limit)
    }

    private static func preserveExtrema(_ points: [PlotPoint], limit: Int) -> [PlotPoint] {
        guard points.count > limit, let first = points.first, let last = points.last else { return points }
        let step = Int(ceil(Double(points.count - 2) / Double(limit / 2 - 1)))
        var reduced = [first]
        for start in stride(from: 1, to: points.count - 1, by: step) {
            let bucket = points[start..<min(start + step, points.count - 1)]
            guard let low = bucket.min(by: { $0.value < $1.value }),
                  let high = bucket.max(by: { $0.value < $1.value }) else { continue }
            if low.hour == high.hour {
                reduced.append(low)
            } else {
                reduced.append(contentsOf: low.hour < high.hour ? [low, high] : [high, low])
            }
        }
        reduced.append(last)
        return reduced
    }
}

extension TimelineRequest {
    func calibration(for simulation: Simulation, events: [DoseEvent], projectedEvents: [DoseEvent] = []) -> Calibration? {
        guard mode == .transfem, method != .off else { return nil }
        return HRTEngine.calibrate(simulation: simulation, events: events, weight: weight, labs: labs,
                                   method: method, history: history, birthYear: birthYear,
                                   projectedEvents: projectedEvents)
    }
}
