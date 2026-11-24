import SwiftUI

struct ConcentrationShareCard: View {
    let model: TimelineModel
    let calendar: Calendar
    let range: TrackerChartRange

    var body: some View {
        ConcentrationTimeline(model: model, calendar: calendar, range: .constant(range), isShareCard: true)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(TrackerTheme.ink)
            .background(TrackerTheme.background)
    }
}

struct ConcentrationTimeline: View {
    let model: TimelineModel
    let calendar: Calendar
    @Binding var range: TrackerChartRange
    var isShareCard = false
    @State private var cursor: Double?
    @ScaledMetric(relativeTo: .caption2) private var gutter: CGFloat = 39
    @ScaledMetric(relativeTo: .caption2) private var axisSize: CGFloat = 10
    private let trailingInset: CGFloat = 12
    private let futureDash: [CGFloat] = [5, 4]

    private var selected: Double { cursor ?? model.now }

    var body: some View {
        let plotHeights: (primary: CGFloat, secondary: CGFloat) = isShareCard ? (164, 88) : (195, 108)
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(model.traces.enumerated()), id: \.element.kind) { index, trace in
                    let color = trace.kind == .cpa ? TrackerTheme.secondaryChart : TrackerTheme.chartLine
                    seriesHeader(trace.kind, color: color)
                    plot(trace, color: color, secondary: index > 0)
                        .frame(height: index == 0 ? plotHeights.primary : plotHeights.secondary)
                        .accessibilityIdentifier("timeline.plot.\(trace.kind.rawValue)")
                }
                timeAxis.frame(height: axisSize + 6)
            }

            Text(readout)
                .font(.footnote.monospacedDigit())
                .accessibilityIdentifier("timeline.readout")
        }
        .onChange(of: range) { cursor = nil }
        .onChange(of: model.window) {
            if let cursor, !model.window.contains(cursor) { self.cursor = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.timeline")
    }

    @ViewBuilder
    private var header: some View {
        if isShareCard {
            VStack(alignment: .leading, spacing: 5) {
                TrackerSectionTitle(title: "Hormone concentration over time")
                HStack(spacing: 5) {
                    Text(rangeTitle(range))
                    Text(verbatim: "·")
                    Text("Model estimate")
                    Spacer(minLength: 8)
                    Text(verbatim: "HRT Tracker")
                }
                .font(.caption)
                .foregroundStyle(TrackerTheme.muted)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    TrackerSectionTitle(title: "Hormone concentration over time")
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    rangePicker.fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    TrackerSectionTitle(title: "Hormone concentration over time")
                    rangePicker.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var rangePicker: some View {
        TrackerSegment(options: TrackerChartRange.allCases, selection: $range, compact: true, title: rangeTitle)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("timeline.range")
    }

    private func rangeTitle(_ range: TrackerChartRange) -> LocalizedStringKey {
        switch range {
        case .week: "7 days"
        case .month: "30 days"
        case .all: "All"
        }
    }

    private func seriesHeader(_ kind: ConcentrationSeries, color: Color) -> some View {
        let items = HStack(spacing: 8) {
            legend(Text(verbatim: kind.name + " · " + kind.unit), color: color)
            legend(Text(isShareCard ? "Expected" : futureLegendTitle), color: futureColor(color), dash: futureDash)
            if !isShareCard, kind != .cpa {
                Label("Lab result", systemImage: "diamond.fill")
                    .symbolRenderingMode(.monochrome)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        let calibration = calibrationLabel(kind)

        return Group {
            if isShareCard {
                items
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        items
                        Spacer(minLength: 0)
                        calibration.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .trailing, spacing: 4) {
                        ScrollView(.horizontal) {
                            items
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollIndicators(.hidden)
                        calibration
                    }
                }
            }
        }
        .font(.caption)
        .lineLimit(1)
        .foregroundStyle(TrackerTheme.muted)
    }

    private var futureLegendTitle: LocalizedStringKey {
        if model.futureUsesPlan { return "Projected from medication plan" }
        if model.futureUsesRecords { return "Future recorded doses" }
        return "Expected"
    }

    private func futureColor(_ color: Color) -> Color {
        color.opacity(model.futureUsesPlan ? 0.88 : 0.52)
    }

    @ViewBuilder
    private func calibrationLabel(_ kind: ConcentrationSeries) -> some View {
        if kind == .e2, let calibration = model.calibration, calibration.count > 0 {
            Text("Calibration ×\(calibration.factor(at: model.now).formatted(.number.precision(.fractionLength(2))))")
        }
    }

    private func legend(_ text: Text, color: Color, dash: [CGFloat] = []) -> some View {
        HStack(spacing: 7) {
            Canvas { context, size in
                let path = Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height / 2))
                    path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: dash))
            }
            .frame(width: 15, height: 8)
            .accessibilityHidden(true)
            text
        }
    }

    private func plot(_ trace: TimelineTrace, color: Color, secondary: Bool) -> some View {
        let canvas = Canvas { context, size in
            let scale = ValueAxis(trace: trace, steps: secondary ? 3 : 4, includesMeasurements: !isShareCard)
            let bounds = CGRect(x: gutter, y: 8, width: max(1, size.width - gutter - trailingInset),
                                height: max(1, size.height - 16))
            func x(_ hour: Double) -> CGFloat { plotX(hour, width: size.width) }
            func y(_ value: Double) -> CGFloat {
                bounds.maxY - (value - scale.minimum) / (scale.maximum - scale.minimum) * bounds.height
            }

            if let target = trace.kind.target {
                let top = y(min(target.upperBound, scale.maximum))
                let bottom = y(max(target.lowerBound, scale.minimum))
                if bottom > top {
                    context.fill(Path(CGRect(x: bounds.minX, y: top, width: bounds.width,
                                             height: bottom - top)),
                                 with: .color(TrackerTheme.band.opacity(0.52)))
                }
            }
            for tick in scale.ticks {
                let height = y(tick)
                drawLine(context, from: CGPoint(x: bounds.minX, y: height),
                         to: CGPoint(x: bounds.maxX, y: height), color: TrackerTheme.separator)
                let number = tick.formatted(.number.precision(.fractionLength(0...2)))
                context.draw(Text(verbatim: number).font(.system(size: axisSize).monospacedDigit())
                    .foregroundStyle(TrackerTheme.muted),
                             at: CGPoint(x: bounds.minX - 6, y: height), anchor: .trailing)
            }

            drawLine(context, from: CGPoint(x: x(model.now), y: bounds.minY),
                     to: CGPoint(x: x(model.now), y: bounds.maxY),
                     color: TrackerTheme.muted.opacity(0.7), dash: [2, 4])

            drawTrace(context, trace.past, color: color, x: x, y: y)
            drawTrace(context, trace.future, color: futureColor(color), dash: futureDash, x: x, y: y)

            if !isShareCard {
                for point in trace.doses {
                    let center = CGPoint(x: x(point.hour), y: y(point.value))
                    drawDot(context, center: center, radius: 2.6, color: color)
                }
                for point in trace.measurements {
                    let midX = x(point.hour), midY = y(point.value)
                    let diamond = Path { path in
                        path.move(to: CGPoint(x: midX, y: midY - 3.7))
                        path.addLine(to: CGPoint(x: midX + 3.7, y: midY))
                        path.addLine(to: CGPoint(x: midX, y: midY + 3.7))
                        path.addLine(to: CGPoint(x: midX - 3.7, y: midY))
                        path.closeSubpath()
                    }
                    context.fill(diamond, with: .color(TrackerTheme.accent))
                }
            }

            if let value = model.value(trace.kind, at: selected) {
                if cursor != nil {
                    drawLine(context, from: CGPoint(x: x(selected), y: bounds.minY),
                             to: CGPoint(x: x(selected), y: bounds.maxY),
                             color: color.opacity(0.75), dash: [2, 4])
                }
                if (scale.minimum...scale.maximum).contains(value) {
                    drawDot(context, center: CGPoint(x: x(selected), y: y(value)), radius: 3.2, color: color)
                }
            }
        }
        return Group {
            if isShareCard {
                canvas
            } else {
                GeometryReader { geometry in
                    canvas
                        .contentShape(Rectangle())
                        .onTapGesture { location in select(location.x, width: geometry.size.width) }
                        .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { drag in
                            guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                            select(drag.location.x, width: geometry.size.width)
                        })
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: trace.kind.name + " · " + trace.kind.unit))
                .accessibilityValue(Text(verbatim: readout))
                .accessibilityAdjustableAction { direction in
                    let step = (model.window.upperBound - model.window.lowerBound) / 30
                    switch direction {
                    case .increment: cursor = min(model.window.upperBound, selected + step)
                    case .decrement: cursor = max(model.window.lowerBound, selected - step)
                    @unknown default: break
                    }
                }
            }
        }
    }

    private var timeAxis: some View {
        Canvas { context, size in
            let span = model.window.upperBound - model.window.lowerBound
            let availableWidth = max(1, size.width - gutter - trailingInset)
            let slots = max(2, min(5, Int(availableWidth / (axisSize * 5.8))))
            let hoursPerTick = max(24, ceil(span / Double(slots) / 24) * 24)
            let firstDay = calendar.startOfDay(for: Date(trackerHours: model.window.lowerBound)).trackerHours
            let nowX = plotX(model.now, width: size.width)
            for hour in stride(from: firstDay, through: model.window.upperBound, by: hoursPerTick) {
                guard model.window.contains(hour) else { continue }
                let x = plotX(hour, width: size.width)
                guard abs(x - nowX) > axisSize * 4.3, x < size.width - axisSize * 1.65 else { continue }
                let date = Date(trackerHours: hour).formatted(.dateTime.month(.defaultDigits).day().timeZone(calendar.timeZone))
                context.draw(Text(verbatim: date).font(.system(size: axisSize)).foregroundStyle(TrackerTheme.muted),
                             at: CGPoint(x: x, y: size.height / 2))
            }
            context.draw(Text("Now").font(.system(size: axisSize, weight: .medium)).foregroundStyle(TrackerTheme.ink),
                         at: CGPoint(x: nowX, y: size.height / 2))
        }
        .accessibilityHidden(true)
    }

    private var readout: String {
        let date = cursor == nil ? label("Now") : Date(trackerHours: selected)
            .formatted(.dateTime.month().day().hour().minute().timeZone(calendar.timeZone))
        let values = model.traces.compactMap { trace in
            model.value(trace.kind, at: selected).map { trace.kind.formatted($0) + " " + trace.kind.unit }
        }
        return ([date] + values).joined(separator: " · ")
    }

    private func plotX(_ hour: Double, width: CGFloat) -> CGFloat {
        let fraction = (hour - model.window.lowerBound) / (model.window.upperBound - model.window.lowerBound)
        return gutter + fraction * max(1, width - gutter - trailingInset)
    }

    private func select(_ x: CGFloat, width: CGFloat) {
        let fraction = min(1, max(0, (x - gutter) / max(1, width - gutter - trailingInset)))
        cursor = model.window.lowerBound + fraction * (model.window.upperBound - model.window.lowerBound)
    }

    private func drawTrace(
        _ context: GraphicsContext, _ points: [PlotPoint], color: Color,
        dash: [CGFloat] = [], x: (Double) -> CGFloat, y: (Double) -> CGFloat
    ) {
        guard let first = points.first else { return }
        let path = Path { path in
            path.move(to: CGPoint(x: x(first.hour), y: y(first.value)))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: x(point.hour), y: y(point.value)))
            }
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dash))
    }

    private func drawDot(_ context: GraphicsContext, center: CGPoint, radius: CGFloat, color: Color) {
        let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                         width: radius * 2, height: radius * 2))
        context.fill(dot, with: .color(TrackerTheme.background))
        context.stroke(dot, with: .color(color), lineWidth: 1)
    }

    private func drawLine(
        _ context: GraphicsContext, from: CGPoint, to: CGPoint, color: Color, dash: [CGFloat] = []
    ) {
        let path = Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: dash))
    }
}

private struct ValueAxis {
    let minimum: Double
    let maximum: Double
    let ticks: [Double]

    init(trace: TimelineTrace, steps: Double, includesMeasurements: Bool) {
        let measurements = includesMeasurements ? trace.measurements : []
        let values = (trace.past + trace.future + measurements).map(\.value).filter(\.isFinite)
        var low = max(0, values.min() ?? 0)
        var high = max(low, values.max() ?? 0)
        if high - low < trace.kind.axisFloor {
            low = max(0, (high + low - trace.kind.axisFloor) / 2)
            high = low + trace.kind.axisFloor
        }
        let pad = (high - low) * 0.12
        let rough = (high - low + 2 * pad) / steps
        let power = pow(10, floor(log10(rough)))
        let normalized = rough / power
        let step = (normalized < 1.5 ? 1 : normalized < 3 ? 2 : normalized < 7 ? 5 : 10) * power
        let start = max(0, floor((low - pad) / step)) * step
        let end = ceil((high + pad) / step) * step
        minimum = start
        maximum = end
        ticks = Array(stride(from: start, through: end + step / 2, by: step))
    }
}

extension Date.FormatStyle {
    func timeZone(_ zone: TimeZone) -> Self {
        var style = self
        style.timeZone = zone
        return style
    }
}
