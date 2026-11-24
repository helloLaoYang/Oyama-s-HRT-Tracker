import Foundation

public enum CalibrationMethod: String, Codable, CaseIterable, Sendable {
    case off, mipd, ekf
    case ouKalman = "ou_kalman"
}

public enum CalibrationHistoryMode: String, Codable, CaseIterable, Sendable {
    case retrospective, forward
}

public struct Calibration: Sendable {
    public let method: CalibrationMethod
    public let scale: Double
    public let kMul: Double
    public let fitErrPct: Double?
    public let count: Int
    private let multiplier: @Sendable (Double) -> Double

    public var halfLifeDeltaPct: Double { (1 / kMul - 1) * 100 }

    public func factor(at timeH: Double) -> Double { multiplier(timeH) }

    fileprivate init(
        method: CalibrationMethod, scale: Double, kMul: Double, fitErrPct: Double?, count: Int,
        multiplier: @escaping @Sendable (Double) -> Double
    ) {
        self.method = method
        self.scale = scale
        self.kMul = kMul
        self.fitErrPct = fitErrPct
        self.count = count
        self.multiplier = multiplier
    }
}

public extension HRTEngine {
    // TS: src/domain/calibration/index.ts
    static func calibrate(
        simulation: Simulation?, events: [DoseEvent], weight: Double, labs: [LabResult], method: CalibrationMethod,
        history: CalibrationHistoryMode, birthYear: Int? = nil, projectedEvents: [DoseEvent] = []
    ) -> Calibration {
        let points = labs.compactMap { lab -> FitPoint? in
            let observed: Double
            switch lab.unit.lowercased() {
            case "pg/ml": observed = lab.concValue
            case "pmol/l": observed = lab.concValue / 3.671
            default: return nil
            }
            guard observed.isFinite, observed > 0, let predicted = simulation?.value(at: lab.timeH)?.e2,
                  predicted.isFinite, predicted >= 1 else { return nil }
            return FitPoint(timeH: lab.timeH, observed: observed, predicted: predicted)
        }.sorted { $0.timeH < $1.timeH }

        guard let simulation, !points.isEmpty, method != .off else {
            return Calibration(method: method, scale: 1, kMul: 1, fitErrPct: nil, count: points.count, multiplier: { _ in 1 })
        }
        if method == .ouKalman { return FitMath.ouKalman(points, history: history) }

        let times = points.map(\.timeH)
        let observations = points.map { log($0.observed) }
        let useClearance = FitMath.clearanceIdentifiable(times[...])
        let field = ClearanceField(
            simulation: simulation, times: times, events: events, projectedEvents: projectedEvents, weight: weight,
            birthYear: birthYear ?? simulation.birthYear, useClearance: useClearance
        )

        func fit(count: Int) -> FitParameters {
            let allowClearance = useClearance && FitMath.clearanceIdentifiable(times.prefix(count))
            return method == .ekf
                ? FitMath.ekf(field, observations, count: count, allowClearance: allowClearance)
                : FitMath.mipd(field, observations, count: count, allowClearance: allowClearance)
        }

        let fitted: FitParameters
        let factor: @Sendable (Double) -> Double
        if history == .forward {
            let segments = (1...points.count).map { fit(count: $0) }
            fitted = segments[segments.count - 1]
            factor = { time in
                guard let index = times.lastIndex(where: { $0 <= time }) else { return 1 }
                return field.factor(segments[index], at: time)
            }
        } else {
            fitted = fit(count: points.count)
            let parameters = fitted
            factor = { time in field.factor(parameters, at: time) }
        }
        return Calibration(
            method: method, scale: FitMath.clampFactor(exp(fitted.amplitude)), kMul: exp(fitted.clearance),
            fitErrPct: FitMath.error(points, factor: factor), count: points.count, multiplier: factor
        )
    }
}

private struct FitPoint {
    let timeH: Double
    let observed: Double
    let predicted: Double
}

private struct FitParameters: Sendable {
    let amplitude: Double
    let clearance: Double
}

// TS: src/domain/calibration/estimators.ts
private struct ClearanceField: Sendable {
    let logK: [Double]
    let simulations: [Simulation?]
    let logConcentrations: [[Double]]
    let baseline: Simulation

    init(
        simulation: Simulation, times: [Double], events: [DoseEvent], projectedEvents: [DoseEvent],
        weight: Double, birthYear: Int?, useClearance: Bool
    ) {
        baseline = simulation
        if useClearance {
            let minK = FitMath.minLogK
            let span = FitMath.maxLogK - minK
            let knots = (0...20).map { minK + span * (Double($0) / 20) }
            logK = knots
            simulations = knots.map { knot in
                let multiplier = exp(knot)
                if abs(multiplier - 1) < 0.001 { return simulation }
                var parameters = simulation.parameters
                parameters.e2Clearance *= multiplier
                parameters.e2InjectionClearance *= multiplier
                return HRTEngine.simulate(
                    events: events, weight: weight, nowH: simulation.nowH, birthYear: birthYear,
                    throughH: simulation.throughH, parameters: parameters, projectedEvents: projectedEvents
                )
            }
        } else {
            // With fewer than three separated clusters, every estimator holds k at zero.
            logK = [0]
            simulations = [simulation]
        }
        logConcentrations = simulations.map { candidate in
            times.map { Self.knot(candidate, baseline: simulation, at: $0) }
        }
    }

    private static func knot(_ simulation: Simulation?, baseline: Simulation, at time: Double) -> Double {
        if let value = simulation?.value(at: time)?.e2, value.isFinite, value >= 1e-6 { return log(value) }
        return log(max(1e-6, baseline.value(at: time)?.e2 ?? 0))
    }

    private func upperIndex(_ k: Double) -> Int {
        var upper = 1
        while upper < logK.count - 1 && logK[upper] < k { upper += 1 }
        return upper
    }

    func logConcentration(_ index: Int, _ k: Double) -> Double {
        if k <= logK[0] { return logConcentrations[0][index] }
        let last = logK.count - 1
        if k >= logK[last] { return logConcentrations[last][index] }
        let upper = upperIndex(k)
        let weight = (k - logK[upper - 1]) / (logK[upper] - logK[upper - 1])
        return logConcentrations[upper - 1][index] * (1 - weight) + logConcentrations[upper][index] * weight
    }

    func slope(_ index: Int, _ k: Double) -> Double {
        if k < logK[0] || k > logK[logK.count - 1] || logK.count == 1 { return 0 }
        let upper = upperIndex(k)
        return (logConcentrations[upper][index] - logConcentrations[upper - 1][index]) / (logK[upper] - logK[upper - 1])
    }

    func factor(_ parameters: FitParameters, at time: Double) -> Double {
        let scale = exp(parameters.amplitude)
        guard let unadjusted = baseline.value(at: time)?.e2, unadjusted >= 1, abs(parameters.clearance) >= 1e-9 else {
            return FitMath.clampFactor(scale)
        }
        let k = FitMath.clampLogK(parameters.clearance)
        let upper = upperIndex(k)
        let weight = (k - logK[upper - 1]) / (logK[upper] - logK[upper - 1])
        let logValue: Double
        if weight <= 0 { logValue = Self.knot(simulations[upper - 1], baseline: baseline, at: time) }
        else if weight >= 1 { logValue = Self.knot(simulations[upper], baseline: baseline, at: time) }
        else {
            let low = Self.knot(simulations[upper - 1], baseline: baseline, at: time)
            let high = Self.knot(simulations[upper], baseline: baseline, at: time)
            logValue = low * (1 - weight) + high * weight
        }
        return FitMath.clampFactor((scale * exp(logValue)) / unadjusted)
    }
}

private enum FitMath {
    static let minLogK = log(0.5)
    static let maxLogK = log(2.0)
    private static let observationSD = 0.13
    private static let amplitudePriorSD = 0.5
    private static let clearancePriorSD = 0.35
    private static let minimumClusters = 3

    static func clampLogK(_ k: Double) -> Double { max(minLogK, min(maxLogK, k)) }
    static func clampFactor(_ level: Double) -> Double { max(0.01, min(100, level)) }

    static func clearanceIdentifiable(_ hours: ArraySlice<Double>) -> Bool {
        var anchor = -Double.infinity
        var clusters = 0
        for hour in hours where hour - anchor > 6 {
            anchor = hour
            clusters += 1
        }
        return clusters >= minimumClusters
    }

    static func error(_ points: [FitPoint], factor: (Double) -> Double) -> Double? {
        guard points.count >= 2 else { return nil }
        let squared = points.reduce(0.0) { sum, point in
            let residual = log(point.observed) - log(point.predicted * factor(point.timeH))
            return sum + residual * residual
        }
        return (exp(sqrt(squared / Double(points.count))) - 1) * 100
    }

    static func ekf(
        _ field: ClearanceField, _ observed: [Double], count: Int, allowClearance: Bool
    ) -> FitParameters {
        var amplitude = 0.0
        var clearance = 0.0
        var p00 = amplitudePriorSD * amplitudePriorSD
        var p11 = allowClearance ? clearancePriorSD * clearancePriorSD : 1e-8
        var p01 = 0.0
        var p10 = 0.0
        let variance = observationSD * observationSD
        let q00 = pow(log(1.01), 2)
        let q11 = allowClearance ? pow(log(1.005), 2) : 0
        for index in 0..<count {
            p00 += q00
            p11 += q11
            let slope = allowClearance ? field.slope(index, clearance) : 0
            let innovation = observed[index] - (amplitude + field.logConcentration(index, clearance))
            let projection0 = p00 + p01 * slope
            let projection1 = p10 + p11 * slope
            let totalVariance = projection0 + slope * projection1 + variance
            let gain0 = projection0 / totalVariance
            let gain1 = projection1 / totalVariance
            amplitude += gain0 * innovation
            clearance = clampLogK(clearance + gain1 * innovation)
            let a00 = 1 - gain0
            let a01 = -gain0 * slope
            let a10 = -gain1
            let a11 = 1 - gain1 * slope
            let next00 = a00 * p00 + a01 * p10
            let next01 = a00 * p01 + a01 * p11
            let next10 = a10 * p00 + a11 * p10
            let next11 = a10 * p01 + a11 * p11
            (p00, p01, p10, p11) = (next00, next01, next10, next11)
        }
        return FitParameters(amplitude: amplitude, clearance: clearance)
    }

    static func mipd(
        _ field: ClearanceField, _ observed: [Double], count: Int, allowClearance: Bool
    ) -> FitParameters {
        let sigma = observationSD
        let nu = 4.0
        let robust = count >= minimumClusters
        let amplitudePrecision = 1 / (amplitudePriorSD * amplitudePriorSD)
        let clearancePrecision = 1 / (clearancePriorSD * clearancePriorSD)

        func objective(_ amplitude: Double, _ clearance: Double) -> Double {
            var result = 0.5 * amplitudePrecision * amplitude * amplitude
                + (allowClearance ? 0.5 * clearancePrecision * clearance * clearance : 0)
            for index in 0..<count {
                let scaled = (observed[index] - (amplitude + field.logConcentration(index, clearance))) / sigma
                result += robust ? 0.5 * (nu + 1) * log(1 + (scaled * scaled) / nu) : 0.5 * scaled * scaled
            }
            return result
        }

        func solve(_ initialAmplitude: Double, _ initialClearance: Double) -> (fit: FitParameters, error: Double) {
            var amplitude = initialAmplitude
            var clearance = allowClearance ? initialClearance : 0
            for _ in 0..<50 {
                var h00 = amplitudePrecision
                var h01 = 0.0
                var h11 = allowClearance ? clearancePrecision : 1
                var g0 = -amplitudePrecision * amplitude
                var g1 = allowClearance ? -clearancePrecision * clearance : 0
                for index in 0..<count {
                    let residual = observed[index] - (amplitude + field.logConcentration(index, clearance))
                    let scaled = residual / sigma
                    let weight = robust ? (nu + 1) / (nu + scaled * scaled) / (sigma * sigma) : 1 / (sigma * sigma)
                    let derivative = allowClearance ? field.slope(index, clearance) : 0
                    h00 += weight
                    h01 += weight * derivative
                    h11 += weight * derivative * derivative
                    g0 += weight * residual
                    g1 += weight * derivative * residual
                }
                let determinant = h00 * h11 - h01 * h01
                if abs(determinant) < 1e-12 { break }
                let d0 = (h11 * g0 - h01 * g1) / determinant
                let d1 = allowClearance ? (h00 * g1 - h01 * g0) / determinant : 0
                let original = objective(amplitude, clearance)
                var step = 1.0
                while step > 1e-4 && objective(amplitude + step * d0, clampLogK(clearance + step * d1)) > original + 1e-12 {
                    step /= 2
                }
                let nextAmplitude = amplitude + step * d0
                let nextClearance = clampLogK(clearance + step * d1)
                let moved = abs(nextAmplitude - amplitude) + abs(nextClearance - clearance)
                (amplitude, clearance) = (nextAmplitude, nextClearance)
                if moved < 1e-7 { break }
            }
            return (FitParameters(amplitude: amplitude, clearance: clearance), objective(amplitude, clearance))
        }

        var best = solve(0, 0)
        let starts = allowClearance ? stride(from: 0, to: field.logK.count, by: 5).map { field.logK[$0] } : [0]
        for start in starts {
            let residuals = (0..<count).map { observed[$0] - field.logConcentration($0, start) }.sorted()
            let candidate = solve(residuals[count / 2], start)
            if candidate.error < best.error { best = candidate }
        }
        return best.fit
    }

    static func ouKalman(_ points: [FitPoint], history: CalibrationHistoryMode) -> Calibration {
        let times = points.map(\.timeH)
        let observed = points.map { log($0.observed) - log($0.predicted) }
        let count = points.count
        let theta = 1.0 / 336
        let populationVariance = 0.25
        let measurementVariance = observationSD * observationSD
        var filtered = [Double](repeating: 0, count: count)
        var filteredVariance = filtered
        var predicted = filtered
        var predictedVariance = filtered
        for index in points.indices {
            if index == 0 {
                predictedVariance[index] = populationVariance
            } else {
                let phi = exp(-theta * (times[index] - times[index - 1]))
                predicted[index] = phi * filtered[index - 1]
                predictedVariance[index] = phi * phi * filteredVariance[index - 1] + populationVariance * (1 - phi * phi)
            }
            let gain = predictedVariance[index] / (predictedVariance[index] + measurementVariance)
            filtered[index] = predicted[index] + gain * (observed[index] - predicted[index])
            filteredVariance[index] = (1 - gain) * predictedVariance[index]
        }
        var smoothed = filtered
        for index in stride(from: count - 2, through: 0, by: -1) {
            let phi = exp(-theta * (times[index + 1] - times[index]))
            let correction = (filteredVariance[index] * phi) / predictedVariance[index + 1]
            smoothed[index] = filtered[index] + correction * (smoothed[index + 1] - predicted[index + 1])
        }
        let states = history == .forward ? filtered : smoothed
        let factor: @Sendable (Double) -> Double = { time in
            let estimate: Double
            if history == .forward {
                guard let index = times.lastIndex(where: { $0 <= time }) else { return 1 }
                estimate = exp(-theta * (time - times[index])) * states[index]
            } else if time <= times[0] {
                estimate = exp(-theta * (times[0] - time)) * states[0]
            } else if time >= times[count - 1] {
                estimate = exp(-theta * (time - times[count - 1])) * states[count - 1]
            } else {
                let index = times.lastIndex(where: { $0 <= time }) ?? 0
                let duration = times[index + 1] - times[index]
                let elapsed = time - times[index]
                let divisor = sinh(theta * duration)
                estimate = (sinh(theta * (duration - elapsed)) * states[index] + sinh(theta * elapsed) * states[index + 1])
                    / (divisor == 0 ? 1 : divisor)
            }
            return clampFactor(exp(estimate))
        }
        return Calibration(
            method: .ouKalman, scale: clampFactor(exp(states[count - 1])), kMul: 1,
            fitErrPct: error(points, factor: factor), count: count, multiplier: factor
        )
    }
}
