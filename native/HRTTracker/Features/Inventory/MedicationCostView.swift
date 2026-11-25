import HRTEngine
import SwiftUI

struct StockUseDetails: View {
    let use: StockUse

    var body: some View {
        if let selected = use.selected {
            let units = use.parts.reduce(0) { $0 + $1.units }
            LabeledContent(inventoryText("Stock used"), value: "\(stockNumber(units)) \(selected.pack.kind.unit)")
            let prices = stockCostTotals(use.parts)
            ForEach(prices.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { currency in
                LabeledContent(use.complete ? inventoryText("Dose cost") : inventoryText("Priced subtotal"),
                               value: stockMoney(prices[currency, default: 0], currency))
            }
            if use.parts.contains(where: { $0.cost == nil }) { Text(inventoryText("Price needed")) }
            if use.missingStock { Text(inventoryText("Missing stock")) }
        }
    }
}

func stockCostTotals(_ parts: [StockAllocation]) -> [StockCurrency: Decimal] {
    var totals: [StockCurrency: Decimal] = [:]
    for part in parts {
        if let cost = part.cost, let currency = part.supply.purchase?.currency {
            totals[currency, default: 0] += cost
        }
    }
    return totals
}

private struct CostSpecification: Hashable {
    let medication: InventoryMedication
    let pack: MedicationPack
    init(_ supply: MedicationSupply) {
        medication = InventoryMedication(route: supply.route, ester: supply.ester)
        pack = supply.pack
    }
}

private enum CostEditor: Identifiable {
    case price(MedicationSupply), specification(DoseEvent), stock(DoseEvent)

    var id: String {
        switch self {
        case let .price(s): "price-" + s.id
        case let .specification(e): "spec-" + e.id
        case let .stock(e): "stock-" + e.id
        }
    }
}

struct MedicationCostView: View {
    let store: TrackerStore
    let inventory: InventorySnapshot
    @State private var range = MedicationCostRange.last30
    @State private var expanded = false
    @State private var editing: CostEditor?

    var body: some View {
        let start = range.start(now: store.now, calendar: store.calendar)
        let uses = inventory.ledger.uses.filter { $0.dose.timeH >= (start?.trackerHours ?? -.infinity) }
        let parts = uses.flatMap(\.parts)
        let totals = stockCostTotals(parts)
        let complete = uses.filter(\.complete).count
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { title; Spacer(); periodPicker }
                VStack(alignment: .leading) { title; periodPicker }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(complete < uses.count ? inventoryText("Priced subtotal") : inventoryText("Estimated medication cost"))
                    .font(.footnote).foregroundStyle(TrackerTheme.muted)
                if totals.isEmpty {
                    Text(uses.isEmpty ? inventoryText("No doses in this period") : inventoryText("Cost pending"))
                } else {
                    ForEach(totals.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { currency in
                        HStack(alignment: .firstTextBaseline) {
                            Text(stockMoney(totals[currency, default: 0], currency))
                                .font(.system(.largeTitle).weight(.light)).monospacedDigit()
                                .accessibilityIdentifier("cost.total.\(currency.rawValue)")
                            Text(currency.rawValue).font(.footnote).foregroundStyle(TrackerTheme.muted)
                        }
                    }
                }
                Text(periodCaption(start: start, complete: complete, count: uses.count))
                    .font(.footnote).foregroundStyle(TrackerTheme.muted)
            }
            pendingRows(uses: uses, parts: parts)
            Button { expanded.toggle() } label: {
                HStack {
                    Text(inventoryText("Details by specification"))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityIdentifier("cost.details")
            if expanded { detailRows(parts) }
            NavigationLink { InventoryView(store: store) } label: {
                HStack { Text(inventoryText("Inventory")); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                    .frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("cost.inventory")
        }
        .buttonStyle(.plain)
        .sheet(item: $editing) { item in
            switch item {
            case let .price(lot):
                let status = InventoryStockStatus(supply: lot, remaining: inventory.ledger.remaining[lot.id, default: 0],
                                                  regimens: inventory.regimens, nowH: store.nowH)
                NavigationStack { InventoryEditor(store: store, existing: status, regimens: inventory.regimens, priceFirst: true) }
            case let .stock(event):
                NavigationStack { InventoryEditor(store: store, existing: nil, regimens: inventory.regimens, forDose: event, linkDoseID: event.id) }
            case let .specification(event):
                NavigationStack {
                    List {
                        if let use = inventory.ledger.uses.first(where: { $0.id == event.id }) {
                            ForEach(use.choices) { lot in
                                Button {
                                    var dose = use.dose
                                    dose.inventorySupplyId = lot.id
                                    if store.saveDose(dose) { editing = nil }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(stockChoiceLabel(lot, for: event.route))
                                        let units = stockQuantity(route: event.route, doseMG: event.doseMG, extras: event.extras) / lot.pack.unitMG
                                        Text("\(stockNumber(units)) \(lot.pack.kind.unit) · \(stockPriceLabel(lot))")
                                            .font(.footnote).foregroundStyle(TrackerTheme.muted)
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle(inventoryText("Choose specification"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } } }
                }.presentationDetents([.medium, .large])
            }
        }
    }

    private var title: some View {
        Text(inventoryText("Medication cost")).font(.headline.weight(.medium)).accessibilityAddTraits(.isHeader)
    }

    private var periodPicker: some View {
        HStack(spacing: 0) {
            ForEach(MedicationCostRange.allCases, id: \.self) { choice in
                Button {
                    range = choice
                } label: {
                    Text(choice.title).font(.footnote).padding(.horizontal, 6).padding(.vertical, 5)
                        .background(range == choice ? TrackerTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityAddTraits(range == choice ? .isSelected : [])
                .accessibilityIdentifier("cost.range.\(choice.rawValue)")
            }
        }.background(TrackerTheme.subtle, in: RoundedRectangle(cornerRadius: 10))
    }

    private func periodCaption(start: Date?, complete: Int, count: Int) -> String {
        let style = Date.FormatStyle().month().day().timeZone(store.calendar.timeZone)
        let end = store.now.formatted(style)
        let dates = start.map { range == .today ? end : "\($0.formatted(style)) – \(end)" } ?? inventoryText("All records")
        return count == 0 ? dates : "\(dates) · " + inventoryText("\(complete) / \(count) priced")
    }

    @ViewBuilder
    private func pendingRows(uses: [StockUse], parts: [StockAllocation]) -> some View {
        let lots = Dictionary(grouping: parts.filter { $0.cost == nil }, by: \.supply.id).values.compactMap(\.first)
        ForEach(lots.sorted { $0.supply.id < $1.supply.id }, id: \.supply.id) { part in
            let supply = part.supply
            action(inventoryText("Price needed"), trackerDrugName(supply.ester) + " · " + packageDetail(supply.pack),
                   inventoryText("Add price")) { editing = .price(supply) }
                .accessibilityIdentifier("cost.price.\(supply.id)")
        }
        ForEach([true, false], id: \.self) { ambiguous in
            let groups = Dictionary(grouping: uses.filter { ambiguous ? $0.needsSpecification : $0.missingStock }) {
                InventoryMedication(route: $0.dose.route, ester: $0.dose.ester)
            }
            ForEach(groups.keys.sorted { $0.id < $1.id }) { med in
                if let first = groups[med]?.first {
                    let date = Date(trackerHours: first.dose.timeH).formatted(.dateTime.month().day().timeZone(store.calendar.timeZone))
                    action(ambiguous ? inventoryText("Specification needed") : inventoryText("Missing stock"),
                           med.name + " · " + date, ambiguous ? inventoryText("Choose specification") : inventoryText("Add stock")) {
                        editing = ambiguous ? .specification(first.dose) : .stock(first.dose)
                    }
                    .accessibilityIdentifier("cost.\(ambiguous ? "spec" : "stock").\(med.id)")
                }
            }
        }
    }

    private func action(_ title: String, _ note: String, _ action: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title); Text(note).font(.footnote).foregroundStyle(TrackerTheme.muted)
                }
                Spacer()
                Text(action).font(.subheadline).foregroundStyle(TrackerTheme.accent)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(TrackerTheme.accent)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func detailRows(_ parts: [StockAllocation]) -> some View {
        let groups = Dictionary(grouping: parts) { CostSpecification($0.supply) }
        if groups.isEmpty { Text(inventoryText("No matched stock in this period")).font(.footnote).foregroundStyle(TrackerTheme.muted) }
        ForEach(groups.keys.sorted { ($0.medication.id, packageDetail($0.pack)) < ($1.medication.id, packageDetail($1.pack)) }, id: \.self) { spec in
            let items = groups[spec, default: []]
            let totals = stockCostTotals(items)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(spec.medication.name)
                    Text("\(packageDetail(spec.pack)) · \(stockNumber(items.reduce(0) { $0 + $1.units })) \(spec.pack.kind.unit)")
                        .font(.footnote).foregroundStyle(TrackerTheme.muted)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    ForEach(totals.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { currency in
                        Text("\(stockMoney(totals[currency, default: 0], currency)) \(currency.rawValue)").monospacedDigit()
                    }
                    if items.contains(where: { $0.cost == nil }) { Text(inventoryText("Price needed")).font(.footnote) }
                }
            }
        }
    }
}

private extension MedicationCostRange {
    var title: String {
        switch self {
        case .today: inventoryText("Today")
        case .last7: inventoryText("7d")
        case .last30: inventoryText("30d")
        case .all: inventoryText("All")
        }
    }
}
