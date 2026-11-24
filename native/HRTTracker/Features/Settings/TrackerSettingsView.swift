import HRTEngine
import SwiftUI
import UniformTypeIdentifiers

struct TrackerSettingsView: View {
    let store: TrackerStore
    let modelSettings: AIModelSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TrackerHeader(title: "Settings", subtitle: "") { EmptyView() }
                NavigationLink {
                    GeneralTrackerSettings(store: store)
                } label: {
                    row("General settings", description: "Weight, appearance, and projection", icon: "slider.horizontal.3")
                }
                .accessibilityIdentifier("settings.general")
                NavigationLink {
                    TrackerDataSettings(store: store)
                } label: {
                    row("Data management", description: "Import, export, and backup", icon: "externaldrive")
                }
                .accessibilityIdentifier("settings.data")
                NavigationLink {
                    AIModelSettingsView(settings: modelSettings)
                } label: {
                    row("AI models", description: "On-device and compatible models", icon: "sparkles", table: "AIMain")
                }
                .accessibilityIdentifier("settings.aiModels")
                NavigationLink {
                    TrackerAboutView(mode: store.mode, parameters: store.pkParameters)
                } label: {
                    row("About", description: "Concentration model and disclaimer", icon: "info.circle")
                }
                .accessibilityIdentifier("settings.about")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 17)
            .padding(.vertical, 12)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(TrackerTheme.background.ignoresSafeArea())
        .foregroundStyle(TrackerTheme.ink)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func row(_ title: LocalizedStringKey, description: LocalizedStringKey, icon: String,
                     table: String? = nil) -> some View {
        HStack(spacing: 12) {
            TrackerIcon(systemName: icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(title, tableName: table).font(.subheadline)
                Text(description, tableName: table).font(.footnote).foregroundStyle(TrackerTheme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(TrackerTheme.muted)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct GeneralTrackerSettings: View {
    @Bindable var store: TrackerStore
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .system

    var body: some View {
        Form {
            Section("What the estimates use") {
                Picker("HRT mode", selection: $store.mode) {
                    Text("Transfeminine").tag(HRTMode.transfem)
                    Text("Transmasculine").tag(HRTMode.transmasc)
                }
                LabeledContent("Weight (kg)") {
                    TextField("Weight (kg)", value: $store.weight, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Toggle(isOn: $store.ageModelEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Age adjustment (Beta)")
                        Text("Adjusts the estimate by age. Evidence is stronger for testosterone than for estradiol.")
                            .font(.footnote)
                            .foregroundStyle(TrackerTheme.muted)
                    }
                }
                if store.ageModelEnabled {
                    NavigationLink { AgeModelSettingsView(store: store) } label: {
                        LabeledContent("Age") {
                            Text(store.birthYear.map { String(store.calendar.component(.year, from: store.now) - $0) }
                                 ?? label("Not set"))
                        }
                    }
                    .accessibilityIdentifier("settings.age")
                }
                NavigationLink { DrugParametersView(store: store) } label: {
                    LabeledContent("Edit parameters") {
                        if !store.pkOverrides.isEmpty { Text("Customized").foregroundStyle(TrackerTheme.accent) }
                    }
                }
                .accessibilityIdentifier("settings.pkParameters")
            }
            Section("Inventory") {
                NavigationLink { InventoryView(store: store) } label: {
                    LabeledContent("Medication inventory") {
                        if !store.supplies.isEmpty { Text(store.supplies.count.formatted()).monospacedDigit() }
                    }
                }
                .accessibilityIdentifier("settings.inventory")
            }
            Section {
                NavigationLink {
                    AppearanceSettingsView(store: store)
                } label: {
                    LabeledContent("Appearance") { Text(store.appearance.title) }
                }
                .accessibilityIdentifier("settings.appearance")
                NavigationLink {
                    LanguageSettingsView(language: $language)
                } label: {
                    LabeledContent("Language") { Text(verbatim: language.title) }
                }
                .accessibilityIdentifier("settings.language")
                Toggle("Project using medication plan", isOn: $store.showPrediction)
                    .accessibilityIdentifier("settings.prediction")
                NavigationLink("Medication plan") { MedicationPlansView(store: store) }
            }
        }
        .navigationTitle("General settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LanguageSettingsView: View {
    @Binding var language: AppLanguage

    var body: some View {
        List(AppLanguage.allCases) { option in
            Button {
                language = option
            } label: {
                HStack {
                    Text(verbatim: option.title).foregroundStyle(TrackerTheme.ink)
                    Spacer()
                    if language == option {
                        Image(systemName: "checkmark").foregroundStyle(TrackerTheme.accent)
                    }
                }
            }
            .accessibilityAddTraits(language == option ? .isSelected : [])
            .accessibilityIdentifier("language.\(option.rawValue)")
        }
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AgeModelSettingsView: View {
    let store: TrackerStore
    @Environment(\.dismiss) private var dismiss
    @State private var birthYearText: String

    init(store: TrackerStore) {
        self.store = store
        _birthYearText = State(initialValue: store.birthYear.map(String.init) ?? "")
    }

    private var lastYear: Int { store.calendar.component(.year, from: store.now) }

    private var selectedYear: Int? {
        Int(birthYearText.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { (1900...lastYear).contains($0) ? $0 : nil }
    }

    var body: some View {
        Form {
            Section {
                TextField("Birth year (optional)", text: $birthYearText).keyboardType(.numberPad)
                if let selectedYear {
                    LabeledContent("Age", value: (lastYear - selectedYear).formatted())
                    if lastYear - selectedYear < 19 {
                        Text("The model uses an extrapolation for ages below 19.")
                            .font(.footnote)
                            .foregroundStyle(TrackerTheme.muted)
                    }
                }
            } footer: {
                Text("The model uses the year to estimate age when each recorded dose was taken.")
            }
            if store.birthYear != nil {
                Section {
                    Button("Remove birth year", role: .destructive) {
                        store.birthYear = nil
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("Age adjustment (Beta)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let selectedYear {
                        store.birthYear = selectedYear
                        dismiss()
                    }
                }
                .disabled(selectedYear == nil)
            }
        }
    }
}

private struct AppearanceSettingsView: View {
    @Bindable var store: TrackerStore

    var body: some View {
        List {
            ForEach(AppAppearance.allCases) { appearance in
                Button {
                    store.appearance = appearance
                } label: {
                    HStack {
                        Text(appearance.title).foregroundStyle(TrackerTheme.ink)
                        Spacer()
                        if store.appearance == appearance {
                            Image(systemName: "checkmark").foregroundStyle(TrackerTheme.accent)
                        }
                    }
                }
                .accessibilityAddTraits(store.appearance == appearance ? .isSelected : [])
                .accessibilityIdentifier("appearance.\(appearance.rawValue)")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension AppAppearance {
    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .mono: "Monochrome"
        }
    }
}

private struct TrackerAboutView: View {
    let mode: HRTMode
    let parameters: PKParameters

    var body: some View {
        List {
            Section("About concentration estimates") {
                NavigationLink("Model explanation") { ModelGuideView(mode: mode, parameters: parameters) }
                    .accessibilityIdentifier("settings.modelGuide")
                Text("Concentrations are model estimates and may differ substantially from laboratory results.")
            }
            Section("Disclaimer") {
                Text("Use laboratory reports and your care team to make treatment decisions.")
                Link("Project website", destination: URL(string: "https://github.com/helloLaoYang/Oyama-s-HRT-Tracker")!)
                    .accessibilityIdentifier("settings.projectWebsite")
            }
            NavigationLink(FeedbackText.localized("Feedback")) { FeedbackView() }
                .accessibilityIdentifier("settings.feedback")
            NavigationLink("Open-source licenses") { OpenSourceLicensesView() }
                .accessibilityIdentifier("settings.licenses")
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OpenSourceLicensesView: View {
    private static let licenseText = Bundle.main.url(forResource: "LICENSE", withExtension: nil).flatMap {
        try? String(contentsOf: $0, encoding: .utf8)
    }

    var body: some View {
        List {
            Section("Project license") {
                Link(destination: URL(string: "https://github.com/xunxunProjects/Oyama-s-HRT-Tracker/blob/main/LICENSE")!) {
                    Text(verbatim: "Oyama’s HRT Tracker")
                }
            }
            Section("Original pharmacokinetic model") {
                Link(destination: URL(string: "https://github.com/LaoZhong-Mihari/HRT-Recorder-PKcomponent-Test")!) {
                    Text(verbatim: "LaoZhong-Mihari · HRT-Recorder-PKcomponent-Test")
                }
                .accessibilityIdentifier("licenses.pkSource")
            }
            Section {
                if let license = Self.licenseText {
                    Text(verbatim: license)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("licenses.mit")
                } else {
                    Text("License text could not be loaded.")
                }
            }
        }
        .navigationTitle("Open-source licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TrackerDataSettings: View {
    let store: TrackerStore
    @State private var pickingFile = false
    @State private var exportingFile = false
    @State private var document: TrackerBackupFile?
    @State private var preview: BackupPreview?
    @State private var showingPreview = false
    @State private var feedback: String?

    var body: some View {
        List {
            Button("Import data") { pickingFile = true }
                .accessibilityIdentifier("backup.import")
            Button("Export data") {
                do {
                    document = TrackerBackupFile(data: try store.exportBackup())
                    exportingFile = true
                } catch {
                    feedback = error.localizedDescription
                }
            }
            .accessibilityIdentifier("backup.export")
        }
        .navigationTitle("Data management")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                preview = try store.previewBackup(Data(contentsOf: url))
                showingPreview = true
            } catch {
                feedback = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exportingFile, document: document, contentType: .json,
                      defaultFilename: "HRTrace-Backup") { result in
            if case .failure(let error) = result { feedback = error.localizedDescription }
        }
        .navigationDestination(isPresented: $showingPreview) {
            if let preview {
                List {
                    Section("Import preview") {
                        countRows(preview.counts)
                    }
                    if !preview.settingsToImport.isEmpty {
                        Section("Settings to import") {
                            ForEach(preview.settingsToImport, id: \.self) { Text($0) }
                        }
                    }
                    if !preview.ignoredCategories.isEmpty {
                        Section("Skipped categories") {
                            ForEach(preview.ignoredCategories, id: \.self) { Text($0) }
                        }
                    }
                    Button("Import records") {
                        do {
                            let counts = try store.importBackup(preview)
                            showingPreview = false
                            feedback = label("Imported \(counts.added), updated \(counts.updated), skipped \(counts.skipped).")
                        } catch {
                            feedback = error.localizedDescription
                        }
                    }
                }
                .navigationTitle("Import preview")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .alert("Data management", isPresented: Binding(
            get: { feedback != nil },
            set: { if !$0 { feedback = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(feedback ?? "")
        }
    }

    @ViewBuilder
    private func countRows(_ counts: BackupCounts) -> some View {
        LabeledContent("To add", value: counts.added.formatted())
        LabeledContent("To update", value: counts.updated.formatted())
        LabeledContent("To skip", value: counts.skipped.formatted())
        LabeledContent("Invalid entries", value: counts.invalid.formatted())
    }
}

private struct TrackerBackupFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
