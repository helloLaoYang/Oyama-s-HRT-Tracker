import Charts
import SwiftUI

struct OverviewWidgetDetail: View {
    enum Presentation {
        case estimate
        case trend

        var title: Text {
            switch self {
            case .estimate: Text("Current estimated level")
            case .trend: Text("Last 24 hours", tableName: "WidgetNavigation")
            }
        }

        var identifier: String {
            switch self {
            case .estimate: "widget.detail.estimate"
            case .trend: "widget.detail.trend"
            }
        }
    }

    @ObservedObject var watchSync: PhoneWatchSync
    let metric: WatchMetric
    let presentation: Presentation
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 42

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    presentation.title
                        .font(.headline.weight(.medium))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier(presentation.identifier)
                    Text(metricName)
                        .font(.subheadline)
                        .foregroundStyle(TrackerTheme.muted)
                        .accessibilityIdentifier("widget.detail.metric.\(metric.rawValue)")
                    concentration(at: context.date)
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 12)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(TrackerTheme.ink)
        .background(TrackerTheme.background.ignoresSafeArea())
        .navigationTitle("Overview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private var metricName: LocalizedStringKey {
        switch metric {
        case .e2: "Estradiol"
        case .cpa: "Cyproterone acetate"
        case .testosterone: "Testosterone"
        }
    }

    @ViewBuilder
    private func concentration(at date: Date) -> some View {
        let snapshot = watchSync.widgetSnapshot
        if let snapshot, date >= snapshot.expiresAt {
            detail("Waiting for an updated estimate.")
        } else {
            switch presentation {
            case .estimate:
                if let point = snapshot?.current(for: metric, at: date) {
                    estimate(point)
                } else {
                    detail("No concentration estimate yet.")
                }
            case .trend:
                if let points = snapshot?.history(for: metric, at: date), points.count > 1 {
                    trend(points, at: date)
                } else {
                    detail("No concentration history is available for this metric.")
                }
            }
        }
    }

    private func estimate(_ point: WatchConcentrationPoint) -> some View {
        let number = Text(verbatim: metric.formatted(point.value))
            .font(.system(size: valueSize, weight: .light).monospacedDigit())
            .accessibilityIdentifier("widget.detail.value")
        let unit = Text(verbatim: metric.unit)
            .font(.subheadline)
            .foregroundStyle(TrackerTheme.muted)
        return VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    number
                    unit
                }
                VStack(alignment: .leading, spacing: 2) {
                    number
                    unit
                }
            }
            HStack(spacing: 6) {
                Text("Model estimate")
                Text(point.time, style: .time)
            }
            .font(.footnote)
            .foregroundStyle(TrackerTheme.muted)
        }
    }

    private func trend(_ points: [WatchConcentrationPoint], at date: Date) -> some View {
        let start = date.addingTimeInterval(-86_400)
        let color = metric == .cpa ? TrackerTheme.secondaryChart : TrackerTheme.chartLine
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Model estimate")
                    .font(.footnote)
                    .foregroundStyle(TrackerTheme.muted)
                Text(verbatim: metric.unit)
                    .font(.footnote)
                    .foregroundStyle(TrackerTheme.muted)
            }
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Time", point.time), y: .value("Concentration", point.value))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(color)
                }
                if let latest = points.last {
                    PointMark(x: .value("Time", latest.time), y: .value("Concentration", latest.value))
                        .symbolSize(28)
                        .foregroundStyle(color)
                }
            }
            .chartXScale(domain: start...date)
            .chartXAxis {
                AxisMarks(values: [start, date]) { mark in
                    if let tick = mark.as(Date.self) {
                        AxisValueLabel {
                            if tick == start {
                                Text("24 hours ago", tableName: "WidgetNavigation")
                            } else {
                                Text("Now")
                            }
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
            }
            .frame(height: 220)
            .accessibilityIdentifier("widget.detail.chart")
        }
    }

    private func detail(_ title: LocalizedStringKey) -> some View {
        Text(title, tableName: "WidgetNavigation")
            .font(.footnote)
            .foregroundStyle(TrackerTheme.muted)
    }
}
