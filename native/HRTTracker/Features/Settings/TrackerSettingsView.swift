import HRTEngine
import SwiftUI
import UniformTypeIdentifiers

struct TrackerSettingsView: View {
    let store: TrackerStore

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
                    TrackerAboutView()
                } label: {
                    row("About", description: "Concentration model and disclaimer", icon: "info.circle")
                }
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

    private func row(_ title: LocalizedStringKey, description: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 12) {
            TrackerIcon(systemName: icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline)
                Text(description).font(.footnote).foregroundStyle(TrackerTheme.muted)
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
    @State private var birthYearText = ""
    @FocusState private var birthYearFocused: Bool

    var body: some View {
        Form {
            Section {
                Picker("HRT mode", selection: $store.mode) {
                    Text("Transfeminine").tag(HRTMode.transfem)
                    Text("Transmasculine").tag(HRTMode.transmasc)
                }
                LabeledContent("Weight (kg)") {
                    TextField("Weight (kg)", value: $store.weight, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Include age in the model", isOn: $store.ageModelEnabled)
                if store.ageModelEnabled {
                    TextField("Birth year (optional)", text: $birthYearText)
                        .keyboardType(.numberPad)
                        .focused($birthYearFocused)
                        .onChange(of: birthYearText) { _, text in
                            if text.isEmpty { store.birthYear = nil }
                            else if let year = Int(text), (1900...Calendar.current.component(.year, from: store.now)).contains(year) {
                                store.birthYear = year
                            }
                        }
                }
            }
            Section {
                NavigationLink {
                    AppearanceSettingsView(store: store)
                } label: {
                    LabeledContent("Appearance") { Text(store.appearance.title) }
                }
                .accessibilityIdentifier("settings.appearance")
                Toggle("Project using medication plan", isOn: $store.showPrediction)
                    .accessibilityIdentifier("settings.prediction")
                NavigationLink("Medication plan") { MedicationPlansView(store: store) }
            }
        }
        .onAppear { birthYearText = store.birthYear.map(String.init) ?? "" }
        .navigationTitle("General settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { birthYearFocused = false }
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
    var body: some View {
        List {
            Section("About concentration estimates") {
                Text("Concentrations are model estimates and may differ substantially from laboratory results.")
            }
            Section("Disclaimer") {
                Text("Use laboratory reports and your care team to make treatment decisions.")
                Link("Project website", destination: URL(string: "https://hrt.mahiro.uk")!)
            }
        }
        .navigationTitle("About")
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
                      defaultFilename: "HRT-Tracker-Backup") { result in
            if case .failure(let error) = result { feedback = error.localizedDescription }
        }
        .navigationDestination(isPresented: $showingPreview) {
            if let preview {
                List {
                    Section("Import preview") {
                        countRows(preview.counts)
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
                            feedback = String(localized: "Imported \(counts.added), updated \(counts.updated), skipped \(counts.skipped).")
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
