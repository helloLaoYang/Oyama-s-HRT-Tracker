import HRTEngine
import SwiftUI
import UIKit

func planDoseCaption(_ plan: MedicationPlan) -> String {
    if plan.route == .patchApply, let release = plan.extras["releaseRateUGPerDay"] {
        let count = max(1, plan.extras["patchCount"].flatMap { Int(exactly: $0) } ?? 1)
        let perPatch = (release / Double(count)).formatted(.number.precision(.fractionLength(0...2)))
        return count == 1 ? label("\(perPatch) µg/day") :
            label("\(perPatch) µg/day × \(count) patches")
    }
    return plan.doseMG.formatted(.number.precision(.fractionLength(0...3))) + " mg"
}

func planRepeatCaption(_ plan: MedicationPlan) -> String {
    if plan.everyDays == 1 { return label("Daily") }
    if plan.everyDays < 1 { return label("Every \((plan.everyDays * 24).formatted(.number)) hours") }
    return label("Every \(plan.everyDays.formatted(.number)) days")
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
                                if let id = plan.inventorySupplyId, let lot = store.supplies.first(where: { $0.id == id }) {
                                    Text(packageDetail(lot.pack)).font(.footnote).foregroundStyle(TrackerTheme.muted)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("plan.edit.\(plan.ester)")
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
    var stock: MedicationSupply? = nil

    var body: some View {
        Picker("Route", selection: Binding(get: { plan.route }, set: { route in
            guard route != plan.route else { return }
            let keepStock = stock?.canSupply(route, plan.ester) == true
            plan.route = route
            let drugs = PlanChoice.drugs(route, mode: mode, forecast: forecast)
            if !drugs.contains(plan.ester), let first = drugs.first { plan.ester = first }
            if !keepStock {
                plan.doseMG = 0
                plan.inventorySupplyId = nil
            }
            plan.extras = [:]
        })) {
            ForEach(PlanChoice.routes(for: mode, forecast: forecast), id: \.self) { route in
                Text(route.trackerTitle).tag(route)
            }
        }

        Picker("Medication", selection: Binding(get: { plan.ester }, set: { drug in
            if plan.ester != drug {
                plan.ester = drug
                plan.inventorySupplyId = nil
            }
        })) {
            ForEach(PlanChoice.drugs(plan.route, mode: mode, forecast: forecast), id: \.self) { ester in
                Text(trackerDrugName(ester)).tag(ester)
            }
        }

        if plan.route == .patchApply {
            let existingMass = plan.doseMG > 0 && plan.extras["releaseRateUGPerDay"] == nil
            if existingMass {
                amountField("Total dose (mg)", value: $plan.doseMG)
            } else if !forecast {
                let title = HistoryText.localized("Release rate per patch (µg/day)")
                LabeledContent(title) {
                    TextField(title, value: perPatchRate, format: .number.precision(.fractionLength(0...4)))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                Stepper(value: patchCount, in: 1...max(10, patchCount.wrappedValue)) {
                    LabeledContent(HistoryText.localized("Patches"), value: String(patchCount.wrappedValue))
                }
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

    private var perPatchRate: Binding<Double> {
        Binding {
            (plan.extras["releaseRateUGPerDay"] ?? 0) / Double(HistoryText.patchCount(plan.extras))
        } set: { rate in
            plan.extras["releaseRateUGPerDay"] = rate > 0 ? rate * Double(HistoryText.patchCount(plan.extras)) : nil
        }
    }

    private var patchCount: Binding<Int> {
        Binding { HistoryText.patchCount(plan.extras) } set: { count in
            let rate = perPatchRate.wrappedValue
            plan.extras["patchCount"] = count > 1 ? Double(count) : nil
            perPatchRate.wrappedValue = rate
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
    @State private var addingStock = false
    @Environment(\.dismiss) private var dismiss
    @State private var showError = false

    init(store: TrackerStore, plan: MedicationPlan? = nil) {
        self.store = store
        self.isNew = plan == nil
        _plan = State(initialValue: plan ?? PlanChoice.newPlan(for: store.mode))
    }

    var body: some View {
        let specifications = InventorySpecifications(store.supplies)
        let selected = specifications.selected(plan)
        let choices = specifications.active.filter { $0.specification != selected?.specification } + [selected].compactMap { $0 }
        let needsChoice = selected == nil && !specifications.matching(plan).isEmpty
        Form {
            Section {
                if !choices.isEmpty {
                    Picker(inventoryText("Stock specification"), selection: Binding(
                        get: { selected?.id ?? "" },
                        set: { id in
                            guard let lot = specifications.byID[id] else { return }
                            if !lot.canSupply(plan.route, plan.ester) {
                                plan.route = lot.route
                                plan.ester = lot.ester
                                plan.doseMG = 0
                                plan.extras = [:]
                            }
                            if case let .patch(rate?) = lot.pack, plan.doseMG == 0 {
                                if let total = plan.extras["releaseRateUGPerDay"], total > 0 {
                                    let count = (total / rate).rounded()
                                    if (1...10).contains(count), abs(total - count * rate) <= total * 1e-9 {
                                        plan.extras["patchCount"] = count > 1 ? count : nil
                                    }
                                } else {
                                    plan.extras["releaseRateUGPerDay"] = rate
                                }
                            }
                            plan.inventorySupplyId = id
                        }
                    )) {
                        Text(inventoryText("Choose specification")).tag("")
                        ForEach(choices) { lot in
                            Text(InventoryMedication(route: lot.route, ester: lot.ester).name + " · " + packageDetail(lot.pack))
                                .tag(lot.id)
                        }
                    }
                    .accessibilityIdentifier("plan.inventorySpec")
                }
                PlanMedicationFields(mode: store.mode, plan: $plan, forecast: false, stock: selected)
                if specifications.matching(plan).isEmpty {
                    Button(inventoryText("Add stock")) { addingStock = true }
                }
            }
            if let selected, plan.doseMG > 0 || (plan.extras["releaseRateUGPerDay"] ?? 0) > 0 {
                let probe = DoseEvent(id: plan.id, route: plan.route, timeH: store.nowH, doseMG: plan.doseMG,
                                      ester: plan.ester, extras: plan.extras, inventorySupplyId: selected.id)
                if let use = InventoryLedger.preview(probe, supplies: store.supplies, events: store.doses) {
                    Section { StockUseDetails(use: use) }
                }
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
        .sheet(isPresented: $addingStock) {
            NavigationStack {
                InventoryEditor(store: store, existing: nil, regimens: [plan] + store.plans.filter { $0.id != plan.id },
                                forDose: DoseEvent(route: plan.route, timeH: store.nowH, doseMG: plan.doseMG,
                                                   ester: plan.ester, extras: plan.extras, inventorySupplyId: plan.inventorySupplyId))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if plan.route == .patchApply && plan.extras["patchWearH"] == nil {
                        plan.extras["patchWearH"] = plan.everyDays * 24
                    }
                    if store.savePlan(plan) { dismiss() } else { showError = true }
                }
                .disabled(needsChoice || (plan.doseMG <= 0 && (plan.extras["releaseRateUGPerDay"] ?? 0) <= 0))
                .accessibilityIdentifier("plan.save")
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
