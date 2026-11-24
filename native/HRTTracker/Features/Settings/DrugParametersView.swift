import Foundation
import HRTEngine
import SwiftUI

struct DrugParametersView: View {
    let store: TrackerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var draft: [String: String] = [:]
    @State private var openGroups: Set<String> = ["e2Injection"]
    @State private var confirmation: Confirmation?
    @State private var saveFailed = false
    @FocusState private var focusedField: String?

    private enum Confirmation: String, Identifiable {
        case reset, discard
        var id: String { rawValue }
    }

    private var invalidKeys: Set<String> {
        Set(draft.keys.filter { key in
            guard let raw = draft[key], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return parseNumber(raw) == nil
        })
    }

    private var overridesToSave: [String: Double] {
        var result = store.pkOverrides
        for (key, input) in draft {
            if let value = parseNumber(input) { result[key] = value }
        }
        return PKParameters.normalizedOverrides(result)
    }

    private var hasChanges: Bool { !invalidKeys.isEmpty || overridesToSave != store.pkOverrides }

    var body: some View {
        Form {
            Section {
                Text("These parameters affect model estimates. Changing them can change past curves and future simulations.")
                    .font(.footnote)
                    .foregroundStyle(TrackerTheme.muted)
                if !store.pkOverrides.isEmpty {
                    LabeledContent("Parameter status", value: label("Customized"))
                        .accessibilityIdentifier("pk.customized")
                }
            }
            ForEach(ParameterGroup.all) { group in
                Section {
                    DisclosureGroup(group.title, isExpanded: expanded(group.id)) {
                        ForEach(group.fields) { field in
                            if let defaultValue = PKParameters.defaults[field.id],
                               let range = PKParameters.range(for: field.id) {
                                parameterField(field, defaultValue: defaultValue, range: range)
                            }
                        }
                    }
                }
            }
            Section {
                Button("Restore default parameters", role: .destructive) { confirmation = .reset }
                    .disabled(draft.isEmpty && store.pkOverrides.isEmpty)
                    .accessibilityIdentifier("pk.reset")
            }
        }
        .navigationTitle("Drug parameters")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasChanges)
        .toolbar {
            if hasChanges {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        confirmation = .discard
                    } label: {
                        TrackerTheme.navigationIcon("chevron.backward")
                    }
                    .accessibilityLabel("Back")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    focusedField = nil
                    if store.savePKOverrides(overridesToSave) { draft = [:] }
                    else { saveFailed = true }
                }
                .disabled(!hasChanges || !invalidKeys.isEmpty)
                .accessibilityIdentifier("pk.save")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .confirmationDialog(
            confirmation == .reset ? "Restore default parameters?" : "Discard unsaved changes?",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible, presenting: confirmation
        ) { action in
            switch action {
            case .reset:
                Button("Restore defaults", role: .destructive) {
                    focusedField = nil
                    if store.savePKOverrides([:]) { draft = [:] }
                    else { saveFailed = true }
                }
            case .discard:
                Button("Discard changes", role: .destructive) { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Could not save changes", isPresented: $saveFailed) { Button("OK", role: .cancel) {} }
    }

    private func parameterField(_ field: ParameterField, defaultValue: Double, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(field.title)
                Spacer()
                TextField("Parameter value", text: Binding {
                    draft[field.id] ?? display(store.pkOverrides[field.id] ?? defaultValue)
                } set: { draft[field.id] = $0 })
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: field.id)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(minWidth: 75, maxWidth: 120)
                .accessibilityLabel(Text(field.title))
                .accessibilityIdentifier("pk.value.\(field.id)")
            }
            if invalidKeys.contains(field.id) {
                Text("Enter a numeric value.").foregroundStyle(.red).font(.caption)
            } else {
                Text("Default \(display(defaultValue)) · Range \(display(range.lowerBound))–\(display(range.upperBound))")
                    .foregroundStyle(TrackerTheme.muted)
                    .font(.caption)
            }
        }
        .padding(.vertical, 3)
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding {
            openGroups.contains(id)
        } set: { open in
            if open { openGroups.insert(id) } else { openGroups.remove(id) }
        }
    }

    private func display(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)).locale(locale))
    }

    private func parseNumber(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let value = try? FloatingPointFormatStyle<Double>.number.locale(locale).parseStrategy.parse(text),
              value.isFinite else { return nil }
        return value
    }
}

private struct ParameterField: Identifiable {
    let id: String
    let title: LocalizedStringKey

    init(_ id: String, _ title: LocalizedStringKey) {
        self.id = id
        self.title = title
    }
}

private struct ParameterGroup: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let fields: [ParameterField]

    static let all = [
        ParameterGroup(id: "e2Injection", title: "Estradiol injection", fields: [
            .init("e2_ff_EB", "Estradiol benzoate formation fraction"),
            .init("e2_ff_EV", "Estradiol valerate formation fraction"),
            .init("e2_ff_EC", "Estradiol cypionate formation fraction"),
            .init("e2_ff_EN", "Estradiol enanthate formation fraction"),
            .init("e2_ff_EU", "Estradiol undecylate formation fraction"),
        ]),
        ParameterGroup(id: "e2Oral", title: "Oral and sublingual estradiol", fields: [
            .init("e2_oral_bio", "Oral bioavailability"),
            .init("e2_sl_quick", "Sublingual fraction · Quick"),
            .init("e2_sl_casual", "Sublingual fraction · Casual"),
            .init("e2_sl_standard", "Sublingual fraction · Standard"),
            .init("e2_sl_strict", "Sublingual fraction · Strict"),
        ]),
        ParameterGroup(id: "e2Gel", title: "Estradiol gel", fields: [
            .init("e2_gel_arm", "Upper arm bioavailability"),
            .init("e2_gel_thigh", "Thigh bioavailability"),
            .init("e2_gel_scrotal", "Scrotal bioavailability"),
        ]),
        ParameterGroup(id: "e2Elimination", title: "Estradiol elimination", fields: [
            .init("e2_kClear", "Non-injection elimination rate (h⁻¹)"),
            .init("e2_kClearInj", "Injection elimination rate (h⁻¹)"),
        ]),
        ParameterGroup(id: "tInjection", title: "Testosterone injection", fields: [
            .init("t_ff_TC", "Testosterone cypionate formation fraction"),
            .init("t_ff_TE", "Testosterone enanthate formation fraction"),
            .init("t_ff_TU", "Testosterone undecanoate formation fraction"),
        ]),
        ParameterGroup(id: "tOther", title: "Testosterone gel and elimination", fields: [
            .init("t_gel_arm", "Upper arm bioavailability"),
            .init("t_gel_thigh", "Thigh bioavailability"),
            .init("t_gel_scrotal", "Scrotal bioavailability"),
            .init("t_kClear", "Non-injection elimination rate (h⁻¹)"),
            .init("t_kClearInj", "Injection elimination rate (h⁻¹)"),
        ]),
    ]
}
