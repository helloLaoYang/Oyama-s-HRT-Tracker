import HRTEngine
import SwiftUI

@MainActor
struct AIAssistantView: View {
    let store: TrackerStore
    let modelSettings: AIModelSettings
    let conversation: AIConversationStore
    let showCurve: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("ai.preferredModel") private var preferredModel: Model?
    @FocusState private var isQuestionFocused: Bool

    @State private var range: AIRange = .month
    @State private var loadedSnapshot: AIInsightSnapshot?
    @State private var loadedKey: SnapshotKey?
    @State private var appleStatus: AIAppleAvailability?
    @State private var question = ""
    @State private var attachments: [AIAssistantAttachment] = []
    @State private var importingAttachments = false
    @State private var generatesImage = false
    @State private var liveReply: LiveReply?
    @State private var pendingRecordChange: PendingRecordChange?
    @State private var presentedReport: ReportRoute?
    @State private var sheet: DetailSheet?
    @State private var requestTask: Task<Void, Never>?
    @State private var runningID: UUID?
    @State private var failure: String?
    @State private var showClearConfirmation = false
    @State private var showModelSettings = false

    private enum Model: String {
        case apple, compatible
    }

    private struct ReportRoute: Hashable {
        let id = UUID()
        let document: AIConversationDocument
        let mode: HRTMode
        let savedTurnID: UUID?

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private struct SnapshotKey: Equatable {
        let mode: HRTMode
        let range: AIRange
        let day: Date
        let doses: [DoseEvent]
        let labs: [LabResult]
    }

    private struct CloudRequest {
        let profile: AIProviderProfile
        let attachments: [AIAssistantAttachment]
        let generatesImage: Bool
        let sendingRevision: UUID

        var allowsRecordChanges: Bool { profile.api == .responses && !generatesImage }

        var instructions: String {
            if generatesImage { return AIAssistantRequest.imageInstructions }
            return allowsRecordChanges ? AIAssistantRequest.recordChangeInstructions : AIAssistantRequest.streamingInstructions
        }
    }

    private struct Approval {
        let request: AIAssistantRequest
        let cloud: CloudRequest
        let memory: AIConversationContext?
    }

    private struct LiveReply {
        let question: String
        let attachmentNames: [String]
        var text = ""
        var reasoning = ""
        var imagePreview: Data?
        var generatedImage: Data?
        var recordChange: AIRecordChangeArguments?

        var scrollStep: Int {
            (text.utf8.count + reasoning.utf8.count) / 64 * 2 + (imagePreview == nil && generatedImage == nil ? 0 : 1)
        }
    }

    private struct PendingRecordChange {
        let requestID: UUID
        let mode: HRTMode
        let question: String
        let attachmentNames: [String]
        let draft: AIRecordChangeDraft
    }

    private enum DetailSheet: Identifiable {
        case consent(Approval)
        case record(AIRecordReference)

        var id: String {
            switch self {
            case .consent(let approval): approval.request.id.uuidString
            case .record(let reference):
                switch reference {
                case .dose(let id): "dose-" + id
                case .lab(let id): "lab-" + id
                case .curve: "curve"
                }
            }
        }
    }

    private var snapshot: AIInsightSnapshot? {
        guard loadedKey == snapshotKey else { return nil }
        return loadedSnapshot
    }

    private var snapshotKey: SnapshotKey {
        SnapshotKey(mode: store.mode, range: range, day: store.calendar.startOfDay(for: store.now),
                    doses: store.doses, labs: store.labs)
    }

    private var model: Model {
        if let preferredModel, preferredModel == .apple || modelSettings.profile != nil {
            return preferredModel
        }
        return modelSettings.profile == nil ? .apple : .compatible
    }

    private var modelUnavailable: String? {
        switch model {
        case .apple: (appleStatus ?? AIModelClient.appleAvailability(locale: locale)).unavailableReason
        case .compatible: modelSettings.profile == nil ? assistantLabel("Configure a compatible model to continue.") : nil
        }
    }

    private var isWorking: Bool { runningID != nil }
    private var acceptsAttachments: Bool { model == .compatible && modelSettings.profile != nil }
    private var canGenerateImage: Bool { model == .compatible && modelSettings.profile?.api == .responses }
    private var incompatibleMedia: Bool {
        (!attachments.isEmpty && !acceptsAttachments) || (generatesImage && !canGenerateImage)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        chat
                        Color.clear.frame(height: 1).accessibilityHidden(true).id("ai.end")
                    }
                    .padding(17)
                    .frame(maxWidth: 540, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .top, spacing: 0) {
                    controls
                        .disabled(pendingRecordChange != nil)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 6)
                        .frame(maxWidth: 540)
                        .frame(maxWidth: .infinity)
                        .background(TrackerTheme.background)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if pendingRecordChange == nil { composer }
                }
                .onChange(of: conversation.turns.count, initial: true) { oldCount, newCount in
                    guard newCount > 0 else { return }
                    if newCount == oldCount {
                        scroll.scrollTo("ai.end", anchor: .bottom)
                    } else {
                        withAnimation(.easeOut(duration: 0.18)) { scroll.scrollTo("ai.end", anchor: .bottom) }
                    }
                }
                .onChange(of: liveReply?.scrollStep) { _, step in
                    if step != nil { scroll.scrollTo("ai.end", anchor: .bottom) }
                }
                .onChange(of: pendingRecordChange?.requestID) { _, id in
                    if id != nil { scroll.scrollTo("ai.pendingRecordChange", anchor: .top) }
                }
            }
            .background(TrackerTheme.background.ignoresSafeArea())
            .foregroundStyle(TrackerTheme.ink)
            .navigationTitle(assistantLabel("Record assistant"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(assistantLabel("Done")) { dismiss() }
                        .accessibilityIdentifier("ai.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showModelSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(assistantLabel("Model settings"))
                    .accessibilityIdentifier("ai.modelSettings")
                    .disabled(isWorking || pendingRecordChange != nil)
                }
            }
            .navigationDestination(isPresented: $showModelSettings) {
                AIModelSettingsView(settings: modelSettings)
            }
            .navigationDestination(item: $presentedReport) { report in
                AIAssistantDocumentView(
                    document: report.document,
                    allowsSourceNavigation: report.mode == store.mode,
                    onEdit: report.savedTurnID.map { id in
                        { text in try conversation.updateDocument(id, text: text) }
                    }
                ) { reference in
                    if report.mode == store.mode { show(reference) }
                }
            }
        }
        .tint(TrackerTheme.accent)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await AIModelClient.monitorAppleAvailability(locale: locale) { appleStatus = $0 }
        }
        .task(id: snapshotKey) {
            let key = snapshotKey
            let refreshed = await AIInsightSnapshot.capture(store: store, range: key.range)
            if !Task.isCancelled {
                loadedSnapshot = refreshed
                loadedKey = key
            }
        }
        .onDisappear { stop() }
        .onChange(of: store.mode) { _, _ in
            stop()
            pendingRecordChange = nil
            failure = nil
            sheet = nil
        }
        .sheet(item: $sheet) { current in
            switch current {
            case .consent(let approval):
                AIAssistantConsent(
                    request: approval.request, profile: approval.cloud.profile, memory: approval.memory,
                    attachments: approval.cloud.attachments, generatesImage: approval.cloud.generatesImage,
                    remembersApproval: modelSettings.confirmationMode == .firstSend
                ) { includeMemory in
                    sheet = nil
                    let cloud = approval.cloud
                    guard model == .compatible, cloud.profile == modelSettings.profile,
                          cloud.sendingRevision == modelSettings.sendingRevision,
                          cloud.attachments == attachments, cloud.generatesImage == generatesImage,
                          approval.request.snapshot.mode == store.mode,
                          approval.request.snapshot.range == range,
                          approval.request.snapshot.facts == snapshot?.facts,
                          loadedKey == snapshotKey else {
                        failure = assistantLabel("The model or records changed. Start the request again.")
                        return
                    }
                    modelSettings.authorizeSending(for: cloud.profile, includeMemory: includeMemory,
                                                   includesAttachments: !cloud.attachments.isEmpty)
                    run(approval.request, context: includeMemory ? approval.memory : nil, cloud: cloud)
                }
                .presentationDetents([.large])
            case .record(let reference):
                AIAssistantRecordDetail(reference: reference, store: store)
                    .presentationDetents([.medium, .large])
            }
        }
        .confirmationDialog(
            assistantLabel("Clear chat and memory?"), isPresented: $showClearConfirmation, titleVisibility: .visible
        ) {
            Button(assistantLabel("Clear chat and memory"), role: .destructive) {
                stop()
                pendingRecordChange = nil
                do { try conversation.clear(); failure = nil }
                catch { failure = assistantLabel("Could not update local chat and memory.") }
            }
            Button(assistantLabel("Cancel"), role: .cancel) {}
        } message: {
            Text(assistantLabel("This removes the conversation and all saved memories from this device."))
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                rangeMenu.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                modelMenu.fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 4) {
                rangeMenu
                modelMenu
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rangeMenu: some View {
        Menu {
            ForEach(AIRange.allCases) { option in
                Button {
                    if option != range { setRange(option) }
                } label: {
                    if option == range {
                        Label(assistantLabel("Last \(option.rawValue) days"), systemImage: "checkmark")
                    } else {
                        Text(assistantLabel("Last \(option.rawValue) days"))
                    }
                }
            }
        } label: {
            Label(assistantLabel("Last \(range.rawValue) days"), systemImage: "chevron.down")
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
        }
        .accessibilityIdentifier("ai.range")
    }

    private var modelMenu: some View {
        Menu {
            Button { preferredModel = .apple } label: {
                if model == .apple { Label(assistantLabel("Apple on-device"), systemImage: "checkmark") }
                else { Text(assistantLabel("Apple on-device")) }
            }
            if let profile = modelSettings.profile {
                Button { preferredModel = .compatible } label: {
                    if model == .compatible { Label(profile.model, systemImage: "checkmark") }
                    else { Text(verbatim: profile.model) }
                }
            }
        } label: {
            Label(
                model == .apple ? assistantLabel("Apple on-device") :
                    modelSettings.profile?.model ?? assistantLabel("Compatible model"),
                systemImage: "chevron.down"
            )
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .font(.subheadline)
        }
        .disabled(isWorking)
        .accessibilityIdentifier("ai.modelMenu")
        .onChange(of: model) { _, _ in failure = nil }
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(assistantLabel("Chat stays on this device"), systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(TrackerTheme.muted)
                Spacer(minLength: 0)
                NavigationLink {
                    AIAssistantMemoryView(conversation: conversation, mode: store.mode)
                } label: {
                    Text(assistantLabel("Memory")).font(.subheadline)
                }
                .accessibilityIdentifier("ai.memories")
                if !conversation.turns.isEmpty || !conversation.memories.isEmpty {
                    Menu {
                        Button(assistantLabel("Clear chat and memory"), role: .destructive) {
                            showClearConfirmation = true
                        }
                        .accessibilityIdentifier("ai.clear")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .accessibilityLabel(assistantLabel("Chat actions"))
                }
            }

            if conversation.turns.isEmpty, pendingRecordChange == nil, liveReply == nil {
                Text(assistantLabel("Ask about your records or a general topic."))
                    .font(.subheadline)
                    .foregroundStyle(TrackerTheme.muted)
            }

            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(conversation.turns) { turn in
                    VStack(alignment: .leading, spacing: 10) {
                        questionBubble(turn.question, attachmentNames: turn.attachmentNames)
                        if let document = turn.document {
                            AIAssistantDocumentCard(document: document) {
                                isQuestionFocused = false
                                presentedReport = ReportRoute(document: document, mode: turn.mode, savedTurnID: turn.id)
                            }
                        } else {
                            if let summary = turn.reasoningSummary, !summary.isEmpty {
                                AIAssistantReasoning(summary: summary, startsExpanded: false)
                            }
                            if !turn.answer.isEmpty {
                                Text(verbatim: turn.answer).textSelection(.enabled)
                            }
                            if let image = turn.generatedImage {
                                AIAssistantGeneratedImage(data: image)
                            }
                            if turn.mode == store.mode {
                                ForEach(Array(turn.sources.enumerated()), id: \.offset) { _, source in
                                    Button { show(source) } label: {
                                        Label(sourceTitle(source), systemImage: "arrow.up.right")
                                            .font(.footnote)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            } else if !turn.sources.isEmpty {
                                Text(assistantLabel("This source is no longer available for the current mode."))
                                    .font(.footnote)
                                    .foregroundStyle(TrackerTheme.muted)
                            }
                        }
                    }
                }
            }
            if let pending = pendingRecordChange {
                VStack(alignment: .leading, spacing: 10) {
                    questionBubble(pending.question, attachmentNames: pending.attachmentNames)
                    AIRecordChangeCard(draft: pending.draft, store: store) {
                        pendingRecordChange = nil
                    } onSaved: { reference in
                        finishRecordChange(pending, reference: reference)
                    }
                    .id(pending.requestID)
                }
                .id("ai.pendingRecordChange")
            } else if let liveReply {
                questionBubble(liveReply.question, attachmentNames: liveReply.attachmentNames)
                if !liveReply.reasoning.isEmpty {
                    AIAssistantReasoning(summary: liveReply.reasoning, startsExpanded: true)
                }
                if !liveReply.text.isEmpty {
                    Text(verbatim: AIAssistantRequest.displayedStreamText(liveReply.text))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("ai.streaming.answer")
                }
                if let preview = liveReply.generatedImage ?? liveReply.imagePreview {
                    AIAssistantGeneratedImage(data: preview, allowsSharing: false)
                }
                if liveReply.text.isEmpty, liveReply.reasoning.isEmpty, liveReply.imagePreview == nil,
                   liveReply.generatedImage == nil {
                    ProgressView(assistantLabel("Preparing a reply…"))
                }
            } else if isWorking {
                ProgressView(assistantLabel("Preparing a reply…"))
            }
        }
    }

    private func questionBubble(_ text: String, attachmentNames: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: text)
            ForEach(attachmentNames.indices, id: \.self) { index in
                Label(attachmentNames[index], systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(TrackerTheme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(TrackerTheme.subtle, in: RoundedRectangle(cornerRadius: 15))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("ai.turn")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if conversation.storageUnavailable {
                status(assistantLabel("Local chat storage is unavailable."), icon: "exclamationmark.circle")
            }
            if let failure {
                status(failure, icon: "exclamationmark.circle")
                    .accessibilityIdentifier("ai.error")
            }
            if let modelUnavailable {
                status(modelUnavailable, icon: "sparkles")
            }
            if incompatibleMedia {
                status(assistantLabel("Switch to a model that supports these attachments or image generation to send this message."),
                       icon: "paperclip")
            }
            composerField
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 8)
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(TrackerTheme.background)
    }

    private var composerField: some View {
        VStack(alignment: .leading, spacing: 0) {
            AIAssistantAttachmentControls(attachments: $attachments,
                                          allowsAdding: acceptsAttachments,
                                          onLoadingChanged: { importingAttachments = $0 },
                                          onError: { failure = $0 }) {
                documentCommand(.recap)
                documentCommand(.visit)
                if canGenerateImage || generatesImage {
                    Button {
                        generatesImage.toggle()
                    } label: {
                        composerToolLabel(assistantLabel("Generate image"), icon: "photo.badge.plus",
                                          selected: generatesImage)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(generatesImage ? .isSelected : [])
                    .accessibilityIdentifier("ai.generateImage")
                }
            }
            .disabled(isWorking)
            HStack(alignment: .bottom, spacing: 6) {
                TextField(assistantLabel("Ask a question"), text: $question, axis: .vertical)
                    .lineLimit(3...4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
                    .padding(.bottom, 8)
                    .padding(.leading, 6)
                    .focused($isQuestionFocused)
                    .accessibilityIdentifier("ai.question")
                    .disabled(isWorking || conversation.storageUnavailable)
                if isWorking {
                    composerButton(title: assistantLabel("Stop"), icon: "stop.fill", action: stop)
                        .accessibilityIdentifier("ai.stop")
                } else {
                    composerButton(title: assistantLabel("Send"), icon: "arrow.up", action: prepareQuestion)
                        .disabled(modelUnavailable != nil || conversation.storageUnavailable || snapshot == nil ||
                                  incompatibleMedia || importingAttachments ||
                                  question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("ai.send")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(TrackerTheme.subtle, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai.composer")
    }

    private func composerButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(TrackerTheme.accent, in: Circle())
                .foregroundStyle(TrackerTheme.accentInk)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(ComposerActionStyle())
        .accessibilityLabel(title)
    }

    private func documentCommand(_ kind: AIConversationDocument.Kind) -> some View {
        Button { openReport(kind) } label: {
            composerToolLabel(commandTitle(kind), icon: kind == .recap ? "list.bullet.rectangle" : "doc.text")
        }
        .buttonStyle(.plain)
        .disabled(snapshot == nil || isWorking)
        .accessibilityIdentifier(kind == .recap ? "ai.command.recap" : "ai.command.visit")
    }

    private func composerToolLabel(_ title: String, icon: String, selected: Bool = false) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(minHeight: 28)
            .background(selected ? TrackerTheme.wash : TrackerTheme.surface, in: Capsule())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
    }

    private func commandTitle(_ kind: AIConversationDocument.Kind) -> String {
        kind == .recap ? assistantLabel("Recap") : assistantLabel("Visit summary")
    }

    private func status(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .foregroundStyle(TrackerTheme.muted)
    }

    private func sourceTitle(_ source: AIRecordReference) -> String {
        switch source {
        case .dose: assistantLabel("View dose")
        case .lab: assistantLabel("View lab result")
        case .curve: assistantLabel("View concentration plot")
        }
    }

    private func show(_ reference: AIRecordReference) {
        isQuestionFocused = false
        if reference == .curve {
            dismiss()
            showCurve()
        } else {
            sheet = .record(reference)
        }
    }

    private func setRange(_ value: AIRange) {
        stop()
        range = value
        failure = nil
    }

    private func openReport(_ kind: AIConversationDocument.Kind) {
        guard let snapshot, !isWorking else { return }
        isQuestionFocused = false
        let document = snapshot.document(kind, at: store.now, calendar: store.calendar)
        presentedReport = ReportRoute(document: document, mode: snapshot.mode, savedTurnID: nil)
    }

    private func prepareQuestion() {
        guard let snapshot, !isWorking, pendingRecordChange == nil,
              modelUnavailable == nil, !conversation.storageUnavailable,
              !incompatibleMedia, !importingAttachments else { return }
        isQuestionFocused = false
        failure = nil
        let draft = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        if draft.count > 500 {
            failure = assistantLabel("Keep the question to 500 characters or fewer.")
            return
        }
        let request = AIAssistantRequest(purpose: .question, question: draft, snapshot: snapshot,
                                         includesRecordFacts: !generatesImage)

        do {
            switch model {
            case .apple:
                let inputWithoutMemory = try request.input(context: nil, includeRecentTurns: false)
                let context = try conversation.context(
                    mode: snapshot.mode, modelLimit: AIModelClient.appleContextLimit(),
                    reservedTokens: AIModelClient.appleOutputLimit,
                    baseInput: AIAssistantRequest.instructions + inputWithoutMemory, includeRecentTurns: true
                )
                run(request, context: context)
            case .compatible:
                guard let profile = modelSettings.profile else { return }
                let cloud = CloudRequest(profile: profile, attachments: attachments, generatesImage: generatesImage,
                                         sendingRevision: modelSettings.sendingRevision)
                let inputWithoutMemory = try request.input(context: nil, includeRecentTurns: false,
                                                          allowsRecordChanges: cloud.allowsRecordChanges)
                let baseInput = cloud.instructions + inputWithoutMemory
                let limit = AIModelClient.compatibleContextLimit(for: profile)
                let outputLimit = AIModelClient.compatibleOutputLimit(for: profile)
                guard AIConversationStore.fits(modelLimit: limit, reservedTokens: outputLimit, baseInput: baseInput) else {
                    throw AIModelClientError.contextLimitExceeded
                }
                let remembered = modelSettings.rememberedSending(for: profile, includesAttachments: !attachments.isEmpty)
                var memory = remembered == false || cloud.generatesImage ? nil : try? conversation.context(
                    mode: snapshot.mode, modelLimit: limit, reservedTokens: outputLimit,
                    baseInput: baseInput, includeRecentTurns: false
                )
                if let context = memory {
                    let previewedInput = cloud.instructions + (try request.input(
                        context: context, includeRecentTurns: false, allowsRecordChanges: cloud.allowsRecordChanges
                    ))
                    if !AIConversationStore.fits(modelLimit: limit, reservedTokens: outputLimit, baseInput: previewedInput) {
                        memory = nil
                    }
                }
                if let includeMemory = remembered {
                    run(request, context: includeMemory ? memory : nil, cloud: cloud)
                } else {
                    sheet = .consent(Approval(request: request, cloud: cloud, memory: memory))
                }
            }
        } catch {
            failure = assistantLabel("Could not prepare this request. Shorten it and try again.")
        }
    }

    private func run(_ request: AIAssistantRequest, context: AIConversationContext?, cloud: CloudRequest? = nil) {
        guard !isWorking, let prompt = request.question else { return }
        runningID = request.id
        if let cloud {
            liveReply = LiveReply(question: prompt, attachmentNames: cloud.attachments.map(\.name))
        }
        requestTask = Task {
            defer {
                if runningID == request.id {
                    runningID = nil
                    requestTask = nil
                    liveReply = nil
                }
            }
            do {
                let selection: AIAssistantRequest.Selection
                if let cloud {
                    guard cloud.sendingRevision == modelSettings.sendingRevision else { throw AIModelClientError.settingsChanged }
                    let input = try request.input(context: context, includeRecentTurns: false,
                                                  allowsRecordChanges: cloud.allowsRecordChanges)
                    let apiKey = try modelSettings.apiKey(for: cloud.profile)
                    try await AIModelClient.streamCompatible(
                        system: cloud.instructions, input: input, profile: cloud.profile, apiKey: apiKey,
                        attachments: cloud.attachments, generateImage: cloud.generatesImage,
                        allowRecordChanges: cloud.allowsRecordChanges
                    ) { update in
                        guard runningID == request.id else { return }
                        receive(update)
                    }
                    try Task.checkCancellation()
                    guard runningID == request.id, request.snapshot.mode == store.mode, let liveReply else { return }
                    if let change = liveReply.recordChange, cloud.allowsRecordChanges {
                        let draft = AIRecordChangeDraft(arguments: change, snapshot: request.snapshot,
                                                        reference: request.recordReference(for: change.recordRef),
                                                        calendar: store.calendar)
                        pendingRecordChange = PendingRecordChange(
                            requestID: request.id, mode: request.snapshot.mode, question: prompt,
                            attachmentNames: liveReply.attachmentNames, draft: draft
                        )
                        resetComposer()
                        return
                    }
                    if liveReply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       liveReply.generatedImage != nil {
                        selection = AIAssistantRequest.Selection(answer: "", facts: [])
                    } else {
                        selection = try request.streamSelection(from: liveReply.text)
                    }
                } else {
                    let response = try await completeOnDevice(request, context: context)
                    selection = try request.selection(from: response)
                }
                try Task.checkCancellation()
                guard runningID == request.id, request.snapshot.mode == store.mode else { return }

                var sources: [AIRecordReference] = []
                for source in selection.facts.compactMap(\.source) where !sources.contains(source) {
                    sources.append(source)
                }
                do {
                    try conversation.append(AIChatTurn(
                        date: store.now, mode: request.snapshot.mode, question: prompt,
                        answer: selection.answer, sources: sources,
                        reasoningSummary: liveReply.flatMap { $0.reasoning.isEmpty ? nil : $0.reasoning },
                        generatedImage: liveReply?.generatedImage,
                        attachmentNames: liveReply?.attachmentNames ?? []
                    ))
                    resetComposer()
                } catch {
                    failure = assistantLabel("Could not update local chat and memory.")
                }
            } catch is CancellationError {
                // The draft remains available.
            } catch is AIAssistantRequest.InvalidReply {
                guard runningID == request.id, !Task.isCancelled else { return }
                failure = AIModelClientError.invalidResponse.errorDescription
            } catch {
                guard runningID == request.id, !Task.isCancelled else { return }
                if let safeError = error as? AIModelClientError {
                    failure = safeError.errorDescription ?? assistantLabel("Could not complete the request. Try again.")
                } else {
                    failure = assistantLabel("Could not complete the request. Try again.")
                }
            }
        }
    }

    private func receive(_ update: AIStreamUpdate) {
        switch update {
        case .text(let text): liveReply?.text += text
        case .reasoningSummary(let text): liveReply?.reasoning += text
        case .imagePreview(let image): liveReply?.imagePreview = image
        case .image(let image):
            if AIAssistantGeneratedImage.isValid(image) { liveReply?.generatedImage = image }
            liveReply?.imagePreview = nil
        case .recordChange(let change): liveReply?.recordChange = change
        }
    }

    private func resetComposer() {
        question = ""
        attachments = []
        generatesImage = false
    }

    private func finishRecordChange(_ pending: PendingRecordChange, reference: AIRecordReference) {
        guard pendingRecordChange?.requestID == pending.requestID else { return }
        pendingRecordChange = nil
        let answer: String
        switch reference {
        case .dose: answer = assistantLabel("Medication record saved.")
        case .lab: answer = assistantLabel("Lab result saved.")
        case .curve: return
        }
        do {
            try conversation.append(AIChatTurn(
                id: pending.requestID, date: store.now, mode: pending.mode, question: pending.question,
                answer: answer, sources: [reference], attachmentNames: pending.attachmentNames
            ))
        } catch {
            failure = assistantLabel("The record was saved. Could not save the chat receipt.")
        }
    }

    private func completeOnDevice(_ request: AIAssistantRequest, context: AIConversationContext?) async throws -> String {
        let system = AIAssistantRequest.instructions
        let localLimit = AIModelClient.appleContextLimit()
        let outputLimit = AIModelClient.appleOutputLimit
        let candidates = try [
            request.input(context: context, includeRecentTurns: true),
            request.input(context: context, includeRecentTurns: false),
            request.input(context: nil, includeRecentTurns: false)
        ]
        var attempted = Set<String>()
        for input in candidates where attempted.count < 2 && !attempted.contains(input) {
            try Task.checkCancellation()
            let fits: Bool
            if let count = await AIModelClient.appleTokenCount(system: system, input: input), let localLimit {
                fits = count < localLimit - outputLimit - 32
            } else {
                fits = AIConversationStore.fits(modelLimit: localLimit, reservedTokens: outputLimit,
                                                baseInput: system + input)
            }
            guard fits else { continue }
            attempted.insert(input)
            do {
                return try await AIModelClient.completeApple(system: system, input: input, locale: locale)
            } catch AIModelClientError.contextLimitExceeded {
                continue
            }
        }
        throw AIModelClientError.contextLimitExceeded
    }

    private func stop() {
        requestTask?.cancel()
        requestTask = nil
        runningID = nil
        liveReply = nil
    }
}

private struct AIAssistantReasoning: View {
    let summary: String
    @State private var expanded: Bool

    init(summary: String, startsExpanded: Bool) {
        self.summary = summary
        _expanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(verbatim: summary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 7)
                .textSelection(.enabled)
        } label: {
            Label(assistantLabel("Reasoning summary"), systemImage: "brain")
        }
        .font(.footnote)
        .foregroundStyle(TrackerTheme.muted)
        .padding(10)
        .background(TrackerTheme.subtle, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("ai.reasoningSummary")
    }
}

private struct ComposerActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(isEnabled ? (configuration.isPressed ? 0.76 : 1) : 0.4)
    }
}

func assistantLabel(_ key: String.LocalizationValue) -> String {
    label(key, table: "AIAssistant")
}
