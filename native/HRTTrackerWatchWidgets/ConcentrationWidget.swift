import AppIntents
import Foundation
import SwiftUI
import WidgetKit

enum WidgetMetric: String, AppEnum, CaseIterable {
    case automatic, e2, cpa, testosterone

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Metric", table: "WatchWidgets")
    )
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .automatic: DisplayRepresentation(title: LocalizedStringResource("Follow iPhone", table: "WatchWidgets")),
        .e2: DisplayRepresentation(title: LocalizedStringResource("Estradiol", table: "WatchWidgets")),
        .cpa: DisplayRepresentation(title: LocalizedStringResource("Cyproterone acetate", table: "WatchWidgets")),
        .testosterone: DisplayRepresentation(title: LocalizedStringResource("Testosterone", table: "WatchWidgets")),
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

struct ConcentrationConfiguration: WidgetConfigurationIntent {
    static let title = LocalizedStringResource("Current concentration", table: "WatchWidgets")

    @Parameter(title: LocalizedStringResource("Metric", table: "WatchWidgets"), default: .automatic)
    var metric: WidgetMetric

    init() {}

    init(metric: WidgetMetric) {
        self.metric = metric
    }
}

private struct ConcentrationEntry: TimelineEntry {
    let date: Date
    let metric: WatchMetric
    let value: Double?
    var recentRangePosition: Double? = nil
}

private struct ConcentrationProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ConcentrationEntry {
        ConcentrationEntry(date: .now, metric: .e2, value: nil)
    }

    func snapshot(for configuration: ConcentrationConfiguration, in context: Context) async -> ConcentrationEntry {
        let now = Date.now
        if context.isPreview {
            let metric = configuration.metric.resolve(primary: nil)
            let value: Double = switch metric {
            case .e2: 128
            case .cpa: 6.1
            case .testosterone: 1024
            }
            return ConcentrationEntry(date: now, metric: metric, value: value, recentRangePosition: 0.65)
        }
        let snapshot = WatchSnapshotCache.load()
        let metric = configuration.metric.resolve(primary: snapshot?.primaryMetric)
        return reading(for: metric, at: now, in: snapshot, family: context.family)
    }

    func timeline(for configuration: ConcentrationConfiguration, in context: Context) async -> Timeline<ConcentrationEntry> {
        let now = Date.now
        let snapshot = WatchSnapshotCache.load()
        let metric = configuration.metric.resolve(primary: snapshot?.primaryMetric)
        let current = reading(for: metric, at: now, in: snapshot, family: context.family)
        guard let snapshot, now < snapshot.expiresAt else {
            return Timeline(entries: [current], policy: .never)
        }

        let updates = snapshot.points(for: metric).compactMap { point -> ConcentrationEntry? in
            guard now < point.time, point.time < snapshot.expiresAt else { return nil }
            return reading(for: metric, at: point.time, in: snapshot, family: context.family)
        }
        let expired = ConcentrationEntry(date: snapshot.expiresAt, metric: metric, value: nil)
        return Timeline(entries: [current] + updates + [expired], policy: .never)
    }

    private func reading(for metric: WatchMetric, at date: Date, in snapshot: WatchSnapshot?,
                         family: WidgetFamily) -> ConcentrationEntry {
        let value = snapshot?.current(for: metric, at: date)?.value
        var entry = ConcentrationEntry(date: date, metric: metric, value: value)
        if family == .accessoryCircular, let snapshot, let value {
            let recent = snapshot.history(for: metric, at: date).map(\.value)
            if let low = recent.min(), let high = recent.max(), low < high {
                entry.recentRangePosition = (value - low) / (high - low)
            }
        }
        return entry
    }

    func recommendations() -> [AppIntentRecommendation<ConcentrationConfiguration>] {
        if #available(watchOS 26.0, *) { return [] }
        return WidgetMetric.allCases.map { metric in
            AppIntentRecommendation(
                intent: ConcentrationConfiguration(metric: metric),
                description: Text(WidgetMetric.caseDisplayRepresentations[metric]?.title ?? "Current concentration")
            )
        }
    }
}

private struct ConcentrationWidgetView: View {
    let entry: ConcentrationEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons

    private var isPrivate: Bool { redactionReasons.contains(.privacy) }
    private var reading: String { entry.value.map(entry.metric.formatted) ?? "—" }

    var body: some View {
        Group {
            if isPrivate {
                layout(name: Text("Concentration", tableName: "WatchWidgets"), symbol: nil, number: "—", unit: nil)
                    .unredacted()
            } else {
                layout(
                    name: Text(entry.metric.title), symbol: entry.metric.symbol, number: reading,
                    unit: entry.value == nil ? nil : entry.metric.unit
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .widgetURL(WatchRoute.url(for: isPrivate ? nil : entry.metric))
        .containerBackground(for: .widget) {
            Color(red: 0.15, green: 0.13, blue: 0.11)
        }
    }

    private var accessibilityDescription: Text {
        if isPrivate { return Text("Concentration hidden", tableName: "WatchWidgets") }
        let metric = String(localized: entry.metric.title)
        if entry.value == nil {
            return Text("No current \(metric) estimate", tableName: "WatchWidgets")
        }
        return Text("\(metric) model estimate, \(reading) \(entry.metric.unit)", tableName: "WatchWidgets")
    }

    @ViewBuilder
    private func layout(name: Text, symbol: String?, number: String, unit: String?) -> some View {
        switch family {
        case .accessoryCircular:
            let position = isPrivate ? nil : entry.recentRangePosition
            VStack(spacing: -2) {
                numberText(number, font: .system(size: 19, design: .rounded), weight: .semibold)
                if let symbol {
                    Text(symbol)
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .padding(.top, position == nil ? 0 : 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if let position {
                    RecentRangeArc(position: position)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.primary)
            .widgetAccentable()
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 3) {
                name
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .widgetAccentable()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    numberText(number, font: .title2)
                        .layoutPriority(1)
                    if let unit {
                        Text(unit)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryCorner:
            numberText(number, font: .headline)
                .widgetLabel {
                    if let symbol { Text(symbol) }
                }
        default:
            Text(symbol.map { "\($0) \(number)" } ?? number)
        }
    }

    private func numberText(_ number: String, font: Font, weight: Font.Weight = .medium) -> some View {
        Text(verbatim: number)
            .font(font.monospacedDigit().weight(weight))
            .lineLimit(1)
            .minimumScaleFactor(0.55)
    }
}

private struct RecentRangeArc: View {
    let position: Double

    var body: some View {
        let center = CGPoint(x: 15, y: 15)
        let radius: CGFloat = 13
        let start = -150.0
        let sweep = 120.0
        let angle = Angle.degrees(start + sweep * position).radians
        return Path { path in
            path.addArc(center: center, radius: radius, startAngle: .degrees(start),
                        endAngle: .degrees(start + sweep), clockwise: false)
        }
        .stroke(.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(.primary)
                .frame(width: 4, height: 4)
                .position(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        .frame(width: 30, height: 10)
    }
}

@main
struct ConcentrationWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "CurrentConcentration", intent: ConcentrationConfiguration.self,
                               provider: ConcentrationProvider()) { entry in
            ConcentrationWidgetView(entry: entry)
                .privacySensitive()
        }
        .configurationDisplayName(Text("Current concentration", tableName: "WatchWidgets"))
        .description(Text("Show the current model estimate for one concentration.", tableName: "WatchWidgets"))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
    }
}
