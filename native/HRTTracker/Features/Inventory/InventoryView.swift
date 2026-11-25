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
                Text(stockSpecificationLabel(status.supply)).font(.footnote).foregroundStyle(TrackerTheme.muted)
                Text(inventoryRunOut(status, nowH: store.nowH, calendar: store.calendar))
                    .font(.footnote)
                    .foregroundStyle(low ? TrackerTheme.accent : TrackerTheme.muted)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Text(inventoryText("\(inventoryRemaining(status)) remaining")).font(.subheadline.monospacedDigit())
                Text(stockPriceLabel(status.supply)).font(.footnote).foregroundStyle(TrackerTheme.muted)
            }.multilineTextAlignment(.trailing)
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
    let inventory: InventorySnapshot

    var body: some View {
        let low = inventory.combinedStatuses.filter {
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

struct InventorySnapshot {
    let regimens: [MedicationPlan]
    let statuses: [InventoryStockStatus]
    let combinedStatuses: [InventoryStockStatus]
    let ledger: InventoryLedger

    @MainActor
    init(store: TrackerStore) {
        let supplies = store.supplies
        let nowH = store.nowH
        let events = store.doses
        let regimens = InventoryRegimens.current(events: events, plans: store.plans, nowH: nowH)
        self.regimens = regimens
        let ledger = InventoryLedger(supplies: supplies, events: events, nowH: nowH)
        self.ledger = ledger
        statuses = supplies.filter { $0.archivedAt == nil }.map {
            InventoryStockStatus(supply: $0, remaining: ledger.remaining[$0.id, default: 0], regimens: regimens, nowH: nowH)
        }
        let byMedication = Dictionary(grouping: statuses) { InventoryMedication(route: $0.supply.route, ester: $0.supply.ester) }
        combinedStatuses = byMedication.values.compactMap { group in
            guard let first = group.first else { return nil }
            return InventoryStockStatus(supply: first.supply, remaining: group.reduce(0) { $0 + $1.remaining },
                                        regimens: regimens, nowH: nowH)
        }.sorted { $0.id < $1.id }
    }
}

private struct InventoryEditorTarget: Identifiable {
    let status: InventoryStockStatus?

    var id: String { status?.id ?? "" }
}

struct InventoryMedication: Hashable, Identifiable {
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

struct InventoryEditor: View {
    private enum Field: String {
        case amount = "count"
        case opened, volume, strength, unitsPerPack, packCount, totalPrice
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
    @State private var editingPrice: Bool
    @State private var unitsPerPack: String
    @State private var packCount: String
    @State private var totalPrice: String
    @State private var currency: StockCurrency
    @State private var start: Date
    @State private var newLotID = UUID().uuidString.lowercased()
    @State private var confirmingDelete = false
    @State private var saveFailed = false
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @MainActor
    init(store: TrackerStore, existing: InventoryStockStatus?, regimens: [MedicationPlan],
         priceFirst: Bool = false, forDose dose: DoseEvent? = nil) {
        self.store = store
        self.existing = existing
        self.regimens = regimens
        var options = InventoryMedication.options(mode: store.mode, regimens: regimens)
        let requested = dose.map { InventoryMedication(route: $0.route, ester: $0.ester) }
        if let requested, !options.contains(requested) { options.append(requested) }
        self.options = options
        let medication = existing.map { InventoryMedication(route: $0.supply.route, ester: $0.supply.ester) }
            ?? requested ?? options.first ?? InventoryMedication(route: .oral, ester: "E2")
        _medication = State(initialValue: medication)
        let pack = existing?.supply.pack ?? dose?.inventorySupplyId.flatMap { id in store.supplies.first { $0.id == id }?.pack }
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
        let purchase = existing?.supply.purchase
        let currency = purchase?.currency ?? store.supplies.compactMap(\.purchase?.currency).first
            ?? Locale.current.currency.flatMap { StockCurrency(rawValue: $0.identifier) } ?? .CNY
        _editingPrice = State(initialValue: priceFirst)
        _currency = State(initialValue: currency)
        _unitsPerPack = State(initialValue: purchase.map { Self.input($0.unitsPerPack) } ?? "")
        _packCount = State(initialValue: Self.input(purchase?.packCount ?? 1))
        _totalPrice = State(initialValue: purchase?.totalMinor.map { Self.input(Double($0) / Double(currency.scale)) } ?? "")
        _start = State(initialValue: dose.map { Date(trackerHours: $0.timeH) } ?? store.now)
    }

    var body: some View {
        Form {
            if let existing {
                Picker(inventoryText("Adjust stock"), selection: $editingPrice) {
                    Text(inventoryText("Recount")).tag(false)
                    Text(inventoryText("Purchase price")).tag(true)
                }.pickerStyle(.segmented)
                Section {
                    LabeledContent(inventoryText("Medication"), value: medication.name)
                    LabeledContent(inventoryText("Package"), value: packageDetail(existing.supply.pack))
                    if case .patch(nil) = existing.supply.pack, editingPrice {
                        field(inventoryText("Release per patch (µg/24 h)"), value: $strength, field: .strength)
                    }
                }
            } else {
                Section {
                    Picker(inventoryText("Medication"), selection: $medication) {
                        ForEach(options) { item in Text(item.name).tag(item) }
                    }
                    .accessibilityIdentifier("inventory.medication")
                    let known = Set(store.supplies.filter { $0.ester == medication.ester && $0.route == medication.route }.map(\.pack))
                    if !known.isEmpty {
                        Menu(inventoryText("Use existing specification")) {
                            ForEach(known.sorted { packageDetail($0) < packageDetail($1) }, id: \.self) { pack in
                                Button(packageDetail(pack)) {
                                    kind = pack.kind
                                    let fields = Self.packParameters(pack)
                                    volume = fields.volume
                                    strength = fields.strength
                                }
                            }
                        }
                    }
                    Picker(inventoryText("Package"), selection: Binding(get: { kind }, set: { kind = $0; setDefaults($0) })) {
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
                    } else if kind == .patch {
                        field(inventoryText("Release per patch (µg/24 h)"), value: $strength, field: .strength)
                    }
                }
            }
            if existing == nil || !editingPrice {
                Section {
                    field(kind.countTitle, value: $count, field: .amount)
                    if kind == .vial {
                        field(inventoryText("Opened quantity (mg)"), value: $openedMG, field: .opened)
                    }
                    if existing == nil {
                        DatePicker(inventoryText("Stock starts"), selection: $start, in: ...store.now)
                    }
                } header: {
                    Text(existing == nil ? inventoryText("Quantity on hand") : inventoryText("Count what is left now"))
                }
            }
            if existing == nil || editingPrice {
                Section(inventoryText("Purchase price")) {
                    field(inventoryText("Package size (\(kind.unit)/\(kind.purchaseUnit))"), value: $unitsPerPack, field: .unitsPerPack)
                    field(inventoryText("Purchased quantity (\(kind.purchaseUnit))"), value: $packCount, field: .packCount)
                    Picker(inventoryText("Currency"), selection: $currency) {
                        ForEach(StockCurrency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    field(inventoryText("Total paid (optional)"), value: $totalPrice, field: .totalPrice)
                    if let price = purchase?.unitPrice {
                        LabeledContent(inventoryText("Unit price"), value: "\(stockMoney(price, currency, unit: true))/\(kind.unit)")
                    }
                }
            }
            if existing != nil {
                Section {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Text(inventoryText("Remove from inventory"))
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
            setDefaults(kind)
        }
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
        .confirmationDialog(inventoryText("Remove this stock? Previous medication costs are kept."), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(inventoryText("Remove from inventory"), role: .destructive) {
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
        if let existing, !(existing.supply.pack == .patch(rate: nil) && editingPrice) {
            pack = existing.supply.pack
        } else {
            switch kind {
            case .vial: pack = .vial(ml: decimal(volume) ?? 0, mgPerMl: decimal(strength) ?? 0)
            case .pill: pack = .pill(mg: decimal(strength) ?? 0)
            case .pump: pack = .pump(mg: decimal(strength) ?? 0)
            case .sachet: pack = .sachet(mg: decimal(strength) ?? 0)
            case .patch:
                if !strength.isEmpty && decimal(strength) == nil { return nil }
                pack = .patch(rate: decimal(strength))
            case .bulk: pack = .bulk
            }
        }
        guard pack.isValid else { return nil }
        if var supply = existing?.supply, editingPrice {
            guard let purchase else { return nil }
            supply.pack = pack
            supply.purchase = purchase
            return supply
        }
        guard let units = decimal(count), units >= 0 else { return nil }
        var total = units
        if kind == .vial, !openedMG.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let opened = decimal(openedMG), opened >= 0 else { return nil }
            total += opened / pack.unitMG
        }
        guard existing != nil || total > 0 else { return nil }
        if var supply = existing?.supply {
            let at = (store.isDemo ? store.now : Date()).timeIntervalSince1970 * 1_000
            var counts = supply.recounts ?? []
            counts.removeAll { $0.at == at }
            counts.append(StockRecount(at: at, count: total))
            supply.recounts = counts
            return supply.isValid ? supply : nil
        }
        guard let purchase else { return nil }
        var supply = MedicationSupply(id: newLotID, route: medication.route, ester: medication.ester, pack: pack,
                                      count: total, startedAt: start.timeIntervalSince1970 * 1_000)
        supply.purchase = purchase
        return supply.isValid ? supply : nil
    }

    private var purchase: StockPurchase? {
        let basis = existing?.supply.count ?? decimal(count) ?? 1
        guard let perPack = unitsPerPack.isEmpty ? max(basis, 1) : decimal(unitsPerPack),
              let packs = decimal(packCount) else { return nil }
        var minor: Int?
        if !totalPrice.isEmpty {
            guard let cents = StockPurchase.minorAmount(totalPrice, currency: currency, locale: locale) else { return nil }
            minor = cents
        }
        let value = StockPurchase(unitsPerPack: perPack, packCount: packs, totalMinor: minor, currency: currency)
        return value.isValid ? value : nil
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
            TextField(title, text: value, prompt: Text(field == .unitsPerPack ? Self.input(max(existing?.supply.count ?? decimal(count) ?? 1, 1)) : field == .totalPrice ? "—" : "0"))
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
        case let .patch(rate): ("", rate.map(input) ?? "")
        case .bulk: ("", "")
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
        stockInputNumber(input, locale: locale)
    }

    private static func input(_ number: Double) -> String {
        number.formatted(.number.grouping(.never).precision(.fractionLength(0...12)))
    }
}

extension MedicationPack.Kind {
    var unit: String {
        switch self {
        case .pill: inventoryText("tablet")
        case .patch: inventoryText("patch")
        case .vial: inventoryText("vial")
        case .sachet: inventoryText("sachet")
        case .pump: inventoryText("pump")
        case .bulk: "mg"
        }
    }

    var purchaseUnit: String {
        switch self {
        case .pump: inventoryText("bottle")
        case .bulk: inventoryText("pack")
        default: inventoryText("box")
        }
    }

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

func packageDetail(_ pack: MedicationPack) -> String {
    switch pack {
    case let .vial(ml, mgPerMl): inventoryText("\(stockNumber(ml)) mL · \(stockNumber(mgPerMl)) mg/mL")
    case let .pill(mg), let .pump(mg), let .sachet(mg): "\(stockNumber(mg)) mg/\(pack.kind.unit)"
    case let .patch(rate?): "\(stockNumber(rate)) µg/24 h"
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

func stockNumber(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...6)))
}

func stockMoney(_ value: Decimal, _ currency: StockCurrency, unit: Bool = false) -> String {
    value.formatted(.currency(code: currency.rawValue).precision(.fractionLength(currency.fractionDigits...(unit ? 6 : currency.fractionDigits))))
}

func stockPriceLabel(_ supply: MedicationSupply) -> String {
    guard let purchase = supply.purchase, let price = purchase.unitPrice else { return inventoryText("Price needed") }
    return "\(stockMoney(price, purchase.currency, unit: true))/\(supply.pack.kind.unit)"
}

private func stockSpecificationLabel(_ supply: MedicationSupply) -> String {
    let specification = packageDetail(supply.pack)
    guard let purchase = supply.purchase else { return specification }
    let kind = supply.pack.kind
    return "\(specification) · \(stockNumber(purchase.unitsPerPack)) \(kind.unit)/\(kind.purchaseUnit)"
}

func inventoryText(_ key: String.LocalizationValue) -> String {
    label(key, table: "Inventory")
}
