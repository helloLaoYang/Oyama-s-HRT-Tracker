import UIKit
import XCTest
@testable import HRTTracker

final class AIAssistantPhotoInputTests: XCTestCase {
    private func temporaryPhoto() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
    }

    @MainActor
    func testRecognizesChineseAndEnglishInOnePhoto() throws {
        let url = temporaryPhoto()
        defer { try? FileManager.default.removeItem(at: url) }
        let chineseHeading = "\u{5316}\u{9A8C}\u{7ED3}\u{679C}"
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_100, height: 320), format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_100, height: 320))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 64),
                                                              .foregroundColor: UIColor.black]
            (chineseHeading as NSString).draw(at: CGPoint(x: 60, y: 50), withAttributes: attributes)
            ("Estradiol 120 pg/mL" as NSString).draw(at: CGPoint(x: 60, y: 145), withAttributes: attributes)
        }
        try XCTUnwrap(image.pngData()).write(to: url)

        guard case .recognized(let text) = AIAssistantPhotoText.recognize(url) else {
            return XCTFail("Expected readable photo text")
        }
        let compactText = text.filter { !$0.isWhitespace }
        XCTAssertTrue(compactText.contains(chineseHeading), "\(text)")
        XCTAssertTrue(compactText.localizedCaseInsensitiveContains("Estradiol120pg/mL"), "\(text)")
    }

    func testRejectsAnOversizedPhotoBeforeDecoding() throws {
        let url = temporaryPhoto()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 25_000_001)
        try file.close()

        XCTAssertEqual(AIAssistantPhotoText.recognize(url), .tooLarge)
    }
}
