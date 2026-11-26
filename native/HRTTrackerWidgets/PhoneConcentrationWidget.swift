import SwiftUI
import WidgetKit

@main
struct PhoneConcentrationWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: PhoneWidgetSnapshotCache.kind, intent: PhoneConcentrationConfiguration.self,
                               provider: PhoneConcentrationProvider()) { entry in
            PhoneConcentrationWidgetView(entry: entry)
        }
        .configurationDisplayName(Text("Concentration estimate", tableName: "PhoneWidgets"))
        .description(Text("View a model estimate and its recent trend.", tableName: "PhoneWidgets"))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

private struct PhoneConcentrationWidgetView: View {
    let entry: PhoneConcentrationEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.redactionReasons) private var redaction
    @Environment(\.colorScheme) private var colorScheme

    private var isLockScreen: Bool { family == .accessoryCircular || family == .accessoryRectangular }
    private var isHidden: Bool {
        !entry.isPreview && (redaction.contains(.privacy) || (isLockScreen && !entry.showOnLockScreen))
    }

    private var hasHomePalette: Bool { !isLockScreen && renderingMode == .fullColor }
    private var surface: Color {
        colorScheme == .dark ? Color(red: 0.18, green: 0.15, blue: 0.13) : Color(red: 1, green: 0.98, blue: 0.95)
    }
    private var accent: Color {
        guard hasHomePalette else { return .primary }
        return colorScheme == .dark ? Color(red: 0.87, green: 0.56, blue: 0.45) : Color(red: 0.67, green: 0.34, blue: 0.24)
    }

    private var formattedValue: String? { entry.point.map { entry.metric.formatted($0.value) } }

    private var route: PhoneWidgetRoute {
        if isHidden || entry.isPreview { return .overview }
        if case .placeholder = entry.reading { return .overview }
        return .estimate(entry.metric)
    }

    var body: some View {
        Group {
            if isHidden {
                hiddenLayout
                    .unredacted()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Estimate hidden", tableName: "PhoneWidgets"))
            } else if case .placeholder = entry.reading {
                layout.redacted(reason: .placeholder)
            } else {
                layout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(route.url)
        .containerBackground(for: .widget) {
            if hasHomePalette { surface }
        }
        .privacySensitive(!entry.isPreview)
    }

    @ViewBuilder
    private var layout: some View {
        switch family {
        case .accessoryCircular:
            circle(label: Text(verbatim: entry.metric.symbol), number: formattedValue ?? "—")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(readingDescription)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                eyebrow(Text("\(Text(entry.metric.title)) estimate", tableName: "PhoneWidgets"))
                readout(font: .title2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(readingDescription)
        case .systemMedium:
            if case .estimate(_, let history) = entry.reading {
                medium(history: history)
            } else {
                homeReading(arrow: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(readingDescription)
            }
        default:
            homeReading(arrow: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(readingDescription)
        }
    }

    @ViewBuilder
    private var hiddenLayout: some View {
        switch family {
        case .accessoryCircular:
            circle(label: Text("Hidden", tableName: "PhoneWidgets"), number: "—")
        case .accessoryRectangular:
            Text("Content hidden", tableName: "PhoneWidgets")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    eyebrow(Text(verbatim: "HRTrace"))
                    Spacer(minLength: 0)
                    arrowImage
                }
                Spacer(minLength: 0)
                Text("Content hidden", tableName: "PhoneWidgets")
                    .font(.headline)
                Spacer(minLength: 0)
                Text("Open app to view", tableName: "PhoneWidgets")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func homeReading(arrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                eyebrow(entry.isPreview ? Text("Example estimate", tableName: "PhoneWidgets") :
                            Text("Concentration estimate", tableName: "PhoneWidgets"))
                if arrow {
                    Spacer(minLength: 0)
                    arrowImage
                }
            }
            Spacer(minLength: 0)
            Text(entry.metric.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            readout(font: .largeTitle)
            Spacer(minLength: 0)
            statusNote
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func medium(history: [WatchConcentrationPoint]) -> some View {
        HStack(spacing: 10) {
            Link(destination: route.url) {
                homeReading(arrow: false)
            }
            .accessibilityLabel(readingDescription)
            Divider()
            Link(destination: entry.isPreview ? PhoneWidgetRoute.overview.url : PhoneWidgetRoute.trend(entry.metric).url) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        eyebrow(Text("24-hour trend", tableName: "PhoneWidgets"))
                        Spacer(minLength: 0)
                        arrowImage
                    }
                    Spacer(minLength: 0)
                    if history.count >= 2 {
                        PhoneWidgetTrend(points: history, end: entry.date, tint: accent)
                            .frame(height: 42)
                            .widgetAccentable()
                        HStack {
                            Text("24 h ago", tableName: "PhoneWidgets")
                            Spacer(minLength: 4)
                            Text("Now", tableName: "PhoneWidgets")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    } else {
                        Text("Not enough history", tableName: "PhoneWidgets")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .accessibilityLabel(Text("\(Text(entry.metric.title)), 24-hour estimate trend", tableName: "PhoneWidgets"))
        }
        .foregroundStyle(.primary)
    }

    private func circle(label: Text, number: String) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                eyebrow(label)
                numberText(number, font: .headline)
            }
            .padding(.horizontal, 3)
        }
    }

    private func eyebrow(_ title: Text) -> some View {
        title
            .font(.caption2.weight(.semibold))
            .foregroundStyle(accent)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .widgetAccentable()
    }

    private var arrowImage: some View {
        Image(systemName: "arrow.up.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(accent)
            .accessibilityHidden(true)
    }

    private func readout(font: Font) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            numberText(formattedValue ?? "—", font: font)
                .layoutPriority(1)
            if formattedValue != nil {
                Text(verbatim: entry.metric.unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private func numberText(_ value: String, font: Font) -> some View {
        Text(verbatim: value)
            .font(font.weight(.medium).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.55)
    }

    private var statusNote: Text {
        switch entry.reading {
        case .placeholder, .empty:
            Text("No estimate yet", tableName: "PhoneWidgets")
        case .expired:
            Text("Open HRTrace to update", tableName: "PhoneWidgets")
        case .estimate(let point, _):
            Text("As of \(point.time.formatted(date: .omitted, time: .shortened))", tableName: "PhoneWidgets")
        }
    }

    private var readingDescription: Text {
        let metric = Text(entry.metric.title)
        if let formattedValue {
            return Text("\(metric) model estimate, \(formattedValue) \(entry.metric.unit)", tableName: "PhoneWidgets")
        }
        switch entry.reading {
        case .expired:
            return Text("\(metric) estimate expired. Open HRTrace to update.", tableName: "PhoneWidgets")
        default:
            return Text("No \(metric) estimate yet", tableName: "PhoneWidgets")
        }
    }
}

private struct PhoneWidgetTrend: View {
    let points: [WatchConcentrationPoint]
    let end: Date
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let hours: TimeInterval = 24 * 3_600
            let start = end.addingTimeInterval(-hours)
            guard let min = points.map(\.value).min(), let max = points.map(\.value).max() else { return }
            let coordinates = points.map { point in
                let x = point.time.timeIntervalSince(start) / hours
                let y = max == min ? 0.5 : (max - point.value) / (max - min)
                return CGPoint(x: 3 + x * (size.width - 6), y: 3 + y * (size.height - 8))
            }
            guard let last = coordinates.last else { return }
            context.stroke(Path { $0.addLines(coordinates) }, with: .color(tint),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: last.x - 2.4, y: last.y - 2.4, width: 4.8, height: 4.8)),
                         with: .color(tint))
        }
        .accessibilityHidden(true)
    }
}
