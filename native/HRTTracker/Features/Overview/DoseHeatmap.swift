import HRTEngine
import SwiftUI

struct DoseHeatmap: View {
    let doses: [DoseEvent]
    let now: Date
    let calendar: Calendar
    @State private var selection: Date?
    private let weekCount = 21
    private let gap: CGFloat = 3

    var body: some View {
        let today = calendar.startOfDay(for: now)
        let selected = selection ?? today
        let cells = makeWeeks(through: today)
        let counts = Dictionary(grouping: doses.filter { $0.route != .patchRemove && $0.timeH <= now.trackerHours }) {
            calendar.startOfDay(for: Date(trackerHours: $0.timeH))
        }
        let maxCount = max(4, counts.values.map(\.count).max() ?? 0)
        VStack(alignment: .leading, spacing: 8) {
            TrackerSectionTitle(title: "Medication activity")
            monthLabels(cells, through: today)
                .frame(height: 19)
                .accessibilityHidden(true)
            HStack(alignment: .top, spacing: gap) {
                VStack(spacing: gap) {
                    ForEach(0..<7) { row in
                        Color.clear.aspectRatio(1, contentMode: .fit).overlay {
                            if let letter = [0: label("Mon"), 2: label("Wed"), 4: label("Fri")][row] {
                                Text(letter).font(.system(size: 9)).fixedSize().foregroundStyle(TrackerTheme.muted)
                            }
                        }
                    }
                }
                .accessibilityHidden(true)
                ForEach(cells.indices, id: \.self) { column in
                    VStack(spacing: gap) {
                        ForEach(cells[column], id: \.self) { date in
                            if date <= today {
                                let events = counts[date, default: []]
                                let level = ceil(Double(events.count) * 4 / Double(maxCount))
                                let color = level > 0 ? TrackerTheme.chartLine.opacity(0.14 + level * 0.19) : TrackerTheme.separator
                                Button {
                                    selection = date
                                } label: {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(color)
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay {
                                            if date == today || date == selected {
                                                RoundedRectangle(cornerRadius: 3)
                                                    .strokeBorder(TrackerTheme.accent, lineWidth: date == selected ? 1.3 : 0.75)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(detail(date, events: events))
                                .accessibilityAddTraits(date == selected ? .isSelected : [])
                            } else {
                                Color.clear.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Daily medication records for the past 21 weeks")
            Text(detail(selected, events: counts[selected, default: []], drugs: true))
                .font(.footnote)
                .foregroundStyle(TrackerTheme.muted)
                .accessibilityIdentifier("heatmap.selected")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.heatmap")
    }

    private func monthLabels(_ weeks: [[Date]], through today: Date) -> some View {
        GeometryReader { geometry in
            let width = (geometry.size.width - gap * CGFloat(weekCount)) / CGFloat(weekCount + 1)
            let ticks = weeks.indices.filter { index in
                let current = min(weeks[index][6], today)
                let previous = index > 0 ? weeks[index - 1][6] : weeks[0][0]
                return index > 1 && index < weekCount - 1 && calendar.component(.month, from: current) != calendar.component(.month, from: previous)
            }
            ForEach(ticks, id: \.self) { index in
                Text(weeks[index][6].formatted(.dateTime.month(.abbreviated).timeZone(calendar.timeZone)))
                    .font(.caption2)
                    .foregroundStyle(TrackerTheme.muted)
                    .fixedSize()
                    .position(x: width + gap + CGFloat(index) * (width + gap) + width / 2,
                              y: geometry.size.height / 2)
            }
        }
    }

    private func makeWeeks(through today: Date) -> [[Date]] {
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7
        let offset = -((weekCount - 1) * 7 + weekday)
        return (0..<weekCount).map { week in
            (0..<7).map { day in
                calendar.date(byAdding: .day, value: offset + 7 * week + day, to: today) ?? today
            }
        }
    }

    private func detail(_ date: Date, events: [DoseEvent], drugs: Bool = false) -> String {
        let when = date.formatted(.dateTime.month().day().weekday().timeZone(calendar.timeZone))
        let count = label("\(events.count) medication records")
        guard drugs, !events.isEmpty else { return when + " · " + count }
        let names = Set(events.map { trackerDrugName($0.ester) }).sorted().joined(separator: "、")
        return when + " · " + count + " · " + names
    }
}
