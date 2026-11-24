import HRTEngine
import SwiftUI

struct InventoryView: View {
    @Bindable var store: TrackerStore
    @State private var editing: InventoryEditorTarget?

    var body: some View {
        let inventory = InventorySnapshot(store: store)
        List {
            if inventory.statuses.isEmpty {
                ContentUnavailableView {
                    Label(inventoryText("No inventory yet"), systemImage: "shippingbox")
                } description: {
                    Text(inventoryText("Add stock and it will be adjusted as you record medication."))
                }
                .listRowSeparator(.hidden)
                .listRowBackground(TrackerTheme.background)
            } else {
                ForEach(inventory.statuses) { status in
                    Button { editing = InventoryEditorTarget(status: status) } label: {
                        statusRow(status)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparatorTint(TrackerTheme.separator)
                    .listRowBackground(TrackerTheme.background)
                    .accessibilityIdentifier("inventory.supply.\(status.id)")
                }
            }

            Section {
                Picker(selection: $store.supplyLeadDays) {
                    ForEach(leadDayOptions, id: \.self) { days in
                        Text(inventoryText("\(days) days")).tag(days)
                    }
                } label: {
                    Text(inventoryText("Low-stock warning"))
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("inventory.leadDays")
                .listRowBackground(TrackerTheme.background)
            } header: {
                Text(inventoryText("Warn before stock runs out"))
                    .foregroundStyle(TrackerTheme.muted)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(TrackerTheme.background.ignoresSafeArea())
        .foregroundStyle(TrackerTheme.ink)
        .navigationTitle(inventoryText("Inventory"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = InventoryEditorTarget(status: nil) } label: {
                    Label {
                        Text(inventoryText("Add stock"))
                    } icon: {
                        TrackerTheme.navigationIcon("plus")
                    }
                }
                .accessibilityIdentifier("inventory.add")
            }
        }
        .sheet(item: $editing) { target in
            NavigationStack {
                InventoryEditor(store: store, existing: target.status, regimens: inventory.regimens)
            }
        }
    }

    private var leadDayOptions: [Int] {
        Array(Set([7, 14, 30, store.supplyLeadDays])).sorted()
    }

    private func statusRow(_ status: InventoryStockStatus) -> some View {
        let details = InventoryMedication(route: status.supply.route, ester: status.supply.ester)
        let low = status.isLow(leadDays: store.supplyLeadDays, nowH: store.nowH)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(details.name).font(.body)
                Text(inventoryRunOut(status, nowH: store.nowH, calendar: store.calendar))
                    .font(.footnote)
                    .foregroundStyle(low ? TrackerTheme.accent : TrackerTheme.muted)
            }
            Spacer(minLength: 6)
            Text(inventoryText("\(inventoryRemaining(status)) remaining"))
                .font(.subheadline.monospacedDigit())
                .multilineTextAlignment(.trailing)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(TrackerTheme.muted)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct InventoryAlertsView: View {
    let store: TrackerStore

    var body: some View {
        let low = InventorySnapshot(store: store).statuses.filter {
            $0.isLow(leadDays: store.supplyLeadDays, nowH: store.nowH)
        }
        if !low.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(low) { status in
                    NavigationLink {
                        InventoryView(store: store)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(alertText(status)).font(.subheadline)
                            Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
                        }
                        .foregroundStyle(TrackerTheme.accent)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inventory.alert.\(status.id)")
                }
            }
        }
    }

    private func alertText(_ status: InventoryStockStatus) -> String {
        let medication = InventoryMedication(route: status.supply.route, ester: status.supply.ester).name
        guard status.remaining > 0 else { return inventoryText("\(medication) is out of stock.") }
        return inventoryText("\(medication) is running low. \(inventoryRunOut(status, nowH: store.nowH, calendar: store.calendar))")
    }
}

private struct InventorySnapshot {
    let regimens: [MedicationPlan]
    let statuses: [InventoryStockStatus]

    @MainActor
    init(store: TrackerStore) {
        let supplies = store.supplies
        let nowH = store.nowH
        let events = store.doses
        let regimens = InventoryRegimens.current(events: events, plans: store.plans, nowH: nowH)
        self.regimens = regimens
        statuses = supplies.map { InventoryStockStatus(supply: $0, events: events, regimens: regimens, nowH: nowH) }
    }
}

private struct InventoryEditorTarget: Identifiable {
    let status: InventoryStockStatus?

    var id: String { status?.id ?? "" }
}

private struct InventoryMedication: Hashable, Identifiable {
    let route: Route
    let ester: String

    var id: String { "\(route.rawValue)|\(ester)" }

    var name: String {
        let routeName = RouteLabel.value(route)
        return inventoryText("\(trackerDrugName(ester)) · \(routeName)")
    }

    static func options(mode: HRTMode, regimens: [MedicationPlan]) -> [Self] {
        let current = regimens.map { Self(route: $0.route, ester: $0.ester) }
        let routes: [Route] = mode == .transmasc ? [.injection, .gel, .patchApply] : [.injection, .oral, .sublingual, .gel, .patchApply]
        let stockable = routes.flatMap { route -> [Self] in
            let drugs = route == .sublingual ? ["E2"] : PlanChoice.drugs(route, mode: mode)
            return drugs.map { Self(route: route, ester: $0) }
        }
        var seen: Set<Self> = []
        return (current + stockable).filter { seen.insert($0).inserted }
    }

    private enum RouteLabel {
        static func value(_ route: Route) -> String {
            switch route {
            case .injection: label("Injection")
            case .oral: label("Oral")
            case .sublingual: label("Sublingual")
            case .gel: label("Gel")
            case .patchApply, .patchRemove: inventoryText("Patch")
            case .nasal: label("Nasal")
            case .sc: label("Subcutaneous")
            case .pellet: label("Pellet")
            }
        }
    }
}

private struct InventoryEditor: View {
    private enum Field: String {
        case amount = "count"
        case opened, volume, strength
    }

    let store: TrackerStore
    let existing: InventoryStockStatus?
    let regimens: [MedicationPlan]
    let options: [InventoryMedication]

    @State private var medication: InventoryMedication
    @State private var kind: MedicationPack.Kind
    @State private var strength: String
    @State private var volume: String
    @State private var count: String
    @State private var openedMG: String
    @State private var confirmingDelete = false
    @State private var saveFailed = false
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @MainActor
    init(store: TrackerStore, existing: InventoryStockStatus?, regimens: [MedicationPlan]) {
        self.store = store
        self.existing = existing
        self.regimens = regimens
        let options = InventoryMedication.options(mode: store.mode, regimens: regimens)
        self.options = options
        let medication = existing.map { InventoryMedication(route: $0.supply.route, ester: $0.supply.ester) }
            ?? options.first ?? InventoryMedication(route: .oral, ester: "E2")
        _medication = State(initialValue: medication)
        let pack = existing?.supply.pack
            ?? Self.initialPack(MedicationPack.Kind.choices(for: medication.route)[0], medication: medication, regimens: regimens)
        _kind = State(initialValue: pack.kind)
        let fields = Self.packParameters(pack)
        _strength = State(initialValue: fields.strength)
        _volume = State(initialValue: fields.volume)
        _count = State(initialValue: existing.map {
            Self.input(pack.kind == .vial ? $0.remainingVials.whole : $0.remainingUnits)
        } ?? "")
        _openedMG = State(initialValue: existing.flatMap {
            pack.kind == .vial ? Self.input($0.remainingVials.openedMG) : nil
        } ?? "")
    }

    var body: some View {
        Form {
            if let existing {
                Section {
                    LabeledContent(inventoryText("Medication"), value: medication.name)
                    LabeledContent(inventoryText("Package"), value: packageDetail(existing.supply.pack))
                }
            } else {
                Section {
                    Picker(inventoryText("Medication"), selection: $medication) {
                        ForEach(options) { item in Text(item.name).tag(item) }
                    }
                    .accessibilityIdentifier("inventory.medication")
                    Picker(inventoryText("Package"), selection: $kind) {
                        ForEach(MedicationPack.Kind.choices(for: medication.route), id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .accessibilityIdentifier("inventory.pack")
                    if kind == .vial {
                        field(inventoryText("Vial volume (mL)"), value: $volume, field: .volume)
                        field(inventoryText("Concentration (mg/mL)"), value: $strength, field: .strength)
                    } else if [.pill, .pump, .sachet].contains(kind) {
                        field(massTitle, value: $strength, field: .strength)
                    }
                }
            }
            Section {
                field(kind.countTitle, value: $count, field: .amount)
                if kind == .vial {
                    field(inventoryText("Opened quantity (mg)"), value: $openedMG, field: .opened)
                }
            } header: {
                Text(existing == nil ? inventoryText("Quantity on hand") : inventoryText("Count what is left now"))
            }
            if existing != nil {
                Section {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Text(inventoryText("Delete stock"))
                    }
                    .accessibilityIdentifier("inventory.delete")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(TrackerTheme.background.ignoresSafeArea())
        .navigationTitle(existing == nil ? inventoryText("Add stock") : inventoryText("Adjust stock"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: medication) { _, item in
            let choices = MedicationPack.Kind.choices(for: item.route)
            if !choices.contains(kind) { kind = choices[0] }
            else if kind == .pill { setDefaults(.pill) }
        }
        .onChange(of: kind) { _, choice in setDefaults(choice) }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(inventoryText("Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(inventoryText("Save")) { save() }
                    .disabled(candidate == nil)
                    .accessibilityIdentifier("inventory.save")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(inventoryText("Done")) { focus = nil }
            }
        }
        .confirmationDialog(inventoryText("Delete this stock record?"), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(inventoryText("Delete stock"), role: .destructive) {
                if let existing, store.deleteSupply(existing.id) { dismiss() }
                else { saveFailed = true }
            }
        }
        .alert(inventoryText("Could not save inventory"), isPresented: $saveFailed) {
            Button(inventoryText("OK"), role: .cancel) {}
        }
    }

    private var candidate: MedicationSupply? {
        let pack: MedicationPack
        if let existing {
            pack = existing.supply.pack
        } else {
            switch kind {
            case .vial: pack = .vial(ml: decimal(volume) ?? 0, mgPerMl: decimal(strength) ?? 0)
            case .pill: pack = .pill(mg: decimal(strength) ?? 0)
            case .pump: pack = .pump(mg: decimal(strength) ?? 0)
            case .sachet: pack = .sachet(mg: decimal(strength) ?? 0)
            case .patch: pack = .patch
            case .bulk: pack = .bulk
            }
        }
        guard pack.isValid, let units = decimal(count), units >= 0 else { return nil }
        var total = units
        if kind == .vial, !openedMG.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let opened = decimal(openedMG), opened >= 0 else { return nil }
            total += opened / pack.unitMG
        }
        guard existing != nil || total > 0 else { return nil }
        let date = store.isDemo ? store.now : Date()
        let supply = MedicationSupply(
            id: existing?.id ?? UUID().uuidString.lowercased(),
            route: medication.route, ester: medication.ester, pack: pack,
            count: total, startedAt: date.timeIntervalSince1970 * 1_000
        )
        return supply.isValid ? supply : nil
    }

    private var massTitle: String {
        switch kind {
        case .pill: inventoryText("Strength (mg per tablet)")
        case .pump: inventoryText("Strength (mg per pump)")
        case .sachet: inventoryText("Strength (mg per sachet)")
        default: inventoryText("Strength (mg)")
        }
    }

    private func save() {
        guard let candidate else { return }
        if store.saveSupply(candidate) { dismiss() }
        else { saveFailed = true }
    }

    private func field(_ title: String, value: Binding<String>, field: Field) -> some View {
        LabeledContent(title) {
            TextField(title, text: value, prompt: Text("0"))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($focus, equals: field)
                .accessibilityIdentifier("inventory.\(field.rawValue)")
        }
    }

    private func setDefaults(_ choice: MedicationPack.Kind) {
        let pack = Self.initialPack(choice, medication: medication, regimens: regimens)
        let fields = Self.packParameters(pack)
        volume = fields.volume
        strength = fields.strength
    }

    private static func packParameters(_ pack: MedicationPack) -> (volume: String, strength: String) {
        switch pack {
        case let .vial(ml, mgPerMl): (input(ml), input(mgPerMl))
        case let .pill(mg), let .pump(mg), let .sachet(mg): ("", input(mg))
        case .patch, .bulk: ("", "")
        }
    }

    private static func initialPack(
        _ kind: MedicationPack.Kind, medication: InventoryMedication, regimens: [MedicationPlan]
    ) -> MedicationPack {
        let usualTabletMG: [String: Double] = ["CPA": 12.5, "SPIRO": 50, "BICA": 25, "MPA": 10, "RLX": 60]
        let planned = regimens.first { $0.route == medication.route && $0.ester == medication.ester }?.doseMG
        let tabletMG = planned.flatMap { $0 > 0 ? $0 : nil } ?? usualTabletMG[medication.ester] ?? 2
        return kind.defaultPack(pillStrength: tabletMG)
    }

    private func decimal(_ input: String) -> Double? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let format = FloatingPointFormatStyle<Double>.number.locale(locale)
        let amount = (try? format.parseStrategy.parse(text)) ?? Double(text)
        return amount.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func input(_ number: Double) -> String {
        number.formatted(.number.grouping(.never).precision(.fractionLength(0...12)))
    }
}

private extension MedicationPack.Kind {
    var title: String {
        switch self {
        case .vial: inventoryText("Vial")
        case .pill: inventoryText("Tablet")
        case .pump: inventoryText("Pump")
        case .sachet: inventoryText("Sachet")
        case .patch: inventoryText("Patch")
        case .bulk: inventoryText("Bulk (mg)")
        }
    }

    var countTitle: String {
        switch self {
        case .vial: inventoryText("Vials")
        case .pill: inventoryText("Tablets")
        case .pump: inventoryText("Pumps")
        case .sachet: inventoryText("Sachets")
        case .patch: inventoryText("Patches")
        case .bulk: inventoryText("Amount (mg)")
        }
    }
}

private func packageDetail(_ pack: MedicationPack) -> String {
    switch pack {
    case let .vial(ml, mgPerMl): inventoryText("\(stockNumber(ml)) mL · \(stockNumber(mgPerMl)) mg/mL")
    case let .pill(mg), let .pump(mg), let .sachet(mg): inventoryText("\(pack.kind.title) · \(stockNumber(mg)) mg per unit")
    case .patch, .bulk: pack.kind.title
    }
}

private func inventoryRemaining(_ status: InventoryStockStatus) -> String {
    let units = stockNumber(status.remainingUnits)
    switch status.supply.pack.kind {
    case .vial:
        let (whole, openedMG) = status.remainingVials
        if whole == 0 && openedMG >= 0.05 { return inventoryText("\(stockNumber(openedMG)) mg") }
        if openedMG >= 0.05 { return inventoryText("\(stockNumber(whole)) vials + \(stockNumber(openedMG)) mg") }
        return inventoryText(whole == 1 ? "\(units) vial" : "\(units) vials")
    case .pill: return inventoryText(status.remainingUnits == 1 ? "\(units) tablet" : "\(units) tablets")
    case .pump: return inventoryText(status.remainingUnits == 1 ? "\(units) pump" : "\(units) pumps")
    case .sachet: return inventoryText(status.remainingUnits == 1 ? "\(units) sachet" : "\(units) sachets")
    case .patch: return inventoryText(status.remainingUnits == 1 ? "\(units) patch" : "\(units) patches")
    case .bulk: return inventoryText("\(units) mg")
    }
}

private func inventoryRunOut(_ status: InventoryStockStatus, nowH: Double, calendar: Calendar) -> String {
    guard let projected = status.runOutH else { return inventoryText("No current regimen uses this stock.") }
    if status.remaining <= 0 { return inventoryText("Out of stock") }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    let date = formatter.string(from: Date(trackerHours: projected))
    let days = max(0, ((projected - nowH) / 24).rounded())
    let count = days.formatted()
    return inventoryText(days == 1 ? "About \(count) day left · \(date)" : "About \(count) days left · \(date)")
}

private func stockNumber(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2)))
}

private func inventoryText(_ key: String.LocalizationValue) -> String {
    String(localized: key, table: "Inventory")
}
