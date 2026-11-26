import SwiftUI

@MainActor
struct BodyMeasurementEditor: View {
    let store: TrackerStore
    private let metric: BodyMetric?
    private let record: BodyMeasurement?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var group: BodyMeasurementGroup = .common
    @State private var draft: [BodyMetric: String] = [:]
    @State private var measuredAt: Date
    @State private var includesMeasurementTime: Bool
    @State private var saveFailed = false
    @FocusState private var focusedMetric: BodyMetric?

    init(store: TrackerStore, metric: BodyMetric? = nil, record: BodyMeasurement? = nil) {
        self.store = store
        self.metric = metric
        self.record = record
        _measuredAt = State(initialValue: record?.current?.measuredAt ?? store.now)
        _includesMeasurementTime = State(initialValue: record == nil || record?.current?.measuredAt != nil)
    }

    private var title: LocalizedStringKey {
        if record != nil { return "Revise measurement" }
        return metric == nil ? "Add measurements" : "Add measurement"
    }

    private var metrics: [BodyMetric] { metric.map { [$0] } ?? BodyMetric.allCases }

    private var values: [BodyMetric: Double] {
        Dictionary(uniqueKeysWithValues: metrics.compactMap { key in
            if let raw = draft[key] { return parse(raw, metric: key).map { (key, $0) } }
            guard key == metric, let previous = record?.current else { return nil }
            return (key, previous.value)
        })
    }

    private var invalidMetrics: Set<BodyMetric> {
        Set(draft.compactMap { key, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && parse(trimmed, metric: key) == nil ? key : nil
        })
    }

    private var measurementDate: Date? { includesMeasurementTime ? measuredAt : nil }

    private var latestAllowedDate: Date { store.isDemo ? store.now : Date() }

    private var canSave: Bool {
        guard invalidMetrics.isEmpty, !values.isEmpty else { return false }
        guard let previous = record?.current, let metric else { return true }
        return values[metric] != previous.value || measurementDate != previous.measuredAt
    }

    var body: some View {
        Form {
            Section {
                if metric == nil { groupSelector }
                ForEach(metric.map { [$0] } ?? group.metrics) { field in
                    fieldRow(field)
                }
            } footer: {
                if record != nil {
                    Text("Saving creates a new version.")
                } else if metric == nil {
                    Text("Every measurement is optional. Fill in any field to save.")
                }
            }
            Section {
                if record != nil, record?.current?.measuredAt == nil {
                    Toggle("Measurement time known", isOn: $includesMeasurementTime)
                        .accessibilityIdentifier("body.form.includesTime")
                }
                if includesMeasurementTime {
                    DatePicker("Measurement time", selection: $measuredAt, in: ...latestAllowedDate)
                        .accessibilityIdentifier("body.form.time")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(TrackerTheme.background.ignoresSafeArea())
        .environment(\.timeZone, store.calendar.timeZone)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!canSave)
                    .accessibilityIdentifier("body.form.save")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedMetric = nil }
                    .accessibilityIdentifier("body.form.done")
            }
        }
        .onChange(of: group) { _, _ in
            focusedMetric = nil
        }
        .alert("Could not update body measurements.", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private var groupSelector: some View {
        ViewThatFits(in: .horizontal) {
            TrackerSegment(options: BodyMeasurementGroup.allCases, selection: $group, compact: true,
                           optionIdentifier: { "body.form.group.\($0.rawValue)" }, title: \.title)
            Menu {
                ForEach(BodyMeasurementGroup.allCases) { choice in
                    Button { group = choice } label: {
                        if choice == group {
                            Label(choice.title, systemImage: "checkmark")
                        } else {
                            Text(choice.title)
                        }
                    }
                    .accessibilityIdentifier("body.form.group.\(choice.rawValue)")
                }
            } label: {
                Label(group.title, systemImage: "chevron.up.chevron.down")
            }
            .accessibilityLabel("Measurement groups")
        }
    }

    private func fieldRow(_ field: BodyMetric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 6) {
                    TextField("Measurement", text: binding(for: field), prompt: Text("Optional"))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(minWidth: 76, maxWidth: 125)
                        .focused($focusedMetric, equals: field)
                        .accessibilityLabel(Text(field.title))
                        .accessibilityIdentifier("body.form.value.\(field.rawValue)")
                    Text(verbatim: field.unit)
                        .font(.footnote)
                        .foregroundStyle(TrackerTheme.muted)
                        .accessibilityHidden(true)
                }
            } label: {
                Text(field.title)
            }
            if invalidMetrics.contains(field) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enter a number in the allowed range.")
                    let range = field.validRange
                    Text(verbatim: "\(display(range.lowerBound))–\(display(range.upperBound)) \(field.unit)")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("body.form.error.\(field.rawValue)")
            } else if let hint = field.measurementHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(TrackerTheme.muted)
            }
        }
    }

    private func binding(for field: BodyMetric) -> Binding<String> {
        Binding {
            if let raw = draft[field] { return raw }
            guard field == metric, let previous = record?.current else { return "" }
            return display(previous.value)
        } set: { newValue in
            draft[field] = newValue
        }
    }

    private func display(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...16)).locale(locale))
    }

    private func parse(_ raw: String, metric: BodyMetric) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = text.wholeMatch(of: .localizedDouble(locale: locale))?.output ?? Double(text),
              value.isFinite, metric.validRange.contains(value) else { return nil }
        return value
    }

    private func save() {
        guard canSave else { return }
        let saved: Bool
        if let record, let metric, let value = values[metric] {
            saved = store.reviseBodyMeasurement(record.id, value: value, measuredAt: measurementDate)
        } else if let date = measurementDate {
            saved = store.saveBodyMeasurements(values, measuredAt: date)
        } else {
            return
        }
        if saved {
            focusedMetric = nil
            dismiss()
        } else {
            saveFailed = true
        }
    }
}

enum BodyMeasurementGroup: String, CaseIterable, Identifiable {
    case common = "basics"
    case torso, arms, legs

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .common: "Common"
        case .torso: "Torso"
        case .arms: "Arms"
        case .legs: "Legs"
        }
    }

    var metrics: [BodyMetric] {
        switch self {
        case .common: [.height, .weight, .chest, .waist, .hips]
        case .torso: [.shoulder, .neck, .underbust, .abdomen]
        case .arms: [.armLength, .upperArm]
        case .legs: [.inseam, .thigh, .calf]
        }
    }
}

extension BodyMetric {
    var title: LocalizedStringKey {
        switch self {
        case .height: "Height"
        case .weight: "Weight"
        case .chest: "Chest circumference"
        case .waist: "Waist circumference"
        case .hips: "Hip circumference"
        case .shoulder: "Shoulder width"
        case .neck: "Neck circumference"
        case .underbust: "Underbust circumference"
        case .abdomen: "Abdominal circumference"
        case .armLength: "Arm length"
        case .upperArm: "Upper arm circumference"
        case .inseam: "Inseam"
        case .thigh: "Thigh circumference"
        case .calf: "Calf circumference"
        }
    }

    fileprivate var measurementHint: LocalizedStringKey? {
        switch self {
        case .height, .weight: nil
        case .chest: "At the fullest part of the chest"
        case .waist: "At the narrowest part of the waist"
        case .hips: "At the widest part of the hips"
        case .shoulder: "Straight across from shoulder to shoulder"
        case .neck: "Around the neck"
        case .underbust: "Around the body just below the chest"
        case .abdomen: "Around the abdomen at navel level"
        case .armLength: "From shoulder to wrist on the same arm each time"
        case .upperArm: "At the widest part of the same upper arm each time"
        case .inseam: "From crotch to floor"
        case .thigh: "At the widest part of the same thigh each time"
        case .calf: "At the widest part of the same calf each time"
        }
    }
}
