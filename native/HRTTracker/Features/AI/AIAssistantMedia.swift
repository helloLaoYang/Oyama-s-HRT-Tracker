import CoreTransferable
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

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
