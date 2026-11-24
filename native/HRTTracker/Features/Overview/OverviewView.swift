import HRTEngine
import SwiftUI

struct OverviewView: View {
    let store: TrackerStore
    @State private var range: TrackerChartRange = .week
    @State private var timeline: TimelineModel?
    @State private var loadedRequest: TimelineRequest?
    @State private var shareSnapshot: ConcentrationShareSnapshot?
    @State private var showDose = false
    @State private var showInfo = false
    @State private var earlyPlan: MedicationPlan?
    @State private var loggedPlans: [String: String] = [:]
    @ScaledMetric(relativeTo: .largeTitle) private var mainValueSize: CGFloat = 56
    @ScaledMetric(relativeTo: .largeTitle) private var pairedValueSize: CGFloat = 44

    var body: some View {
        let request = timelineRequest
        let shareableTimeline = loadedRequest == request && timeline?.traces.isEmpty == false ? timeline : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TrackerHeader(title: "Overview", subtitle: dateLabel) {
                    Button {
                        if let shareableTimeline {
                            shareSnapshot = ConcentrationShareSnapshot(
                                timeline: shareableTimeline, calendar: store.calendar, range: request.range,
                                monochrome: store.appearance == .mono
                            )
                        }
                    } label: {
                        Label {
                            Text("Share")
                        } icon: {
                            TrackerTheme.navigationIcon("square.and.arrow.up")
                        }
                        .font(.subheadline)
                        .frame(minHeight: 44)
                        .foregroundStyle(TrackerTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(shareableTimeline == nil)
                    .opacity(shareableTimeline == nil ? 0.5 : 1)
                    .accessibilityIdentifier("overview.share")
                }
                currentLevel
                todayPlan
                InventoryAlertsView(store: store)
                Divider().overlay(TrackerTheme.separator)
                if let timeline, !timeline.traces.isEmpty {
                    ConcentrationTimeline(model: timeline, calendar: store.calendar, range: $range)
                } else if request.events.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        TrackerSectionTitle(title: "Hormone concentration over time")
                        Text("No dose records yet")
                            .font(.footnote)
                            .foregroundStyle(TrackerTheme.muted)
                        Button("Record dose") { showDose = true }
                            .font(.subheadline)
                    }
                } else if loadedRequest != request {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    Text("No supported concentration model for these records.")
                        .font(.footnote)
                        .foregroundStyle(TrackerTheme.muted)
                }
                Divider().overlay(TrackerTheme.separator)
                DoseHeatmap(doses: store.doses, now: store.now, calendar: store.calendar)
                NavigationLink {
                    ForecastView(store: store)
                } label: {
                    TrackerLinkLabel(title: "Regimen simulation")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("overview.forecast")
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 12)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(TrackerTheme.background.ignoresSafeArea())
        .foregroundStyle(TrackerTheme.ink)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: request) {
            if request.events.isEmpty {
                timeline = nil
                loadedRequest = request
                return
            }
            if loadedRequest?.mode != request.mode { timeline = nil }
            let calculation = Task.detached(priority: .userInitiated) { TimelineModel.calculate(request) }
            let result = await withTaskCancellationHandler {
                await calculation.value
            } onCancel: {
                calculation.cancel()
            }
            if !Task.isCancelled {
                timeline = result
                loadedRequest = request
            }
        }
        .sheet(isPresented: $showDose) { DoseEditorView(store: store) }
        .sheet(item: $shareSnapshot) { snapshot in
            ConcentrationSharePreview(snapshot: snapshot)
        }
        .sheet(isPresented: $showInfo) {
            VStack(alignment: .leading, spacing: 16) {
                TrackerSectionTitle(title: "About concentration estimates")
                Text("Concentrations are model estimates and may differ substantially from laboratory results.")
                    .foregroundStyle(TrackerTheme.muted)
                Button("Done") { showInfo = false }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Record ahead of schedule?", isPresented: Binding(
            get: { earlyPlan != nil },
            set: { if !$0 { earlyPlan = nil } }
        ), titleVisibility: .visible, presenting: earlyPlan) { plan in
            Button("Record now") { complete(plan) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var timelineRequest: TimelineRequest {
        let explicit = store.plans.compactMap { plan in
            store.nextScheduledTime(plan).map {
                ScheduledMedication(plan: plan, first: $0 <= store.now ? ceil(store.nowH) : $0.trackerHours,
                                    timeZone: store.calendar.timeZone)
            }
        }
        let scheduled = store.showPrediction
            ? ForecastRegimen.current(events: store.doses, plans: explicit, now: store.nowH).map(\.schedule)
            : []
        return TimelineRequest(events: store.doses, labs: store.labs, mode: store.mode,
                               weight: store.weight, birthYear: store.ageModelEnabled ? store.birthYear : nil,
                               parameters: store.pkParameters,
                               method: store.calibrationMethod,
                               history: store.calibrationHistory, scheduled: scheduled, now: store.now.trackerHours,
                               range: range)
    }

    private var dateLabel: String {
        store.now.formatted(.dateTime.month().day().weekday(.wide).timeZone(store.calendar.timeZone))
    }

    private var currentLevel: some View {
        let primary: ConcentrationSeries = store.mode == .transmasc ? .testosterone : .e2
        let plotted = timeline?.traces.map(\.kind) ?? []
        let series = plotted.isEmpty ? [primary] : plotted
        let testosterone = plotted.first == .testosterone
        let hasCompanion = testosterone || series.count > 1
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Current estimate")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.footnote)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(TrackerTheme.accent)
                .accessibilityLabel("About concentration estimates")
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    if let first = series.first { estimate(first, paired: hasCompanion) }
                    if hasCompanion {
                        Spacer(minLength: 0)
                        if testosterone {
                            estimate(.testosterone, paired: true, alternateUnit: true, alignTrailing: true)
                        } else {
                            estimate(.cpa, paired: true, alignTrailing: true)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(series, id: \.self) { estimate($0, paired: hasCompanion) }
                    if testosterone { estimate(.testosterone, paired: true, alternateUnit: true) }
                }
            }
            if let kind = series.first, let comparison = kind.comparisonRange, let target = kind.target {
                LevelRail(range: comparison, target: target,
                          value: timeline?.value(kind, at: store.now.trackerHours))
            }
        }
        .accessibilityIdentifier("overview.estimate")
    }

    private func estimate(
        _ kind: ConcentrationSeries, paired: Bool, alternateUnit: Bool = false, alignTrailing: Bool = false
    ) -> some View {
        let mainValue = timeline?.traces.contains(where: { $0.kind == kind }) == true
            ? timeline?.value(kind, at: store.now.trackerHours) : nil
        let value = alternateUnit ? mainValue.map { $0 / 28.842 } : mainValue
        let unit = alternateUnit ? "nmol/L" : kind.unit
        let size = paired ? pairedValueSize : mainValueSize
        return VStack(alignment: alignTrailing ? .trailing : .leading, spacing: 3) {
            Text(alternateUnit ? label("Total testosterone") : kind.name)
                .font(.footnote)
                .foregroundStyle(TrackerTheme.muted)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    estimateReading(kind, value: value, unit: unit, size: size)
                }
                VStack(alignment: .leading, spacing: 2) {
                    estimateReading(kind, value: value, unit: unit, size: size)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            if !alternateUnit, let value, let target = kind.target {
                Text(value < target.lowerBound ? "Below target range" :
                     value > target.upperBound ? "Above target range" : "Within target range")
                    .font(.caption)
                    .foregroundStyle(target.contains(value) ? TrackerTheme.good : TrackerTheme.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func estimateReading(_ kind: ConcentrationSeries, value: Double?, unit: String, size: CGFloat) -> some View {
        Text(value.map(kind.formatted) ?? "—")
            .font(.system(size: size, weight: .light))
            .monospacedDigit()
        Text(unit).font(.footnote).foregroundStyle(TrackerTheme.muted)
    }

    private var todayPlan: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Today's plan")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(TrackerTheme.muted)
                .accessibilityAddTraits(.isHeader)
            ForEach(store.plans) { plan in
                planRow(plan)
            }
            NavigationLink {
                MedicationPlansView(store: store)
            } label: {
                TrackerLinkLabel(title: "Medication plan")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("overview.plan")
        }
    }

    private func planRow(_ plan: MedicationPlan) -> some View {
        let status = store.planStatus(plan)
        return HStack(spacing: 11) {
            TrackerIcon(systemName: plan.route.trackerIcon)
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.route == .patchApply && plan.ester == "E2" ? label("Replace estradiol patch") : trackerDrugName(plan.ester))
                    .font(.subheadline)
                Text(planDoseCaption(plan) + (plan.route == .oral ? " · " + label("Oral") : "") + " · " + statusLabel(status))
                    .font(.footnote)
                    .foregroundStyle(TrackerTheme.muted)
            }
            Spacer(minLength: 4)
            if case .taken = status {
                if let id = loggedPlans[plan.id] {
                    Button("Undo") {
                        if store.deleteDose(id) { loggedPlans[plan.id] = nil }
                    }
                    .font(.subheadline)
                    .foregroundStyle(TrackerTheme.accent)
                    .frame(minHeight: 44)
                }
                Image(systemName: "checkmark")
                    .foregroundStyle(TrackerTheme.good)
                    .accessibilityLabel("Completed")
            } else {
                Button(completionLabel(plan.route)) {
                    if case .rest = status { earlyPlan = plan } else { complete(plan) }
                }
                .font(.subheadline)
                .foregroundStyle(TrackerTheme.accent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("plan.complete.\(plan.ester)")
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 5)
    }

    private func statusLabel(_ status: MedicationPlanStatus) -> String {
        switch status {
        case .taken:
            label("Recorded today")
        case .due(let done, let total):
            total > 1 ? String(localized: "\(done) of \(total) recorded") : label("Due today")
        case .rest(let next):
            String(localized: "Next \(next.formatted(.dateTime.month(.defaultDigits).day().timeZone(store.calendar.timeZone)))")
        }
    }

    private func completionLabel(_ route: Route) -> LocalizedStringKey {
        switch route {
        case .patchApply: "Replaced"
        case .oral, .sublingual: "Taken"
        case .injection, .sc: "Injected"
        default: "Record"
        }
    }

    private func complete(_ plan: MedicationPlan) {
        if let event = store.complete(plan) { loggedPlans[plan.id] = event.id }
    }
}

private struct LevelRail: View {
    let range: ClosedRange<Double>
    let target: ClosedRange<Double>
    let value: Double?

    var body: some View {
        VStack(spacing: 5) {
            Canvas { context, size in
                let targetTicks = tick(target.lowerBound)...tick(target.upperBound)
                let current = value.map(tick)
                for index in 0...36 {
                    let isCurrent = index == current
                    let inTarget = targetTicks.contains(index)
                    let filled = current.map { index < $0 } ?? false
                    let height: CGFloat = isCurrent ? 18 : inTarget ? 11 : 7
                    let width: CGFloat = isCurrent ? 3 : 1
                    let color = isCurrent ? TrackerTheme.good : inTarget ? TrackerTheme.chartLine :
                        filled ? TrackerTheme.muted : TrackerTheme.secondaryChart.opacity(0.45)
                    let x = (size.width - 2) * CGFloat(index) / 36 + 1
                    let rect = CGRect(x: x - width / 2, y: size.height - height, width: width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                }
            }
            .frame(height: 19)
            .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(range.lowerBound, format: .number)
                    Spacer()
                    targetLabel
                    Spacer()
                    Text(range.upperBound, format: .number)
                }
                targetLabel
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(TrackerTheme.muted)
        }
    }

    private var targetLabel: some View {
        Text("Target range \(target.lowerBound.formatted(.number))–\(target.upperBound.formatted(.number))")
    }

    private func tick(_ value: Double) -> Int {
        let clamped = value.clamped(to: range)
        return Int((36 * log(clamped / range.lowerBound) / log(range.upperBound / range.lowerBound)).rounded())
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
