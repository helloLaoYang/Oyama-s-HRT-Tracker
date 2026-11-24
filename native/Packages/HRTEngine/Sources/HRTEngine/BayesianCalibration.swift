import Foundation

// TS: src/domain/calibration/bayes.ts
enum BayesianCalibration {
    static func fit(field: ClearanceField, points: [FitPoint], history: CalibrationHistoryMode) -> Calibration {
        let times = points.map(\.timeH)
        let observations = points.map { log($0.observed) }
        let sigmas = points.map { FitMath.labLogSD($0, simulation: field.baseline) }
        let full = BayesMixture(field: field, times: times[...], observations: observations, sigmas: sigmas)
        let prefixes = history == .forward ? times.indices.map { index in
            index == times.count - 1 ? full : BayesMixture(
                field: field, times: times.prefix(index + 1), observations: observations, sigmas: sigmas
            )
        } : []
        let mixtureAt: @Sendable (Double) -> BayesMixture? = { time in
            if history == .retrospective { return full }
            return times.lastIndex { $0 <= time }.map { prefixes[$0] }
        }
        let factorCache = BayesTimeCache { time in
            guard let mixture = mixtureAt(time) else { return 1 }
            return FitMath.clampFactor(exp(mixture.mean(field: field, time: time)))
        }
        let uncertaintyCache = BayesTimeCache { time in
            guard let mixture = mixtureAt(time) else { return 0 }
            return sqrt(mixture.moments(field: field, time: time, withShape: true).variance)
        }
        let factor: @Sendable (Double) -> Double = { factorCache.value(at: $0) }
        let last = times[times.count - 1]
        let amplitude = full.moments(field: field, time: last, withShape: false).mean
        let level = full.moments(field: field, time: last, withShape: true)
        let spread = 1.6448536269514722 * sqrt(level.variance)
        let interval = FitMath.clampFactor(exp(level.mean - spread))...FitMath.clampFactor(exp(level.mean + spread))
        let clearance = full.fits.reduce(0.0) { $0 + $1.weight * $1.fit.position.clearance }
        var drift = ["none": 0.0, "weeks": 0, "months": 0, "year": 0]
        for member in full.fits {
            drift[member.fit.hypothesis.family, default: 0] += member.weight
        }
        let discounted = points.indices.reduce(0) { count, index in
            let meanWeight = full.fits.reduce(0.0) { $0 + $1.weight * $1.fit.studentWeights[index] }
            return count + (meanWeight < 0.5 ? 1 : 0)
        }
        return Calibration(
            method: .bayes, scale: FitMath.clampFactor(exp(amplitude)), kMul: exp(FitMath.clampLogK(clearance)),
            fitErrPct: FitMath.error(points, factor: factor), count: points.count, latestInterval: interval,
            discounted: discounted, drift: drift, factorSD: { uncertaintyCache.value(at: $0) }, multiplier: factor
        )
    }
}

private struct BayesHypothesis: Sendable {
    let share: Double
    let memory: Double
    let prior: Double
    let family: String

    static let all: [Self] = {
        let noDrift = 1.0 / 3
        let perDrift = (1 - noDrift) / 6
        let memories = [(336.0, "weeks"), (90.0 * 24, "months"), (365.0 * 24, "year")]
        return [.init(share: 0, memory: .infinity, prior: noDrift, family: "none")]
            + [0.25, 0.5].flatMap { share in
                memories.map { .init(share: share, memory: $0.0, prior: perDrift, family: $0.1) }
            }
    }()
}

// Unit-variance Ornstein–Uhlenbeck process conditioned on the nearest anchors.
private enum DriftPrior {
    private static func oneMinusExp(_ value: Double) -> Double { -expm1(-value) }

    static func interpolate(_ time: Double, _ anchors: [Double], _ memory: Double) -> (weights: [(Int, Double)], variance: Double) {
        let last = anchors.count - 1
        if time <= anchors[0] {
            let gap = (anchors[0] - time) / memory
            return ([(0, exp(-gap))], oneMinusExp(2 * gap))
        }
        if time >= anchors[last] {
            let gap = (time - anchors[last]) / memory
            return ([(last, exp(-gap))], oneMinusExp(2 * gap))
        }
        var low = 0
        var high = last
        while high - low > 1 {
            let middle = (low + high) / 2
            if anchors[middle] <= time { low = middle } else { high = middle }
        }
        let elapsed = (time - anchors[low]) / memory
        let remaining = (anchors[high] - time) / memory
        let denominator = oneMinusExp(2 * (elapsed + remaining))
        guard denominator > 0 else { return ([(low, 1)], 0) }
        let from = oneMinusExp(2 * elapsed)
        let to = oneMinusExp(2 * remaining)
        return (
            [(low, exp(-elapsed) * to / denominator), (high, exp(-remaining) * from / denominator)],
            max(0, from * to / denominator)
        )
    }

    static func precision(_ anchors: [Double], memory: Double) -> (diagonal: [Double], off: [Double], logDetCovariance: Double) {
        var diagonal = Array(repeating: 0.0, count: anchors.count)
        var off = Array(repeating: 0.0, count: max(0, anchors.count - 1))
        guard !anchors.isEmpty else { return (diagonal, off, 0) }
        diagonal[0] = 1
        var logDetCovariance = 0.0
        for index in off.indices {
            let gap = (anchors[index + 1] - anchors[index]) / memory
            let correlation = exp(-gap)
            let complement = max(oneMinusExp(2 * gap), 1e-12)
            let inverse = 1 / complement
            diagonal[index] += correlation * correlation * inverse
            diagonal[index + 1] += inverse
            off[index] -= correlation * inverse
            logDetCovariance += log(complement)
        }
        return (diagonal, off, logDetCovariance)
    }
}

// The drift block is tridiagonal. A 1×1 or 2×2 Schur complement accounts for amplitude and clearance.
private struct BayesPrecision: Sendable {
    var diagonal: [Double]
    var off: [Double]
    var coupling: [[Double]]
    var border: [[Double]]

    func factor() -> BayesFactor? {
        var d = Array(repeating: 0.0, count: diagonal.count)
        var l = d
        var logDet = 0.0
        for index in d.indices {
            if index == 0 {
                d[0] = diagonal[0]
            } else {
                l[index] = off[index - 1] / d[index - 1]
                d[index] = diagonal[index] - l[index] * off[index - 1]
            }
            guard d[index].isFinite, d[index] > 0 else { return nil }
            logDet += log(d[index])
        }

        var couplingInverse = coupling
        for column in border.indices {
            let solution = BayesFactor.solveTridiagonal(d, l, coupling.map { $0[column] })
            for index in solution.indices { couplingInverse[index][column] = solution[index] }
        }
        var schur = border
        for row in border.indices {
            for column in border.indices {
                let reduction = coupling.indices.reduce(0.0) { $0 + coupling[$1][row] * couplingInverse[$1][column] }
                schur[row][column] -= reduction
            }
        }
        guard schur[0][0] > 0 else { return nil }
        let inverse: [[Double]]
        if border.count == 1 {
            logDet += log(schur[0][0])
            inverse = [[1 / schur[0][0]]]
        } else {
            let determinant = schur[0][0] * schur[1][1] - schur[0][1] * schur[1][0]
            guard determinant > 0 else { return nil }
            logDet += log(determinant)
            inverse = [
                [schur[1][1] / determinant, -schur[0][1] / determinant],
                [-schur[1][0] / determinant, schur[0][0] / determinant]
            ]
        }
        return BayesFactor(d: d, l: l, couplingInverse: couplingInverse, schurInverse: inverse, logDet: logDet)
    }
}

private struct BayesFactor: Sendable {
    let d: [Double]
    let l: [Double]
    let couplingInverse: [[Double]]
    let schurInverse: [[Double]]
    let logDet: Double

    static func solveTridiagonal(_ d: [Double], _ l: [Double], _ rhs: [Double]) -> [Double] {
        var x = rhs
        for index in x.indices.dropFirst() { x[index] -= l[index] * x[index - 1] }
        for index in x.indices { x[index] /= d[index] }
        for index in x.indices.dropLast().reversed() { x[index] -= l[index + 1] * x[index + 1] }
        return x
    }

    func solve(_ precision: BayesPrecision, drift: [Double], border: [Double]) -> (drift: [Double], border: [Double]) {
        let preliminary = Self.solveTridiagonal(d, l, drift)
        var rhs = border
        for column in rhs.indices {
            for index in preliminary.indices { rhs[column] -= precision.coupling[index][column] * preliminary[index] }
        }
        let solution = schurInverse.map { row in row.indices.reduce(0.0) { $0 + row[$1] * rhs[$1] } }
        let result = preliminary.indices.map { index in
            preliminary[index] - solution.indices.reduce(0.0) { $0 + couplingInverse[index][$1] * solution[$1] }
        }
        return (result, solution)
    }
}

private struct BayesPosition: Sendable {
    let amplitude: Double
    let clearance: Double
    let drift: [Double]
}

private struct BayesFit: Sendable {
    let hypothesis: BayesHypothesis
    let position: BayesPosition
    let anchors: [Double]
    let sdDrift: Double
    let allowClearance: Bool
    let precision: BayesPrecision
    let factor: BayesFactor
    let logEvidence: Double
    let studentWeights: [Double]

    private func clearanceShift(_ field: ClearanceField, at time: Double) -> Double {
        guard abs(position.clearance) >= 1e-9, let baseline = field.baseline.value(at: time)?.e2, baseline >= 1 else { return 0 }
        return field.logConcentration(at: time, clearance: position.clearance) - log(baseline)
    }

    func mean(field: ClearanceField, time: Double) -> Double {
        var mean = position.amplitude
        if !anchors.isEmpty {
            for (index, weight) in DriftPrior.interpolate(time, anchors, hypothesis.memory).weights {
                mean += weight * position.drift[index]
            }
        }
        return mean + clearanceShift(field, at: time)
    }

    func moments(field: ClearanceField, time: Double, withShape: Bool) -> (mean: Double, variance: Double) {
        var mean = position.amplitude
        var drift = Array(repeating: 0.0, count: anchors.count)
        var conditionalVariance = 0.0
        if !anchors.isEmpty {
            let interpolation = DriftPrior.interpolate(time, anchors, hypothesis.memory)
            for (index, weight) in interpolation.weights {
                mean += weight * position.drift[index]
                drift[index] += weight
            }
            conditionalVariance = sdDrift * sdDrift * interpolation.variance
        }
        var border = allowClearance ? [1.0, 0] : [1.0]
        if withShape {
            mean += clearanceShift(field, at: time)
            if allowClearance, let baseline = field.baseline.value(at: time)?.e2, baseline >= 1 {
                border[1] = field.slope(at: time, clearance: position.clearance)
            }
        }
        let solved = factor.solve(precision, drift: drift, border: border)
        var variance = border.indices.reduce(0.0) { $0 + border[$1] * solved.border[$1] }
            + drift.indices.reduce(0.0) { $0 + drift[$1] * solved.drift[$1] }
        variance += conditionalVariance
        return (mean, max(0, variance))
    }
}

private struct BayesMixture: Sendable {
    let fits: [(fit: BayesFit, weight: Double)]

    init(field: ClearanceField, times: ArraySlice<Double>, observations: [Double], sigmas: [Double]) {
        let modes = BayesHypothesis.all.compactMap { hypothesis -> (fit: BayesFit, logPosterior: Double)? in
            let problem = BayesProblem(field: field, times: times, observations: observations, sigmas: sigmas, hypothesis: hypothesis)
            guard let fit = problem.fit() else { return nil }
            return (fit, log(hypothesis.prior) + fit.logEvidence)
        }
        guard let top = modes.map({ $0.logPosterior }).max() else { fits = []; return }
        let mass = modes.map { exp($0.logPosterior - top) }
        let total = mass.reduce(0, +)
        fits = zip(modes, mass).map { ($0.0.fit, $0.1 / total) }
    }

    func mean(field: ClearanceField, time: Double) -> Double {
        fits.reduce(0.0) { $0 + ($1.weight >= 1e-12 ? $1.weight * $1.fit.mean(field: field, time: time) : 0) }
    }

    func moments(field: ClearanceField, time: Double, withShape: Bool) -> (mean: Double, variance: Double) {
        var mean = 0.0
        var second = 0.0
        for member in fits where member.weight >= 1e-12 {
            let term = member.fit.moments(field: field, time: time, withShape: withShape)
            mean += member.weight * term.mean
            second += member.weight * (term.variance + term.mean * term.mean)
        }
        return (mean, max(0, second - mean * mean))
    }
}

private struct BayesProblem {
    let field: ClearanceField
    let count: Int
    let observations: [Double]
    let sigmas: [Double]
    let hypothesis: BayesHypothesis
    let allowClearance: Bool
    let robust: Bool
    let sdAmplitude: Double
    let sdDrift: Double
    let anchors: [Double]
    let labAnchor: [Int]
    let driftPrecision: (diagonal: [Double], off: [Double], logDetCovariance: Double)

    private let nu = FitMath.studentDegrees
    private let clearancePrecision = 1 / (FitMath.clearancePriorSD * FitMath.clearancePriorSD)
    private var driftScale: Double { anchors.isEmpty ? 0 : 1 / (sdDrift * sdDrift) }

    init(field: ClearanceField, times: ArraySlice<Double>, observations: [Double], sigmas: [Double], hypothesis: BayesHypothesis) {
        self.field = field
        count = times.count
        self.observations = observations
        self.sigmas = sigmas
        self.hypothesis = hypothesis
        allowClearance = FitMath.clearanceIdentifiable(times)
        robust = times.count >= FitMath.minimumClusters
        sdAmplitude = FitMath.amplitudePriorSD * sqrt(1 - hypothesis.share)
        sdDrift = FitMath.amplitudePriorSD * sqrt(hypothesis.share)

        var anchors: [Double] = []
        var mapping: [Int] = []
        if hypothesis.share > 0 {
            var first = -Double.infinity
            var members = 0
            var sum = 0.0
            for time in times {
                if time - first > FitMath.labClusterHours {
                    if members > 0 { anchors.append(sum / Double(members)) }
                    first = time
                    members = 0
                    sum = 0
                }
                sum += time
                members += 1
                mapping.append(anchors.count)
            }
            anchors.append(sum / Double(members))
        }
        self.anchors = anchors
        labAnchor = mapping
        driftPrecision = DriftPrior.precision(anchors, memory: hypothesis.memory)
    }

    private func residual(_ index: Int, _ p: BayesPosition) -> Double {
        let drift = anchors.isEmpty ? 0 : p.drift[labAnchor[index]]
        return observations[index] - (p.amplitude + drift + field.logConcentration(index, p.clearance))
    }

    private func driftGradient(_ values: [Double], at index: Int) -> Double {
        var component = driftPrecision.diagonal[index] * values[index]
        if index > 0 { component += driftPrecision.off[index - 1] * values[index - 1] }
        if index < values.count - 1 { component += driftPrecision.off[index] * values[index + 1] }
        return component
    }

    private func objective(_ p: BayesPosition) -> Double {
        var loss = 0.5 * (nu + 1) * log1p((p.amplitude * p.amplitude) / (nu * sdAmplitude * sdAmplitude))
        if allowClearance { loss += 0.5 * clearancePrecision * p.clearance * p.clearance }
        for index in anchors.indices {
            loss += 0.5 * driftScale * p.drift[index] * driftGradient(p.drift, at: index)
        }
        for index in 0..<count {
            let scaled = residual(index, p) / sigmas[index]
            loss += robust ? 0.5 * (nu + 1) * log1p((scaled * scaled) / nu) : 0.5 * scaled * scaled
        }
        return loss
    }

    private func normal(_ p: BayesPosition) -> (precision: BayesPrecision, driftGradient: [Double], borderGradient: [Double]) {
        let columns = allowClearance ? 2 : 1
        let zeros = Array(repeating: 0.0, count: columns)
        var precision = BayesPrecision(
            diagonal: driftPrecision.diagonal.map { $0 * driftScale }, off: driftPrecision.off.map { $0 * driftScale },
            coupling: Array(repeating: zeros, count: anchors.count), border: Array(repeating: zeros, count: columns)
        )
        var drift = anchors.indices.map { driftScale * driftGradient(p.drift, at: $0) }
        var border = zeros
        let priorWeight = (nu + 1) / (nu * sdAmplitude * sdAmplitude + p.amplitude * p.amplitude)
        precision.border[0][0] += priorWeight
        border[0] += priorWeight * p.amplitude
        if allowClearance {
            precision.border[1][1] += clearancePrecision
            border[1] += clearancePrecision * p.clearance
        }
        for index in 0..<count {
            let error = residual(index, p)
            let variance = sigmas[index] * sigmas[index]
            let weight = robust ? (nu + 1) / (nu * variance + error * error) : 1 / variance
            let slope = allowClearance ? field.slope(index, p.clearance) : 0
            precision.border[0][0] += weight
            border[0] -= weight * error
            if allowClearance {
                precision.border[0][1] += weight * slope
                precision.border[1][0] += weight * slope
                precision.border[1][1] += weight * slope * slope
                border[1] -= weight * slope * error
            }
            if !anchors.isEmpty {
                let anchor = labAnchor[index]
                precision.diagonal[anchor] += weight
                precision.coupling[anchor][0] += weight
                if allowClearance { precision.coupling[anchor][1] += weight * slope }
                drift[anchor] -= weight * error
            }
        }
        return (precision, drift, border)
    }

    private func solve(from initial: BayesPosition) -> (position: BayesPosition, loss: Double) {
        var position = initial
        var loss = objective(position)
        for _ in 0..<80 {
            let update = normal(position)
            guard let factor = update.precision.factor() else { break }
            let change = factor.solve(update.precision, drift: update.driftGradient.map { -$0 }, border: update.borderGradient.map { -$0 })
            var step = 1.0
            var next: (position: BayesPosition, loss: Double)?
            while step > 1e-4 {
                let candidate = BayesPosition(
                    amplitude: position.amplitude + step * change.border[0],
                    clearance: allowClearance ? FitMath.clampLogK(position.clearance + step * change.border[1]) : 0,
                    drift: position.drift.indices.map { position.drift[$0] + step * change.drift[$0] }
                )
                let value = objective(candidate)
                if value <= loss + 1e-12 { next = (candidate, value); break }
                step /= 2
            }
            guard let next else { break }
            let moved = abs(next.position.amplitude - position.amplitude)
                + abs(next.position.clearance - position.clearance)
                + position.drift.indices.reduce(0.0) { $0 + abs(next.position.drift[$1] - position.drift[$1]) }
            (position, loss) = next
            if moved < 1e-9 { break }
        }
        return (position, loss)
    }

    func fit() -> BayesFit? {
        let zeros = Array(repeating: 0.0, count: anchors.count)
        var best = solve(from: BayesPosition(amplitude: 0, clearance: 0, drift: zeros))
        let starts = allowClearance ? stride(from: 0, to: field.logK.count, by: 5).map { field.logK[$0] } : [0]
        for start in starts {
            let residuals = (0..<count).map { observations[$0] - field.logConcentration($0, start) }.sorted()
            let median = residuals[count / 2]
            let initial = BayesPosition(
                amplitude: median * (1 - hypothesis.share), clearance: start,
                drift: zeros.map { _ in median * hypothesis.share }
            )
            let candidate = solve(from: initial)
            if candidate.loss < best.loss { best = candidate }
        }
        let precision = normal(best.position).precision
        guard let factor = precision.factor(), best.loss.isFinite else { return nil }
        var logEvidence = -best.loss - log(sdAmplitude) - 0.5 * factor.logDet
        if !anchors.isEmpty {
            logEvidence -= Double(anchors.count) * log(sdDrift) + 0.5 * driftPrecision.logDetCovariance
        }
        let weights = (0..<count).map { index in
            let scaled = residual(index, best.position) / sigmas[index]
            return robust ? (nu + 1) / (nu + scaled * scaled) : 1
        }
        return BayesFit(
            hypothesis: hypothesis, position: best.position, anchors: anchors, sdDrift: sdDrift,
            allowClearance: allowClearance, precision: precision, factor: factor, logEvidence: logEvidence, studentWeights: weights
        )
    }
}

private final class BayesTimeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double: Double] = [:]
    private let compute: @Sendable (Double) -> Double

    init(_ compute: @escaping @Sendable (Double) -> Double) {
        self.compute = compute
    }

    func value(at time: Double) -> Double {
        guard time.isFinite else { return compute(time) }
        if let cached = lock.withLock({ values[time] }) { return cached }
        let value = compute(time)
        lock.withLock {
            if values.count >= 20_000 { values.removeAll(keepingCapacity: true) }
            values[time] = value
        }
        return value
    }
}
