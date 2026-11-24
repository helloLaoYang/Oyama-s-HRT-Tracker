import HRTEngine
import SwiftUI
import UIKit

func aiRecordChangeLabel(_ key: String.LocalizationValue) -> String {
    label(key, table: "AIRecordChanges")
}

@MainActor
struct AIRecordChangeCard: View {
    @State private var draft: AIRecordChangeDraft
    @State private var error: String?
    @State private var conflicted = false
    let store: TrackerStore
    let onCancel: () -> Void
    let onSaved: (AIRecordReference) -> Void

    init(draft: AIRecordChangeDraft, store: TrackerStore, onCancel: @escaping () -> Void,
         onSaved: @escaping (AIRecordReference) -> Void) {
        _draft = State(initialValue: draft)
        self.store = store
        self.onCancel = onCancel
        self.onSaved = onSaved
    }

    private var proposedChange: TrackerRecordChange? {
        guard !conflicted, draft.mode == store.mode else { return nil }
        return draft.change(parameters: store.pkParameters, now: currentTime)
    }

    private var currentTime: Date { store.isDemo ? store.now : Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TrackerIcon(systemName: draft.isLab ? "testtube.2" : "pills")
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .accessibilityAddTraits(.isHeader)
                    Text(aiRecordChangeLabel("Review and save to your records."))
                        .font(.footnote)
                        .foregroundStyle(TrackerTheme.muted)
                }
            }
            if draft.isEditing { existingRecord }
            if draft.analyteMismatch {
                Text(aiRecordChangeLabel("This analyte cannot be saved in the current tracking mode."))
                    .font(.footnote)
                    .foregroundStyle(TrackerTheme.muted)
            } else if !draft.isEditing || draft.selected != nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text(aiRecordChangeLabel(draft.isEditing ? "Proposed changes" : "Record details"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(TrackerTheme.muted)
                    dateRow
                    if draft.isLab { labFields } else { doseFields }
                }
                .padding(12)
                .background(TrackerTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(TrackerTheme.accent)
                    .accessibilityIdentifier("ai.recordChange.error")
            }
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TrackerTheme.subtle, in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(TrackerTheme.ink)
        .tint(TrackerTheme.accent)
        .environment(\.calendar, draft.calendar)
        .environment(\.timeZone, draft.calendar.timeZone)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai.recordChange")
    }

    private var title: String {
        switch draft.arguments.operation {
        case .addDose: aiRecordChangeLabel("Add medication record")
        case .editDose: aiRecordChangeLabel("Edit medication record")
        case .addLab: LabText.localized("Add lab result")
        case .editLab: LabText.localized("Edit lab result")
        }
    }

    @ViewBuilder private var existingRecord: some View {
        if draft.candidates.isEmpty {
            Text(aiRecordChangeLabel("No editable record was found in this date range."))
                .font(.footnote)
                .foregroundStyle(TrackerTheme.muted)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(aiRecordChangeLabel(draft.selected == nil ? "Record to change" : "Current record"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(TrackerTheme.muted)
                    Spacer(minLength: 6)
                    Menu {
                        ForEach(draft.candidates) { candidate in
                            Button {
                                draft.select(candidate.id)
                            } label: {
                                if candidate.id == draft.selectedID {
                                    Label(candidateText(candidate), systemImage: "checkmark")
                                } else {
                                    Text(candidateText(candidate))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if draft.selected == nil { Text(aiRecordChangeLabel("Choose a record")) }
                            Image(systemName: "chevron.up.chevron.down")
                                .imageScale(.small)
                        }
                        .font(.footnote)
                        .padding(.vertical, 4)
                        .padding(.leading, 8)
                    }
                    .accessibilityLabel(aiRecordChangeLabel("Choose a record"))
                    .accessibilityIdentifier("ai.recordChange.target")
                }
                if let candidate = draft.selected {
                    Text(candidateText(candidate))
                        .font(.footnote)
                        .accessibilityIdentifier("ai.recordChange.original")
                    if case .lab(let record) = candidate, let assay = record.assay, !assay.isEmpty {
                        Text(LabText.assayText(assay))
                            .font(.footnote)
                            .foregroundStyle(TrackerTheme.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(TrackerTheme.wash, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func candidateText(_ candidate: AIRecordChangeDraft.Candidate) -> String {
        let date = candidate.date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard,
                                                            timeZone: draft.calendar.timeZone))
        switch candidate {
        case .dose(let record):
            return [HistoryText.drug(record.ester), HistoryText.doseDescription(record), date]
                .joined(separator: " · ")
        case .lab(let record):
            return [draft.analyteTitle, "\(HistoryText.amount(record.concValue)) \(LabText.unitText(record.unit))", date]
                .joined(separator: " · ")
        }
    }

    @ViewBuilder private var dateRow: some View {
        let title = draft.isLab ? LabText.localized("Sample time") : aiRecordChangeLabel("Medication time")
        if let time = draft.time {
            DatePicker(title, selection: Binding(get: { draft.time ?? time }, set: { draft.time = $0 }),
                       in: ...currentTime)
                .datePickerStyle(.compact)
                .accessibilityIdentifier("ai.recordChange.time")
        } else {
            LabeledContent(title) {
                Button(aiRecordChangeLabel("Set date and time")) { draft.time = currentTime }
                    .accessibilityIdentifier("ai.recordChange.time")
            }
        }
    }

    @ViewBuilder private var labFields: some View {
        if draft.confirmedAnalyte {
            LabeledContent(aiRecordChangeLabel("Analyte"), value: draft.analyteTitle)
                .accessibilityIdentifier("ai.recordChange.analyte")
        } else {
            pickerRow(aiRecordChangeLabel("Analyte"), selection: $draft.confirmedAnalyte, id: "analyte") {
                Text(aiRecordChangeLabel("Choose an analyte")).tag(false)
                Text(draft.analyteTitle).tag(true)
            }
        }
        numberField(LabText.localized("Measured value"), text: $draft.amountText, id: "amount")
        unitPicker
        pickerRow(LabText.localized("Assay method (optional)"), selection: $draft.assay, id: "assay") {
            if draft.assay == nil { Text(aiRecordChangeLabel("Choose a value")).tag(nil as String?) }
            ForEach(draft.availableAssays, id: \.self) { assay in
                Text(LabText.assayText(assay)).tag(Optional(assay))
            }
        }
    }

    @ViewBuilder private var doseFields: some View {
        pickerRow(aiRecordChangeLabel("Route"),
                  selection: Binding(get: { draft.route }, set: { draft.chooseRoute($0) }), id: "route") {
            Text(aiRecordChangeLabel("Choose a value")).tag(nil as Route?)
            ForEach(Route.allCases, id: \.self) { route in
                Text(HistoryText.route(route)).tag(Optional(route))
            }
        }
        if let route = draft.route {
            pickerRow(aiRecordChangeLabel("Medication"), selection: $draft.drug, id: "drug") {
                Text(aiRecordChangeLabel("Choose a value")).tag(nil as String?)
                ForEach(draft.availableDrugCodes, id: \.self) { drug in
                    Text(HistoryText.drug(drug)).tag(Optional(drug))
                }
            }
            if route != .patchRemove {
                numberField(aiRecordChangeLabel(route == .patchApply ? "Amount per patch" : "Amount"),
                            text: $draft.amountText, id: "amount")
                unitPicker
            }
            if route == .patchApply {
                numberField(aiRecordChangeLabel("Patch count"), text: $draft.patchCountText, id: "patchCount",
                            keyboard: .numberPad)
                numberField(aiRecordChangeLabel("Wear days (optional)"), text: $draft.wearDaysText, id: "wearDays")
            }
            if route == .gel {
                pickerRow(aiRecordChangeLabel("Application site"), selection: $draft.gelSite, id: "gelSite") {
                    Text(aiRecordChangeLabel("Choose a value")).tag(nil as AIRecordChangeDraft.GelSite?)
                    ForEach(AIRecordChangeDraft.GelSite.allCases, id: \.self) { site in
                        Text(site.title).tag(Optional(site))
                    }
                }
            }
            if route == .sublingual {
                let title = aiRecordChangeLabel("Hold time (minutes)")
                let placeholder = draft.keepsOriginalHold ? aiRecordChangeLabel("Keep recorded hold time") : "—"
                numberField(title, text: $draft.holdMinutesText, id: "holdMinutes", placeholder: placeholder)
            }
        }
    }

    private var unitPicker: some View {
        pickerRow(LabText.localized("Unit"),
                  selection: Binding(get: { draft.unit }, set: { draft.chooseUnit($0) }), id: "unit") {
            Text(aiRecordChangeLabel("Choose a value")).tag(nil as String?)
            ForEach(draft.availableUnits, id: \.self) { unit in
                Text(AIRecordChangeDraft.unitTitle(unit)).tag(Optional(unit))
            }
        }
    }

    private func pickerRow<Selection: Hashable, Content: View>(
        _ title: String, selection: Binding<Selection>, id: String, @ViewBuilder content: () -> Content
    ) -> some View {
        LabeledContent(title) {
            Picker(title, selection: selection, content: content)
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityIdentifier("ai.recordChange." + id)
        }
    }

    private func numberField(_ title: String, text: Binding<String>, id: String,
                             placeholder: String = "—", keyboard: UIKeyboardType = .decimalPad) -> some View {
        LabeledContent(title) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .accessibilityLabel(title)
                .accessibilityIdentifier("ai.recordChange." + id)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(LabText.localized("Cancel"), role: .cancel, action: onCancel)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("ai.recordChange.cancel")
            Spacer(minLength: 0)
            Button(aiRecordChangeLabel("Save record"), action: save)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .foregroundStyle(TrackerTheme.accentInk)
                .background(TrackerTheme.accent, in: Capsule())
                .buttonStyle(.plain)
                .opacity(proposedChange == nil ? 0.45 : 1)
                .disabled(proposedChange == nil)
                .accessibilityIdentifier("ai.recordChange.save")
        }
    }

    private func save() {
        guard let change = proposedChange else { return }
        switch store.applyRecordChange(change, mode: draft.mode) {
        case .saved, .alreadySaved:
            onSaved(draft.reference(for: change))
        case .conflict:
            conflicted = true
            error = aiRecordChangeLabel("The original record changed. Ask for a new proposal.")
        case .invalid:
            error = aiRecordChangeLabel("Review the record details and try again.")
        case .failed:
            error = aiRecordChangeLabel("Could not save the record. Try again.")
        }
    }
}
