import SwiftUI

struct AIAssistantDocumentCard: View {
    let document: AIConversationDocument
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                TrackerIcon(systemName: document.kind.icon)
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.kind.title).font(.subheadline.weight(.medium))
                    Text(document.period).font(.footnote).foregroundStyle(TrackerTheme.muted)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            Text(aiDocumentLabel("Doses \(document.doseCount)"))
                            Text("·").accessibilityHidden(true)
                            Text(aiDocumentLabel("Labs \(document.labCount)"))
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(aiDocumentLabel("Doses \(document.doseCount)"))
                            Text(aiDocumentLabel("Labs \(document.labCount)"))
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(TrackerTheme.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(TrackerTheme.muted)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TrackerTheme.subtle, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ai.document")
    }
}

@MainActor
struct AIAssistantDocumentView: View {
    @State private var document: AIConversationDocument
    @State private var editing = false
    @State private var saveFailed = false

    private let allowsSourceNavigation: Bool
    private let onEdit: ((String) throws -> Void)?
    private let showSource: (AIRecordReference) -> Void

    init(document: AIConversationDocument, allowsSourceNavigation: Bool = true,
         onEdit: ((String) throws -> Void)? = nil, showSource: @escaping (AIRecordReference) -> Void) {
        _document = State(initialValue: document)
        self.allowsSourceNavigation = allowsSourceNavigation
        self.onEdit = onEdit
        self.showSource = showSource
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                header(document)
                switch document.kind {
                case .recap:
                    recap(document)
                case .visit:
                    visit(document)
                }
            }
            .padding(17)
            .frame(maxWidth: 540, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if document.kind == .visit {
                actions(document)
            }
        }
        .background(TrackerTheme.background.ignoresSafeArea())
        .foregroundStyle(TrackerTheme.ink)
        .navigationTitle(document.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) {
            AIAssistantReportEditor(text: document.exportText) { text in
                do {
                    try onEdit?(text)
                    document.editedText = text == document.generatedText ? nil : text
                } catch {
                    saveFailed = true
                }
            }
        }
        .alert(aiDocumentLabel("Could not save the changes."), isPresented: $saveFailed) {
            Button(assistantLabel("OK"), role: .cancel) {}
        }
    }

    private func header(_ document: AIConversationDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(document.period)
                .font(.subheadline)
                .foregroundStyle(TrackerTheme.muted)
                .accessibilityIdentifier("ai.document.period")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    metric(document.doseCount, label: aiDocumentLabel("Dose records"), icon: "pills", compact: true)
                    metric(document.labCount, label: aiDocumentLabel("Lab results"), icon: "testtube.2", compact: true)
                }
                VStack(spacing: 8) {
                    metric(document.doseCount, label: aiDocumentLabel("Dose records"), icon: "pills")
                    metric(document.labCount, label: aiDocumentLabel("Lab results"), icon: "testtube.2")
                }
            }
        }
    }

    private func metric(_ count: Int, label: String, icon: String, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(TrackerTheme.muted)
                .fixedSize(horizontal: compact, vertical: false)
            Text(count.formatted())
                .font(.title2.weight(.medium).monospacedDigit())
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TrackerTheme.subtle, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func recap(_ document: AIConversationDocument) -> some View {
        recordSection(aiDocumentLabel("Latest medication"), rows: document.doses, document: document)
        recordSection(aiDocumentLabel("Latest lab measurement"), rows: document.labs, document: document)
        if !document.estimates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(aiDocumentLabel("Model estimates"))
                    .font(.headline.weight(.medium))
                    .accessibilityAddTraits(.isHeader)
                ForEach(document.estimates.indices, id: \.self) { index in
                    row(document.estimates[index], document: document, showDay: true)
                        .accessibilityIdentifier("ai.document.estimate.\(index)")
                }
                Text(aiDocumentLabel("Estimates are calculated from recorded doses and are separate from lab measurements."))
                    .font(.footnote)
                    .foregroundStyle(TrackerTheme.muted)
            }
            .padding(12)
            .background(TrackerTheme.wash, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func visit(_ document: AIConversationDocument) -> some View {
        if let editedText = document.editedText {
            Text(aiDocumentLabel("Edited summary"))
                .font(.subheadline.weight(.medium))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: editedText)
                .font(.body)
                .textSelection(.enabled)
                .accessibilityIdentifier("ai.document.editedText")
        } else {
            recordSection(aiDocumentLabel("Medication records"), rows: document.doses, document: document)
            recordSection(aiDocumentLabel("Measured lab results"), rows: document.labs, document: document)
        }
    }

    private func recordSection(_ title: String, rows: [AIConversationDocument.Item], document: AIConversationDocument) -> some View {
        let grouped = Dictionary(grouping: rows) { document.calendar.startOfDay(for: $0.date) }
        return VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline.weight(.medium))
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text(aiDocumentLabel("No entries in this period."))
                    .font(.footnote)
                    .foregroundStyle(TrackerTheme.muted)
            } else if document.kind == .recap {
                ForEach(rows.indices, id: \.self) { index in
                    row(rows[index], document: document, showDay: true)
                }
            } else {
                ForEach(grouped.keys.sorted(), id: \.self) { day in
                    let entries = (grouped[day] ?? []).sorted { $0.date < $1.date }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(document.dateLabel(day))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(TrackerTheme.muted)
                        ForEach(entries.indices, id: \.self) { index in
                            row(entries[index], document: document, showDay: false)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: AIConversationDocument.Item, document: AIConversationDocument, showDay: Bool) -> some View {
        let time = document.timeLabel(item.date)
        let date = showDay ? "\(document.dateLabel(item.date)) · \(time)" : time
        let content = HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.title).font(.subheadline.weight(.medium))
                Text(verbatim: item.detail).font(.subheadline)
                Text(verbatim: date).font(.caption).foregroundStyle(TrackerTheme.muted)
            }
            Spacer(minLength: 0)
            if allowsSourceNavigation {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(TrackerTheme.muted)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        if allowsSourceNavigation {
            Button { showSource(item.source) } label: { content }
                .buttonStyle(.plain)
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    private func actions(_ document: AIConversationDocument) -> some View {
        HStack(spacing: 10) {
            Button {
                editing = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.body)
                    .frame(width: 44, height: 44)
                    .background(TrackerTheme.subtle, in: Circle())
                    .contentShape(.rect)
            }
            .accessibilityLabel(aiDocumentLabel("Edit summary"))
            .accessibilityIdentifier("ai.document.edit")

            NavigationLink {
                AIAssistantReportPreview(text: document.exportText)
            } label: {
                Text(aiDocumentLabel("Preview export"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(TrackerTheme.accentInk)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(TrackerTheme.accent, in: Capsule())
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("ai.document.preview")
        }
        .buttonStyle(.plain)
        .foregroundStyle(TrackerTheme.accent)
        .padding(.horizontal, 17)
        .padding(.vertical, 10)
        .frame(maxWidth: 540, alignment: .trailing)
        .frame(maxWidth: .infinity)
        .background(TrackerTheme.background)
    }
}
