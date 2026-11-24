import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ConcentrationShareSnapshot: Identifiable {
    let id = UUID()
    let timeline: TimelineModel
    let calendar: Calendar
    let range: TrackerChartRange
    let monochrome: Bool
}

struct ConcentrationSharePreview: View {
    let snapshot: ConcentrationShareSnapshot

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @FocusState private var editingCaption: Bool
    @State private var caption = String(localized: "My concentration trend · HRT Tracker (model estimate)")
    @State private var copiedCaption = false
    @State private var image: UIImage?
    @State private var imageFailed = false
    @State private var exportFile: ConcentrationImageFile?
    @State private var exportingImage = false
    @State private var exportFailed = false
    @State private var presenter = UIViewController()

    private var hasCaption: Bool {
        !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    imagePreview
                    VStack(alignment: .leading, spacing: 8) {
                        TrackerSectionTitle(title: "Caption")
                        TextField("Caption", text: $caption, axis: .vertical)
                            .font(.subheadline)
                            .lineLimit(2...4)
                            .padding(12)
                            .background(TrackerTheme.subtle, in: RoundedRectangle(cornerRadius: 10))
                            .focused($editingCaption)
                            .accessibilityIdentifier("overview.share.caption")
                    }
                    fallbackActions
                }
                .padding(17)
                .frame(maxWidth: 540)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { shareButton }
            .background(TrackerTheme.background.ignoresSafeArea())
            .foregroundStyle(TrackerTheme.ink)
            .navigationTitle("Share preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("overview.share.close")
                }
            }
        }
        .tint(TrackerTheme.accent)
        .task { prepareImage() }
        .onChange(of: caption) { copiedCaption = false }
        .fileExporter(isPresented: $exportingImage, document: exportFile, contentType: .png,
                      defaultFilename: "HRT-Tracker-Concentration") { result in
            if case .failure = result { exportFailed = true }
        }
        .alert("Could not save image", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(TrackerTheme.separator)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("Hormone concentration over time")
                .accessibilityIdentifier("overview.share.image")
        } else if imageFailed {
            ContentUnavailableView("Could not prepare image", systemImage: "photo")
        } else {
            ProgressView("Preparing image…")
                .frame(maxWidth: .infinity, minHeight: 180)
        }
    }

    private var fallbackActions: some View {
        HStack(spacing: 16) {
            Button {
                UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: caption]], options: [.localOnly: true])
                copiedCaption = true
            } label: {
                Label {
                    if copiedCaption { Text("Caption copied") } else { Text("Copy caption") }
                } icon: {
                    Image(systemName: copiedCaption ? "checkmark" : "document.on.document")
                }
            }
            .disabled(!hasCaption)
            .accessibilityIdentifier("overview.share.copy")

            Button {
                guard let data = image?.pngData() else {
                    exportFailed = true
                    return
                }
                exportFile = ConcentrationImageFile(data: data)
                exportingImage = true
            } label: {
                Label("Save image", systemImage: "arrow.down.to.line")
            }
            .disabled(image == nil)
            .accessibilityIdentifier("overview.share.save")
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
    }

    private var shareButton: some View {
        Button {
            guard let image else { return }
            editingCaption = false
            var items: [Any] = [image]
            if hasCaption { items.append(caption) }
            let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = presenter.view.bounds
            }
            presenter.present(activity, animated: true)
        } label: {
            Label("Share image and text", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(TrackerTheme.accentInk)
        }
        .buttonStyle(.borderedProminent)
        .disabled(image == nil)
        .accessibilityIdentifier("overview.share.send")
        .background {
            SharePresenter(controller: presenter)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 10)
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity)
        .background(TrackerTheme.background)
    }

    private func prepareImage() {
        guard image == nil else { return }
        let card = ConcentrationShareCard(model: snapshot.timeline, calendar: snapshot.calendar, range: snapshot.range)
            .frame(width: 390)
            .environment(\.colorScheme, colorScheme)
            .environment(\.locale, locale)
            .environment(\.dynamicTypeSize, .large)
            .saturation(snapshot.monochrome ? 0 : 1)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        image = renderer.uiImage
        imageFailed = image == nil
    }
}

private struct SharePresenter: UIViewControllerRepresentable {
    let controller: UIViewController

    func makeUIViewController(context: Context) -> UIViewController { controller }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

private struct ConcentrationImageFile: FileDocument {
    static let readableContentTypes: [UTType] = [.png]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
