import SwiftUI

@MainActor
struct AIRecordCorrectionView: View {
    let store: TrackerStore
    let snapshot: AIInsightSnapshot
    let generateReply: AIAssistantView.GenerateReply

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var selectedID: String?
    @State private var statement = ""
    @State private var newValue = ""
    @State private var generation: Task<Void, Never>?
    @State private var generationID: UUID?
    @State private var generationMessage: String?
    @State private var saveError: String?
    @State private var completion: Completion?

    private enum Completion {
        case saved(undo: TrackerRecordChange?)
        case alreadySaved
        case undone
    }

    private var records: [AIRecordCorrection.Record] {
        let candidates = snapshot.doses.map(AIRecordCorrection.Record.dose) + snapshot.labs.map(AIRecordCorrection.Record.lab)
        return candidates.filter { $0.isEditable(in: snapshot.mode, through: store.now) }
            .sorted { $0.time > $1.time }
    }

    private var record: AIRecordCorrection.Record? { records.first { $0.id == selectedID } }
    private var request: String { statement.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var decimalSeparator: String { locale.decimalSeparator ?? "." }

    private var draft: AIRecordCorrection? {
        guard let record, let amount = AIRecordCorrection.enteredValue(newValue, decimalSeparator: decimalSeparator),
              store.mode == snapshot.mode else { return nil }
        return AIRecordCorrection(record: record, amount: amount, mode: snapshot.mode, through: store.now)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let completion {
                    resultSection(completion)
                } else if records.isEmpty {
                    Text(correctionLabel("No records in this period can be corrected here."))
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        Picker(correctionLabel("Record"), selection: $selectedID) {
                            Text(correctionLabel("Choose a record")).tag(nil as String?)
                            ForEach(records) { record in
                                Text(verbatim: recordOption(record)).tag(Optional(record.id))
                            }
                        }
                        .accessibilityIdentifier("ai.correction.record")
                        .disabled(generationID != nil)
                    }
                    if let record {
                        requestSection(record)
                        reviewSection(record)
                    }
                }
                if let saveError {
                    Text(saveError).foregroundStyle(.red)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(correctionLabel("Correct a record"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(assistantLabel("Done")) { dismiss() }
                }
            }
        }
        .tint(TrackerTheme.accent)
        .onChange(of: selectedID) { _, _ in
            stopGeneration()
            statement = ""
            newValue = ""
            generationMessage = nil
            saveError = nil
        }
        .onChange(of: store.mode) { _, _ in
            stopGeneration()
            dismiss()
        }
        .onDisappear { stopGeneration() }
    }

    private func requestSection(_ record: AIRecordCorrection.Record) -> some View {
        Section {
            TextField(correctionLabel("Describe the correction"), text: $statement, axis: .vertical)
                .lineLimit(2...4)
                .disabled(generationID != nil)
            if generationID != nil {
                HStack {
                    ProgressView()
                    Text(correctionLabel("Preparing draft…"))
                    Spacer()
                    Button(assistantLabel("Cancel")) { stopGeneration() }
                }
            } else {
                Button(correctionLabel("Draft with AI")) { generate(for: record) }
                    .accessibilityIdentifier("ai.correction.generate")
                    .disabled(request.isEmpty || store.mode != snapshot.mode)
            }
            if let generationMessage { Text(generationMessage).foregroundStyle(.secondary) }
        } header: {
            Text(correctionLabel("AI draft"))
        } footer: {
            Text(correctionLabel("State one replacement number in the record’s existing unit, or enter the value below."))
        }
    }

    private func reviewSection(_ record: AIRecordCorrection.Record) -> some View {
        Section {
            LabeledContent(correctionLabel("Before"), value: "\(number(record.value)) \(record.unit)")
            HStack {
                Text(correctionLabel("After"))
                Spacer()
                TextField(correctionLabel("New value"), text: $newValue)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("ai.correction.value")
                    .disabled(generationID != nil)
                Text(verbatim: record.unit).foregroundStyle(.secondary)
            }
            Button(correctionLabel("Confirm and save")) {
                if let draft { save(draft) }
            }
            .disabled(draft == nil || generationID != nil)
            .accessibilityIdentifier("ai.correction.save")
        } header: {
            Text(correctionLabel("Review change"))
        } footer: {
            if !newValue.isEmpty, draft == nil {
                Text(correctionLabel("Enter a different valid value without digit grouping."))
            }
        }
    }

    @ViewBuilder
    private func resultSection(_ completion: Completion) -> some View {
        Section {
            switch completion {
            case .saved(let undo):
                Label(correctionLabel("Correction saved"), systemImage: "checkmark.circle")
                if let undo {
                    Button(correctionLabel("Undo correction")) { revert(undo) }
                        .accessibilityIdentifier("ai.correction.undo")
                }
            case .alreadySaved:
                Label(correctionLabel("This value is already saved"), systemImage: "checkmark.circle")
            case .undone:
                Label(correctionLabel("Original value restored"), systemImage: "arrow.uturn.backward.circle")
            }
        }
    }

    private func recordOption(_ record: AIRecordCorrection.Record) -> String {
        let name: String
        switch record {
        case .dose(let dose): name = trackerDrugName(dose.ester)
        case .lab: name = snapshot.mode == .transfem ? LabText.localized("Estradiol") : LabText.localized("Total testosterone")
        }
        let date = record.time.formatted(.dateTime.month().day().hour().minute().timeZone(store.calendar.timeZone))
        return "\(name) · \(date) · \(number(record.value)) \(record.unit)"
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.significantDigits(1...17)).locale(locale))
    }

    private func generate(for record: AIRecordCorrection.Record) {
        let statement = request
        let separator = decimalSeparator
        guard generationID == nil, store.mode == snapshot.mode else { return }
        guard statement.count <= 300, AIRecordCorrection.statedValue(statement, decimalSeparator: separator) != nil else {
            generationMessage = correctionLabel("Enter a short correction with one explicit number.")
            return
        }
        guard AIRecordCorrection.usesRecordUnit(statement, unit: record.unit) else {
            generationMessage = correctionLabel("State one replacement number in the record’s existing unit, or enter the value below.")
            return
        }
        let id = UUID()
        let prompt = AIRecordCorrection.extractionPrompt(statement: statement, unit: record.unit)
        generationID = id
        generationMessage = nil
        generation = Task {
            defer {
                if generationID == id { stopGeneration() }
            }
            do {
                let reply = try await generateReply(prompt, []) { _ in }
                try Task.checkCancellation()
                guard generationID == id, store.mode == snapshot.mode else { return }
                guard let amount = AIRecordCorrection.modelValue(reply, matching: statement, unit: record.unit,
                                                                 decimalSeparator: separator),
                      let draft = AIRecordCorrection(record: record, amount: amount, mode: store.mode, through: store.now)
                else {
                    generationMessage = correctionLabel("AI could not draft this correction. You can enter the new value below.")
                    return
                }
                newValue = String(draft.amount).replacingOccurrences(of: ".", with: separator)
                generationMessage = correctionLabel("Draft ready. Check the proposed value before saving.")
            } catch {
                guard generationID == id, !Task.isCancelled else { return }
                generationMessage = correctionLabel("AI could not draft this correction. You can enter the new value below.")
            }
        }
    }

    private func stopGeneration() {
        generation?.cancel()
        generation = nil
        generationID = nil
    }

    private func save(_ draft: AIRecordCorrection) {
        saveError = nil
        let result = store.applyRecordChange(draft.change, mode: snapshot.mode)
        switch result {
        case .saved: completion = .saved(undo: draft.undoAfterSave(in: store))
        case .alreadySaved: completion = .alreadySaved
        case .conflict, .invalid, .failed: showFailure(result)
        }
    }

    private func revert(_ undo: TrackerRecordChange) {
        saveError = nil
        let result = store.applyRecordChange(undo, mode: snapshot.mode)
        switch result {
        case .saved, .alreadySaved: completion = .undone
        case .conflict, .invalid, .failed: showFailure(result)
        }
    }

    private func showFailure(_ result: TrackerRecordChangeResult) {
        if result == .conflict {
            saveError = correctionLabel("The record changed. Close this sheet and reopen it before trying again.")
        } else {
            saveError = correctionLabel("Could not save the correction.")
        }
    }
}
