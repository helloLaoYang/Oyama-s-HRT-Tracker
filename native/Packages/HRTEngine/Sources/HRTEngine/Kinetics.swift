import Foundation

/// Overrides use the same keys and limits as the Web PK configuration.
public struct PKParameters: Equatable, Sendable {
    public static let defaults: [String: Double] = [
        "e2_kClear": 0.41, "e2_kClearInj": 0.041,
        "e2_ff_EB": 0.1092, "e2_ff_EV": 0.0623, "e2_ff_EC": 0.1173, "e2_ff_EN": 0.12, "e2_ff_EU": 0.04,
        "e2_oral_bio": 0.03, "e2_sl_quick": 0.01, "e2_sl_casual": 0.04, "e2_sl_standard": 0.11, "e2_sl_strict": 0.18,
        "e2_gel_arm": 0.05, "e2_gel_thigh": 0.05, "e2_gel_scrotal": 0.25,
        "t_kClear": 0.5, "t_kClearInj": 0.035, "t_ff_TC": 0.043, "t_ff_TE": 0.043, "t_ff_TU": 0.043,
        "t_gel_arm": 0.1, "t_gel_thigh": 0.1, "t_gel_scrotal": 0.5
    ]
    private var values = Self.defaults

    public init(overrides: [String: Double] = [:]) {
        for (key, value) in overrides where value.isFinite {
            guard let range = Self.range(for: key) else { continue }
            values[key] = min(range.upperBound, max(range.lowerBound, value))
        }
    }

    public static func range(for key: String) -> ClosedRange<Double>? {
        guard defaults[key] != nil else { return nil }
        switch key {
        case "e2_kClear", "t_kClear": return 0.001...5
        case "e2_kClearInj", "t_kClearInj": return 0.001...1
        default: return 0...1
        }
    }

    /// Web settings treat the old testosterone formation fractions as unset.
    public static func normalizedOverrides(_ input: [String: Double]) -> [String: Double] {
        let formerDefaultKeys: Set<String> = ["t_ff_TC", "t_ff_TE", "t_ff_TU"]
        let parameters = Self(overrides: input.filter { !(formerDefaultKeys.contains($0.key) && $0.value == 0.025) })
        return parameters.values.filter { defaults[$0.key] != $0.value }
    }

    fileprivate subscript(_ key: String) -> Double { values[key] ?? 0 }

    var e2Clearance: Double {
        get { self["e2_kClear"] }
        set { values["e2_kClear"] = newValue }
    }

    var e2InjectionClearance: Double {
        get { self["e2_kClearInj"] }
        set { values["e2_kClearInj"] = newValue }
    }
}

enum Hormone: Int {
    case e2, testosterone, cpa

    init?(ester: String) {
        switch ester {
        case "E2", "EB", "EV", "EC", "EN", "EU": self = .e2
        case "T", "TC", "TE", "TU": self = .testosterone
        case "CPA": self = .cpa
        default: return nil
        }
    }
}

// TS: src/domain/shared/math.ts
enum KineticMath {
    static func firstDifference(_ x: Double, _ y: Double, _ elapsed: Double) -> Double {
        let z = (abs(y - x) * elapsed) / 2
        if z > 1 { return (exp(-x * elapsed) - exp(-y * elapsed)) / (x - y) }
        let sinhc = z == 0 ? 1 : sinh(z) / z
        return -elapsed * exp((-(x + y) / 2) * elapsed) * sinhc
    }

    static func secondDifference(_ first: Double, _ second: Double, _ third: Double, _ elapsed: Double) -> Double {
        var (a, b, c) = (first, second, third)
        if a > b { swap(&a, &b) }
        if b > c { swap(&b, &c) }
        if a > b { swap(&a, &b) }
        if (c - a) * elapsed >= 0.5 {
            return (firstDifference(b, c, elapsed) - firstDifference(a, b, elapsed)) / (c - a)
        }
        let mean = (a + b + c) / 3
        let ua = (mean - a) * elapsed
        let ub = (mean - b) * elapsed
        let uc = (mean - c) * elapsed
        var h1 = 1.0
        var h2 = 1.0
        var h3 = 1.0
        var factorial = 2.0
        var sum = 0.5
        for index in 1..<20 {
            h1 *= ua
            h2 = h1 + ub * h2
            h3 = h2 + uc * h3
            factorial *= Double(index + 2)
            sum += h3 / factorial
        }
        return elapsed * elapsed * exp(-mean * elapsed) * sum
    }

    static func amount(_ elapsed: Double, _ dose: Double, _ fraction: Double, _ first: Double, _ second: Double, _ clear: Double) -> Double {
        guard first > 0, dose > 0 else { return 0 }
        if second > 0 {
            return dose * fraction * first * second * secondDifference(first, second, clear, elapsed)
        }
        return -dose * fraction * first * firstDifference(first, clear, elapsed)
    }
}

// TS: src/domain/shared/amounts.ts and src/domain/shared/eventModel.ts
struct KineticModel {
    enum Kernel {
        case single(absorption: Double, hydrolysis: Double, fraction: Double)
        case depot(share: Double, fast: Double, slow: Double, hydrolysis: Double, fraction: Double)
        case sublingual(share: Double, fast: Double, slow: Double, fastHydrolysis: Double, slowHydrolysis: Double, fastFraction: Double, slowFraction: Double, fastClearance: Double?)
        case wear(absorption: Double, fraction: Double, release: Double, hours: Double)
        case cpa

        func scalingAbsorption(by multiplier: Double) -> Self {
            switch self {
            case let .single(absorption, hydrolysis, fraction):
                .single(absorption: absorption * multiplier, hydrolysis: hydrolysis, fraction: fraction)
            case let .depot(share, fast, slow, hydrolysis, fraction):
                .depot(share: share, fast: fast * multiplier, slow: slow * multiplier, hydrolysis: hydrolysis, fraction: fraction)
            case let .sublingual(share, fast, slow, fastHydrolysis, slowHydrolysis, fastFraction, slowFraction, fastClearance):
                .sublingual(
                    share: share, fast: fast * multiplier, slow: slow * multiplier, fastHydrolysis: fastHydrolysis,
                    slowHydrolysis: slowHydrolysis, fastFraction: fastFraction, slowFraction: slowFraction, fastClearance: fastClearance
                )
            case let .wear(absorption, fraction, release, hours):
                .wear(absorption: absorption * multiplier, fraction: fraction, release: release, hours: hours)
            case .cpa: self
            }
        }
    }

    let dose: DoseEvent
    let hormone: Hormone
    let clearance: Double
    let kernel: Kernel
    let lifetime: Double

    static let cpaBeta = log(2.0) / 43.9
    private static let cpaSlowWeight = (14 / (0.0035 * 60) - 5.2786 / 0.25) * cpaBeta

    var deliversConcentration: Bool {
        switch kernel {
        case let .wear(_, fraction, release, _): return release > 0 || (dose.doseMG > 0 && fraction > 0)
        case let .single(absorption, _, fraction): return dose.doseMG > 0 && absorption > 0 && fraction > 0
        case let .depot(_, fast, slow, _, fraction): return dose.doseMG > 0 && (fast > 0 || slow > 0) && fraction > 0
        case let .sublingual(share, _, _, _, _, fastFraction, slowFraction, _):
            return dose.doseMG > 0 && (share * fastFraction > 0 || (1 - share) * slowFraction > 0)
        case .cpa: return dose.doseMG > 0
        }
    }

    init(dose: DoseEvent, hormone: Hormone, clearance: Double, kernel: Kernel, wear: Double) {
        self.dose = dose
        self.hormone = hormone
        self.clearance = clearance
        self.kernel = kernel

        if dose.route == .patchApply || dose.route == .pellet {
            lifetime = wear == .greatestFiniteMagnitude ? .infinity : wear + (clearance > 0 ? ceil(13.816 / clearance) : 10_000)
            return
        }

        let rates: [Double]
        switch kernel {
        case let .single(absorption, hydrolysis, _):
            rates = [absorption, hydrolysis, clearance]
        case let .depot(_, fast, slow, hydrolysis, _):
            rates = [fast, slow, hydrolysis, clearance]
        case let .sublingual(_, fast, slow, fastHydrolysis, slowHydrolysis, _, _, fastClearance):
            rates = [fast, slow, fastHydrolysis, slowHydrolysis, clearance, fastClearance ?? 0]
        case let .wear(absorption, _, _, _):
            rates = [absorption, clearance]
        case .cpa:
            rates = [0.5, clearance]
        }
        lifetime = rates.filter { $0 > 0 }.min().map { ceil(13.816 / $0) } ?? .infinity
    }

    func amount(at timeH: Double) -> Double {
        let elapsed = timeH - dose.timeH
        let amount = dose.doseMG
        switch kernel {
        case let .single(absorption, hydrolysis, fraction):
            return KineticMath.amount(elapsed, amount, fraction, absorption, hydrolysis, clearance)
        case let .depot(share, fast, slow, hydrolysis, fraction):
            return KineticMath.amount(elapsed, amount * share, fraction, fast, hydrolysis, clearance)
                + KineticMath.amount(elapsed, amount * (1 - share), fraction, slow, hydrolysis, clearance)
        case let .sublingual(share, fast, slow, fastHydrolysis, slowHydrolysis, fastFraction, slowFraction, fastClearance):
            return KineticMath.amount(elapsed, amount * share, fastFraction, fast, fastHydrolysis, fastClearance ?? clearance)
                + KineticMath.amount(elapsed, amount * (1 - share), slowFraction, slow, slowHydrolysis, clearance)
        case let .wear(absorption, fraction, release, hours):
            let delivery = min(elapsed, hours)
            let supplied = release > 0
                ? (release / clearance) * (1 - exp(-clearance * delivery))
                : KineticMath.amount(delivery, amount, fraction, absorption, 0, clearance)
            return elapsed <= hours ? supplied : supplied * exp(-clearance * (elapsed - hours))
        case .cpa:
            return KineticMath.amount(elapsed, amount, 0.88 * 5.2786, 0.5, 0, 0.25)
                + KineticMath.amount(elapsed, amount, 0.88 * Self.cpaSlowWeight, 0.5, 0, Self.cpaBeta)
        }
    }
}

// TS: src/domain/constants.ts and the route modules under src/domain/transfem and transmasc.
enum RouteParameters {
    private static let depotE2: [String: (Double, Double, Double, Double, Double)] = [
        "E2": (1, 0.5, 0, 0, 272.38),
        "EB": (0.9, 0.144, 0.114, 0.09, 376.5),
        "EV": (0.4, 0.0216, 0.0138, 0.07, 356.5),
        "EC": (0.229164549, 0.005035046, 0.004510574, 0.045, 396.58),
        "EN": (0.05, 0.001, 0.005, 0.015, 384.56),
        "EU": (0.08, 0.006, 0.0022, 0.012, 440.66)
    ]
    private static let depotT: [String: (Double, Double, Double, Double, Double)] = [
        "T": (0, 0, 0, 0, 288.42),
        "TC": (0.35, 0.025, 0.005, 0.2, 412.6),
        "TE": (0.4, 0.035, 0.008, 0.2, 400.59),
        "TU": (0, log(2.0) / (50 * 24), log(2.0) / (50 * 24), 0.036, 456.7)
    ]
    private static let noDelivery = KineticModel.Kernel.single(absorption: 0, hydrolysis: 0, fraction: 0)
    private static let sites = ["arm", "thigh", "scrotal"]
    private static let estronePool = log(2.0) / 14.36
    static let sublingualTiers = ["quick", "casual", "standard", "strict"]

    static func model(
        _ event: DoseEvent, hormone: Hormone, weightFactor: Double, birthYear: Int?, parameters: PKParameters, wear: Double,
        absorptionMultiplier: Double = 1
    ) -> KineticModel {
        let clearance: Double
        let kernel: KineticModel.Kernel
        switch hormone {
        case .cpa:
            clearance = event.route == .oral ? KineticModel.cpaBeta : parameters.e2Clearance
            kernel = event.route == .oral ? .cpa : noDelivery
        case .e2:
            let base = event.route == .injection ? parameters.e2InjectionClearance : parameters.e2Clearance
            clearance = base * ageFactor(birthYear, event.timeH, slope: log(1 / 0.75) / 52) * weightFactor
            kernel = estradiol(event, parameters: parameters, clearance: clearance, wear: wear)
        case .testosterone:
            let isDepotInjection = event.route == .injection || event.route == .sc
            let base = parameters[isDepotInjection ? "t_kClearInj" : "t_kClear"]
            clearance = base * ageFactor(birthYear, event.timeH, slope: log(1821.0 / 1390) / 40) * weightFactor
            kernel = testosterone(event, parameters: parameters, wear: wear)
        }
        let personalKernel = hormone == .e2 && absorptionMultiplier != 1
            ? kernel.scalingAbsorption(by: absorptionMultiplier) : kernel
        return KineticModel(dose: event, hormone: hormone, clearance: clearance, kernel: personalKernel, wear: wear)
    }

    private static func estradiol(
        _ event: DoseEvent, parameters: PKParameters, clearance: Double, wear: Double
    ) -> KineticModel.Kernel {
        guard let (share, fast, slow, hydrolysis, mass) = depotE2[event.ester] else { return noDelivery }
        let equivalent = 272.38 / mass
        let oralAbsorption = event.ester == "EV" ? 0.05 : 0.32
        let oralHydrolysis = event.ester == "EV" ? 0 : estronePool
        let oralFraction = parameters["e2_oral_bio"] * equivalent
        switch event.route {
        case .injection:
            let fraction = event.ester == "E2" ? 1 : parameters["e2_ff_\(event.ester)"] * equivalent
            return .depot(share: share, fast: fast, slow: slow, hydrolysis: hydrolysis, fraction: fraction)
        case .oral:
            return .single(absorption: oralAbsorption, hydrolysis: oralHydrolysis, fraction: oralFraction)
        case .sublingual:
            let theta: Double
            if let custom = event.extras["sublingualTheta"], custom.isFinite {
                theta = min(1, max(0, custom))
            } else {
                let tier = sublingualTiers[index(event.extras["sublingualTier"], count: sublingualTiers.count, fallback: 2)]
                theta = parameters["e2_sl_\(tier)"]
            }
            return .sublingual(
                share: theta, fast: 1.8, slow: oralAbsorption, fastHydrolysis: hydrolysis, slowHydrolysis: oralHydrolysis,
                fastFraction: equivalent, slowFraction: oralFraction, fastClearance: hydrolysis == 0 ? clearance * (1.2 / 0.41) : nil
            )
        case .gel:
            let site = sites[index(event.extras["gelSite"], count: sites.count, fallback: 0)]
            return .single(absorption: 0.0193, hydrolysis: 0, fraction: parameters["e2_gel_\(site)"] * equivalent)
        case .patchApply:
            return patch(event, absorption: 0.0075, equivalent: equivalent, wear: wear)
        default:
            return noDelivery
        }
    }

    private static func testosterone(_ event: DoseEvent, parameters: PKParameters, wear: Double) -> KineticModel.Kernel {
        guard let (share, fast, slow, hydrolysis, mass) = depotT[event.ester] else { return noDelivery }
        let equivalent = 288.42 / mass
        switch event.route {
        case .injection, .sc:
            guard event.ester != "T" else { return noDelivery }
            let rateFactor = event.route == .sc ? 0.5 : 1.0
            return .depot(
                share: share, fast: fast * rateFactor, slow: slow * rateFactor,
                hydrolysis: hydrolysis, fraction: parameters["t_ff_\(event.ester)"] * equivalent
            )
        case .oral:
            return event.ester == "TU" ? .single(absorption: 0.4, hydrolysis: 0, fraction: 0.05 * equivalent) : noDelivery
        case .nasal:
            return event.ester == "T" ? .single(absorption: 2, hydrolysis: 0, fraction: 0.08 * equivalent) : noDelivery
        case .gel:
            let site = sites[index(event.extras["gelSite"], count: sites.count, fallback: 0)]
            return .single(absorption: 0.05, hydrolysis: 0, fraction: parameters["t_gel_\(site)"] * equivalent)
        case .patchApply, .pellet:
            return patch(event, absorption: event.route == .pellet ? 0.001 : 0.03, equivalent: equivalent, wear: wear)
        default:
            return noDelivery
        }
    }

    private static func patch(_ event: DoseEvent, absorption: Double, equivalent: Double, wear: Double) -> KineticModel.Kernel {
        let rate = event.extras["releaseRateUGPerDay"] ?? 0
        let release = rate.isFinite && rate > 0 ? (rate / 24 / 1_000) * equivalent : 0
        return .wear(absorption: release > 0 ? 0 : absorption, fraction: equivalent, release: release, hours: wear)
    }

    private static func index(_ value: Double?, count: Int, fallback: Int) -> Int {
        guard let value, value.isFinite else { return fallback }
        return Int(min(Double(count - 1), max(0, value.rounded())))
    }

    // TS: src/domain/features/popPK.ts
    private static func ageFactor(_ birthYear: Int?, _ timeH: Double, slope: Double) -> Double {
        guard let birthYear else { return 1 }
        let age = 1970 + timeH / (365.2425 * 24) - (Double(birthYear) + 0.5)
        if age >= 19 { return exp(-slope * (min(75, age) - 54)) }
        let maturation: Double
        if age < 10 { maturation = 0.7 }
        else if age < 12 { maturation = 0.7 + 0.08 * (age - 10) / 2 }
        else if age < 15 { maturation = 0.78 + 0.12 * (age - 12) / 3 }
        else { maturation = 0.9 + 0.10 * (age - 15) / 4 }
        return exp(-slope * (19 - 54)) * maturation
    }
}

public extension HRTEngine {
    // TS: src/domain/transfem/e2-sublingual.ts
    static func sublingualTheta(fromHoldMinutes minutes: Double, parameters: PKParameters = .init()) -> Double {
        guard minutes > 0 else { return 0 }
        let points = holdPoints(parameters)
        let hold = max(1, minutes)
        if hold >= points[3].hold { return thetaPastTiers(hold, last: points[3]) }
        let index = (0..<3).first { hold <= points[$0 + 1].hold } ?? 0
        let start = points[index]
        let end = points[index + 1]
        let fraction = (hold - start.hold) / (end.hold - start.hold)
        return min(1, max(0, start.theta + (end.theta - start.theta) * fraction))
    }

    static func sublingualHoldMinutes(fromTheta theta: Double, parameters: PKParameters = .init()) -> Double {
        let points = holdPoints(parameters)
        let last = points[3]
        if theta > last.theta {
            if theta >= thetaPastTiers(60, last: last) { return 60 }
            var low = last.hold
            var high = 60.0
            for _ in 0..<60 {
                let mid = (low + high) / 2
                if thetaPastTiers(mid, last: last) < theta { low = mid } else { high = mid }
            }
            return (((low + high) / 2) * 100).rounded() / 100
        }
        let fit = (0..<3).first {
            let a = points[$0].theta
            let b = points[$0 + 1].theta
            return min(a, b) <= theta && theta <= max(a, b)
        }
        let index = fit ?? 0
        let start = points[index]
        let end = points[index + 1]
        let delta = end.theta - start.theta
        let fraction = (theta - start.theta) / (delta != 0 ? delta : 1)
        let minutes = start.hold + (end.hold - start.hold) * fraction
        return ((fit != nil ? minutes : max(1, minutes)) * 100).rounded() / 100
    }

    private static func holdPoints(_ parameters: PKParameters) -> [(hold: Double, theta: Double)] {
        zip([2.0, 5, 10, 15], RouteParameters.sublingualTiers).map { ($0, parameters["e2_sl_\($1)"]) }
    }

    private static func thetaPastTiers(_ minutes: Double, last: (hold: Double, theta: Double)) -> Double {
        func thetaModel(_ minutes: Double) -> Double {
            let dissolution = log(2.0) / (5.0 / 60)
            let out = 1.8 + 1.8
            let elapsed = minutes / 60
            return (1.8 * dissolution) / (dissolution - out) *
                ((1 - exp(-out * elapsed)) / out - (1 - exp(-dissolution * elapsed)) / dissolution)
        }
        return min(1, last.theta * thetaModel(minutes) / thetaModel(last.hold))
    }
}
