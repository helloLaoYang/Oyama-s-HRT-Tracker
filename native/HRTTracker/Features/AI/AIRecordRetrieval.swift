import Foundation
import HRTEngine

struct AIRecordRetrieval {
    private struct QueryDay {
        let year: Int?
        let month: Int
        let day: Int

        func matches(_ components: DateComponents) -> Bool {
            (year == nil || components.year == year) && components.month == month && components.day == day
        }
    }

    private struct Match {
        let source: AIRecordReference
        let timeH: Double
        let relevance: Int
    }

    private static let datePatterns = [
        #"(?<![0-9])([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})(?![0-9])"#,
        #"(?<![0-9])(?:([0-9]{4})年)?([0-9]{1,2})月([0-9]{1,2})[日号]"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let doseTerms = ["dose", "doses", "medication", "medications", "用药", "服药", "剂量"]
    private static let labTerms = ["lab", "labs", "blood test", "bloodwork", "measured", "化验", "验血", "抽血", "实测"]

    private static let routes: [Route: [String]] = [
        .injection: ["injection", "injections", "intramuscular", "注射", "肌注"],
        .sc: ["injection", "injections", "subcutaneous", "注射", "皮下"],
        .oral: ["oral", "pill", "pills", "口服"],
        .sublingual: ["sublingual", "舌下"],
        .patchApply: ["patch", "patches", "贴片"],
        .gel: ["gel", "凝胶"],
        .nasal: ["nasal", "鼻喷"],
        .pellet: ["implant", "pellet", "植入"],
    ]

    private static let drugs: [String: [String]] = [
        "E2": ["estradiol", "雌二醇"], "EV": ["estradiol valerate", "戊酸雌二醇", "补佳乐"],
        "EB": ["estradiol benzoate", "苯甲酸雌二醇"], "EC": ["estradiol cypionate", "环戊丙酸雌二醇"],
        "EN": ["estradiol enanthate", "庚酸雌二醇"], "EU": ["estradiol undecylate", "十一酸雌二醇"],
        "CPA": ["cyproterone", "环丙孕酮"], "SPIRO": ["spironolactone", "螺内酯"],
        "BICA": ["bicalutamide", "比卡鲁胺"], "MPA": ["medroxyprogesterone", "甲羟孕酮"],
        "LEUP": ["leuprorelin", "亮丙瑞林"], "TRIP": ["triptorelin", "曲普瑞林"], "RLX": ["raloxifene", "雷洛昔芬"],
        "T": ["testosterone", "睾酮"], "TC": ["testosterone cypionate", "环戊丙酸睾酮"],
        "TE": ["testosterone enanthate", "庚酸睾酮"], "TU": ["testosterone undecanoate", "十一酸睾酮"],
    ]

    private let question: String
    private let asciiQuestion: String
    private let days: [QueryDay]

    var hasExplicitDates: Bool { !days.isEmpty }

    init(question: String) {
        let normalized = Self.normalize(question)
        self.question = normalized
        asciiQuestion = " " + Self.asciiWords(normalized) + " "
        let range = NSRange(normalized.startIndex..., in: normalized)
        days = Self.datePatterns.flatMap { regex in
            regex.matches(in: normalized, range: range).compactMap { match in
                let numbers = (1...3).map { group -> Int? in
                    Range(match.range(at: group), in: normalized).flatMap { Int(normalized[$0]) }
                }
                guard let month = numbers[1], let day = numbers[2] else { return nil }
                return QueryDay(year: numbers[0], month: month, day: day)
            }
        }
    }

    func sources(in snapshot: AIInsightSnapshot, calendar: Calendar) -> [AIRecordReference] {
        let doseTopic = strength(Self.doseTerms)
        let labTopic = strength(Self.labTerms)
        let doseMatches = snapshot.doses.compactMap { dose -> Match? in
            let drugTerms = [dose.ester, HistoryText.drug(dose.ester)] + (Self.drugs[dose.ester] ?? [])
            let routeTerms = Self.routes[dose.route] ?? []
            let relevance = doseTopic + 2 * strength(drugTerms) + strength(routeTerms)
            guard permits(dose.timeH, relevance: relevance, otherTopic: labTopic, in: snapshot, calendar: calendar)
            else { return nil }
            return Match(source: .dose(dose.id), timeH: dose.timeH, relevance: relevance)
        }
        let hormoneTerms = Self.drugs[snapshot.mode == .transfem ? "E2" : "T"] ?? []
        let labMatches = snapshot.labs.compactMap { lab -> Match? in
            let relevance = labTopic + strength(hormoneTerms + [lab.unit, lab.assay ?? ""])
            guard permits(lab.timeH, relevance: relevance, otherTopic: doseTopic, in: snapshot, calendar: calendar)
            else { return nil }
            return Match(source: .lab(lab.id), timeH: lab.timeH, relevance: relevance)
        }
        return (doseMatches + labMatches).sorted { ($0.relevance, $0.timeH) > ($1.relevance, $1.timeH) }
            .prefix(6).map(\.source)
    }

    private func permits(_ timeH: Double, relevance: Int, otherTopic: Int, in snapshot: AIInsightSnapshot,
                         calendar: Calendar) -> Bool {
        guard timeH.isFinite else { return false }
        let date = Date(trackerHours: timeH)
        if let interval = snapshot.capturedInterval, !interval.contains(date) { return false }
        if days.isEmpty { return relevance > 0 }
        guard relevance > 0 || otherTopic == 0 else { return false }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return days.contains { $0.matches(components) }
    }

    private func strength(_ terms: [String]) -> Int {
        terms.lazy.map(Self.normalize).filter { term in
            guard !term.isEmpty else { return false }
            if !term.allSatisfy(\.isASCII) { return question.contains(term) }
            let words = Self.asciiWords(term)
            return !words.isEmpty && asciiQuestion.contains(" " + words + " ")
        }.map(\.count).max() ?? 0
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func asciiWords(_ text: String) -> String {
        text.split { !$0.isASCII || !($0.isLetter || $0.isNumber || $0 == "'") }.joined(separator: " ")
    }
}
