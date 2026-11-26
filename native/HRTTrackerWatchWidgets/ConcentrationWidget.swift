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
    var legacyClockDate: Date?
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
            return ConcentrationEntry(date: now, metric: metric, value: value, legacyClockDate: now)
        }
        let snapshot = WatchSnapshotCache.load()
        let metric = configuration.metric.resolve(primary: snapshot?.primaryMetric)
        return ConcentrationEntry(date: now, metric: metric, value: snapshot?.current(for: metric, at: now)?.value,
                                  legacyClockDate: now)
    }

    func timeline(for configuration: ConcentrationConfiguration, in context: Context) async -> Timeline<ConcentrationEntry> {
        let now = Date.now
        let snapshot = WatchSnapshotCache.load()
        let metric = configuration.metric.resolve(primary: snapshot?.primaryMetric)
        if #unavailable(watchOS 11), context.family == .accessoryRectangular {
            // watchOS 10 cannot archive a live currentDate text. Supply minute ticks for this family only.
            let nextMinute = floor(now.timeIntervalSinceReferenceDate / 60) * 60 + 60
            let ticks = (0..<60).map { Date(timeIntervalSinceReferenceDate: nextMinute + Double($0) * 60) }
            let horizon = Date(timeIntervalSinceReferenceDate: nextMinute + 3600)
            var dates = Set([now, horizon] + ticks)
            if let snapshot, now < snapshot.expiresAt {
                dates.insert(snapshot.expiresAt)
                dates.formUnion(snapshot.points(for: metric).map(\.time).filter { $0 > now && $0 < snapshot.expiresAt })
            }
            let entries = dates.sorted().map { date in
                ConcentrationEntry(date: date, metric: metric, value: snapshot?.current(for: metric, at: date)?.value,
                                   legacyClockDate: date < horizon ? date : nil)
            }
            return Timeline(entries: entries, policy: .after(horizon.addingTimeInterval(-900)))
        }
        let current = ConcentrationEntry(date: now, metric: metric, value: snapshot?.current(for: metric, at: now)?.value)
        guard let snapshot, now < snapshot.expiresAt else {
            return Timeline(entries: [current], policy: .never)
        }

        let updates = snapshot.points(for: metric).compactMap { point -> ConcentrationEntry? in
            guard now < point.time, point.time < snapshot.expiresAt else { return nil }
            return ConcentrationEntry(date: point.time, metric: metric, value: point.value)
        }
        let expired = ConcentrationEntry(date: snapshot.expiresAt, metric: metric, value: nil)
        return Timeline(entries: [current] + updates + [expired], policy: .never)
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
                layout(symbol: nil, number: "—", unit: nil)
                    .unredacted()
            } else {
                layout(
                    symbol: entry.metric.symbol, number: reading,
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
    private func layout(symbol: String?, number: String, unit: String?) -> some View {
        switch family {
        case .accessoryRectangular:
            RectangularReadout(symbol: symbol, number: number, unit: unit, legacyClockDate: entry.legacyClockDate)
        case .accessoryCircular:
            VStack(alignment: .leading, spacing: 0) {
                if let symbol {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(verbatim: symbol)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color(red: 223 / 255, green: 143 / 255, blue: 116 / 255))
                        if let unit {
                            Text(verbatim: unit)
                                .font(.system(size: 7.5, weight: .medium))
                        }
                    }
                    .minimumScaleFactor(0.85)
                    .widgetAccentable()
                }
                numberText(number, font: .system(size: 20, design: .rounded))
            }
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.primary)
            .background { AccessoryWidgetBackground() }
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

private struct RectangularReadout: View {
    let symbol: String?
    let number: String
    let unit: String?
    let legacyClockDate: Date?

    @ViewBuilder private var clock: some View {
        let format = Date.FormatStyle().hour(.defaultDigits(amPM: .omitted)).minute()
        if #available(watchOS 11, *) {
            Text(.currentDate, format: format)
        } else if let legacyClockDate {
            Text(legacyClockDate, format: format)
        }
    }

    var body: some View {
        GeometryReader { bounds in
            // Scale both columns together. The face already supplies the vertical space around the slot.
            let scale = min(bounds.size.width / 198.5, bounds.size.height / 65)
            ZStack(alignment: .leading) {
                if let symbol {
                    Text(verbatim: symbol)
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .offset(y: -21.3 * scale)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
                    Text(verbatim: number)
                        .font(.system(size: 24.5 * scale, weight: .semibold).monospacedDigit())
                        .tracking(0.4 * scale)
                        .minimumScaleFactor(0.65)
                    Spacer(minLength: 0)
                    clock
                        .font(.system(size: 27.1 * scale).monospacedDigit())
                        .tracking(-0.55 * scale)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 76 * scale, alignment: .trailing)
                }
                .fixedSize(horizontal: false, vertical: true)
                if let unit {
                    Text(verbatim: unit)
                        .font(.system(size: 8.7 * scale, weight: .medium))
                        .opacity(0.82)
                        .offset(y: 20.5 * scale)
                }
            }
            .lineLimit(1)
            .foregroundStyle(.primary)
            .widgetAccentable()
            .padding(.leading, 16.5 * scale)
            .padding(.trailing, 11.5 * scale)
            .frame(width: 198.5 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ReadoutBackground(cornerRadius: 10 * scale)
            }
        }
    }
}

private struct ReadoutBackground: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(renderingMode == .fullColor
                  ? Color(white: 0.31).opacity(0.38)
                  : Color.primary.opacity(0.14))
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
