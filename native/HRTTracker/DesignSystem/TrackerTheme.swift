import HRTEngine
import SwiftUI
import UIKit

enum TrackerTheme {
    static let background = color(0xFFFFFF, 0x181714)
    static let surface = color(0xFFFFFF, 0x23211E)
    static let subtle = color(0xF7F6F3, 0x2C2A26)
    static let ink = color(0x181714, 0xFBFBF9)
    static let muted = color(0x6B6860, 0xA7A49E)
    static let separator = color(0xEEEDEA, 0x373530)
    static let accent = color(0xAC573D, 0xDF8F74)
    static let accentInk = color(0xFFFFFF, 0x271811)
    static let wash = color(0xFAF0E9, 0x382119)
    static let chartLine = color(0xCC785C, 0xDF8F74)
    static let secondaryChart = color(0x827D73, 0xABA59B)
    static let band = color(0xF2E6D9, 0x443329)
    static let good = color(0x356B57, 0x9BD5BA)

    static func navigationSymbol(_ name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(weight: .light))?
            .withRenderingMode(.alwaysTemplate)
    }

    static func navigationIcon(_ name: String) -> Image {
        navigationSymbol(name).map(Image.init(uiImage:)) ?? Image(systemName: name)
    }

    static let labNavigationIcon: Image = {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { renderer in
            let context = renderer.cgContext
            context.translateBy(x: 12, y: 12)
            context.rotate(by: .pi / 4)
            context.translateBy(x: -12, y: -12)

            let tube = UIBezierPath()
            tube.move(to: CGPoint(x: 8.5, y: 4))
            tube.addLine(to: CGPoint(x: 8.5, y: 17))
            tube.addQuadCurve(to: CGPoint(x: 12, y: 20.5), controlPoint: CGPoint(x: 8.5, y: 20.5))
            tube.addQuadCurve(to: CGPoint(x: 15.5, y: 17), controlPoint: CGPoint(x: 15.5, y: 20.5))
            tube.addLine(to: CGPoint(x: 15.5, y: 4))
            tube.move(to: CGPoint(x: 7, y: 4))
            tube.addLine(to: CGPoint(x: 17, y: 4))
            tube.move(to: CGPoint(x: 8.5, y: 12))
            tube.addLine(to: CGPoint(x: 15.5, y: 12))
            tube.lineWidth = 1.5
            tube.lineCapStyle = .round
            UIColor.black.setStroke()
            tube.stroke()
        }
        return Image(uiImage: image.withRenderingMode(.alwaysTemplate))
    }()

    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

extension Date {
    var trackerHours: Double { timeIntervalSince1970 / 3600 }
    init(trackerHours: Double) { self.init(timeIntervalSince1970: trackerHours * 3600) }
}

func trackerDrugName(_ ester: String) -> String {
    switch ester {
    case "E2": label("Estradiol")
    case "EV": label("Estradiol valerate")
    case "EB": label("Estradiol benzoate")
    case "EC": label("Estradiol cypionate")
    case "EN": label("Estradiol enanthate")
    case "EU": label("Estradiol undecylate")
    case "CPA": label("Cyproterone acetate")
    case "SPIRO": label("Spironolactone")
    case "BICA": label("Bicalutamide")
    case "MPA": label("Medroxyprogesterone acetate")
    case "LEUP": label("Leuprorelin")
    case "TRIP": label("Triptorelin")
    case "RLX": label("Raloxifene")
    case "T": label("Testosterone")
    case "TC": label("Testosterone cypionate")
    case "TE": label("Testosterone enanthate")
    case "TU": label("Testosterone undecanoate")
    default: ester
    }
}

extension Route {
    var trackerTitle: LocalizedStringKey {
        switch self {
        case .patchApply: "Apply patch"
        case .patchRemove: "Remove patch"
        case .injection: "Injection"
        case .oral: "Oral"
        case .sublingual: "Sublingual"
        case .gel: "Gel"
        case .nasal: "Nasal"
        case .sc: "Subcutaneous"
        case .pellet: "Pellet"
        }
    }

    var trackerIcon: String {
        switch self {
        case .patchApply, .patchRemove: "bandage"
        case .injection, .sc: "syringe"
        case .gel: "drop"
        case .nasal: "wind"
        default: "pill"
        }
    }
}

struct TrackerIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.body)
            .frame(width: 36, height: 36)
            .foregroundStyle(TrackerTheme.accent)
            .background(TrackerTheme.wash, in: RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
    }
}

struct TrackerHeader<Action: View>: View {
    let title: LocalizedStringKey
    let subtitle: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.largeTitle.weight(.medium))
                    .accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(TrackerTheme.muted)
                }
            }
            Spacer()
            action
        }
        .padding(.bottom, 5)
    }
}

struct TrackerSectionTitle: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.headline.weight(.medium))
            .accessibilityAddTraits(.isHeader)
    }
}

struct TrackerSegment<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    var compact = false
    var tableName: String? = nil
    var optionIdentifier: ((Option) -> String)? = nil
    let title: (Option) -> LocalizedStringKey

    var body: some View {
        HStack(spacing: compact ? 2 : 3) {
            ForEach(options, id: \.self) { option in
                let button = Button {
                    selection = option
                } label: {
                    Text(title(option), tableName: tableName)
                        .font(compact ? .footnote : .subheadline)
                        .foregroundStyle(selection == option ? TrackerTheme.ink : TrackerTheme.muted)
                        .padding(.horizontal, compact ? 8 : 11)
                        .padding(.vertical, compact ? 5 : 8)
                        .background {
                            if selection == option {
                                RoundedRectangle(cornerRadius: compact ? 6 : 8)
                                    .fill(TrackerTheme.surface)
                                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
                if let optionIdentifier {
                    button.accessibilityIdentifier(optionIdentifier(option))
                } else {
                    button
                }
            }
        }
        .padding(compact ? 2 : 3)
        .background(TrackerTheme.subtle, in: RoundedRectangle(cornerRadius: compact ? 9 : 11))
    }
}

struct TrackerLinkLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Image(systemName: "chevron.right")
                .font(.caption)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .foregroundStyle(TrackerTheme.accent)
        .frame(minHeight: 44)
    }
}
