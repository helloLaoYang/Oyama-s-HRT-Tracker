import AppIntents
import Foundation
import WidgetKit

enum PhoneWidgetMetric: String, AppEnum {
    case automatic, e2, cpa, testosterone

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Metric", table: "PhoneWidgets")
    )
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .automatic: DisplayRepresentation(title: LocalizedStringResource("Follow app's main metric", table: "PhoneWidgets")),
        .e2: DisplayRepresentation(title: LocalizedStringResource("Estradiol", table: "WatchMetrics")),
        .cpa: DisplayRepresentation(title: LocalizedStringResource("Cyproterone acetate", table: "WatchMetrics")),
        .testosterone: DisplayRepresentation(title: LocalizedStringResource("Testosterone", table: "WatchMetrics")),
    ]

    func resolve(primary: WatchMetric?) -> WatchMetric {
        switch self {
        case .automatic: primary ?? .e2
        case .e2: .e2
        case .cpa: .cpa
        case .testosterone: .testosterone
        }
    }
}

struct PhoneConcentrationConfiguration: WidgetConfigurationIntent {
    static let title = LocalizedStringResource("Concentration estimate", table: "PhoneWidgets")

    @Parameter(title: LocalizedStringResource("Metric", table: "PhoneWidgets"), default: .automatic)
    var metric: PhoneWidgetMetric

    @Parameter(title: LocalizedStringResource("Show estimate on Lock Screen", table: "PhoneWidgets"),
               default: false)
    var showOnLockScreen: Bool

    static var parameterSummary: some ParameterSummary {
        When(widgetFamily: .oneOf, [.accessoryCircular, .accessoryRectangular]) {
            Summary {
                \.$metric
                \.$showOnLockScreen
            }
        } otherwise: {
            Summary { \.$metric }
        }
    }
}

struct PhoneConcentrationEntry: TimelineEntry {
    enum Reading {
        case placeholder, empty, expired
        case estimate(WatchConcentrationPoint, history: [WatchConcentrationPoint])
    }

    let date: Date
    let metric: WatchMetric
    let reading: Reading
    let showOnLockScreen: Bool
    let isPreview: Bool

    var point: WatchConcentrationPoint? {
        guard case .estimate(let point, _) = reading else { return nil }
        return point
    }
}

struct PhoneConcentrationProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PhoneConcentrationEntry {
        PhoneConcentrationEntry(date: .now, metric: .e2, reading: .placeholder,
                                showOnLockScreen: false, isPreview: false)
    }

    func snapshot(for configuration: PhoneConcentrationConfiguration, in context: Context) async -> PhoneConcentrationEntry {
        let date = Date.now
        if context.isPreview {
            return preview(at: date, metric: configuration.metric.resolve(primary: nil))
        }
        return entry(at: date, configuration: configuration, snapshot: PhoneWidgetSnapshotCache.load())
    }

    func timeline(for configuration: PhoneConcentrationConfiguration, in context: Context) async -> Timeline<PhoneConcentrationEntry> {
        let now = Date.now
        let snapshot = PhoneWidgetSnapshotCache.load()
        let current = entry(at: now, configuration: configuration, snapshot: snapshot)
        guard let snapshot, now < snapshot.expiresAt else {
            return Timeline(entries: [current], policy: .never)
        }

        let sampleDates = snapshot.points(for: current.metric).map(\.time)
            .filter { now < $0 && $0 < snapshot.expiresAt }
        let entries = ([now] + sampleDates + [snapshot.expiresAt]).map {
            entry(at: $0, configuration: configuration, snapshot: snapshot)
        }
        return Timeline(entries: entries, policy: .never)
    }

    private func entry(at date: Date, configuration: PhoneConcentrationConfiguration,
                       snapshot: PhoneWidgetSnapshot?) -> PhoneConcentrationEntry {
        let metric = configuration.metric.resolve(primary: snapshot?.primaryMetric)
        let reading: PhoneConcentrationEntry.Reading
        if let snapshot, date >= snapshot.expiresAt {
            reading = .expired
        } else if let snapshot, let point = snapshot.current(for: metric, at: date) {
            reading = .estimate(point, history: snapshot.history(for: metric, at: date))
        } else {
            reading = .empty
        }

        return PhoneConcentrationEntry(date: date, metric: metric, reading: reading,
                                       showOnLockScreen: configuration.showOnLockScreen, isPreview: false)
    }

    private func preview(at date: Date, metric: WatchMetric) -> PhoneConcentrationEntry {
        let values: [Double] = switch metric {
        case .e2: [91, 101, 98, 168, 157, 141, 134, 128]
        case .cpa: [6.9, 6.2, 5.8, 5.4, 7.7, 7.1, 6.6, 6.1]
        case .testosterone: [845, 817, 789, 768, 1_200, 1_130, 1_082, 1_024]
        }
        let history = values.enumerated().map { index, value in
            let hoursAgo = 24 * Double(values.count - 1 - index) / Double(values.count - 1)
            return WatchConcentrationPoint(time: date.addingTimeInterval(-hoursAgo * 3_600), value: value)
        }
        return PhoneConcentrationEntry(date: date, metric: metric,
                                       reading: history.last.map { .estimate($0, history: history) } ?? .empty,
                                       showOnLockScreen: true, isPreview: true)
    }
}
