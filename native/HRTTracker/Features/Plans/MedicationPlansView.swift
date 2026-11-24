import HRTEngine
import SwiftUI
import UIKit

func planDoseCaption(_ plan: MedicationPlan) -> String {
    if plan.route == .patchApply, let release = plan.extras["releaseRateUGPerDay"] {
        let count = max(1, plan.extras["patchCount"].flatMap { Int(exactly: $0) } ?? 1)
        let perPatch = (release / Double(count)).formatted(.number.precision(.fractionLength(0...2)))
        return count == 1 ? String(localized: "\(perPatch) µg/day") :
            String(localized: "\(perPatch) µg/day × \(count) patches")
    }
    return plan.doseMG.formatted(.number.precision(.fractionLength(0...3))) + " mg"
}

func planRepeatCaption(_ plan: MedicationPlan) -> String {
    if plan.everyDays == 1 { return label("Daily") }
    if plan.everyDays < 1 { return String(localized: "Every \((plan.everyDays * 24).formatted(.number)) hours") }
    return String(localized: "Every \(plan.everyDays.formatted(.number)) days")
}

struct MedicationPlansView: View {
    let store: TrackerStore

    var body: some View {
        List {
            Section("Plan entries") {
                ForEach(store.plans) { plan in
                    NavigationLink {
                        MedicationPlanEditor(store: store, plan: plan)
                    } label: {
                        HStack(spacing: 11) {
                            TrackerIcon(systemName: plan.route.trackerIcon)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(trackerDrugName(plan.ester))
                                Text(planDoseCaption(plan) + " · " + planRepeatCaption(plan))
                                    .font(.footnote)
                                    .foregroundStyle(TrackerTheme.muted)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { _ = store.deletePlan(plan.id) }
                    }
                }
                NavigationLink("Add plan entry") { MedicationPlanEditor(store: store) }
                    .accessibilityIdentifier("plan.add")
            }
            Section {
                NavigationLink("Reminder settings") { ReminderSettingsView(store: store) }
            }
        }
        .navigationTitle("Medication plan")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ReminderSettingsView: View {
    let store: TrackerStore
    @State private var authorizing = false
    @State private var permissionDenied = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Toggle("Medication reminders", isOn: remindersBinding)
                .disabled(authorizing)
        }
        .navigationTitle("Reminder settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Allow notifications in Settings", isPresented: $permissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var remindersBinding: Binding<Bool> {
        Binding {
            store.remindersEnabled
        } set: { enabled in
            if !enabled || store.isDemo {
                store.remindersEnabled = enabled
                return
            }
            authorizing = true
            Task { @MainActor in
                let allowed = await MedicationNotifications.authorize()
                store.remindersEnabled = allowed
                permissionDenied = !allowed
                authorizing = false
            }
        }
    }
}

enum PlanChoice {
    static let intervals: [Double] = [1, 2, 3, 3.5, 5, 7, 10, 14, 28, 84]
    static let forecastIntervals: [Double] = [0.5, 1, 2, 3.5, 5, 7, 10, 14]

    static func routes(for mode: HRTMode, forecast: Bool = false) -> [Route] {
        if forecast {
            return mode == .transmasc ? [.injection, .gel, .patchApply] : [.patchApply, .injection, .oral, .sublingual, .gel]
        }
        return mode == .transmasc ? [.injection, .gel, .nasal, .sc, .pellet, .oral, .patchApply] :
            [.patchApply, .injection, .oral, .sublingual, .gel, .nasal, .sc, .pellet]
    }

    static func drugs(_ route: Route, mode: HRTMode, forecast: Bool = false) -> [String] {
        if mode == .transmasc {
            switch route {
            case .injection: return ["TC", "TE", "TU"]
            case .sc: return ["T", "TC", "TE"]
            case .oral: return ["TU"]
            default: return ["T"]
            }
        }
        switch route {
        case .injection: return forecast ? ["EV", "EB", "EC", "EN", "EU"] : ["EV", "EB", "EC", "EN", "EU", "LEUP", "TRIP"]
        case .oral: return forecast ? ["E2", "EV"] : ["E2", "EV", "CPA", "SPIRO", "BICA", "MPA", "RLX"]
        case .sublingual: return ["E2", "EV"]
        default: return ["E2"]
        }
    }

    static func newPlan(for mode: HRTMode) -> MedicationPlan {
        mode == .transmasc ? MedicationPlan(route: .injection, ester: "TC", doseMG: 0, everyDays: 7) :
            MedicationPlan(route: .patchApply, ester: "E2", doseMG: 0, everyDays: 2)
    }
}

struct PlanMedicationFields: View {
    let mode: HRTMode
    @Binding var plan: MedicationPlan
    let forecast: Bool

    var body: some View {
        Picker("Route", selection: $plan.route) {
            ForEach(PlanChoice.routes(for: mode, forecast: forecast), id: \.self) { route in
                Text(route.trackerTitle).tag(route)
            }
        }
        .onChange(of: plan.route) { _, route in
            let drugs = PlanChoice.drugs(route, mode: mode, forecast: forecast)
            if !drugs.contains(plan.ester), let first = drugs.first { plan.ester = first }
            plan.doseMG = 0
            plan.extras = [:]
        }

        Picker("Medication", selection: $plan.ester) {
            ForEach(PlanChoice.drugs(plan.route, mode: mode, forecast: forecast), id: \.self) { ester in
                Text(trackerDrugName(ester)).tag(ester)
            }
        }

        if plan.route == .patchApply {
            let existingMass = plan.doseMG > 0 && plan.extras["releaseRateUGPerDay"] == nil
            if existingMass {
                amountField("Total dose (mg)", value: $plan.doseMG)
            } else {
                amountField("Total release rate (µg/day)", value: extra("releaseRateUGPerDay"))
            }
            amountField("Wear duration (days)", value: extra("patchWearH", scale: 24))
        } else {
            amountField("Dose (mg)", value: $plan.doseMG)
        }

        if plan.route == .sublingual {
            Picker("Absorption tier", selection: sublingualTier) {
                Text("Quick · 2 min").tag(0)
                Text("Casual · 5 min").tag(1)
                Text("Standard · 10 min").tag(2)
                Text("Strict · 15 min").tag(3)
            }
        }

        let options = forecast ? PlanChoice.forecastIntervals : PlanChoice.intervals
        let intervals = Array(Set(options + [plan.everyDays])).sorted()
        Picker("Dosing interval", selection: $plan.everyDays) {
            ForEach(intervals, id: \.self) { days in
                if days == 1 {
                    Text("Daily").tag(days)
                } else if days < 1 {
                    Text("Every \((days * 24).formatted(.number)) hours").tag(days)
                } else {
                    Text("Every \(days.formatted(.number)) days").tag(days)
                }
            }
        }
    }

    private var sublingualTier: Binding<Int> {
        Binding {
            plan.extras["sublingualTier"].flatMap { Int(exactly: $0) } ?? 2
        } set: { tier in
            plan.extras["sublingualTier"] = Double(tier)
            plan.extras["sublingualTheta"] = nil
        }
    }

    private func amountField(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number.precision(.fractionLength(0...4)))
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
        }
    }

    private func extra(_ key: String, scale: Double = 1) -> Binding<Double> {
        Binding {
            (plan.extras[key] ?? 0) / scale
        } set: { value in
            plan.extras[key] = value > 0 ? value * scale : nil
            if key == "releaseRateUGPerDay" { plan.extras["patchCount"] = nil }
        }
    }
}

private struct MedicationPlanEditor: View {
    let store: TrackerStore
    let isNew: Bool
    @State private var plan: MedicationPlan
    @Environment(\.dismiss) private var dismiss
    @State private var showError = false

    init(store: TrackerStore, plan: MedicationPlan? = nil) {
        self.store = store
        self.isNew = plan == nil
        _plan = State(initialValue: plan ?? PlanChoice.newPlan(for: store.mode))
    }

    var body: some View {
        Form {
            Section {
                PlanMedicationFields(mode: store.mode, plan: $plan, forecast: false)
            }
            Section("Frequency and time") {
                DatePicker("Scheduled time", selection: scheduleTime, displayedComponents: .hourAndMinute)
                    .environment(\.timeZone, store.calendar.timeZone)
                Toggle("Medication reminders", isOn: $plan.remindersEnabled)
            }
            if !isNew {
                Section {
                    Button("Delete plan entry", role: .destructive) {
                        if store.deletePlan(plan.id) { dismiss() } else { showError = true }
                    }
                }
            }
        }
        .navigationTitle(isNew ? "Add plan entry" : "Edit medication plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if plan.route == .patchApply && plan.extras["patchWearH"] == nil {
                        plan.extras["patchWearH"] = plan.everyDays * 24
                    }
                    if store.savePlan(plan) { dismiss() } else { showError = true }
                }
                .disabled(plan.doseMG <= 0 && (plan.extras["releaseRateUGPerDay"] ?? 0) <= 0)
            }
        }
        .alert("Could not save changes", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        }
    }

    private var scheduleTime: Binding<Date> {
        Binding {
            let minutes = plan.reminderMinute
            return store.calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: store.now) ?? store.now
        } set: { date in
            let parts = store.calendar.dateComponents([.hour, .minute], from: date)
            plan.reminderMinute = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
        }
    }
}
