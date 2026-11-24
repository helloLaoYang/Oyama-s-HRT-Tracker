import Charts
import HRTEngine
import SwiftUI

@MainActor
struct LabsView: View {
    let store: TrackerStore

    @State private var editor: Editor?
    @State private var confirmingDeletion = false
    @State private var failure = false
    @State private var checked: (request: CheckRequest, analysis: CheckAnalysis?)?

    private struct Editor: Identifiable {
        let id = UUID()
        let lab: LabResult?
    }

    private var orderedLabs: [LabResult] { store.labs.sorted { $0.timeH > $1.timeH } }

    var body: some View {
        let request = CheckRequest(store: store)
        let analysis = checked?.request == request ? checked?.analysis : nil
        List {
            Section {
                NavigationLink {
                    CalibrationSettingsView(store: store)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LabText.localized("Calibration settings"))
                            .font(.subheadline)
                            .foregroundStyle(TrackerTheme.ink)
                        Text(request.caption(analysis?.fit))
                            .font(.footnote)
                            .foregroundStyle(TrackerTheme.muted)
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("labs.calibration")
                .listRowBackground(TrackerTheme.surface)
                .listRowSeparatorTint(TrackerTheme.separator)
            }

            Section {
                if orderedLabs.isEmpty {
                    ContentUnavailableView {
                        Label(LabText.localized("No lab results"), systemImage: "testtube.2")
                    } actions: {
                        Button(LabText.localized("Add lab result")) { editor = Editor(lab: nil) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("labs.addFirst")
                    }
                    .listRowBackground(TrackerTheme.background)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(orderedLabs, id: \.id) { lab in
                        Button {
                            editor = Editor(lab: lab)
                        } label: {
                            labRow(lab, comparison: analysis?.points.first { $0.id == lab.id })
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("labs.record.\(lab.id)")
                        .listRowBackground(TrackerTheme.surface)
                        .listRowSeparatorTint(TrackerTheme.separator)
                    }
                }
            } header: {
                Text(LabText.localized("Lab results"))
                    .textCase(nil)
                    .foregroundStyle(TrackerTheme.muted)
            }

            if let points = analysis?.points, !points.isEmpty {
                Section {
                    comparisonChart(points)
                        .padding(.vertical, 7)
                        .listRowBackground(TrackerTheme.surface)
                } header: {
                    Text(LabText.localized("Model vs. lab results"))
                        .textCase(nil)
                        .foregroundStyle(TrackerTheme.muted)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(TrackerTheme.background)
        .environment(\.timeZone, store.calendar.timeZone)
        .navigationTitle(LabText.localized("Labs"))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !orderedLabs.isEmpty {
                    Menu {
                        Button(LabText.localized("Delete all lab results"), role: .destructive) {
                            confirmingDeletion = true
                        }
                    } label: {
                        TrackerTheme.navigationIcon("ellipsis")
                    }
                    .accessibilityLabel(LabText.localized("Lab result actions"))
                    .accessibilityIdentifier("labs.actions")
                }
                Button {
                    editor = Editor(lab: nil)
                } label: {
                    TrackerTheme.navigationIcon("plus")
                }
                .accessibilityLabel(LabText.localized("Add lab result"))
                .accessibilityIdentifier("labs.addLab")
            }
        }
        .sheet(item: $editor) { request in
            LabEditorView(store: store, lab: request.lab)
        }
        .confirmationDialog(
            LabText.localized("Delete all lab results?"), isPresented: $confirmingDeletion, titleVisibility: .visible
        ) {
            Button(LabText.localized("Delete all lab results"), role: .destructive) {
                if !store.clearLabs() { failure = true }
            }
            Button(LabText.localized("Cancel"), role: .cancel) { }
        }
        .alert(LabText.localized("Could not update the lab results"), isPresented: $failure) {
            Button(LabText.localized("OK"), role: .cancel) { }
        }
        .task(id: request) {
            let result = await request.calculate()
            if !Task.isCancelled { checked = (request, result) }
        }
    }

    private func labRow(_ lab: LabResult, comparison: CheckComparison?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                let value = lab.concValue.formatted(.number.precision(.fractionLength(0...2)))
                let unit = LabText.unitText(lab.unit)
                let name = LabText.localized(store.mode == .transfem ? "Estradiol" : "Total testosterone")
                Text("\(value) \(unit) · \(name)")
                    .font(.subheadline)
                    .foregroundStyle(TrackerTheme.ink)
                Text(Date(trackerHours: lab.timeH), format: .dateTime.month().day().weekday(.wide))
                    .font(.footnote)
                    .foregroundStyle(TrackerTheme.muted)
                if let comparison {
                    let ratio = (comparison.observed / comparison.raw - 1) * 100
                    let value = LabText.number(comparison.raw, digits: store.mode == .transfem ? 1 : 0)
                    let difference = LabText.number(abs(ratio), digits: 0)
                    let relation = if abs(ratio) < 0.5 {
                        LabText.localized("Matches")
                    } else if ratio > 0 {
                        LabText.localized("\(difference)% higher")
                    } else {
                        LabText.localized("\(difference)% lower")
                    }
                    Text(LabText.localized("Raw model \(value)") + " · " + relation)
                        .font(.footnote)
                        .foregroundStyle(TrackerTheme.muted)
                }
            }
            Spacer(minLength: 8)
            Text(Date(trackerHours: lab.timeH), format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(TrackerTheme.muted)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func comparisonChart(_ points: [CheckComparison]) -> some View {
        let lower = min(1, points.map { min($0.raw, $0.observed, $0.fitted ?? .infinity) }.min() ?? 1)
        let upper = max(10, (points.map { max($0.raw, $0.observed, $0.fitted ?? 0) }.max() ?? 10) * 1.13)
        let hasFit = points.contains { $0.fitted != nil }
        return VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach([lower, upper], id: \.self) { value in
                    LineMark(x: .value("Model", value), y: .value("Lab result", value))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .foregroundStyle(TrackerTheme.separator)
                }
                ForEach(points) { point in
                    PointMark(x: .value("Raw model", point.raw), y: .value("Lab result", point.observed))
                        .symbol {
                            Circle().strokeBorder(TrackerTheme.chartLine, lineWidth: 1.5).frame(width: 8, height: 8)
                        }
                    if let fitted = point.fitted {
                        PointMark(x: .value("Calibrated model", fitted), y: .value("Lab result", point.observed))
                            .symbol {
                                Circle().fill(TrackerTheme.accent).frame(width: 7, height: 7)
                            }
                    }
                }
            }
            .chartXScale(domain: lower...upper, type: .log)
            .chartYScale(domain: lower...upper, type: .log)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
            .frame(height: 168)
            .accessibilityLabel(LabText.localized("Scatter plot comparing model estimates and lab results"))
            .accessibilityIdentifier("labs.comparisonChart")

            ViewThatFits(in: .horizontal) {
                HStack { chartAxisCaption; Spacer(minLength: 8); chartLegend(hasFit) }
                VStack(alignment: .leading, spacing: 4) { chartAxisCaption; chartLegend(hasFit) }
            }
            .font(.caption)
            .foregroundStyle(TrackerTheme.muted)
        }
    }

    private var chartAxisCaption: some View { Text(LabText.localized("X: model · Y: lab result")) }

    private func chartLegend(_ hasFit: Bool) -> some View {
        HStack(spacing: 8) {
            Label(LabText.localized("Raw"), systemImage: "circle")
            if hasFit { Label(LabText.localized("Calibrated"), systemImage: "circle.fill") }
        }
        .labelStyle(.titleAndIcon)
    }
}

@MainActor
struct CalibrationSettingsView: View {
    @Bindable var store: TrackerStore
    @State private var checked: (request: CheckRequest, fit: CheckFit?)?

    var body: some View {
        let request = CheckRequest(store: store)
        let fit = checked?.request == request ? checked?.fit : nil
        Form {
            Section(LabText.localized("Current calibration")) {
                Text(request.caption(fit))
                    .accessibilityIdentifier("labs.calibration.summary")
                if let fit {
                    LabeledContent(
                        LabText.localized("Lab results used"),
                        value: LabText.localized("\(fit.count) results")
                    )
                    if abs(fit.halfLifeDelta) >= 0.05 {
                        let change = LabText.number(fit.halfLifeDelta, digits: 1)
                        LabeledContent(LabText.localized("Half-life change"), value: "\(change)%")
                    }
                }
            }
            if store.mode == .transfem {
                Section {
                    Picker(LabText.localized("Calibration method"), selection: $store.calibrationMethod) {
                        ForEach([CalibrationMethod.off, .mipd, .ekf, .ouKalman], id: \.self) { method in
                            Text(CheckRequest.methodTitle(method)).tag(method)
                        }
                    }
                    .accessibilityIdentifier("labs.calibration.method")
                    Picker(LabText.localized("History mode"), selection: $store.calibrationHistory) {
                        Text(LabText.localized("Retrospective")).tag(CalibrationHistoryMode.retrospective)
                        Text(LabText.localized("Forward")).tag(CalibrationHistoryMode.forward)
                    }
                    .accessibilityIdentifier("labs.calibration.history")
                } footer: {
                    Text(LabText.localized(store.calibrationHistory == .forward
                        ? "Each lab result only affects estimates after its sample time."
                        : "Uses available lab results to adjust the past curve."))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(TrackerTheme.background)
        .navigationTitle(LabText.localized("Calibration settings"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: request) {
            let result = await request.calculate()
            if !Task.isCancelled { checked = (request, result?.fit) }
        }
    }
}

private struct CheckComparison: Identifiable, Sendable {
    let id: String
    let raw: Double
    let observed: Double
    let fitted: Double?
}

private struct CheckFit: Sendable {
    let scale: Double
    let error: Double?
    let count: Int
    let halfLifeDelta: Double
}

private struct CheckAnalysis: Sendable {
    let points: [CheckComparison]
    let fit: CheckFit?
}

private struct CheckRequest: Equatable, Sendable {
    let doses: [DoseEvent]
    let labs: [LabResult]
    let weight: Double
    let birthYear: Int?
    let now: Double
    let mode: HRTMode
    let method: CalibrationMethod
    let history: CalibrationHistoryMode

    @MainActor
    init(store: TrackerStore) {
        doses = store.doses
        labs = store.labs
        weight = store.weight
        birthYear = store.ageModelEnabled ? store.birthYear : nil
        now = floor(store.now.trackerHours)
        mode = store.mode
        method = store.calibrationMethod
        history = store.calibrationHistory
    }

    func calculate() async -> CheckAnalysis? {
        await Task.detached(priority: .userInitiated) { buildAnalysis() }.value
    }

    private func buildAnalysis() -> CheckAnalysis? {
        guard !labs.isEmpty,
              let simulation = HRTEngine.simulate(events: doses, weight: weight, nowH: now, birthYear: birthYear) else {
            return nil
        }
        let result = mode == .transfem && method != .off ? HRTEngine.calibrate(
            simulation: simulation, events: doses, weight: weight, labs: labs, method: method, history: history,
            birthYear: birthYear
        ) : nil
        let fit = result.flatMap { result in
            result.count > 0 ? CheckFit(
                scale: result.scale, error: result.fitErrPct, count: result.count, halfLifeDelta: result.halfLifeDeltaPct
            ) : nil
        }
        let points = labs.compactMap { lab -> CheckComparison? in
            guard let sample = simulation.value(at: lab.timeH),
                  let observed = LabText.converted(lab, mode: mode), observed > 0 else { return nil }
            let raw = mode == .transfem ? sample.e2 : sample.testosterone
            guard raw >= 1, raw.isFinite, observed.isFinite else { return nil }
            let fitted = fit == nil ? nil : result.map { raw * $0.factor(at: lab.timeH) }
            return CheckComparison(id: lab.id, raw: raw, observed: observed, fitted: fitted.flatMap { $0 > 0 && $0.isFinite ? $0 : nil })
        }
        return CheckAnalysis(points: points, fit: fit)
    }

    func caption(_ fit: CheckFit?) -> String {
        if mode == .transmasc { return LabText.localized("Showing raw model comparison") }
        if method == .off { return LabText.localized("Off · Showing raw model") }
        let title = Self.methodTitle(method)
        guard let fit else { return title + " · " + LabText.localized("Waiting for a lab result suitable for calibration") }
        let scale = LabText.number(fit.scale, digits: 2)
        let formattedError = fit.error.map { " · ±" + LabText.number($0, digits: 1) + "%" } ?? ""
        return "\(title) · ×\(scale)\(formattedError)"
    }

    static func methodTitle(_ method: CalibrationMethod) -> String {
        switch method {
        case .off: LabText.localized("Off")
        case .mipd: "Hybrid-MIPD"
        case .ekf: "EKF"
        case .ouKalman: "OU-Kalman"
        }
    }
}
