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
    @ScaledMetric(relativeTo: .largeTitle) private var mainValueSize: CGFloat = 42
    @ScaledMetric(relativeTo: .largeTitle) private var pairedValueSize: CGFloat = 36

    var body: some View {
        let request = timelineRequest
        let shareableTimeline = loadedRequest == request && timeline?.traces.isEmpty == false ? timeline : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !request.events.isEmpty {
                    currentLevel(request: request, shareableTimeline: shareableTimeline)
                }
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

    private func currentLevel(request: TimelineRequest, shareableTimeline: TimelineModel?) -> some View {
        let primary: ConcentrationSeries = request.mode == .transmasc ? .testosterone : .e2
        let value = estimateValue(primary)
        let reading = EstimateReading(
            title: primary == .testosterone ? label("Total testosterone") : primary.name,
            number: value.map(primary.formatted), unit: primary.unit
        )
        let companion = companionReading(primary: primary, value: value, events: request.events)

        return VStack(alignment: .leading, spacing: 10) {
            estimateHeader(shareableTimeline: shareableTimeline, chartRange: request.range)
            if let companion {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        estimateColumn(reading, size: pairedValueSize)
                        Spacer(minLength: 0)
                        estimateColumn(companion, size: pairedValueSize, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        estimateColumn(reading, size: pairedValueSize)
                        estimateColumn(companion, size: pairedValueSize)
                    }
                }
            } else {
                let cats = OverviewPixelCats(hasDoses: !request.events.isEmpty, hasLabs: !request.labs.isEmpty)
                VStack(alignment: .leading, spacing: 4) {
                    estimateLabel(reading.title)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            estimateNumber(reading, size: mainValueSize)
                                .frame(minWidth: mainValueSize * 4.3, alignment: .leading)
                            cats
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            estimateNumber(reading, size: mainValueSize)
                            cats
                        }
                    }
                }
            }
            if let value {
                OverviewLevelRail(kind: primary, value: value)
            }
        }
        .padding(.horizontal, 7)
    }

    private func estimateHeader(shareableTimeline: TimelineModel?, chartRange: TrackerChartRange) -> some View {
        HStack(spacing: 12) {
            Button {
                showInfo = true
            } label: {
                HStack(spacing: 7) {
                    Text("Current estimated level")
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .opacity(0.75)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityHint("About concentration estimates")
            .accessibilityIdentifier("overview.estimate.info")
            Spacer(minLength: 0)
            Button {
                if let shareableTimeline {
                    shareSnapshot = ConcentrationShareSnapshot(
                        timeline: shareableTimeline, calendar: store.calendar, range: chartRange,
                        monochrome: store.appearance == .mono
                    )
                }
            } label: {
                Label {
                    Text("Share")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .regular))
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .disabled(shareableTimeline == nil)
            .opacity(shareableTimeline == nil ? 0.5 : 1)
            .accessibilityIdentifier("overview.share")
        }
        .buttonStyle(.plain)
        .font(.subheadline)
        .foregroundStyle(TrackerTheme.muted)
    }

    private func estimateValue(_ kind: ConcentrationSeries) -> Double? {
        guard let timeline, timeline.traces.contains(where: { $0.kind == kind }),
              let value = timeline.value(kind, at: store.nowH), value.isFinite, value > 0 else { return nil }
        return value
    }

    private func companionReading(
        primary: ConcentrationSeries, value: Double?, events: [DoseEvent]
    ) -> EstimateReading? {
        if primary == .testosterone {
            return value.map {
                EstimateReading(title: nil, number: ($0 / 28.842).formatted(.number.precision(.fractionLength(1))),
                                unit: "nmol/L")
            }
        }
        guard events.contains(where: ConcentrationSeries.cpa.matches) else { return nil }
        let cpa = estimateValue(.cpa).flatMap { $0 >= 0.1 ? $0 : nil }
        return EstimateReading(title: ConcentrationSeries.cpa.name,
                               number: cpa?.formatted(.number.precision(.fractionLength(1))),
                               unit: ConcentrationSeries.cpa.unit)
    }

    private func estimateColumn(
        _ reading: EstimateReading, size: CGFloat, alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            estimateLabel(reading.title)
            estimateNumber(reading, size: size)
        }
        .accessibilityElement(children: .combine)
    }

    private func estimateLabel(_ title: String?) -> some View {
        Text(verbatim: title ?? " ")
            .font(.footnote)
            .foregroundStyle(TrackerTheme.muted)
            .accessibilityHidden(title == nil)
    }

    private func estimateNumber(_ reading: EstimateReading, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: reading.number ?? "—")
                .font(.system(size: size, weight: .light).monospacedDigit())
                .foregroundStyle(reading.number == nil ? TrackerTheme.muted : TrackerTheme.ink)
            if reading.number != nil {
                Text(verbatim: reading.unit).font(.subheadline).foregroundStyle(TrackerTheme.muted)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
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

private struct EstimateReading {
    let title: String?
    let number: String?
    let unit: String
}
