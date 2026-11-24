import SwiftUI

struct OverviewPixelCats: View {
    let hasDoses: Bool
    let hasLabs: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            if hasDoses { sprite(Self.donut) }
            if hasLabs { sprite(Self.loaf) }
        }
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func sprite(_ rows: [String]) -> some View {
        let palette = (colorScheme == .dark ? Self.darkPalette : Self.lightPalette).map { color($0) }
        return Canvas { context, size in
            let pixelWidth = size.width / 26
            let pixelHeight = size.height / 15
            var pixels = Array(repeating: Path(), count: palette.count)
            for (y, row) in rows.enumerated() {
                for (x, token) in row.enumerated() {
                    guard let index = token.hexDigitValue else { continue }
                    pixels[index].addRect(CGRect(x: CGFloat(x) * pixelWidth, y: CGFloat(y) * pixelHeight,
                                                 width: pixelWidth, height: pixelHeight))
                }
            }
            for (path, color) in zip(pixels, palette) {
                context.fill(path, with: .color(color), style: FillStyle(antialiased: false))
            }
        }
        .frame(width: 32, height: 32 * 15 / 26)
    }

    private func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    // Static frames and colors from the MIT-licensed web PixelCat by Joseph Smirnova Oyama.
    // A hexadecimal digit selects a palette entry. A dot leaves the pixel transparent.
    private static let donut = [
        "..........................",
        "......6.......6...........",
        ".....606.....606..........",
        ".....6306...6036..........",
        "...7711117771111777.......",
        "..711111111111111117......",
        "..829222222292222228......",
        "..82222aa22222222228......",
        ".8222bbbb2c2222222228..88.",
        ".711b9bbbcc1111111117.7447",
        "..711bbbb1c111111117..7447",
        "..71117771117771111444444.",
        "...6603330003330000666666.",
        ".....66666666666666.......",
        "..........................",
    ]

    private static let loaf = [
        "...........6......6.......",
        "..........606....606......",
        "..........6306666036......",
        ".........600000000006.....",
        ".......7711111111111177...",
        "......711119111111911117..",
        "......822222222222222228..",
        ".....822222222aa222222228.",
        ".....82222222222222222228.",
        ".77..71111111111111111117.",
        ".744711111111111111111117.",
        ".744711111111111111111117.",
        "..6336000006660066600006..",
        "...63366666333663336666...",
        "..........................",
    ]

    private static let lightPalette: [UInt32] = [
        0x9FD4EE, 0xF6BFCE, 0xFFFFFF, 0x7FB8D6, 0xDFA1B3, 0xE2D6DA,
        0x6FA8C9, 0xD191A5, 0xCFBFC4, 0x3F3238, 0xE58BA4, 0xF2A868, 0xD4813F,
    ]

    private static let darkPalette: [UInt32] = [
        0x7FB3CE, 0xD69FAF, 0xE4DBDE, 0x688FA6, 0xB8848F, 0xC3B7BB,
        0x547588, 0x966B76, 0xA0959A, 0x2B2226, 0xC97488, 0xE39B5C, 0xB96F33,
    ]
}
