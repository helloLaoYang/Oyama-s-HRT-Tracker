import SwiftUI

struct OverviewLevelRail: View {
    let kind: ConcentrationSeries
    let value: Double

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if value.isFinite, value > 0, let domain = kind.comparisonRange, let target = kind.target,
           let status {
            let input = RailInput(value: value, domain: domain, target: target)
            let palette = status.tone.colors
            let tone = color(palette.light, palette.dark)
            let low = target.lowerBound.formatted(.number.grouping(.never))
            let high = target.upperBound.formatted(.number.grouping(.never))

            RailLayout(input: input) {
                Text(status.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tone)
                    .accessibilityIdentifier("overview.estimate.status")
                rail(input: input, tone: tone)
                    .accessibilityHidden(true)
                limitLabel(low)
                    .accessibilityLabel(Text("Target range \(low)–\(high)"))
                limitLabel(high)
                    .accessibilityHidden(true)
            }
        }
    }

    private func rail(input: RailInput, tone: Color) -> some View {
        let pending = color(0xE3E1DC, 0x373530)
        return Canvas { context, size in
            let scale = input.scale(width: size.width)
            for index in 0...scale.last {
                let selected = index == scale.current
                let reached = index <= scale.current
                let inTarget = index >= scale.firstTarget && index <= scale.lastTarget
                let tickHeight: CGFloat = selected ? 18 : inTarget ? 11 : 8
                let tickWidth: CGFloat = selected ? 2 : 1.5
                let ink: Color
                if selected {
                    ink = tone
                } else if inTarget {
                    ink = TrackerTheme.accent.opacity(reached ? 1 : 0.4)
                } else {
                    ink = reached ? TrackerTheme.muted : pending
                }
                let rect = CGRect(x: scale.x(index) - tickWidth / 2, y: size.height - tickHeight,
                                  width: tickWidth, height: tickHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: tickWidth / 2), with: .color(ink))
            }
        }
    }

    private func limitLabel(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(TrackerTheme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
    }

    private var status: (title: LocalizedStringKey, tone: RailTone)? {
        switch kind {
        case .e2:
            switch value {
            case ..<8: ("Below reference range", .warning)
            case ..<30: ("In male range", .neutral)
            case ..<70: ("Follicular-phase level", .violet)
            case 100...200: ("In GAHT target range", .positive)
            case ...300: ("Luteal-phase level", .info)
            default: ("Above reference range", .warning)
            }
        case .testosterone:
            switch value {
            case ..<100: ("Below male reference", .neutral)
            case ..<300: ("Below testosterone target range", .violet)
            case ..<600: ("In male range", .positive)
            case ...1000: ("Near upper limit", .positive)
            default: ("Above reference range", .warning)
            }
        case .cpa:
            nil
        }
    }

    private func color(_ light: UInt32, _ dark: UInt32) -> Color {
        let hex = colorScheme == .dark ? dark : light
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255)
    }
}

private enum RailTone {
    case violet, positive, info, neutral, warning

    var colors: (light: UInt32, dark: UInt32) {
        switch self {
        case .violet: (0x5E45CD, 0xB0ADFB)
        case .positive: (0x0F7C55, 0x64D8A4)
        case .info: (0x0267C7, 0x80BDFB)
        case .neutral: (0x6B6860, 0xA7A49E)
        case .warning: (0xA35303, 0xF5B75B)
        }
    }
}

private struct RailInput {
    let value: Double
    let domain: ClosedRange<Double>
    let target: ClosedRange<Double>

    func scale(width: CGFloat) -> RailScale {
        let last = max(24, min(96, Int((width / 7).rounded()))) - 1
        func tickPosition(_ level: Double) -> Double {
            let clamped = min(domain.upperBound, max(domain.lowerBound, level))
            return Double(last) * log(clamped / domain.lowerBound) / log(domain.upperBound / domain.lowerBound)
        }
        return RailScale(width: width, last: last, current: Int(tickPosition(value).rounded()),
                         firstTarget: Int(tickPosition(target.lowerBound).rounded(.up)),
                         lastTarget: Int(tickPosition(target.upperBound).rounded(.down)))
    }
}

private struct RailScale {
    let width: CGFloat
    let last: Int
    let current: Int
    let firstTarget: Int
    let lastTarget: Int

    func x(_ tick: Int) -> CGFloat { 1 + CGFloat(tick) / CGFloat(last) * max(0, width - 2) }

    var targetLabelWidth: CGFloat {
        max(1, min(x(lastTarget) - x(firstTarget) - 3, 2 * min(x(firstTarget), width - x(lastTarget))))
    }
}

private struct RailLayout: Layout {
    let input: RailInput
    private let gap: CGFloat = 5
    private let railHeight: CGFloat = 18

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        let statusHeight = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let limits = ProposedViewSize(width: input.scale(width: width).targetLabelWidth, height: nil)
        let limitsHeight = max(subviews[2].sizeThatFits(limits).height, subviews[3].sizeThatFits(limits).height)
        return CGSize(width: width, height: statusHeight + railHeight + limitsHeight + 2 * gap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let scale = input.scale(width: bounds.width)
        let statusProposal = ProposedViewSize(width: bounds.width, height: nil)
        let statusSize = subviews[0].sizeThatFits(statusProposal)
        let fraction = CGFloat(scale.current) / CGFloat(scale.last)
        let statusX = max(0, min(bounds.width - statusSize.width, scale.x(scale.current) - fraction * statusSize.width))
        subviews[0].place(at: CGPoint(x: bounds.minX + statusX, y: bounds.minY), anchor: .topLeading,
                          proposal: statusProposal)

        let railY = bounds.minY + statusSize.height + gap
        subviews[1].place(at: CGPoint(x: bounds.minX, y: railY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: railHeight))
        let limitsY = railY + railHeight + gap
        let limits = ProposedViewSize(width: scale.targetLabelWidth, height: nil)
        subviews[2].place(at: CGPoint(x: bounds.minX + scale.x(scale.firstTarget), y: limitsY),
                          anchor: .top, proposal: limits)
        subviews[3].place(at: CGPoint(x: bounds.minX + scale.x(scale.lastTarget), y: limitsY),
                          anchor: .top, proposal: limits)
    }
}
