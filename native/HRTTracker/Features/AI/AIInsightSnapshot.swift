import Foundation
import HRTEngine

enum AIRange: Int, CaseIterable, Identifiable, Sendable {
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }
}

enum AIRecordReference: Codable, Equatable, Sendable {
    case dose(String)
    case lab(String)
    case curve
}

struct AIInsightFact: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let source: AIRecordReference?
}

struct AIInsightSnapshot: Sendable {
    let mode: HRTMode
    let range: AIRange
    let facts: [AIInsightFact]
    let report: String
    let doses: [DoseEvent]
    let labs: [LabResult]

    @MainActor
    static func capture(store: TrackerStore, range: AIRange) async -> Self {
        let mode = store.mode
        let now = store.now
        let calendar = store.calendar
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: 1 - range.rawValue, to: today) ?? today
        let interval = start.trackerHours...now.trackerHours
        let primary: ConcentrationSeries = mode == .transfem ? .e2 : .testosterone
        let records = store.doses.filter { $0.timeH.isFinite && $0.timeH <= interval.upperBound }
        let measurements = store.labs.filter { lab in
            guard lab.timeH.isFinite, lab.timeH <= interval.upperBound, lab.concValue > 0,
                  let measured = primary.measuredValue(lab) else { return false }
            return measured.isFinite
        }
        let doses = records.filter { $0.route != .patchRemove && interval.contains($0.timeH) }
        let labs = measurements.filter { interval.contains($0.timeH) }
        let request = TimelineRequest(
            events: records, labs: measurements, mode: mode, weight: store.weight,
            birthYear: store.ageModelEnabled ? store.birthYear : nil, parameters: store.pkParameters,
            method: store.calibrationMethod, history: store.calibrationHistory, scheduled: [],
            now: interval.upperBound, range: .week
        )
        let report = reportText(mode: mode, calendar: calendar, start: start, end: now,
                                doses: doses, labs: labs)
        var facts = recordFacts(mode: mode, calendar: calendar, doses: doses, labs: labs)
        if records.contains(where: HRTEngine.supportsConcentration) {
            let computation = Task.detached(priority: .userInitiated) { TimelineModel.calculate(request) }
            let model = await withTaskCancellationHandler {
                await computation.value
            } onCancel: {
                computation.cancel()
            }
            if !Task.isCancelled, let model {
                facts += concentrationFacts(model: model, at: now, calendar: calendar)
            }
        }
        facts.append(AIInsightFact(
            id: "estimate-explanation",
            text: aiDataLabel("A lab result is measured at sample time. Concentrations on the curve are estimates calculated from dose records."),
            source: nil
        ))
        return Self(mode: mode, range: range, facts: facts, report: report, doses: doses, labs: labs)
    }

    private static func recordFacts(mode: HRTMode, calendar: Calendar, doses: [DoseEvent],
                                    labs: [LabResult]) -> [AIInsightFact] {
        var facts = [
            AIInsightFact(id: "dose-count", text: aiDataLabel("Recorded doses: \(doses.count)"), source: nil),
            AIInsightFact(id: "lab-count", text: aiDataLabel("Recorded lab results: \(labs.count)"), source: nil)
        ]
        if let dose = doses.first {
            let detail = doseText(dose, calendar: calendar)
            facts.append(AIInsightFact(id: "latest-dose", text: aiDataLabel("Latest dose: \(detail)"),
                                       source: .dose(dose.id)))
        }
        if let lab = labs.first {
            let detail = labText(lab, mode: mode, calendar: calendar)
            facts.append(AIInsightFact(id: "latest-lab", text: aiDataLabel("Latest lab measurement: \(detail)"),
                                       source: .lab(lab.id)))
        }
        return facts
    }

    private static func concentrationFacts(model: TimelineModel, at date: Date,
                                           calendar: Calendar) -> [AIInsightFact] {
        model.traces.compactMap { trace in
            let series = trace.kind
            guard let value = model.value(series, at: date.trackerHours), value.isFinite, value > 0
            else { return nil }
            let name = series.name
            let concentration = "\(series.formatted(value)) \(series.unit)"
            let timestamp = dateText(date, calendar: calendar)
            let id = series == .testosterone ? "estimate-t" : "estimate-\(series.rawValue)"
            return AIInsightFact(id: id,
                                 text: aiDataLabel("Model estimate for \(name) at \(timestamp): \(concentration)"),
                                 source: .curve)
        }
    }

    private static func reportText(mode: HRTMode, calendar: Calendar, start: Date, end: Date,
                                   doses: [DoseEvent], labs: [LabResult]) -> String {
        let entries = doses.map { ($0.timeH, doseText($0, calendar: calendar)) } +
            labs.map { ($0.timeH, labText($0, mode: mode, calendar: calendar)) }
        var lines = [aiDataLabel("Visit summary"),
                     dateText(start, calendar: calendar, includeTime: false) + " – " +
                        dateText(end, calendar: calendar, includeTime: false)]
        if entries.isEmpty {
            lines.append(aiDataLabel("No dose records or measured lab results in this period."))
        } else {
            lines.append("")
            lines += entries.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return lines.joined(separator: "\n")
    }

    private static func doseText(_ dose: DoseEvent, calendar: Calendar) -> String {
        [dateText(Date(trackerHours: dose.timeH), calendar: calendar),
         HistoryText.drug(dose.ester), HistoryText.doseDescription(dose)]
            .joined(separator: " · ")
    }

    private static func labText(_ lab: LabResult, mode: HRTMode, calendar: Calendar) -> String {
        let measurement = lab.concValue.formatted(.number.precision(.fractionLength(0...2))) +
            " " + LabText.unitText(lab.unit)
        let name = mode == .transfem ? LabText.localized("Estradiol") : LabText.localized("Total testosterone")
        var fields = [dateText(Date(trackerHours: lab.timeH), calendar: calendar),
                      name, measurement, aiDataLabel("Measured")]
        if let assay = lab.assay, !assay.isEmpty { fields.append(LabText.assayText(assay)) }
        return fields.joined(separator: " · ")
    }

    private static func dateText(_ date: Date, calendar: Calendar, includeTime: Bool = true) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: includeTime ? .shortened : .omitted,
                                        locale: AppLanguage.selection.locale ?? .current,
                                        calendar: calendar, timeZone: calendar.timeZone))
    }
}
