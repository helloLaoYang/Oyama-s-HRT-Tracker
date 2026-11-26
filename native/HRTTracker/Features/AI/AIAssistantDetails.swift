import HRTEngine
import SwiftUI
import UniformTypeIdentifiers

struct AIAssistantReportEditor: View {
    let text: String
    let save: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $draft)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .scrollContentBackground(.hidden)
                .background(TrackerTheme.background)
                .foregroundStyle(TrackerTheme.ink)
                .accessibilityIdentifier("ai.report.editor")
                .navigationTitle(assistantLabel("Edit summary"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(assistantLabel("Cancel")) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(assistantLabel("Done")) {
                            save(draft)
                            dismiss()
                        }
                        .accessibilityIdentifier("ai.report.editor.done")
                    }
                }
        }
        .tint(TrackerTheme.accent)
        .onAppear { draft = text }
    }
}

struct AIAssistantReportPreview: View {
    let text: String

    @State private var showExporter = false
    @State private var exportFailed = false

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .textSelection(.enabled)
                .padding(17)
                .frame(maxWidth: 540, alignment: .leading)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("ai.report.preview.text")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { showExporter = true } label: {
                Text(assistantLabel("Save text"))
                    .frame(maxWidth: .infinity, minHeight: 29)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            .frame(maxWidth: 540)
            .frame(maxWidth: .infinity)
            .background(TrackerTheme.background)
            .accessibilityIdentifier("ai.report.export")
        }
        .background(TrackerTheme.background.ignoresSafeArea())
        .foregroundStyle(TrackerTheme.ink)
        .navigationTitle(assistantLabel("Export preview"))
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $showExporter, document: AIAssistantTextFile(text: text), contentType: .plainText,
            defaultFilename: assistantLabel("HRTrace Visit Summary")
        ) { result in
            if case .failure = result { exportFailed = true }
        }
        .alert(assistantLabel("Could not save the file."), isPresented: $exportFailed) {
            Button(assistantLabel("OK"), role: .cancel) {}
        }
    }
}

private struct AIAssistantTextFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

@MainActor
struct AIAssistantRecordDetail: View {
    let reference: AIRecordReference
    let store: TrackerStore

    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch reference {
        case .dose: assistantLabel("Dose record")
        case .lab: assistantLabel("Lab result")
        case .curve: assistantLabel("Concentration plot")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch reference {
                case .dose(let id):
                    if let dose = store.doses.first(where: { $0.id == id }) {
                        LabeledContent(assistantLabel("Medication"), value: trackerDrugName(dose.ester))
                        LabeledContent(assistantLabel("Dose"), value: HistoryText.doseDescription(dose))
                        dateRow(Date(trackerHours: dose.timeH))
                    } else {
                        unavailable
                    }
                case .lab(let id):
                    if let lab = store.labs.first(where: { $0.id == id }) {
                        LabeledContent(assistantLabel("Measured result")) {
                            Text(verbatim: "\(LabText.number(lab.concValue, digits: 1)) \(LabText.unitText(lab.unit))")
                        }
                        if let assay = lab.assay, !assay.isEmpty {
                            LabeledContent(assistantLabel("Method"), value: LabText.assayText(assay))
                        }
                        dateRow(Date(trackerHours: lab.timeH))
                    } else {
                        unavailable
                    }
                case .curve:
                    unavailable
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(assistantLabel("Done")) { dismiss() }
                }
            }
        }
        .tint(TrackerTheme.accent)
    }

    private var unavailable: some View {
        Text(assistantLabel("This source is no longer available for the current mode."))
            .foregroundStyle(TrackerTheme.muted)
    }

    private func dateRow(_ date: Date) -> some View {
        LabeledContent(assistantLabel("Recorded at")) {
            Text(date, format: .dateTime.year().month().day().hour().minute().timeZone(store.calendar.timeZone))
        }
    }
}

@MainActor
struct AIAssistantMemoryView: View {
    let conversation: AIConversationStore
    let mode: HRTMode

    @State private var failure = false

    private var memories: [AIMemoryEntry] {
        conversation.memories.filter { $0.mode == mode }
    }

    var body: some View {
        Form {
            Section {
                if memories.isEmpty {
                    Text(assistantLabel("Nothing saved yet.")).foregroundStyle(TrackerTheme.muted)
                }
                ForEach(memories) { entry in
                    NavigationLink {
                        AIAssistantMemoryEditor(conversation: conversation, mode: mode, entry: entry)
                    } label: {
                        Text(verbatim: entry.text)
                    }
                }
                .onDelete { offsets in
                    let visible = memories
                    do {
                        for offset in offsets { try conversation.deleteMemory(visible[offset].id) }
                    } catch {
                        failure = true
                    }
                }
            } footer: {
                Text(assistantLabel("Saved only on this device for the current HRT mode."))
            }
            Section {
                NavigationLink {
                    AIAssistantMemoryEditor(conversation: conversation, mode: mode, entry: nil)
                } label: {
                    Label(assistantLabel("Add memory"), systemImage: "plus")
                }
                .accessibilityIdentifier("ai.memory.add")
            }
        }
        .navigationTitle(assistantLabel("Memory"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(assistantLabel("Could not update local chat and memory."), isPresented: $failure) {
            Button(assistantLabel("OK"), role: .cancel) {}
        }
    }
}

@MainActor
private struct AIAssistantMemoryEditor: View {
    let conversation: AIConversationStore
    let mode: HRTMode
    let entry: AIMemoryEntry?

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var failure = false

    private var draft: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField(assistantLabel("What should be remembered?"), text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("ai.memory.text")
            } footer: {
                Text(assistantLabel("For example, save your preferred units or usual review period."))
            }
        }
        .navigationTitle(entry == nil ? assistantLabel("Add memory") : assistantLabel("Edit memory"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = entry?.text ?? "" }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(assistantLabel("Save")) {
                    do {
                        try conversation.saveMemory(id: entry?.id, mode: mode, text: draft)
                        dismiss()
                    } catch {
                        failure = true
                    }
                }
                .disabled(draft.isEmpty || draft.count > 500)
                .accessibilityIdentifier("ai.memory.save")
            }
        }
        .alert(assistantLabel("Could not update local chat and memory."), isPresented: $failure) {
            Button(assistantLabel("OK"), role: .cancel) {}
        }
    }
}
