import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct AIAssistantAttachment: Identifiable, Equatable, Sendable {
    static let maxCount = 4
    static let maxTotalBytes = 16 * 1024 * 1024

    let id = UUID()
    let name: String
    let mimeType: String
    let data: Data

    var isPDF: Bool { mimeType == "application/pdf" }

    var isValidPayload: Bool {
        guard !data.isEmpty, data.count <= Self.maxTotalBytes else { return false }
        switch mimeType {
        case "application/pdf": return Data(data.prefix(1024)).range(of: Data("%PDF-".utf8)) != nil
        case "image/jpeg": return data.starts(with: [0xff, 0xd8, 0xff])
        case "image/png": return data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        default: return false
        }
    }

    static func loadFile(_ url: URL, maxBytes: Int = maxTotalBytes) throws -> Self {
        try load(url, imageName: nil, maxBytes: maxBytes)
    }

    fileprivate static func loadPhoto(_ url: URL) throws -> Self {
        try load(url, imageName: aiMediaLabel("Photo"), maxBytes: maxTotalBytes)
    }

    private static func load(_ url: URL, imageName: String?, maxBytes: Int) throws -> Self {
        guard maxBytes > 0 else { throw AIAssistantAttachmentError.limit }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let resource = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
        guard resource.isRegularFile != false else { throw AIAssistantAttachmentError.invalid }
        let budget = min(maxBytes, maxTotalBytes)
        let isPDF = imageName == nil &&
            (resource.contentType?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf")
        if isPDF {
            if let size = resource.fileSize, size > budget { throw AIAssistantAttachmentError.limit }
            let data = try read(url, limit: budget)
            let attachment = Self(name: fileName(url.deletingPathExtension().lastPathComponent, extension: "pdf"),
                                  mimeType: "application/pdf", data: data)
            guard attachment.isValidPayload else { throw AIAssistantAttachmentError.invalid }
            return attachment
        }

        // The file may be larger than its normalized upload, but importing it still has a local read limit.
        let sourceLimit = 32 * 1024 * 1024
        if let size = resource.fileSize, size > sourceLimit { throw AIAssistantAttachmentError.limit }
        let original = try read(url, limit: sourceLimit)
        guard let source = CGImageSourceCreateWithData(original as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true,
              imageDimensionsFit(source, maxSide: 16_384, maxPixels: 80_000_000),
              let image = mediaThumbnail(source, maxSide: 2_048) else {
            throw AIAssistantAttachmentError.invalid
        }
        let hasAlpha = [.premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly].contains(image.alphaInfo)
        let format: UTType = hasAlpha ? .png : .jpeg
        let bytes = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(bytes, format.identifier as CFString, 1, nil) else {
            throw AIAssistantAttachmentError.invalid
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        // Writing the decoded thumbnail omits source metadata and applies orientation before upload.
        CGImageDestinationAddImage(output, image, hasAlpha ? nil : options)
        guard CGImageDestinationFinalize(output) else { throw AIAssistantAttachmentError.invalid }
        guard bytes.length <= budget else { throw AIAssistantAttachmentError.limit }
        return Self(name: fileName(imageName ?? url.deletingPathExtension().lastPathComponent,
                                   extension: hasAlpha ? "png" : "jpg"),
                    mimeType: hasAlpha ? "image/png" : "image/jpeg", data: bytes as Data)
    }

    private static func read(_ url: URL, limit: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while data.count <= limit {
            let chunkSize = min(65_536, limit + 1 - data.count)
            guard let chunk = try file.read(upToCount: chunkSize), !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        throw AIAssistantAttachmentError.limit
    }

    private static func fileName(_ base: String, extension suffix: String) -> String {
        let safe = base.components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(String((safe.isEmpty ? aiMediaLabel("Attachment") : safe).prefix(96))).\(suffix)"
    }
}

private enum AIAssistantAttachmentError: Error {
    case invalid, limit

    var message: String {
        switch self {
        case .invalid: aiMediaLabel("Could not open this image or PDF.")
        case .limit: aiMediaLabel("Attach up to 4 files totaling no more than 16 MB.")
        }
    }
}

private struct AISelectedPhoto: Transferable {
    let attachment: AIAssistantAttachment

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            Self(attachment: try AIAssistantAttachment.loadPhoto(file.file))
        }
    }
}

struct AIAssistantAttachmentControls<Actions: View>: View {
    @Binding var attachments: [AIAssistantAttachment]
    var allowsAdding = true
    var onLoadingChanged: (Bool) -> Void = { _ in }
    let onError: (String) -> Void
    @ViewBuilder let actions: () -> Actions

    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selection: Selection?

    private enum Selection: Equatable {
        case photo(PhotosPickerItem)
        case files([URL])
    }

    private var remainingBytes: Int {
        AIAssistantAttachment.maxTotalBytes - attachments.reduce(0) { $0 + $1.data.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in chip(for: attachment) }
                    }
                }
                .scrollIndicators(.hidden)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    if allowsAdding { attachmentMenu }
                    actions()
                }
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(TrackerTheme.accent)
        .photosPicker(isPresented: $showPhotos, selection: $selectedPhoto, matching: .images,
                      preferredItemEncoding: .current)
        .onChange(of: selectedPhoto) { _, photo in
            if allowsAdding, let photo { beginImport(.photo(photo)) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image, .pdf], allowsMultipleSelection: true) { result in
            guard allowsAdding else { return }
            switch result {
            case .success(let urls) where !urls.isEmpty: beginImport(.files(urls))
            case .success: break
            case .failure: onError(AIAssistantAttachmentError.invalid.message)
            }
        }
        .onChange(of: allowsAdding) { _, allowed in
            if !allowed {
                showPhotos = false
                showFiles = false
                endImport()
            }
        }
        .onDisappear { endImport() }
        .task(id: selection) {
            guard allowsAdding, let selection else { return }
            await importAttachments(selection)
        }
    }

    private var attachmentMenu: some View {
        Menu {
            Button { showPhotos = true } label: {
                Label(aiMediaLabel("Choose photo"), systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("ai.attachments.photo")
            Button { showFiles = true } label: {
                Label(aiMediaLabel("Choose image or PDF"), systemImage: "folder")
            }
            .accessibilityIdentifier("ai.attachments.file")
        } label: {
            Label(aiMediaLabel("Add attachment"), systemImage: "paperclip")
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.medium))
                .frame(width: 30, height: 30)
                .background(TrackerTheme.surface, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .disabled(selection != nil || attachments.count >= AIAssistantAttachment.maxCount || remainingBytes <= 0)
        .accessibilityIdentifier("ai.attachments.add")
    }

    private func beginImport(_ incoming: Selection) {
        selection = incoming
        onLoadingChanged(true)
    }

    private func endImport() {
        selectedPhoto = nil
        if selection != nil {
            selection = nil
            onLoadingChanged(false)
        }
    }

    private func chip(for attachment: AIAssistantAttachment) -> some View {
        let visualOffset: CGFloat = 5
        return HStack(spacing: 0) {
            Label(attachment.name, systemImage: attachment.isPDF ? "doc" : "photo")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(TrackerTheme.ink)
                .frame(maxWidth: 156, alignment: .leading)
                .padding(.leading, 12)
                .offset(y: visualOffset)
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TrackerTheme.muted)
                    .offset(y: visualOffset)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(aiMediaLabel("Remove \(attachment.name)"))
            .accessibilityIdentifier("ai.attachments.remove")
        }
        .background {
            Capsule().fill(TrackerTheme.surface).frame(height: 30).offset(y: visualOffset)
        }
    }

    private func importAttachments(_ incoming: Selection) async {
        defer {
            if !Task.isCancelled, selection == incoming {
                endImport()
            }
        }

        do {
            let loaded: [AIAssistantAttachment]
            switch incoming {
            case .photo(let item):
                guard let selected = try await item.loadTransferable(type: AISelectedPhoto.self) else {
                    throw AIAssistantAttachmentError.invalid
                }
                loaded = [selected.attachment]
            case .files(let urls):
                guard attachments.count + urls.count <= AIAssistantAttachment.maxCount else {
                    throw AIAssistantAttachmentError.limit
                }
                let budget = remainingBytes
                loaded = try await Task.detached(priority: .userInitiated) {
                    var remaining = budget
                    var files: [AIAssistantAttachment] = []
                    for url in urls {
                        let file = try AIAssistantAttachment.loadFile(url, maxBytes: remaining)
                        remaining -= file.data.count
                        files.append(file)
                    }
                    return files
                }.value
            }
            try Task.checkCancellation()
            guard attachments.count + loaded.count <= AIAssistantAttachment.maxCount,
                  loaded.reduce(0, { $0 + $1.data.count }) <= remainingBytes else {
                throw AIAssistantAttachmentError.limit
            }
            attachments.append(contentsOf: loaded)
        } catch {
            if !Task.isCancelled {
                onError((error as? AIAssistantAttachmentError ?? .invalid).message)
            }
        }
    }
}

struct AIAssistantGeneratedImage: View {
    let data: Data
    var allowsSharing = true
    @State private var rendered: UIImage?

    nonisolated private static let maxBytes = 8 * 1024 * 1024

    nonisolated static func isValid(_ data: Data) -> Bool { source(data) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let rendered {
                Image(uiImage: rendered)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel(aiMediaLabel("Generated image"))
                    .accessibilityIdentifier("ai.generatedImage")
                if allowsSharing {
                    let transfer = AIImageTransfer(data: data,
                                                   isJPEG: data.starts(with: [0xff, 0xd8, 0xff]))
                    ShareLink(item: transfer, preview: SharePreview(aiMediaLabel("Generated image"),
                                                                   image: Image(uiImage: rendered))) {
                        Label(aiMediaLabel("Share image"), systemImage: "square.and.arrow.up")
                            .font(.footnote.weight(.medium))
                    }
                    .accessibilityIdentifier("ai.generatedImage.share")
                }
            }
        }
        .task(id: data) {
            let preview = await Task.detached(priority: .utility) { Self.thumbnail(data) }.value
            if !Task.isCancelled { rendered = preview }
        }
    }

    nonisolated private static func source(_ data: Data) -> CGImageSource? {
        guard !data.isEmpty, data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
              type == .png || type == .jpeg,
              imageDimensionsFit(source, maxSide: 4_096, maxPixels: 16_777_216) else { return nil }
        return source
    }

    nonisolated private static func thumbnail(_ data: Data) -> UIImage? {
        guard let source = source(data), let image = mediaThumbnail(source, maxSide: 1_600) else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct AIImageTransfer: Transferable {
    let data: Data
    let isJPEG: Bool

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
            .exportingCondition { !$0.isJPEG }
            .suggestedFileName("HRTrace.png")
        DataRepresentation(exportedContentType: .jpeg) { $0.data }
            .exportingCondition { $0.isJPEG }
            .suggestedFileName("HRTrace.jpg")
    }
}

private func imageDimensionsFit(_ source: CGImageSource, maxSide: Int, maxPixels: Int) -> Bool {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
          let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
          width > 0, height > 0, width <= maxSide, height <= maxSide else { return false }
    return width * height <= maxPixels
}

private func mediaThumbnail(_ source: CGImageSource, maxSide: Int) -> CGImage? {
    CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxSide,
        kCGImageSourceShouldCacheImmediately: true
    ] as CFDictionary)
}

func aiMediaLabel(_ key: String.LocalizationValue) -> String {
    label(key, table: "AIMedia")
}
