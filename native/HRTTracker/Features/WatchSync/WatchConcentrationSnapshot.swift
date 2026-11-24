import Foundation
import HRTEngine

struct PhoneWatchInputs: Equatable, Sendable {
    private static let forecastHours = 24.0
    private static let refreshInterval: TimeInterval = 6 * 3_600
    private static let sampleInterval: TimeInterval = 15 * 60

    let events: [DoseEvent]
    let labs: [LabResult]
    let mode: HRTMode
    let weight: Double
    let birthYear: Int?
    let parameters: PKParameters
    let method: CalibrationMethod
    let history: CalibrationHistoryMode
    let plans: [MedicationPlan]
    let planVersions: [String: String]
    let day: Date
    let timeZone: TimeZone
    let appLanguage: AppLanguage
    let refreshPeriod: Int

    @MainActor init(store: TrackerStore, at date: Date) {
        let hour = date.trackerHours
        events = store.doses.filter { $0.timeH <= hour }
        labs = store.labs.filter { $0.timeH <= hour }
        mode = store.mode
        weight = store.weight
        birthYear = store.ageModelEnabled ? store.birthYear : nil
        parameters = store.pkParameters
        method = store.calibrationMethod
        history = store.calibrationHistory
        plans = store.plans
        planVersions = store.watchPlanVersions
        let calendar = store.calendar
        day = calendar.startOfDay(for: date)
        timeZone = calendar.timeZone
        appLanguage = AppLanguage.selection
        refreshPeriod = Int(date.timeIntervalSince1970 / Self.refreshInterval)
    }

    var primaryMetric: WatchMetric { mode == .transmasc ? .testosterone : .e2 }

    static func expiration(after date: Date) -> Date { date.addingTimeInterval(forecastHours * 3_600) }

    func concentrationSeries(at date: Date) -> [WatchConcentrationSeries] {
        let now = date.trackerHours
        let end = now + Self.forecastHours
        let kinds: [ConcentrationSeries] = (mode == .transmasc ? [ConcentrationSeries.testosterone] : [.e2, .cpa])
            .filter { kind in events.contains(where: kind.canPlot) }
        guard !kinds.isEmpty, !Task.isCancelled,
              let model = HRTEngine.simulate(events: events, weight: weight, nowH: now, birthYear: birthYear,
                                             throughH: end, parameters: parameters),
              !Task.isCancelled else { return [] }
        let input = TimelineRequest(events: events, labs: labs, mode: mode, weight: weight, birthYear: birthYear,
                                    parameters: parameters, method: method, history: history, scheduled: [],
                                    now: now, range: .week)
        let calibration = kinds.contains(.e2) ? input.calibration(for: model, events: events) : nil
        guard !Task.isCancelled else { return [] }
        return kinds.compactMap { kind in
            guard let metric = WatchMetric(rawValue: kind.rawValue) else { return nil }
            let historical = TimelineModel.plotPoints(model, in: (now - 24)...now, series: kind,
                                                      calibration: calibration, limit: 72)
            // Past extrema are retained for the chart. Samples beyond now are
            // decay from recorded doses, including any still-active patches.
            let prior = historical.dropLast().map { (Date(trackerHours: $0.hour), $0.value) }
            let steps = Int(Self.forecastHours * 3_600 / Self.sampleInterval)
            let future = (0...steps).compactMap { step -> (Date, Double)? in
                let time = date.addingTimeInterval(Double(step) * Self.sampleInterval)
                return model.value(at: time.trackerHours).map { (time, kind.value($0, calibration: calibration)) }
            }
            let points = (prior + future).compactMap { time, value -> WatchConcentrationPoint? in
                guard value.isFinite, value >= 0 else { return nil }
                return WatchConcentrationPoint(time: time, value: value)
            }
            guard !points.isEmpty else { return nil }
            return WatchConcentrationSeries(metric: metric, points: points)
        }
    }
}
