import HRTEngine
import SwiftUI

@MainActor
struct DoseEditorView: View {
    let store: TrackerStore
    let event: DoseEvent?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("dose.quickPresets.v1") private var savedQuickPresets = Data()
    @State private var time: Date
    @State private var route: Route
    @State private var ester: String
    @State private var amount: String
    @State private var equivalent: String
    @State private var lastInput: DoseInput = .raw
    @State private var patchBasis: PatchBasis
    @State private var patchRate: String
    @State private var patchMG: String
    @State private var patchCount: Int
    @State private var wearDays: String
    @State private var sublingualTier: Tier
    @State private var holdMinutes: String
    @State private var gelSite: GelSite
    @State private var batch = false
    @State private var daysBetween = "1"
    @State private var numberOfDoses = 7
    @State private var templateName = ""
    @State private var showingTemplateName = false
    @State private var templateSaved = false
    @State private var formError: String?
    @State private var demoPresetRevision = 0

    private static var demoPresets: [String: [Double]] = [:]

    private enum DoseInput { case raw, equivalent }
    private enum PatchBasis: String { case rate, total }

    private enum Tier: Int, CaseIterable {
        case quick, casual, standard, strict, custom

        var title: String {
            switch self {
            case .quick: HistoryText.localized("Quick 2 minutes")
            case .casual: HistoryText.localized("Casual 5 minutes")
            case .standard: HistoryText.localized("Standard 10 minutes")
            case .strict: HistoryText.localized("Strict 15 minutes")
            case .custom: HistoryText.localized("Custom")
            }
        }
    }

    private enum GelSite: Int, CaseIterable {
        case arm, thigh, scrotal

        var title: String {
            switch self {
            case .arm: HistoryText.localized("Arm")
            case .thigh: HistoryText.localized("Thigh")
            case .scrotal: HistoryText.localized("Scrotal")
            }
        }
    }

    init(store: TrackerStore, event: DoseEvent? = nil) {
        self.store = store
        self.event = event
        let latest = event ?? store.doses
            .filter { $0.route != .patchRemove && $0.timeH <= store.now.trackerHours }
            .max { $0.timeH < $1.timeH }
        let selectedRoute = latest?.route ?? (store.mode == .transfem ? .sublingual : .injection)
        let drug = latest?.ester ?? (store.mode == .transfem ? "EV" : "TC")
        let extras = latest?.extras ?? [:]
        let count = HistoryText.patchCount(extras)
        let rate = extras[HistoryText.rateKey]
        let savedDose = event?.doseMG
        _time = State(initialValue: event.map { Date(trackerHours: $0.timeH) } ?? store.now)
        _route = State(initialValue: selectedRoute)
        _ester = State(initialValue: drug)
        _amount = State(initialValue: savedDose.map(Self.inputText) ?? "")
        _equivalent = State(initialValue: savedDose.map { Self.inputText($0 * Self.factor(drug)) } ?? "")
        _patchBasis = State(initialValue: event?.route == .patchApply && rate == nil ? .total : .rate)
        _patchRate = State(initialValue: event == nil ? "" : rate.map { Self.inputText($0 / Double(count)) } ?? "")
        _patchMG = State(initialValue: savedDose.map { Self.inputText($0 / Double(count)) } ?? "")
        _patchCount = State(initialValue: count)
        _wearDays = State(initialValue: extras[HistoryText.wearKey].map { Self.inputText($0 / 24) } ?? "")
        let hold = extras[HistoryText.thetaKey].map { HRTEngine.sublingualHoldMinutes(fromTheta: $0) }
        _sublingualTier = State(initialValue: hold == nil
            ? Tier(rawValue: Self.boundedIndex(extras[HistoryText.tierKey], through: 3, default: 2)) ?? .standard : .custom)
        _holdMinutes = State(initialValue: hold.map(Self.inputText) ?? "10")
        _gelSite = State(initialValue: GelSite(rawValue: Self.boundedIndex(extras[HistoryText.siteKey], through: 2, default: 0)) ?? .arm)
    }

    var body: some View {
        NavigationStack {
            Form {
                if event == nil, route != .patchRemove {
                    Section {
                        Toggle(isOn: $batch) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(HistoryText.localized("Batch add"))
                                Text(HistoryText.localized("Repeat the same dose at a regular interval"))
                                    .font(.footnote)
                                    .foregroundStyle(TrackerTheme.muted)
                            }
                        }
                        .accessibilityIdentifier("dose.batch")
                        if batch {
                            numberField("Interval in days", value: $daysBetween, id: "dose.batchInterval")
                            Stepper(value: $numberOfDoses, in: 2...24) {
                                LabeledContent(HistoryText.localized("Number of records"), value: String(numberOfDoses))
                            }
                            .accessibilityIdentifier("dose.batchCount")
                        }
                    }
                }

                Section {
                    if event == nil, !store.templates.isEmpty {
                        Menu {
                            ForEach(store.templates, id: \.id) { template in
                                Button(template.name) { loadTemplate(template) }
                            }
                        } label: {
                            Label(HistoryText.localized("Load template"), systemImage: "doc.on.doc")
                        }
                        .accessibilityIdentifier("dose.loadTemplate")
                    }
                    DatePicker(HistoryText.localized("Dose time"), selection: $time)
                        .accessibilityIdentifier("dose.time")
                    Picker(HistoryText.localized("Route"), selection: Binding(get: { route }, set: { selectRoute($0) })) {
                        ForEach(Self.routeOrder, id: \.self) { route in
                            Text(HistoryText.route(route)).tag(route)
                        }
                    }
                    .accessibilityIdentifier("dose.route")
                    if route != .patchRemove, availableDrugs.count > 1 {
                        Picker(HistoryText.localized("Medication"), selection: $ester) {
                            ForEach(availableDrugs, id: \.self) { code in
                                Text("\(HistoryText.drug(code)) (\(code))").tag(code)
                            }
                        }
                        .accessibilityIdentifier("dose.medication")
                    }
                }

                Section {
                    switch route {
                    case .patchRemove:
                        Text(HistoryText.localized("Record only the removal time. The model uses the time worn."))
                            .font(.footnote)
                            .foregroundStyle(TrackerTheme.muted)
                    case .patchApply:
                        patchFields
                    default:
                        dosageFields
                        if route == .sublingual { sublingualFields }
                        if route == .gel { gelFields }
                    }
                }

                if route != .patchRemove {
                    Section {
                        Button {
                            guard doseDraft() != nil else { return }
                            templateSaved = false
                            templateName = ""
                            showingTemplateName = true
                        } label: {
                            Label(HistoryText.localized("Save as template"), systemImage: "doc.badge.plus")
                        }
                        .accessibilityIdentifier("dose.saveTemplate")
                        if templateSaved {
                            Label(HistoryText.localized("Template saved"), systemImage: "checkmark")
                                .font(.footnote)
                                .foregroundStyle(TrackerTheme.good)
                                .accessibilityIdentifier("dose.templateSaved")
                        }
                    }
                }
                if let formError {
                    Text(formError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("dose.error")
                }
            }
            .scrollContentBackground(.hidden)
            .background(TrackerTheme.background)
            .tint(TrackerTheme.accent)
            .navigationTitle(HistoryText.localized(event == nil ? "Add dose record" : "Edit dose record"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(HistoryText.localized("Cancel")) { dismiss() }
                        .accessibilityIdentifier("dose.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(HistoryText.localized("Save"), action: save)
                        .accessibilityIdentifier("dose.save")
                }
            }
            .alert(HistoryText.localized("Save as template"), isPresented: $showingTemplateName) {
                TextField(HistoryText.localized("Template name"), text: $templateName)
                Button(HistoryText.localized("Save"), action: saveTemplate)
                Button(HistoryText.localized("Cancel"), role: .cancel) { }
            }
            .onChange(of: ester) { _, _ in
                switch lastInput {
                case .raw: setRaw(amount)
                case .equivalent: setEquivalent(equivalent)
                }
            }
        }
        .environment(\.timeZone, store.calendar.timeZone)
        .presentationDetents([.fraction(0.78), .large])
        .presentationDragIndicator(.visible)
    }

    private var availableDrugs: [String] {
        let drugs = Self.drugs(for: route, mode: store.mode)
        return drugs.contains(ester) ? drugs : drugs + [ester]
    }

    @ViewBuilder
    private var patchFields: some View {
        Picker(HistoryText.localized("Patch dose"), selection: $patchBasis) {
            Text(HistoryText.localized("Release rate")).tag(PatchBasis.rate)
            Text(HistoryText.localized("Total dose")).tag(PatchBasis.total)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("dose.patchBasis")
        if patchBasis == .rate {
            numberField("Release rate per patch (µg/day)", value: $patchRate, id: "dose.patchRate")
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach([25.0, 37.5, 50, 75, 100], id: \.self) { rate in
                        Button(HistoryText.localized("\(HistoryText.amount(rate)) µg/day")) {
                            patchRate = Self.inputText(rate)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("dose.patch.preset.\(Int(rate * 10))")
                    }
                }
            }
            .scrollIndicators(.hidden)
        } else {
            numberField("Dose per patch (mg)", value: $patchMG, id: "dose.patchMG")
        }
        Stepper(value: $patchCount, in: 1...10) {
            LabeledContent(HistoryText.localized("Patches"), value: String(patchCount))
        }
        .accessibilityIdentifier("dose.patchCount")
        LabeledContent(
            HistoryText.localized(patchBasis == .rate ? "Total release rate" : "Total dose"),
            value: patchTotalText
        )
        .foregroundStyle(TrackerTheme.muted)
        .accessibilityIdentifier("dose.patchTotal")
        numberField("Wear duration (days)", value: $wearDays, id: "dose.patchWearDays")
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Button(HistoryText.localized("Twice weekly (3.5 d)")) { wearDays = "3.5" }
                Button(HistoryText.localized("Weekly (7 d)")) { wearDays = "7" }
                Button(HistoryText.localized("Manual removal")) { wearDays = "" }
            }
            .buttonStyle(.bordered)
        }
        .scrollIndicators(.hidden)
        Text(HistoryText.localized("Leave wear duration blank to log removal separately."))
            .font(.footnote)
            .foregroundStyle(TrackerTheme.muted)
    }

    @ViewBuilder
    private var dosageFields: some View {
        let equivalentLabel: String.LocalizationValue = ["T", "TC", "TE", "TU"].contains(ester)
            ? "Testosterone equivalent (mg)" : "E2 equivalent (mg)"
        let rawOnly = HistoryText.equivalents[ester] == nil && ester != "E2"
        let showsReadout = ester == "EV" && [.injection, .oral].contains(route)
        let readout = equivalent.isEmpty ? "—" : equivalent

        if ester != "E2", route != .gel {
            numberField("Medication dose (mg)", value: Binding(get: { amount }, set: { setRaw($0) }), id: "dose.amount")
        }
        if showsReadout {
            LabeledContent(HistoryText.localized(equivalentLabel), value: readout)
                .foregroundStyle(TrackerTheme.muted)
        } else if !rawOnly || route == .gel {
            numberField(equivalentLabel, value: Binding(get: { equivalent }, set: { setEquivalent($0) }), id: "dose.equivalent")
        }

        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(quickPresets, id: \.self) { preset in
                    Button(HistoryText.localized("\(HistoryText.amount(preset)) mg")) {
                        setRaw(Self.inputText(preset))
                    }
                    .buttonStyle(.bordered)
                    .contextMenu {
                        Button(HistoryText.localized("Delete"), role: .destructive) {
                            writeQuickPresets(quickPresets.filter { $0 != preset })
                        }
                    }
                }
                Button {
                    guard let dose = calculatedAmount, dose > 0, dose <= 10_000 else {
                        formError = HistoryText.localized("Enter a valid dose before adding a shortcut.")
                        return
                    }
                    if !quickPresets.contains(dose) { writeQuickPresets(quickPresets + [dose]) }
                    formError = nil
                } label: {
                    Label(HistoryText.localized("Add quick dose"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("dose.addQuickPreset")
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var sublingualFields: some View {
        Picker(HistoryText.localized("Hold style"), selection: $sublingualTier) {
            ForEach(Tier.allCases, id: \.self) { tier in
                Text(tier.title).tag(tier)
            }
        }
        .accessibilityIdentifier("dose.sublingualTier")
        if sublingualTier == .custom {
            numberField("Hold time (minutes)", value: $holdMinutes, id: "dose.holdMinutes")
        }
    }

    private var gelFields: some View {
        Picker(HistoryText.localized("Application site"), selection: $gelSite) {
            ForEach(GelSite.allCases, id: \.self) { site in
                Text(site.title).tag(site)
            }
        }
        .accessibilityIdentifier("dose.gelSite")
    }

    private var patchTotalText: String {
        guard let patch = Self.number(patchBasis == .rate ? patchRate : patchMG), patch > 0 else { return "—" }
        let total = HistoryText.amount(patch * Double(patchCount))
        return patchBasis == .rate ? HistoryText.localized("\(total) µg/day") : HistoryText.localized("\(total) mg")
    }

    private var calculatedAmount: Double? {
        switch lastInput {
        case .raw: Self.number(amount)
        case .equivalent: Self.number(equivalent).map { $0 / Self.factor(ester) }
        }
    }

    private var quickPresetKey: String { "\(store.mode.rawValue):\(route.rawValue):\(ester)" }

    private var quickPresets: [Double] {
        if store.isDemo {
            _ = demoPresetRevision
            return Self.demoPresets[quickPresetKey] ?? []
        }
        return (try? JSONDecoder().decode([String: [Double]].self, from: savedQuickPresets))?[quickPresetKey] ?? []
    }

    private func writeQuickPresets(_ values: [Double]) {
        if store.isDemo {
            Self.demoPresets[quickPresetKey] = values.sorted()
            demoPresetRevision += 1
        } else {
            var cache = (try? JSONDecoder().decode([String: [Double]].self, from: savedQuickPresets)) ?? [:]
            cache[quickPresetKey] = values.sorted()
            if let data = try? JSONEncoder().encode(cache) { savedQuickPresets = data }
        }
    }

    private func numberField(_ title: String.LocalizationValue, value: Binding<String>, id: String) -> some View {
        LabeledContent(HistoryText.localized(title)) {
            TextField("0", text: value)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .accessibilityLabel(HistoryText.localized(title))
                .accessibilityIdentifier(id)
        }
    }

    private func setRaw(_ value: String) {
        lastInput = .raw
        amount = value
        equivalent = Self.number(value).map { Self.inputText($0 * Self.factor(ester)) } ?? ""
    }

    private func setEquivalent(_ value: String) {
        lastInput = .equivalent
        equivalent = value
        amount = Self.number(value).map { Self.inputText($0 / Self.factor(ester)) } ?? ""
    }

    private func selectRoute(_ selected: Route) {
        guard selected != route else { return }
        route = selected
        let drugs = Self.drugs(for: selected, mode: store.mode)
        if !drugs.contains(ester) {
            ester = drugs[0]
            setRaw("")
        }
        if selected == .patchRemove { batch = false }
    }

    private func loadTemplate(_ template: DoseTemplate) {
        route = template.route
        ester = template.ester
        patchCount = HistoryText.patchCount(template.extras)
        patchBasis = template.extras[HistoryText.rateKey] == nil ? .total : .rate
        patchRate = template.extras[HistoryText.rateKey].map { Self.inputText($0 / Double(patchCount)) } ?? ""
        patchMG = Self.inputText(template.doseMG / Double(patchCount))
        wearDays = template.extras[HistoryText.wearKey].map { Self.inputText($0 / 24) } ?? ""
        if let theta = template.extras[HistoryText.thetaKey] {
            sublingualTier = .custom
            holdMinutes = Self.inputText(HRTEngine.sublingualHoldMinutes(fromTheta: theta))
        } else {
            sublingualTier = Tier(rawValue: Self.boundedIndex(template.extras[HistoryText.tierKey], through: 3, default: 2)) ?? .standard
        }
        gelSite = GelSite(rawValue: Self.boundedIndex(template.extras[HistoryText.siteKey], through: 2, default: 0)) ?? .arm
        setRaw(Self.inputText(template.doseMG))
    }

    private func doseDraft() -> (amount: Double, extras: [String: Double])? {
        if route == .patchRemove { return (0, [:]) }
        var extras = event?.extras ?? [:]
        for key in [HistoryText.rateKey, HistoryText.countKey, HistoryText.wearKey, HistoryText.tierKey, HistoryText.thetaKey, HistoryText.siteKey] {
            extras.removeValue(forKey: key)
        }
        var dose = 0.0
        if route == .patchApply {
            guard let perPatch = Self.number(patchBasis == .rate ? patchRate : patchMG), perPatch > 0,
                  perPatch * Double(patchCount) <= 10_000 else { return invalidDose() }
            let total = perPatch * Double(patchCount)
            if patchBasis == .rate { extras[HistoryText.rateKey] = total } else { dose = total }
            if patchCount > 1 { extras[HistoryText.countKey] = Double(patchCount) }
            if !wearDays.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let wear = Self.number(wearDays), wear > 0, (wear * 24).isFinite else {
                    formError = HistoryText.localized("Enter a positive wear duration or leave it blank.")
                    return nil
                }
                extras[HistoryText.wearKey] = wear * 24
            }
        } else {
            guard let amount = calculatedAmount, amount > 0, amount <= 10_000 else { return invalidDose() }
            dose = amount
        }
        if route == .sublingual {
            if sublingualTier == .custom {
                guard let minutes = Self.number(holdMinutes), minutes >= 1 else {
                    formError = HistoryText.localized("Enter a hold time of at least 1 minute.")
                    return nil
                }
                extras[HistoryText.thetaKey] = HRTEngine.sublingualTheta(fromHoldMinutes: minutes)
            } else {
                extras[HistoryText.tierKey] = Double(sublingualTier.rawValue)
            }
        }
        if route == .gel { extras[HistoryText.siteKey] = Double(gelSite.rawValue) }
        formError = nil
        return (dose, extras)
    }

    private func invalidDose() -> (Double, [String: Double])? {
        formError = HistoryText.localized("Enter a dose greater than 0 and no more than 10000.")
        return nil
    }

    private func saveTemplate() {
        let name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            formError = HistoryText.localized("Enter a template name.")
            return
        }
        guard let dose = doseDraft() else { return }
        templateSaved = store.saveTemplate(DoseTemplate(
            name: name, route: route, ester: ester, doseMG: dose.amount, extras: dose.extras
        ))
        if !templateSaved {
            formError = HistoryText.localized("Could not update the records")
        }
    }

    private func save() {
        guard let draft = doseDraft() else { return }
        let updatedAt = store.now.timeIntervalSince1970 * 1_000
        let original = DoseEvent(
            id: event?.id ?? UUID().uuidString.lowercased(), route: route, timeH: time.trackerHours,
            doseMG: draft.amount, ester: ester, extras: draft.extras, updatedAt: updatedAt
        )
        let didSave: Bool
        if batch, event == nil, route != .patchRemove {
            guard let interval = Self.number(daysBetween), interval > 0,
                  (interval * Double(numberOfDoses) * 24).isFinite else {
                formError = HistoryText.localized("Enter a valid interval between records.")
                return
            }
            let later = (1..<numberOfDoses).map { index in
                DoseEvent(
                    route: route, timeH: original.timeH + Double(index) * interval * 24,
                    doseMG: original.doseMG, ester: original.ester, extras: original.extras, updatedAt: updatedAt
                )
            }
            didSave = store.saveDoses([original] + later)
        } else {
            didSave = store.saveDose(original)
        }
        if didSave { dismiss() } else { formError = HistoryText.localized("Could not update the records") }
    }

    private static let routeOrder: [Route] = [
        .injection, .oral, .sublingual, .gel, .patchApply, .patchRemove, .nasal, .sc, .pellet
    ]

    private static func drugs(for route: Route, mode: HRTMode) -> [String] {
        if mode == .transmasc {
            switch route {
            case .injection: return ["TC", "TE", "TU"]
            case .oral, .sublingual: return ["TU"]
            case .sc: return ["T", "TC", "TE"]
            default: return ["T"]
            }
        }
        switch route {
        case .injection: return ["EB", "EV", "EC", "EN", "EU", "LEUP", "TRIP"]
        case .oral: return ["E2", "EV", "CPA", "SPIRO", "BICA", "MPA", "RLX"]
        case .sublingual: return ["E2", "EV"]
        default: return ["E2"]
        }
    }

    private static func factor(_ ester: String) -> Double { HistoryText.equivalents[ester] ?? 1 }

    private static func number(_ value: String) -> Double? {
        let separator = Locale.current.decimalSeparator ?? "."
        guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: separator, with: ".")), number.isFinite else { return nil }
        return number
    }

    private static func inputText(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...3)))
    }

    private static func boundedIndex(_ value: Double?, through last: Int, default fallback: Int) -> Int {
        guard let value, value.isFinite else { return fallback }
        return Int(min(Double(last), max(0, value.rounded())))
    }
}
