import SwiftUI

@MainActor
struct AIModelSettingsView: View {
    let settings: AIModelSettings

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase

    @State private var address = ""
    @State private var credentialAddress: URL?
    @State private var catalogKey = ""
    @State private var key = ""
    @State private var showKey = false
    @State private var credentialLoadFailed = false
    @State private var model: String?
    @State private var models: [String] = []
    @State private var api: AIProviderAPI = .responses
    @State private var requestsReasoningSummary = false
    @State private var effort: AIReasoningEffort = .medium
    @State private var contextLimit = ""
    @State private var showModels = false
    @State private var showRemoveConfirmation = false
    @State private var restored = false
    @State private var activity: Activity?
    @State private var task: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var status: Status?
    @State private var appleStatus: AIAppleAvailability?

    private enum Activity { case fetchingModels, testingConnection }

    private struct Status {
        let message: String
        let failed: Bool
        let activity: Activity?
    }

    private var baseURL: URL? { AIModelClient.baseURL(from: address) }
    private var appleUnavailable: String? {
        (appleStatus ?? AIModelClient.appleAvailability(locale: locale)).unavailableReason
    }
    private var contextText: String { contextLimit.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var confirmedLimit: Int? { Int(contextText).flatMap { $0 > 0 ? $0 : nil } }
    private var draft: AIProviderProfile? {
        guard let baseURL, let model, contextText.isEmpty || confirmedLimit != nil else { return nil }
        return AIProviderProfile(baseURL: baseURL, model: model, effort: effort, contextLimit: confirmedLimit,
                                 api: api, requestsReasoningSummary: api == .responses && requestsReasoningSummary)
    }

    var body: some View {
        Form {
            Section(AIModelText.localized("Apple on-device model")) {
                Text(appleUnavailable ?? AIModelText.localized("Available on this device"))
                    .foregroundStyle(appleUnavailable == nil ? TrackerTheme.ink : TrackerTheme.muted)
                    .accessibilityIdentifier("ai.models.appleStatus")
                if appleUnavailable == nil, let limit = AIModelClient.appleContextLimit() {
                    contextRow("Effective context", limit: limit)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AIModelText.localized("Service address"))
                    TextField("https://api.example.com/v1", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel(AIModelText.localized("Service address"))
                        .accessibilityIdentifier("ai.models.address")
                    if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, baseURL == nil {
                        Text(AIModelClientError.invalidAddress.errorDescription ?? "")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(AIModelText.localized("API key (optional)"))
                    HStack {
                        Group {
                            if showKey {
                                TextField(AIModelText.localized("API key"), text: $key)
                            } else {
                                SecureField(AIModelText.localized("API key"), text: $key)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("ai.models.key")
                        if !key.isEmpty {
                            Button {
                                showKey.toggle()
                            } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                                    .font(.system(size: 16, weight: .regular))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(AIModelText.localized(showKey ? "Hide API key" : "Show API key"))
                        }
                    }
                }
                modelsRow
                Picker(AIModelText.localized("API format"), selection: $api) {
                    ForEach(AIProviderAPI.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .disabled(activity != nil)
                .accessibilityIdentifier("ai.models.api")
                if api == .responses {
                    Toggle(AIModelText.localized("Show reasoning summaries"), isOn: $requestsReasoningSummary)
                        .disabled(activity != nil)
                        .accessibilityIdentifier("ai.models.reasoningSummary")
                }
                if api == .chatCompletions || requestsReasoningSummary {
                    Picker(AIModelText.localized("Reasoning effort"), selection: $effort) {
                        ForEach(AIReasoningEffort.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    .disabled(activity != nil)
                    .accessibilityIdentifier("ai.models.reasoning")
                }
            } header: {
                Text(AIModelText.localized("Compatible service"))
            } footer: {
                Text(AIModelText.localized("Reasoning summaries and image generation require a compatible Responses API model."))
            }
            Section {
                Picker(AIModelText.localized("Confirm sending"), selection: Binding(
                    get: { settings.confirmationMode }, set: { settings.setConfirmationMode($0) }
                )) {
                    ForEach(AIExternalConfirmationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("ai.models.confirmationMode")
                if settings.hasSendingApproval {
                    Button(AIModelText.localized("Revoke sending permission"), role: .destructive) {
                        settings.revokeSendingApproval()
                    }
                    .accessibilityIdentifier("ai.models.revokeSendingApproval")
                }
            } footer: {
                Text(AIModelText.localized("Attachments require a separate first confirmation. Changing the service address, model, API format, or key resets approval."))
            }
            Section {
                contextRow("Default context", limit: AIModelClient.defaultContextLimit)
                VStack(alignment: .leading, spacing: 4) {
                    Text(AIModelText.localized("Provider context limit"))
                    TextField(AIModelText.localized("Unverified"), text: $contextLimit)
                        .keyboardType(.numberPad)
                        .accessibilityLabel(AIModelText.localized("Provider context limit"))
                        .accessibilityIdentifier("ai.models.context")
                    if !contextText.isEmpty, confirmedLimit == nil {
                        Text(AIModelText.localized("Enter a positive whole number."))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .disabled(activity != nil)
                contextRow("Effective context", limit: min(AIModelClient.defaultContextLimit, confirmedLimit ?? AIModelClient.unverifiedContextLimit))
            } footer: {
                Text(AIModelText.localized("Leave the provider limit blank if unknown. A short context is used until you verify it."))
            }
            Section {
                Button(action: testConnection) {
                    if activity == .testingConnection {
                        ProgressView(AIModelText.localized("Testing connection…"))
                    } else {
                        Text(AIModelText.localized("Test connection"))
                    }
                }
                .accessibilityIdentifier("ai.models.test")
                .disabled(draft == nil || activity != nil || credentialLoadFailed)
                if let status, status.activity != .fetchingModels {
                    statusLabel(status)
                }
            }
            if settings.profile != nil {
                Section {
                    Button(AIModelText.localized("Remove compatible service"), role: .destructive) {
                        showRemoveConfirmation = true
                    }
                    .disabled(activity != nil)
                }
            }
        }
        .navigationTitle(AIModelText.localized("AI models"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(AIModelText.localized("Save"), action: save)
                    .accessibilityIdentifier("ai.models.save")
                    .disabled(draft == nil || activity != nil || credentialLoadFailed)
            }
        }
        .sheet(isPresented: $showModels) { modelPicker }
        .confirmationDialog(AIModelText.localized("Remove compatible service?"), isPresented: $showRemoveConfirmation, titleVisibility: .visible) {
            Button(AIModelText.localized("Remove compatible service"), role: .destructive, action: remove)
        }
        .onAppear(perform: restoreDraft)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await AIModelClient.monitorAppleAvailability(locale: locale) { appleStatus = $0 }
        }
        .onDisappear(perform: cancelOperation)
        .onChange(of: address) { _, value in
            let newURL = AIModelClient.baseURL(from: value)
            guard credentialAddress != newURL else { return }
            credentialAddress = newURL
            let hadCredential = !key.isEmpty || credentialLoadFailed
            catalogKey = ""
            key = ""
            showKey = false
            credentialLoadFailed = false
            model = nil
            models = []
            contextLimit = ""
            cancelOperation()
            setStatus(hadCredential ? AIModelText.localized("Service address changed. Re-enter the API key if needed.") : nil)
        }
        .onChange(of: key) { _, value in
            guard value != catalogKey else { return }
            catalogKey = value
            if !value.isEmpty { credentialLoadFailed = false }
            cancelOperation()
            models = []
            model = nil
            contextLimit = ""
            setStatus(nil)
        }
    }

    private var modelsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(AIModelText.localized("Model name"))
                Spacer(minLength: 8)
                Button(action: fetchModels) {
                    if activity == .fetchingModels {
                        ProgressView().accessibilityLabel(AIModelText.localized("Loading models…"))
                    } else {
                        Text(AIModelText.localized("Fetch models"))
                            .multilineTextAlignment(.trailing)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(baseURL == nil || activity != nil || credentialLoadFailed)
                .accessibilityIdentifier("ai.models.fetch")
            }
            Button {
                showModels = true
            } label: {
                HStack {
                    Text(model ?? AIModelText.localized(models.isEmpty ? "Fetch models first" : "Choose a model"))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.borderless)
            .disabled(models.isEmpty || activity != nil)
            .accessibilityIdentifier("ai.models.selector")
            if let status, status.activity == .fetchingModels {
                statusLabel(status)
            }
        }
    }

    private func statusLabel(_ status: Status) -> some View {
        Text(status.message)
            .font(.footnote)
            .foregroundStyle(status.failed ? Color.red : TrackerTheme.muted)
            .accessibilityIdentifier("ai.models.status")
    }

    private var modelPicker: some View {
        NavigationStack {
            List(models, id: \.self) { name in
                Button {
                    if model != name { contextLimit = "" }
                    model = name
                    showModels = false
                } label: {
                    HStack {
                        Text(name)
                        Spacer()
                        if model == name {
                            Image(systemName: "checkmark").accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(model == name ? .isSelected : [])
                .accessibilityIdentifier("ai.models.choice.\(name)")
            }
            .navigationTitle(AIModelText.localized("Choose a model"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AIModelText.localized("Cancel")) { showModels = false }
                }
            }
        }
    }

    private func contextRow(_ name: String.LocalizationValue, limit: Int) -> some View {
        LabeledContent(AIModelText.localized(name)) {
            Text(limit, format: .number.locale(locale))
                .monospacedDigit()
        }
    }

    private func restoreDraft() {
        guard !restored else { return }
        restored = true
        guard let profile = settings.profile else { return }
        credentialAddress = profile.baseURL
        address = profile.baseURL.absoluteString
        model = profile.model
        api = profile.api
        requestsReasoningSummary = profile.requestsReasoningSummary
        effort = profile.effort
        contextLimit = profile.contextLimit.map(String.init) ?? ""
        do {
            let storedKey = try settings.apiKey(for: profile) ?? ""
            catalogKey = storedKey
            key = storedKey
        } catch {
            credentialLoadFailed = true
            showError(error)
        }
    }

    private func fetchModels() {
        guard let baseURL else { return }
        let apiKey = key
        perform(.fetchingModels) {
            let fetched = try await AIModelClient.fetchModels(baseURL: baseURL, apiKey: apiKey)
            try Task.checkCancellation()
            models = fetched
            if let model, !fetched.contains(model) {
                self.model = nil
                contextLimit = ""
            }
            if fetched.isEmpty {
                setStatus(AIModelText.localized("The service returned no models."))
            } else {
                showModels = true
            }
        }
    }

    private func testConnection() {
        guard let draft else { return }
        let apiKey = key
        perform(.testingConnection) {
            _ = try await AIModelClient.completeCompatible(
                system: "Reply to this connection test with the single word OK.",
                input: "Connection test", profile: draft, apiKey: apiKey
            )
            try Task.checkCancellation()
            setStatus(AIModelText.localized("Connection successful"))
        }
    }

    private func perform(_ activity: Activity, action: @escaping @MainActor () async throws -> Void) {
        cancelOperation()
        let id = UUID()
        operationID = id
        self.activity = activity
        setStatus(nil)
        task = Task {
            defer { if operationID == id { cancelOperation() } }
            do {
                try await action()
            } catch is CancellationError {
                return
            } catch {
                if operationID == id && !Task.isCancelled { showError(error) }
            }
        }
    }

    private func cancelOperation() {
        task?.cancel()
        task = nil
        operationID = nil
        activity = nil
    }

    private func showError(_ error: Error) {
        setStatus((error as? AIModelClientError)?.errorDescription ?? AIModelText.localized("Could not update the model settings."), failed: true)
    }

    private func setStatus(_ message: String?, failed: Bool = false) {
        status = message.map { Status(message: $0, failed: failed, activity: activity) }
    }

    private func save() {
        guard let draft, !credentialLoadFailed else { return }
        do {
            try settings.save(draft, apiKey: key)
            dismiss()
        } catch {
            showError(error)
        }
    }

    private func remove() {
        do {
            try settings.remove()
            dismiss()
        } catch {
            showError(error)
        }
    }
}
