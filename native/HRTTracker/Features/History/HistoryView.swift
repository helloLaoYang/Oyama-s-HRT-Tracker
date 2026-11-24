import HRTEngine
import SwiftUI

struct HistoryView: View {
    let store: TrackerStore

    @State private var search = ""
    @State private var editing: EditMode = .inactive
    @State private var selected = Set<String>()
    @State private var editor: Editor?
    @State private var pendingDeletion: [String] = []
    @State private var confirmingDeletion = false
    @State private var failure = false

    private struct Editor: Identifiable {
        let id = UUID()
        let event: DoseEvent?
    }

    private struct DayGroup: Identifiable {
        var id: Date { day }
        let day: Date
        let records: [DoseEvent]
    }

    private var groups: [DayGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = store.doses.filter { event in
            query.isEmpty || [
                event.ester, HistoryText.drug(event.ester), HistoryText.route(event.route)
            ].contains { $0.localizedCaseInsensitiveContains(query) }
        }
        let byDay = Dictionary(grouping: matches) { event in
            store.calendar.startOfDay(for: Date(trackerHours: event.timeH))
        }
        return byDay.keys.sorted(by: >).map { day in
            DayGroup(day: day, records: (byDay[day] ?? []).sorted { $0.timeH > $1.timeH })
        }
    }

    var body: some View {
        List(selection: $selected) {
            if groups.isEmpty {
                ContentUnavailableView(
                    HistoryText.localized(search.isEmpty ? "No dose records" : "No matching records"),
                    systemImage: "list.clipboard"
                )
                .listRowSeparator(.hidden)
                .listRowBackground(TrackerTheme.background)
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.records, id: \.id) { event in
                            recordRow(event)
                                .tag(event.id)
                                .listRowBackground(TrackerTheme.surface)
                                .listRowSeparatorTint(TrackerTheme.separator)
                        }
                    } header: {
                        Text(group.day, format: .dateTime.month().day().weekday(.wide))
                            .font(.footnote)
                            .foregroundStyle(TrackerTheme.muted)
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(TrackerTheme.background)
        .navigationTitle(HistoryText.localized("Records"))
        .searchable(
            text: $search, placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(HistoryText.localized("Search medication or route"))
        )
        .environment(\.timeZone, store.calendar.timeZone)
        .environment(\.editMode, $editing)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if editing.isEditing {
                    Button(HistoryText.localized("Done")) {
                        editing = .inactive
                        selected = []
                    }
                    .accessibilityIdentifier("history.finishSelection")
                } else {
                    Button {
                        editor = Editor(event: nil)
                    } label: {
                        TrackerTheme.navigationIcon("plus")
                    }
                    .accessibilityLabel(HistoryText.localized("Add dose record"))
                    .accessibilityIdentifier("history.addDose")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if editing.isEditing {
                    Button(HistoryText.localized("Delete"), role: .destructive) {
                        confirmDeletion(Array(selected))
                    }
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("history.deleteSelection")
                } else if !groups.isEmpty {
                    Button(HistoryText.localized("Select")) { editing = .active }
                        .accessibilityIdentifier("history.select")
                }
            }
        }
        .sheet(item: $editor) { request in
            DoseEditorView(store: store, event: request.event)
        }
        .confirmationDialog(
            HistoryText.localized("Delete selected records?"),
            isPresented: $confirmingDeletion,
            titleVisibility: .visible
        ) {
            Button(HistoryText.localized("Delete"), role: .destructive) {
                if store.deleteDoses(pendingDeletion) {
                    selected = []
                    editing = .inactive
                } else {
                    failure = true
                }
                pendingDeletion = []
            }
            Button(HistoryText.localized("Cancel"), role: .cancel) { pendingDeletion = [] }
        }
        .alert(HistoryText.localized("Could not update the records"), isPresented: $failure) {
            Button(HistoryText.localized("OK"), role: .cancel) { }
        }
    }

    @ViewBuilder
    private func recordRow(_ event: DoseEvent) -> some View {
        if editing.isEditing {
            rowLabel(event)
        } else {
            HStack(spacing: 3) {
                Button {
                    editor = Editor(event: event)
                } label: {
                    rowLabel(event)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history.record.\(event.id)")
                Menu {
                    recordActions(event)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(TrackerTheme.accent)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(HistoryText.localized("More record actions"))
                .accessibilityIdentifier("history.recordActions.\(event.id)")
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    repeatDose(event)
                } label: {
                    Label(HistoryText.localized("Record again"), systemImage: "arrow.clockwise")
                }
                .tint(TrackerTheme.accent)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    confirmDeletion([event.id])
                } label: {
                    Label(HistoryText.localized("Delete"), systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func recordActions(_ event: DoseEvent) -> some View {
        Button {
            editor = Editor(event: event)
        } label: {
            Label(HistoryText.localized("Edit record"), systemImage: "pencil")
        }
        Button {
            repeatDose(event)
        } label: {
            Label(HistoryText.localized("Record again"), systemImage: "arrow.clockwise")
        }
        Button(role: .destructive) {
            confirmDeletion([event.id])
        } label: {
            Label(HistoryText.localized("Delete"), systemImage: "trash")
        }
    }

    private func rowLabel(_ event: DoseEvent) -> some View {
        HStack(spacing: 12) {
            TrackerIcon(systemName: event.route.trackerIcon)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.route == .patchRemove ? HistoryText.route(event.route) : HistoryText.drug(event.ester))
                    .font(.subheadline)
                    .foregroundStyle(TrackerTheme.ink)
                if event.route != .patchRemove {
                    Text(HistoryText.doseDescription(event))
                        .font(.footnote)
                        .foregroundStyle(TrackerTheme.muted)
                }
            }
            Spacer(minLength: 8)
            Text(Date(trackerHours: event.timeH), format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(TrackerTheme.muted)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func repeatDose(_ event: DoseEvent) {
        let now = store.now.timeIntervalSince1970
        let repeated = DoseEvent(
            route: event.route, timeH: now / 3600, doseMG: event.doseMG,
            ester: event.ester, extras: event.extras, updatedAt: now * 1_000
        )
        if !store.saveDose(repeated) { failure = true }
    }

    private func confirmDeletion(_ ids: [String]) {
        pendingDeletion = ids
        confirmingDeletion = true
    }
}

enum HistoryText {
    static let rateKey = "releaseRateUGPerDay"
    static let wearKey = "patchWearH"
    static let countKey = "patchCount"
    static let tierKey = "sublingualTier"
    static let thetaKey = "sublingualTheta"
    static let siteKey = "gelSite"

    static let equivalents: [String: Double] = [
        "EB": 272.38 / 376.5, "EV": 272.38 / 356.5, "EC": 272.38 / 396.58,
        "EN": 272.38 / 384.56, "EU": 272.38 / 440.66,
        "TC": 288.42 / 412.6, "TE": 288.42 / 400.59, "TU": 288.42 / 456.7
    ]

    static func localized(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: "History")
    }

    static func amount(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(0...3)))
    }

    static func route(_ route: Route) -> String {
        switch route {
        case .injection: localized("Injection")
        case .oral: localized("Oral")
        case .sublingual: localized("Sublingual")
        case .gel: localized("Gel")
        case .patchApply: localized("Apply patch")
        case .patchRemove: localized("Remove patch")
        case .nasal: localized("Nasal")
        case .sc: localized("Subcutaneous")
        case .pellet: localized("Implant")
        }
    }

    static func drug(_ ester: String) -> String {
        switch ester {
        case "E2": localized("Estradiol")
        case "EV": localized("Estradiol valerate")
        case "EB": localized("Estradiol benzoate")
        case "EC": localized("Estradiol cypionate")
        case "EN": localized("Estradiol enanthate")
        case "EU": localized("Estradiol undecylate")
        case "CPA": localized("Cyproterone acetate")
        case "SPIRO": localized("Spironolactone")
        case "BICA": localized("Bicalutamide")
        case "MPA": localized("Medroxyprogesterone acetate")
        case "LEUP": localized("Leuprorelin")
        case "TRIP": localized("Triptorelin")
        case "RLX": localized("Raloxifene")
        case "T": localized("Testosterone")
        case "TC": localized("Testosterone cypionate")
        case "TE": localized("Testosterone enanthate")
        case "TU": localized("Testosterone undecanoate")
        default: ester
        }
    }

    static func patchCount(_ extras: [String: Double]) -> Int {
        guard let value = extras[countKey], (1...10).contains(value), value.rounded() == value else { return 1 }
        return Int(value)
    }

    static func doseDescription(_ event: DoseEvent) -> String {
        guard event.route == .patchApply else {
            return [route(event.route), localized("\(amount(event.doseMG)) mg")].joined(separator: " · ")
        }
        let count = patchCount(event.extras)
        let dose = if let rate = event.extras[rateKey], rate > 0 {
            localized("\(amount(rate / Double(count))) µg/day")
        } else {
            localized("\(amount(event.doseMG / Double(count))) mg")
        }
        let amountWithCount = count == 1 ? dose : localized("\(dose) × \(count) patches")
        let wear = if let hours = event.extras[wearKey], hours > 0 {
            localized("Wear \(amount(hours / 24)) days")
        } else {
            localized("Manual removal")
        }
        return [amountWithCount, wear].joined(separator: " · ")
    }
}
