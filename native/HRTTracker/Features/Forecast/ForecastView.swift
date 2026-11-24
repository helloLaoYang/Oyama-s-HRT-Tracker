import Charts
import HRTEngine
import SwiftUI

struct ForecastView: View {
    let store: TrackerStore
    @State private var drafts: [ForecastDraft] = []
    @State private var selected = 1
    @State private var nextID = 2
    @State private var weeks = 8
    @State private var result: ForecastResult?
    @State private var busy = true
    @State private var savedTemplate = false
    @State private var cursor: Double?

    private let comparisonColors: [Color] = [TrackerTheme.chartLine, .indigo, .teal]
    private let horizons = [4, 8, 12]

    var body: some View {
        let input = request
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                currentPlan(input.regimens)
                alternatives
                Divider().overlay(TrackerTheme.separator)
                results
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 12)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(TrackerTheme.ink)
        .background(TrackerTheme.background.ignoresSafeArea())
        .navigationTitle("Regimen simulation")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if drafts.isEmpty { drafts = [newDraft(id: 1, regimens: input.regimens)] }
        }
        .task(id: input) {
            guard !input.drafts.isEmpty else { return }
            busy = true
            cursor = nil
            let calculation = Task.detached(priority: .userInitiated) { ForecastResult.calculate(input) }
            let response = await withTaskCancellationHandler {
                await calculation.value
            } onCancel: {
                calculation.cancel()
            }
            guard !Task.isCancelled else { return }
            result = response
            busy = false
        }
    }

    private func currentPlan(_ regimens: [ForecastRegimen]) -> some View {
        let primary = regimens.first { $0.schedule.plan.ester != "CPA" }
        return VStack(alignment: .leading, spacing: 9) {
            Text("Current regimen")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(TrackerTheme.muted)
            if let plan = primary?.schedule.plan {
                planRow(plan, detail: planRepeatCaption(plan))
            } else {
                Text("No regular regimen in the past six weeks.")
                    .font(.footnote)
                    .foregroundStyle(TrackerTheme.muted)
            }
        }
    }

    private var alternatives: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { alternativePicker; Spacer(minLength: 4); addButton }
                VStack(alignment: .leading, spacing: 7) { alternativePicker; addButton }
            }
            if let index = drafts.firstIndex(where: { $0.id == selected }) {
                let active = drafts[index]
                NavigationLink {
                    ForecastEditor(store: store, draft: active) { changed in
                        if let index = drafts.firstIndex(where: { $0.id == changed.id }) { drafts[index] = changed }
                        savedTemplate = false
                    }
                } label: {
                    HStack {
                        planRow(active.plan, detail: active.replacesCurrent ? label("Replace current regimen") : label("Add to current regimen"))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(TrackerTheme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("forecast.edit")

                if active.start.trackerHours > store.nowH + Double(weeks * 168) {
                    Text("This regimen starts after the simulation period.")
                        .font(.footnote)
                        .foregroundStyle(TrackerTheme.muted)
                }
                HStack {
                    if drafts.count > 1 {
                        Button("Remove alternative", role: .destructive) {
                            drafts.removeAll { $0.id == selected }
                            if let first = drafts.first { selected = first.id }
                            savedTemplate = false
                        }
                    }
                    Spacer(minLength: 8)
                    if active.isValid {
                        Button(savedTemplate ? "Template saved" : "Save as template") {
                            savedTemplate = store.saveTemplate(DoseTemplate(
                                name: trackerDrugName(active.plan.ester), route: active.plan.route, ester: active.plan.ester,
                                doseMG: active.plan.doseMG, extras: active.plan.extras
                            ))
                        }
                        .disabled(savedTemplate)
                    }
                }
                .font(.subheadline)
                .buttonStyle(.plain)
                .foregroundStyle(TrackerTheme.accent)
            }
        }
        .onChange(of: selected) { savedTemplate = false }
    }

    private var alternativePicker: some View {
        TrackerSegment(options: drafts.map(\.id), selection: $selected, title: alternativeTitle)
            .accessibilityIdentifier("forecast.alternatives")
    }

    @ViewBuilder
    private var addButton: some View {
        if drafts.count < 3 {
            Button {
                drafts.append(newDraft(id: nextID, regimens: request.regimens))
                selected = nextID
                nextID += 1
            } label: {
                Label("Add alternative", systemImage: "plus")
                    .font(.subheadline)
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("forecast.add")
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { TrackerSectionTitle(title: "Concentration simulation"); Spacer(minLength: 4); horizonPicker }
                VStack(alignment: .leading, spacing: 8) { TrackerSectionTitle(title: "Concentration simulation"); horizonPicker }
            }
            if busy {
                ProgressView("Calculating…")
                    .frame(maxWidth: .infinity, minHeight: 185)
                    .accessibilityIdentifier("forecast.loading")
            } else if let result {
                chart(result)
                chartLegend(result)
                readout(result)
                metrics(result)
                if let active = result.outcomes.first(where: { $0.id == selected }), active.runs > 1 {
                    Text("Timing spread ±\(result.timingSpread.formatted(.number.precision(.fractionLength(1)))) h · \(active.runs) simulations")
                        .font(.caption)
                        .foregroundStyle(TrackerTheme.muted)
                }
            } else {
                Text("Enter a dose in a trial regimen to see the estimate.")
                    .font(.footnote)
                    .foregroundStyle(TrackerTheme.muted)
            }
        }
    }

    private var horizonPicker: some View {
        TrackerSegment(options: horizons, selection: $weeks) { value in
            switch value {
            case 4: "4 weeks"
            case 8: "8 weeks"
            default: "12 weeks"
            }
        }
        .accessibilityIdentifier("forecast.horizon")
    }

    private func chart(_ result: ForecastResult) -> some View {
        let start = result.now - 14 * 24
        let visible = result.outcomes.first { $0.id == selected }
        let target = result.series.target
        return Chart {
            if let target {
                RectangleMark(xStart: .value("Time", start), xEnd: .value("Time", result.end),
                              yStart: .value("Low", target.lowerBound), yEnd: .value("High", target.upperBound))
                    .foregroundStyle(TrackerTheme.band.opacity(0.5))
            }
            if let visible {
                ForEach(visible.band, id: \.hour) { point in
                    AreaMark(x: .value("Time", point.hour),
                             yStart: .value("Low", point.low), yEnd: .value("High", point.high))
                        .foregroundStyle(color(visible.id).opacity(0.17))
                }
            }
            ForEach(result.history, id: \.hour) { point in
                LineMark(x: .value("Time", point.hour), y: .value("Concentration", point.value), series: .value("Series", -1))
                    .foregroundStyle(TrackerTheme.chartLine)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
            ForEach(result.outcomes) { outcome in
                ForEach(outcome.expected, id: \.hour) { point in
                    LineMark(x: .value("Time", point.hour), y: .value("Concentration", point.value),
                             series: .value("Series", outcome.id))
                        .foregroundStyle(color(outcome.id).opacity(outcome.id == selected || outcome.id == 0 ? 1 : 0.65))
                        .lineStyle(StrokeStyle(lineWidth: outcome.id == selected ? 2.1 : 1.5,
                                               dash: outcome.id == 0 ? [3, 4] : [7, 4]))
                }
            }
            RuleMark(x: .value("Now", result.now))
                .foregroundStyle(TrackerTheme.muted)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            if let cursor {
                RuleMark(x: .value("Selected time", cursor))
                    .foregroundStyle(TrackerTheme.accent.opacity(0.6))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: start...result.end)
        .chartXAxis {
            AxisMarks(values: axisHours(result)) { mark in
                AxisValueLabel {
                    if let hour = mark.as(Double.self) {
                        if hour == result.now {
                            Text("Now").fontWeight(.medium)
                        } else {
                            Text(Date(trackerHours: hour).formatted(.dateTime.month(.defaultDigits).day().timeZone(store.calendar.timeZone)))
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) {
                AxisGridLine().foregroundStyle(TrackerTheme.separator)
                AxisValueLabel()
            }
        }
        .chartXSelection(value: $cursor)
        .frame(height: 225)
        .accessibilityLabel("Projected concentration, \(result.series.unit)")
        .accessibilityIdentifier("forecast.chart")
    }

    private func axisHours(_ result: ForecastResult) -> [Double] {
        let interval = (result.end - result.now) / 4
        return [result.now] + (1...4).map { result.now + Double($0) * interval }
    }

    private func chartLegend(_ result: ForecastResult) -> some View {
        let legend = result.outcomes.map { outcome in
            Text(outcome.id == 0 ? "Continuation of current regimen" : alternativeTitle(outcome.id))
                .foregroundStyle(color(outcome.id))
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { ForEach(legend.indices, id: \.self) { legend[$0] } }
            VStack(alignment: .leading, spacing: 5) { ForEach(legend.indices, id: \.self) { legend[$0] } }
        }
        .font(.caption)
    }

    private func readout(_ result: ForecastResult) -> some View {
        let hour = cursor ?? result.now
        let values = result.outcomes.compactMap { outcome -> String? in
            guard outcome.id == 0 || outcome.id == selected,
                  let point = (hour < result.now ? result.history : outcome.expected)
                    .min(by: { abs($0.hour - hour) < abs($1.hour - hour) })
            else { return nil }
            return result.series.formatted(point.value) + " " + result.series.unit
        }
        let date = cursor == nil ? label("Now") : Date(trackerHours: hour)
            .formatted(.dateTime.month().day().hour().minute().timeZone(store.calendar.timeZone))
        return Text(([date] + values).joined(separator: " · "))
            .font(.footnote.monospacedDigit())
            .accessibilityIdentifier("forecast.readout")
    }

    private func metrics(_ result: ForecastResult) -> some View {
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Week \(weeks)").font(.subheadline.weight(.medium))
                Spacer()
                Text(result.series.unit).font(.caption).foregroundStyle(TrackerTheme.muted)
            }
            ForEach(result.outcomes) { outcome in
                if let summary = outcome.metrics {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(outcome.id == 0 ? "Current regimen" : alternativeTitle(outcome.id))
                                .font(.footnote)
                                .foregroundStyle(color(outcome.id))
                            Spacer()
                            steadyLabel(outcome.steadyHour, now: result.now)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack { metricColumns(summary, series: result.series) }
                            VStack(alignment: .leading) { metricColumns(summary, series: result.series) }
                        }
                    }
                    .font(.footnote)
                    .padding(12)
                    .background(TrackerTheme.subtle, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if result.outcomes.contains(where: { $0.id == selected && !$0.band.isEmpty }) {
                Text("Shaded area: 10th–90th simulation percentiles.")
                    .font(.caption)
                    .foregroundStyle(TrackerTheme.muted)
            }
        }
        .accessibilityIdentifier("forecast.metrics")
    }

    @ViewBuilder
    private func steadyLabel(_ hour: Double?, now: Double) -> some View {
        if let hour {
            if hour <= now {
                Text("At steady state").foregroundStyle(TrackerTheme.muted)
            } else {
                Text("Steady by week \(Int(ceil((hour - now) / 168)))").foregroundStyle(TrackerTheme.muted)
            }
        } else {
            Text("Not steady within \(weeks) weeks").foregroundStyle(TrackerTheme.muted)
        }
    }

    @ViewBuilder
    private func metricColumns(_ summary: ForecastMetrics, series: ConcentrationSeries) -> some View {
        metric("Trough", value: series.formatted(summary.trough))
        metric("Peak", value: series.formatted(summary.peak))
        metric("Average", value: series.formatted(summary.average))
        if let share = summary.inTarget {
            metric("In target", value: share.formatted(.percent.precision(.fractionLength(0))))
        }
    }

    private func metric(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(TrackerTheme.muted)
            Text(verbatim: value).monospacedDigit()
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func planRow(_ plan: MedicationPlan, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trackerDrugName(plan.ester)).font(.subheadline)
            Text(planDoseCaption(plan) + " · " + detail)
                .font(.footnote)
                .foregroundStyle(TrackerTheme.muted)
        }
        .padding(.vertical, 6)
    }

    private func alternativeTitle(_ id: Int) -> LocalizedStringKey {
        switch drafts.firstIndex(where: { $0.id == id }) {
        case 0: "Regimen A"
        case 1: "Regimen B"
        default: "Regimen C"
        }
    }

    private func color(_ id: Int) -> Color {
        guard id > 0, let index = drafts.firstIndex(where: { $0.id == id }) else { return TrackerTheme.secondaryChart }
        return comparisonColors[index]
    }

    private func newDraft(id: Int, regimens: [ForecastRegimen]) -> ForecastDraft {
        let main = regimens.first {
            let plan = $0.schedule.plan
            return PlanChoice.routes(for: store.mode, forecast: true).contains(plan.route) &&
                PlanChoice.drugs(plan.route, mode: store.mode, forecast: true).contains(plan.ester)
        }?.schedule
        let modePlan = PlanChoice.newPlan(for: store.mode)
        return ForecastDraft(id: id, plan: main?.plan ?? modePlan,
                             start: main.map { Date(trackerHours: $0.first) } ?? store.now, replacesCurrent: true)
    }

    private var request: ForecastRequest {
        let plans = store.plans.compactMap { plan in
            store.nextScheduledTime(plan).map {
                ScheduledMedication(plan: plan, first: $0 <= store.now ? ceil(store.nowH) : $0.trackerHours,
                                    timeZone: store.calendar.timeZone)
            }
        }
        let timeline = TimelineRequest(events: store.doses, labs: store.labs, mode: store.mode,
                                       weight: store.weight, birthYear: store.ageModelEnabled ? store.birthYear : nil,
                                       parameters: store.pkParameters,
                                       method: store.calibrationMethod,
                                       history: store.calibrationHistory, scheduled: plans, now: store.nowH, range: .week)
        return ForecastRequest(timeline: timeline, weeks: weeks, drafts: drafts,
                               regimens: ForecastRegimen.current(events: store.doses, plans: plans, now: store.nowH))
    }
}

private struct ForecastEditor: View {
    let store: TrackerStore
    let onSave: (ForecastDraft) -> Void
    @State var draft: ForecastDraft
    @Environment(\.dismiss) private var dismiss

    init(store: TrackerStore, draft: ForecastDraft, onSave: @escaping (ForecastDraft) -> Void) {
        self.store = store
        self.onSave = onSave
        _draft = State(initialValue: draft)
    }

    var body: some View {
        Form {
            PlanMedicationFields(mode: store.mode, plan: $draft.plan, forecast: true)
            DatePicker("Start time", selection: $draft.start, in: store.now...)
                .environment(\.timeZone, store.calendar.timeZone)
            Toggle("Replace current regimen of the same hormone", isOn: $draft.replacesCurrent)
        }
        .navigationTitle("Edit trial regimen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Update simulation") {
                    if draft.plan.route == .patchApply && draft.plan.extras["patchWearH"] == nil {
                        draft.plan.extras["patchWearH"] = draft.plan.everyDays * 24
                    }
                    onSave(draft)
                    dismiss()
                }
                .disabled(!draft.isValid)
            }
        }
    }
}
