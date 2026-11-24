import HRTEngine
import SwiftUI

@MainActor
struct LabEditorView: View {
    let store: TrackerStore
    let lab: LabResult?

    @Environment(\.dismiss) private var dismiss
    @State private var time: Date
    @State private var amount: String
    @State private var unit: String
    @State private var assay: String
    @State private var formError: String?
    @State private var confirmingDeletion = false

    init(store: TrackerStore, lab: LabResult? = nil) {
        self.store = store
        self.lab = lab
        _time = State(initialValue: lab.map { Date(trackerHours: $0.timeH) } ?? store.now)
        _amount = State(initialValue: lab.map { $0.concValue.formatted(.number.grouping(.never).precision(.fractionLength(0...3))) } ?? "")
        _unit = State(initialValue: lab?.unit.lowercased() ?? LabText.units(store.mode)[0])
        _assay = State(initialValue: lab?.assay ?? "")
    }

    private var units: [String] {
        let available = LabText.units(store.mode)
        if let raw = lab?.unit.lowercased(), !available.contains(raw) { return available + [raw] }
        return available
    }

    private var assays: [String] {
        let available = ["", "lcms", "immuno", "chemi"]
        if let raw = lab?.assay, !available.contains(raw) { return available + [raw] }
        return available
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(LabText.localized("Sample time"), selection: $time)
                        .accessibilityIdentifier("lab.time")
                    LabeledContent(LabText.localized("Measured value")) {
                        TextField("0", text: $amount)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .accessibilityLabel(LabText.localized("Measured value"))
                            .accessibilityIdentifier("lab.value")
                    }
                    Picker(LabText.localized("Unit"), selection: $unit) {
                        ForEach(units, id: \.self) { unit in
                            Text(LabText.unitText(unit)).tag(unit)
                        }
                    }
                    .accessibilityIdentifier("lab.unit")
                    Picker(LabText.localized("Assay method (optional)"), selection: $assay) {
                        ForEach(assays, id: \.self) { assay in
                            Text(LabText.assayText(assay)).tag(assay)
                        }
                    }
                    .accessibilityIdentifier("lab.assay")
                }
                if lab != nil {
                    Section {
                        Button(LabText.localized("Delete"), role: .destructive) {
                            confirmingDeletion = true
                        }
                        .accessibilityIdentifier("lab.delete")
                    }
                }
                if let formError {
                    Text(formError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("lab.error")
                }
            }
            .scrollContentBackground(.hidden)
            .background(TrackerTheme.background)
            .tint(TrackerTheme.accent)
            .navigationTitle(LabText.localized(lab == nil ? "Add lab result" : "Edit lab result"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LabText.localized("Cancel")) { dismiss() }
                        .accessibilityIdentifier("lab.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LabText.localized("Save"), action: save)
                        .accessibilityIdentifier("lab.save")
                }
            }
            .confirmationDialog(
                LabText.localized("Delete this lab result?"), isPresented: $confirmingDeletion, titleVisibility: .visible
            ) {
                Button(LabText.localized("Delete"), role: .destructive, action: remove)
                Button(LabText.localized("Cancel"), role: .cancel) { }
            }
        }
        .environment(\.timeZone, store.calendar.timeZone)
        .presentationDetents([.fraction(0.62), .large])
        .presentationDragIndicator(.visible)
    }

    private func save() {
        let normalized = amount.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard let value = Double(normalized), value.isFinite, value > 0 else {
            formError = LabText.localized("Enter a measured value greater than zero.")
            return
        }
        let result = LabResult(
            id: lab?.id ?? UUID().uuidString.lowercased(), timeH: time.trackerHours, concValue: value,
            unit: unit, assay: assay.isEmpty ? nil : assay, updatedAt: store.now.timeIntervalSince1970 * 1_000
        )
        if store.saveLab(result) {
            dismiss()
        } else {
            formError = LabText.localized("Could not update the lab results")
        }
    }

    private func remove() {
        guard let lab else { return }
        if store.deleteLab(lab.id) {
            dismiss()
        } else {
            formError = LabText.localized("Could not update the lab results")
        }
    }
}

enum LabText {
    static func localized(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: "Labs")
    }

    static func units(_ mode: HRTMode) -> [String] {
        mode == .transfem ? ["pg/ml", "pmol/l"] : ["ng/dl", "nmol/l"]
    }

    static func unitText(_ unit: String) -> String {
        switch unit.lowercased() {
        case "pg/ml": "pg/mL"
        case "pmol/l": "pmol/L"
        case "ng/dl": "ng/dL"
        case "nmol/l": "nmol/L"
        default: unit
        }
    }

    static func assayText(_ assay: String) -> String {
        switch assay {
        case "": localized("Not entered")
        case "lcms": "LC-MS/MS"
        case "immuno": localized("Immunoassay")
        case "chemi": localized("Chemiluminescence")
        default: assay
        }
    }

    static func converted(_ result: LabResult, mode: HRTMode) -> Double? {
        switch (mode, result.unit.lowercased()) {
        case (.transfem, "pg/ml"), (.transmasc, "ng/dl"): result.concValue
        case (.transfem, "pmol/l"): result.concValue / 3.671
        case (.transmasc, "nmol/l"): result.concValue * 28.842
        default: nil
        }
    }

    static func number(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }
}
