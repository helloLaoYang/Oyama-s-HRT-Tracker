import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct AIAssistantPhotoInput: View {
    var maximumTextLength = 500
    let onInsert: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var phase = Phase.waiting
    @State private var text = ""

    private enum Phase: Equatable {
        case waiting, reading, review, noText, unreadable, tooLarge
    }

    private var editedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canInsert: Bool { phase == .review && !editedText.isEmpty && editedText.count <= maximumTextLength }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                        Label(aiPhotoInputLabel("Choose photo"), systemImage: "photo")
                    }
                    .disabled(phase == .reading)
                    .accessibilityIdentifier("ai.photo.choose")
                } footer: {
                    Text(aiPhotoInputLabel("Text is recognized on this device. Only text you add goes into the draft."))
                }

                switch phase {
                case .waiting:
                    EmptyView()
                case .reading:
                    ProgressView(aiPhotoInputLabel("Reading photo…"))
                case .review:
                    Section {
                        TextEditor(text: $text)
                            .frame(minHeight: 180)
                            .accessibilityLabel(aiPhotoInputLabel("Recognized text"))
                            .accessibilityIdentifier("ai.photo.text")
                    } header: {
                        Text(aiPhotoInputLabel("Recognized text"))
                    } footer: {
                        Text(editedText.count > maximumTextLength
                             ? aiPhotoInputLabel("Shorten the text to \(maximumTextLength) characters to add it.")
                             : aiPhotoInputLabel("Review the values, units, and dates before adding the text."))
                    }
                case .noText:
                    photoError(aiPhotoInputLabel("No readable text was found in this photo."))
                case .unreadable:
                    photoError(aiPhotoInputLabel("This photo could not be read. Choose another photo."))
                case .tooLarge:
                    photoError(aiPhotoInputLabel("This photo is too large. Choose a smaller photo."))
                }
            }
            .navigationTitle(aiPhotoInputLabel("Read text from photo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(assistantLabel("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(aiPhotoInputLabel("Add text")) {
                        onInsert(editedText)
                        dismiss()
                    }
                    .disabled(!canInsert)
                    .accessibilityIdentifier("ai.photo.insert")
                }
            }
        }
        .tint(TrackerTheme.accent)
        .task(id: selection) {
            guard let selection else { return }
            await read(selection)
        }
    }

    private func photoError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .accessibilityIdentifier("ai.photo.error")
    }

    private func read(_ item: PhotosPickerItem) async {
        phase = .reading
        text = ""
        do {
            let result = try await item.loadTransferable(type: AIAssistantPhotoText.self)
            try Task.checkCancellation()
            switch result {
            case .recognized(let recognized):
                text = recognized
                phase = .review
            case .noText: phase = .noText
            case .tooLarge: phase = .tooLarge
            case .unreadable, nil: phase = .unreadable
            }
        } catch {
            if !Task.isCancelled { phase = .unreadable }
        }
        // Clear the picker selection so the same photo can be chosen again.
        if !Task.isCancelled { selection = nil }
    }
}

enum AIAssistantPhotoText: Sendable, Equatable, Transferable {
    case recognized(String), noText, unreadable, tooLarge

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image, shouldAttemptToOpenInPlace: true) { received in
            try Task.checkCancellation()
            return recognize(received.file)
        }
    }

    static func recognize(_ url: URL) -> Self {
        let maximumPhotoBytes = 25_000_000
        let maximumSourcePixels = 64_000_000
        let maximumImageDimension = 3_072
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return .unreadable }
        guard size <= maximumPhotoBytes else { return .tooLarge }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let dimensions = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = dimensions[kCGImagePropertyPixelWidth as String] as? Int, width > 0,
              let height = dimensions[kCGImagePropertyPixelHeight as String] as? Int, height > 0
        else { return .unreadable }
        guard width <= maximumSourcePixels / height else { return .tooLarge }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumImageDimension,
              ] as CFDictionary) else { return .unreadable }

        do {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            let supported = try request.supportedRecognitionLanguages()
            let preferred = ["zh-Hans", "zh-Hant", "en-US", "de-DE", "fr-FR", "ja-JP"]
            request.recognitionLanguages = preferred.filter { supported.contains($0) }
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: thumbnail).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .noText : .recognized(text)
        } catch {
            return .unreadable
        }
    }
}

func aiPhotoInputLabel(_ key: String.LocalizationValue) -> String {
    label(key, table: "AIPhotoInput")
}
