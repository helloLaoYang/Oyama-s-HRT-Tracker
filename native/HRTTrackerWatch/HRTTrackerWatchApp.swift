import Charts
import SwiftUI

@main
@MainActor
struct HRTTrackerWatchApp: App {
    @State private var store = WatchTrackerStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchConcentrationView(store: store)
                .task { store.activate() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.activate() }
                }
        }
        .backgroundTask(.watchConnectivity) { _ in await store.receiveBackgroundDelivery() }
    }
}

private enum WatchAppearance {
    static let background = Color(red: 24 / 255, green: 23 / 255, blue: 20 / 255)
    static let surface = Color(red: 46 / 255, green: 42 / 255, blue: 36 / 255)
    static let accent = Color(red: 223 / 255, green: 143 / 255, blue: 116 / 255)
    static let companion = Color(red: 193 / 255, green: 183 / 255, blue: 169 / 255)
}

private enum WatchDestination: Hashable {
    case today
    case confirm(WatchDoseOccurrence)
}

private struct WatchConcentrationView: View {
    let store: WatchTrackerStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var path: [WatchDestination] = []
    @State private var selectedMetric: WatchMetric?
    @State private var showingMetrics = false
    @State private var openReading = 0

    private var metric: WatchMetric { selectedMetric ?? store.snapshot?.primaryMetric ?? .e2 }

    private var availableMetrics: [WatchMetric] {
        guard let snapshot = store.snapshot else { return [] }
        return WatchMetric.allCases.filter { $0 == snapshot.primaryMetric || !snapshot.points(for: $0).isEmpty }
    }

    private var metricColor: Color { metric == .cpa ? WatchAppearance.companion : WatchAppearance.accent }

    var body: some View {
        NavigationStack(path: $path) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let point = store.snapshot?.current(for: metric, at: context.date)
                let history = store.snapshot?.history(for: metric, at: context.date) ?? []
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            reading(point, at: context.date)
                                .id("reading")
                            shortcuts(showTrend: point != nil && !history.isEmpty, reader: reader)
                            if point != nil && !history.isEmpty {
                                WatchTrendView(metric: metric, color: metricColor, points: history, now: context.date)
                                    .padding(.top, 8)
                                    .id("trend")
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: openReading) { _, _ in reader.scrollTo("reading", anchor: .top) }
                }
            }
            .navigationTitle("Concentration")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: WatchDestination.self) { destination in
                switch destination {
                case .today:
                    WatchTodayView(store: store)
                case .confirm(let occurrence):
                    WatchDoseConfirmation(occurrence: occurrence) {
                        if store.record(occurrence), !path.isEmpty { path.removeLast() }
                    }
                }
            }
            .background(WatchAppearance.background.ignoresSafeArea())
        }
        .tint(WatchAppearance.accent)
        .onOpenURL { url in
            guard WatchRoute.matches(url) else { return }
            selectedMetric = WatchRoute.metric(from: url)
            showingMetrics = false
            path.removeAll()
            openReading += 1
        }
        .alert("Medication record", isPresented: Binding(
            get: { store.issue != nil }, set: { if !$0 { store.issue = nil } }
        )) {
            Button("OK", role: .cancel) { store.issue = nil }
        } message: {
            switch store.issue {
            case .storage:
                Text("The watch could not update its local records. Try again.")
            case .planChanged:
                Text("The medication plan changed on iPhone. Check the current plan before recording.")
            case nil:
                EmptyView()
            }
        }
    }

    private func reading(_ point: WatchConcentrationPoint?, at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if availableMetrics.count > 1 || (availableMetrics.count == 1 && !availableMetrics.contains(metric)) {
                Button { showingMetrics = true } label: {
                    HStack(spacing: 5) {
                        Text(metric.title)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .font(.footnote)
                    .foregroundStyle(metricColor)
                    .frame(minHeight: 32, alignment: .leading)
                }
                .buttonStyle(.plain)
                .confirmationDialog("Concentration", isPresented: $showingMetrics, titleVisibility: .visible) {
                    ForEach(availableMetrics, id: \.self) { option in
                        Button { selectedMetric = option } label: { Text(option.title) }
                    }
                }
            } else {
                Text(metric.title).font(.footnote).foregroundStyle(metricColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        readingNumber(point)
                        if point != nil { Text(metric.unit).font(.caption2).foregroundStyle(.secondary) }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        readingNumber(point)
                        if point != nil { Text(metric.unit).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                if let point {
                    Text("Model estimate · \(point.time.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if store.snapshot.map({ now >= $0.expiresAt }) ?? true {
                    Text("Open HRT Tracker on iPhone to sync.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No concentration estimate yet.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("watch.currentEstimate")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readingNumber(_ point: WatchConcentrationPoint?) -> some View {
        Text(point.map { metric.formatted($0.value) } ?? "—")
            .font(.system(.largeTitle, design: .rounded).weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
    }

    private func shortcuts(showTrend: Bool, reader: ScrollViewProxy) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 5)) : AnyLayout(HStackLayout(spacing: 5))
        return layout {
            if showTrend {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { reader.scrollTo("trend", anchor: .top) }
                } label: {
                    navigationLabel("24h trend", icon: "chevron.down")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Last 24 hours")
                .accessibilityIdentifier("watch.openTrend")
            }
            NavigationLink(value: WatchDestination.today) {
                navigationLabel("Today", icon: "chevron.right")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Today's medication")
            .accessibilityIdentifier("watch.today")
        }
    }

    private func navigationLabel(_ title: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 2)
            Image(systemName: icon).font(.caption2.weight(.regular)).foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minHeight: 38)
        .background(WatchAppearance.surface, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

private struct WatchTrendView: View {
    let metric: WatchMetric
    let color: Color
    let points: [WatchConcentrationPoint]
    let now: Date

    private var start: Date { now.addingTimeInterval(-86_400) }

    private var bounds: ClosedRange<Double> {
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let padding = max((high - low) * 0.12, max(high * 0.04, 0.1))
        return max(0, low - padding)...(high + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Last 24 hours").font(.headline.weight(.medium))
            HStack(spacing: 4) {
                Text(metric.title)
                Text("·")
                Text(metric.unit)
            }
            .foregroundStyle(.secondary)
            .font(.caption2)

            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Time", point.time), y: .value("Concentration", point.value))
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(color)
                }
                if let point = points.last {
                    PointMark(x: .value("Time", point.time), y: .value("Concentration", point.value))
                        .symbolSize(28)
                        .foregroundStyle(color)
                }
            }
            .chartXScale(domain: start...now)
            .chartYScale(domain: bounds)
            .chartXAxis {
                AxisMarks(values: [start, now]) { mark in
                    if let time = mark.as(Date.self) {
                        AxisValueLabel {
                            if time == start { Text("Yesterday") } else { Text("Now") }
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { mark in
                    AxisGridLine()
                    if let value = mark.as(Double.self) {
                        AxisValueLabel { Text(metric.formatted(value)) }
                    }
                }
            }
            .frame(height: 89)
            .accessibilityIdentifier("watch.trend")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WatchTodayView: View {
    let store: WatchTrackerStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    if let snapshot = store.snapshot, context.date < snapshot.planValidUntil {
                        if snapshot.occurrences.isEmpty {
                            Text("Nothing scheduled today.").foregroundStyle(.secondary)
                        }
                        ForEach(snapshot.occurrences) { occurrence in
                            switch store.status(of: occurrence) {
                            case .available:
                                NavigationLink(value: WatchDestination.confirm(occurrence)) {
                                    occurrenceRow(occurrence, status: "To record", icon: "chevron.right")
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("watch.plan.available")
                            case .pending:
                                occurrenceRow(occurrence, status: "Pending sync", icon: "clock")
                                    .accessibilityIdentifier("watch.plan.pending")
                            case .recorded:
                                occurrenceRow(occurrence, status: "Recorded", icon: "checkmark")
                                    .accessibilityIdentifier("watch.plan.recorded")
                            }
                        }
                    } else {
                        Text("Open HRT Tracker on iPhone to sync.").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .font(.footnote)
            }
        }
        .navigationTitle("Today's medication")
        .navigationBarTitleDisplayMode(.inline)
        .background(WatchAppearance.background.ignoresSafeArea())
    }

    private func occurrenceRow(_ occurrence: WatchDoseOccurrence, status: LocalizedStringKey, icon: String) -> some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(occurrence.title)
                HStack(spacing: 4) {
                    Text(occurrence.scheduledAt, style: .time)
                    Text("·")
                    Text(status)
                }
                .foregroundStyle(.secondary)
                .font(.caption2)
            }
            Spacer(minLength: 0)
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(minHeight: 43)
        .background(WatchAppearance.surface, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct WatchDoseConfirmation: View {
    let occurrence: WatchDoseOccurrence
    let confirm: () -> Void

    private var confirmationLabel: LocalizedStringKey {
        switch occurrence.action {
        case .take: "Confirm taken"
        case .replacePatch: "Confirm patch replaced"
        case .inject: "Confirm injection"
        case .record: "Confirm record"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text(occurrence.title).font(.headline.weight(.medium))
                if !occurrence.detail.isEmpty {
                    Text(occurrence.detail).font(.footnote).foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("Recording time · \(context.date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button(confirmationLabel, action: confirm)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("watch.record")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .navigationTitle("Record dose")
        .navigationBarTitleDisplayMode(.inline)
        .background(WatchAppearance.background.ignoresSafeArea())
    }
}
