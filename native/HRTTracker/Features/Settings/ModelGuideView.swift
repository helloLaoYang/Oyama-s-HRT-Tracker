import Charts
import HRTEngine
import SwiftUI

struct ModelGuideView: View {
    let mode: HRTMode
    let parameters: PKParameters
    @State private var route: Route = .injection
    @State private var doseScale: Double = 1
    @State private var weight: Double = 70
    @State private var spacingScale: Double = 1
    @State private var labScale: Double = 1.25
    @State private var study: ModelStudy?

    private var routes: [Route] { mode == .transfem ? [.injection, .oral, .sublingual, .gel] : [.injection, .oral, .gel] }

    var body: some View {
        let input = ModelStudy.Input(mode: mode, route: route, doseScale: doseScale, weight: weight,
                                     spacingScale: spacingScale, labScale: labScale, parameters: parameters)
        List {
            Section {
                Text("The overview uses the recorded doses to estimate concentrations. These examples use synthetic data and the same model.")
                Picker("Route", selection: $route) {
                    ForEach(routes, id: \.self) { Text($0.trackerTitle).tag($0) }
                }
            }
            Section("One dose") {
                Text("Absorption raises the curve and elimination lowers it. A slower release spreads the curve over a longer time.")
                exampleSlider("Example dose", value: $doseScale, range: 0.5...2, suffix: "×")
                if let study { ModelGuideChart(series: study.single, until: study.singleEnd, unit: study.unit) }
            }
            Section("Doses add up") {
                Text("The model adds the remaining concentration from each previous dose. Repeated doses can settle into a recurring range.")
                exampleSlider("Dosing interval", value: $spacingScale, range: 0.5...2, suffix: "×")
                if let study { ModelGuideChart(series: study.repeated, until: study.repeatedEnd, unit: study.unit) }
            }
            Section("Body weight") {
                Text("Body weight affects the volume in which the medicine is distributed and may also affect modeled clearance.")
                exampleSlider("Weight (kg)", value: $weight, range: 40...120, suffix: " kg", fractionDigits: 0)
                if let study { ModelGuideChart(series: study.weightComparison, until: study.repeatedEnd, unit: study.unit) }
            }
            if mode == .transfem {
                Section("Calibrating with lab results") {
                    Text("An estradiol lab result can help estimate how the model differs from the sampled concentration.")
                    exampleSlider("Example lab result", value: $labScale, range: 0.5...2, suffix: "×")
                    if let study {
                        ModelGuideChart(series: study.calibrated, observed: study.labs, until: study.repeatedEnd, unit: study.unit)
                    }
                    NavigationLink("How these methods work") { CalibrationGuideView(parameters: parameters) }
                        .accessibilityIdentifier("model.guide.calibration")
                }
            }
            Section("Model limitations") {
                Text("Individual response varies. Some routes have fewer data than others.")
                Text("Use laboratory reports and your care team to make treatment decisions.")
            }
        }
        .font(.subheadline)
        .navigationTitle("Model explanation")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: input) {
            let computation = Task.detached(priority: .userInitiated) { ModelStudy.calculate(input) }
            let result = await withTaskCancellationHandler { await computation.value } onCancel: { computation.cancel() }
            guard !Task.isCancelled else { return }
            study = result
        }
    }
}

struct CalibrationGuideView: View {
    let parameters: PKParameters
    @State private var method: CalibrationMethod = .mipd
    @State private var history: CalibrationHistoryMode = .retrospective
    @State private var labScale: Double = 1.3
    @State private var study: CalibrationStudy?

    var body: some View {
        let input = CalibrationStudy.Input(method: method, history: history, labScale: labScale, parameters: parameters)
        List {
            Section {
                Text("The dashed curve shows the starting model. Diamonds mark synthetic lab results.")
                Picker("Calibration method", selection: $method) {
                    ForEach(CalibrationMethod.allCases, id: \.self) { Text($0.guideTitle).tag($0) }
                }
                Picker("Calibration history", selection: $history) {
                    Text("Retrospective calibration").tag(CalibrationHistoryMode.retrospective)
                    Text("Forward-only calibration").tag(CalibrationHistoryMode.forward)
                }
                exampleSlider("Example lab result", value: $labScale, range: 0.5...2, suffix: "×")
                if let study {
                    ModelGuideChart(series: study.lines, observed: study.labs, until: study.end, unit: "pg/mL")
                    LabeledContent("Calibration multiplier", value: study.factor.formatted(.number.precision(.fractionLength(2))) + "×")
                } else {
                    ProgressView()
                }
            }
            Section("Calibration methods") {
                ForEach(CalibrationMethod.allCases, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.guideTitle).font(.subheadline.weight(.medium))
                        Text(item.guideSummary).font(.footnote).foregroundStyle(TrackerTheme.muted)
                    }
                }
            }
        }
        .font(.subheadline)
        .navigationTitle("How calibration works")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: input) {
            let computation = Task.detached(priority: .userInitiated) { CalibrationStudy.calculate(input) }
            let result = await withTaskCancellationHandler { await computation.value } onCancel: { computation.cancel() }
            guard !Task.isCancelled else { return }
            study = result
        }
    }
}

extension CalibrationMethod {
    var guideTitle: LocalizedStringKey {
        switch self {
        case .off: "Off"
        case .mipd: "Hybrid-MIPD"
        case .ekf: "EKF"
        case .ouKalman: "OU-Kalman"
        case .bayes: "Full Bayes"
        case .mcmc: "Personal PK"
        }
    }

    var guideSummary: LocalizedStringKey {
        switch self {
        case .off: "Shows the original model without a lab-derived correction."
        case .mipd: "Fits level and clearance with a population prior and a robust likelihood."
        case .ekf: "Updates the estimated level and clearance in the order that labs were taken."
        case .ouKalman: "Follows a changing level correction and lets older results gradually lose influence."
        case .bayes: "Averages several drift models and estimates uncertainty from the posterior distribution."
        case .mcmc: "Samples route-specific levels, clearance, and absorption to estimate a personal curve."
        }
    }
}

private func exampleSlider(
    _ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, suffix: String, fractionDigits: Int = 2
) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        LabeledContent {
            Text(verbatim: value.wrappedValue.formatted(.number.precision(.fractionLength(0...fractionDigits))) + suffix)
                .monospacedDigit()
        } label: {
            Text(title)
        }
        Slider(value: value, in: range, step: fractionDigits == 0 ? 1 : 0.05) { Text(title) }
    }
}

private struct GuideLine: Identifiable, Sendable {
    let id: String
    let points: [PlotPoint]
    var dashed = false
}

private struct ModelGuideChart: View {
    let series: [GuideLine]
    var observed: [PlotPoint] = []
    let until: Double
    let unit: String

    var body: some View {
        Chart {
            ForEach(series) { line in
                ForEach(line.points, id: \.hour) { point in
                    LineMark(x: .value("Hours", point.hour), y: .value("Concentration", point.value),
                             series: .value("Curve", line.id))
                        .foregroundStyle(line.dashed ? TrackerTheme.secondaryChart : TrackerTheme.chartLine)
                        .lineStyle(StrokeStyle(lineWidth: 1.7, dash: line.dashed ? [4, 3] : []))
                }
            }
            ForEach(observed, id: \.hour) { point in
                PointMark(x: .value("Hours", point.hour), y: .value("Concentration", point.value))
                    .symbol(.diamond)
                    .foregroundStyle(TrackerTheme.accent)
            }
        }
        .chartXScale(domain: 0...until)
        .chartXAxisLabel("Hours")
        .chartYAxisLabel(unit)
        .frame(height: 145)
        .accessibilityLabel("Example concentration curve")
    }
}

private enum GuideSimulation {
    static let start = 498_720.0

    static func line(
        _ id: String, model: Simulation, through end: Double, series: ConcentrationSeries,
        correction: Calibration? = nil, dashed: Bool = false
    ) -> GuideLine {
        let points = TimelineModel.plotPoints(model, in: start...(start + end), series: series,
                                              calibration: correction, limit: 180)
            .map { PlotPoint(hour: $0.hour - start, value: $0.value) }
        return GuideLine(id: id, points: points, dashed: dashed)
    }
}

private struct ModelStudy: Sendable {
    struct Input: Equatable, Sendable {
        let mode: HRTMode
        let route: Route
        let doseScale: Double
        let weight: Double
        let spacingScale: Double
        let labScale: Double
        let parameters: PKParameters
    }

    let single: [GuideLine]
    let repeated: [GuideLine]
    let weightComparison: [GuideLine]
    let calibrated: [GuideLine]
    let labs: [PlotPoint]
    let singleEnd: Double
    let repeatedEnd: Double
    let unit: String

    static func calculate(_ input: Input) -> Self? {
        let start = GuideSimulation.start
        let series: ConcentrationSeries = input.mode == .transfem ? .e2 : .testosterone
        let injection = input.route == .injection
        let spacing = (injection ? 84.0 : 24.0) * input.spacingScale
        let horizon = spacing * 8
        let singleEnd = injection ? 168.0 : 48.0
        let drug: String
        let dose: Double
        switch (input.mode, input.route) {
        case (.transfem, .injection): (drug, dose) = ("EV", 3)
        case (.transfem, _): (drug, dose) = ("E2", 2)
        case (.transmasc, .injection): (drug, dose) = ("TC", 50)
        case (.transmasc, .oral): (drug, dose) = ("TU", 40)
        case (.transmasc, _): (drug, dose) = ("T", 25)
        }

        let events = (0..<8).map { position in
            DoseEvent(id: "guide-\(position)", route: input.route, timeH: start + Double(position) * spacing,
                      doseMG: dose * input.doseScale, ester: drug)
        }
        let now = start + horizon
        guard let first = events.first,
              let single = HRTEngine.simulate(events: [first], weight: 70, nowH: now, throughH: start + singleEnd,
                                              parameters: input.parameters),
              let repeated = HRTEngine.simulate(events: events, weight: 70, nowH: now, parameters: input.parameters),
              let weighted = HRTEngine.simulate(events: events, weight: input.weight, nowH: now,
                                                parameters: input.parameters) else { return nil }

        let labHour = start + spacing * 6.25
        let labs = series == .e2 ? repeated.value(at: labHour).map { sample in
            [LabResult(id: "guide-lab", timeH: labHour, concValue: sample.e2 * input.labScale, unit: "pg/ml")]
        } ?? [] : []
        let calibrated = labs.isEmpty ? nil : HRTEngine.calibrate(simulation: repeated, events: events, weight: 70,
                                                                   labs: labs, method: .mipd, history: .retrospective)
        let reference = GuideSimulation.line("Reference", model: repeated, through: horizon, series: series, dashed: true)
        let corrected = GuideSimulation.line("Calibrated", model: repeated, through: horizon,
                                             series: series, correction: calibrated)
        return Self(
            single: [GuideSimulation.line("Single", model: single, through: singleEnd, series: series)],
            repeated: [GuideSimulation.line("Repeated", model: repeated, through: horizon, series: series)],
            weightComparison: [reference, GuideSimulation.line("Weighted", model: weighted, through: horizon, series: series)],
            calibrated: [reference, corrected], labs: labs.map { PlotPoint(hour: $0.timeH - start, value: $0.concValue) },
            singleEnd: singleEnd, repeatedEnd: horizon, unit: series.unit
        )
    }
}

private struct CalibrationStudy: Sendable {
    struct Input: Equatable, Sendable {
        let method: CalibrationMethod
        let history: CalibrationHistoryMode
        let labScale: Double
        let parameters: PKParameters
    }

    let lines: [GuideLine]
    let labs: [PlotPoint]
    let end: Double
    let factor: Double

    static func calculate(_ input: Input) -> Self? {
        let start = GuideSimulation.start
        let end = 42.0 * 24
        let events = stride(from: 0.0, to: end, by: 72).enumerated().map { index, hour in
            DoseEvent(id: "calibration-guide-dose-\(index)", route: .patchApply, timeH: start + hour,
                      doseMG: 0, ester: "E2", extras: ["releaseRateUGPerDay": 100, "patchWearH": 72])
        }
        guard let model = HRTEngine.simulate(events: events, weight: 70, nowH: start + end,
                                             parameters: input.parameters) else { return nil }
        let labs = [91.0, 270, 490, 780].enumerated().compactMap { index, hour in
            model.value(at: start + hour).map { sample in
                let scale = [0.8, input.labScale, 1.2, 1.05][index]
                return LabResult(id: "calibration-guide-lab-\(index)", timeH: sample.timeH,
                                 concValue: sample.e2 * scale, unit: "pg/ml", assay: "lcms")
            }
        }
        let fitted = HRTEngine.calibrate(simulation: model, events: events, weight: 70, labs: labs,
                                         method: input.method, history: input.history)
        guard !Task.isCancelled else { return nil }
        return Self(
            lines: [
                GuideSimulation.line("Original", model: model, through: end, series: .e2, dashed: true),
                GuideSimulation.line("Adjusted", model: model, through: end, series: .e2, correction: fitted),
            ],
            labs: labs.map { PlotPoint(hour: $0.timeH - start, value: $0.concValue) },
            end: end, factor: fitted.factor(at: start + end)
        )
    }
}
