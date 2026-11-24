import Foundation

public enum HRTMode: String, Codable, CaseIterable, Sendable {
    case transfem, transmasc
}

public enum Route: String, Codable, CaseIterable, Sendable {
    case sublingual, injection, patchApply, patchRemove, gel, oral, nasal, sc, pellet
}

public struct DoseEvent: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var route: Route
    public var timeH: Double
    public var doseMG: Double
    public var ester: String
    public var extras: [String: Double]
    public var updatedAt: Double?

    public init(
        id: String = UUID().uuidString.lowercased(),
        route: Route,
        timeH: Double,
        doseMG: Double,
        ester: String,
        extras: [String: Double] = [:],
        updatedAt: Double? = nil
    ) {
        self.id = id
        self.route = route
        self.timeH = timeH
        self.doseMG = doseMG
        self.ester = ester
        self.extras = extras
        self.updatedAt = updatedAt
    }
}

public struct LabResult: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var timeH: Double
    public var concValue: Double
    public var unit: String
    public var assay: String?
    public var updatedAt: Double?

    public init(
        id: String = UUID().uuidString.lowercased(),
        timeH: Double,
        concValue: Double,
        unit: String,
        assay: String? = nil,
        updatedAt: Double? = nil
    ) {
        self.id = id
        self.timeH = timeH
        self.concValue = concValue
        self.unit = unit
        self.assay = assay
        self.updatedAt = updatedAt
    }
}

public struct CurveSample: Equatable, Sendable {
    public let timeH: Double
    public let e2: Double
    public let cpa: Double
    public let testosterone: Double

    public init(timeH: Double, e2: Double, cpa: Double, testosterone: Double) {
        self.timeH = timeH
        self.e2 = e2
        self.cpa = cpa
        self.testosterone = testosterone
    }
}

public struct Simulation: Sendable {
    public let points: [CurveSample]
    public let auc: Double
    let nowH: Double
    let throughH: Double?
    let birthYear: Int?
    let parameters: PKParameters

    public func value(at timeH: Double) -> CurveSample? {
        guard timeH.isFinite, let first = points.first, let last = points.last else { return nil }
        if timeH <= first.timeH { return first }
        if timeH >= last.timeH { return last }

        var left = 0
        var right = points.count - 1
        while right - left > 1 {
            let middle = (left + right) / 2
            if points[middle].timeH < timeH {
                left = middle
            } else {
                right = middle
            }
        }

        let start = points[left]
        let end = points[right]
        if timeH == end.timeH { return end }
        let fraction = (timeH - start.timeH) / (end.timeH - start.timeH)
        return CurveSample(
            timeH: timeH,
            e2: start.e2 + (end.e2 - start.e2) * fraction,
            cpa: start.cpa + (end.cpa - start.cpa) * fraction,
            testosterone: start.testosterone + (end.testosterone - start.testosterone) * fraction
        )
    }
}

public enum HRTEngine {}
