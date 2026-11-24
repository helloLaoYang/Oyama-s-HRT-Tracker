import Foundation

struct AIConversationDocument: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case recap, visit

        var title: String {
            switch self {
            case .recap: aiDocumentLabel("Record recap")
            case .visit: aiDocumentLabel("Visit summary")
            }
        }

        var icon: String { self == .recap ? "chart.bar" : "doc.text" }
    }

    struct Item: Codable, Equatable, Sendable {
        let title: String
        let detail: String
        let date: Date
        let source: AIRecordReference
    }

    let kind: Kind
    let start: Date
    let end: Date
    let timeZoneID: String
    let doseCount: Int
    let labCount: Int
    let doses: [Item]
    let labs: [Item]
    let estimates: [Item]
    var editedText: String? = nil

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt
        return calendar
    }

    var period: String {
        let first = dateLabel(start)
        let last = dateLabel(end)
        return first == last ? first : "\(first) – \(last)"
    }

    func dateLabel(_ date: Date) -> String {
        formatted(date, date: .abbreviated, time: .omitted)
    }

    func timeLabel(_ date: Date) -> String {
        formatted(date, date: .omitted, time: .shortened)
    }

    var generatedText: String {
        var paragraphs = [kind.title, period]
        appendSection(aiDocumentLabel("Medication records"), rows: doses, count: doseCount, into: &paragraphs)
        appendSection(aiDocumentLabel("Measured lab results"), rows: labs, count: labCount, into: &paragraphs)
        if !estimates.isEmpty {
            appendSection(aiDocumentLabel("Model estimates"), rows: estimates, count: nil, into: &paragraphs)
            paragraphs.append(aiDocumentLabel("Estimates are calculated from recorded doses and are separate from lab measurements."))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    var exportText: String { editedText ?? generatedText }

    private func appendSection(_ title: String, rows: [Item], count: Int?, into paragraphs: inout [String]) {
        let heading = count.map { "\(title) · \($0.formatted())" } ?? title
        let lines = rows.sorted { $0.date < $1.date }.map { row in
            "\(formatted(row.date, date: .abbreviated, time: .shortened)) · \(row.title) · \(row.detail)"
        }
        paragraphs.append(([heading] + (lines.isEmpty ? [aiDocumentLabel("No entries in this period.")] : lines))
            .joined(separator: "\n"))
    }

    private func formatted(_ value: Date, date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        value.formatted(Date.FormatStyle(date: date, time: time, locale: AppLanguage.selection.locale ?? .current,
                                         calendar: calendar, timeZone: calendar.timeZone))
    }
}

func aiDocumentLabel(_ key: String.LocalizationValue) -> String {
    label(key, table: "AIDocuments")
}
