import Foundation

// TS: src/domain/calibration/mcmc.ts. The route grid changes shape while the
// sampled personal level and route offsets change the amplitudes.
enum PersonalPKCalibration {
    private static let clearanceKnots = knots(FitMath.minLogK, FitMath.maxLogK, count: 13)
    private static let absorptionKnots = knots(log(0.4), log(2.5), count: 9)
    private static let routePriorSD = 0.35
    private static let absorptionPriorSD = 0.4
    private static let chainCount = 4
    private static let burnIn = 2_500
    private static let keptIterations = 2_500
    private static let thin = 5

    static func fit(
        simulation: Simulation, events: [DoseEvent], projectedEvents: [DoseEvent],
        weight: Double, birthYear: Int?, points: [FitPoint], history: CalibrationHistoryMode
    ) -> Calibration {
        let routes = HRTEngine.estradiolRoutes(events: events, projectedEvents: projectedEvents)
        guard !routes.isEmpty, !points.isEmpty else {
            return Calibration(method: .mcmc, scale: 1, kMul: 1, fitErrPct: nil, count: points.count, multiplier: { _ in 1 })
        }

        let model = RouteField(
            events: events, projected: projectedEvents, weight: weight,
            birthYear: HRTEngine.plausibleBirthYear(birthYear ?? simulation.birthYear, nowH: simulation.nowH),
            routes: routes, parameters: simulation.parameters
        )
        let hours = points.map(\.timeH)
        let data = Data(
            hours: hours, observations: points.map { log($0.observed) },
            deviations: points.map { FitMath.labLogSD($0, simulation: simulation) },
            routes: routes.count, grid: model.grid(at: hours)
        )
        let full = sample(data, count: points.count)
        let fits = history == .forward ? (1..<points.count).map { sample(data, count: $0) } + [full] : [full]
        let curve = CurveEstimate(simulation: simulation, model: model, fits: fits, labHours: history == .forward ? hours : [])
        let posterior = summarize(full, data: data)
        let levels = TimeMemo()
        let uncertainty = TimeMemo()
        let factor: @Sendable (Double) -> Double = { hour in
            levels.value(at: hour) { curve.factor(at: hour) }
        }
        let deviation: @Sendable (Double) -> Double = { hour in
            uncertainty.value(at: hour) { curve.deviation(at: hour) }
        }
        return Calibration(
            method: .mcmc, scale: posterior.scale, kMul: posterior.clearance, fitErrPct: FitMath.error(points, factor: factor),
            count: points.count, latestInterval: posterior.interval, discounted: full.discounted,
            absMul: posterior.absorption, routeScales: full.layout.hasRouteOffsets
                ? Dictionary(uniqueKeysWithValues: zip(routes, posterior.routeScales)) : nil,
            rHat: full.rHat, factorSD: deviation, multiplier: factor
        )
    }

    fileprivate struct RouteField: Sendable {
        let events: [DoseEvent]
        let projected: [DoseEvent]
        let weight: Double
        let birthYear: Int?
        let routes: [Route]
        let parameters: PKParameters

        func curves(knot: Int, at times: [Double]) -> [[Double]] {
            HRTEngine.estradiolRouteCurves(
                events: events, projectedEvents: projected, weight: weight, birthYear: birthYear, times: times,
                routes: routes, parameters: parameters,
                clearanceMultiplier: exp(clearanceKnots[knot / absorptionKnots.count]),
                absorptionMultiplier: exp(absorptionKnots[knot % absorptionKnots.count])
            )
        }

        func grid(at times: [Double]) -> [[[Double]]] {
            (0..<(clearanceKnots.count * absorptionKnots.count)).map { curves(knot: $0, at: times) }
        }
    }

    fileprivate struct Layout {
        let routes: Int
        let freeClearance: Bool
        let freeAbsorption: Bool

        var hasRouteOffsets: Bool { routes > 1 }
        var clearanceIndex: Int { 1 + (hasRouteOffsets ? routes : 0) }
        var absorptionIndex: Int { clearanceIndex + (freeClearance ? 1 : 0) }
        var dimensions: Int { absorptionIndex + (freeAbsorption ? 1 : 0) }

        func draw(_ parameters: [Double]) -> (amplitudes: [Double], clearance: Double, absorption: Double) {
            let level = parameters[0]
            let amplitudes = (0..<routes).map { exp(level + (hasRouteOffsets ? parameters[$0 + 1] : 0)) }
            return (amplitudes, freeClearance ? parameters[clearanceIndex] : 0, freeAbsorption ? parameters[absorptionIndex] : 0)
        }
    }

    fileprivate struct Weight: Sendable {
        let knot: Int
        let value: Double
    }

    fileprivate struct Data {
        let hours: [Double]
        let observations: [Double]
        let deviations: [Double]
        let routes: Int
        let grid: [[[Double]]]

        func logPrediction(amplitudes: [Double], weights: [Weight], at index: Int) -> Double {
            var total = 0.0
            for weight in weights {
                let row = grid[weight.knot]
                for route in 0..<routes {
                    total += weight.value * amplitudes[route] * row[route][index]
                }
            }
            return log(max(total, 1e-9))
        }
    }

    private static func knots(_ low: Double, _ high: Double, count: Int) -> [Double] {
        (0..<count).map { index in
            index == (count - 1) / 2 ? 0 : low + (high - low) * Double(index) / Double(count - 1)
        }
    }

    private static func bracket(_ list: [Double], _ value: Double) -> (Int, Double) {
        if value <= list[0] { return (0, 0) }
        if value >= list[list.count - 1] { return (list.count - 2, 1) }
        var upper = 1
        while upper < list.count - 1 && list[upper] < value { upper += 1 }
        return (upper - 1, (value - list[upper - 1]) / (list[upper] - list[upper - 1]))
    }

    private static func corners(clearance: Double, absorption: Double) -> [Weight] {
        let (clearanceIndex, k) = bracket(clearanceKnots, clearance)
        let (absorptionIndex, a) = bracket(absorptionKnots, absorption)
        let stride = absorptionKnots.count
        let first = clearanceIndex * stride + absorptionIndex
        return [
            Weight(knot: first, value: (1 - k) * (1 - a)),
            Weight(knot: first + stride, value: k * (1 - a)),
            Weight(knot: first + 1, value: (1 - k) * a),
            Weight(knot: first + stride + 1, value: k * a)
        ].filter { $0.value > 1e-12 }
    }

    private static func enoughAbsorptionClusters(_ hours: ArraySlice<Double>) -> Bool {
        var count = 0
        var anchor = -Double.infinity
        for time in hours where time - anchor > FitMath.labClusterHours {
            count += 1
            if count >= 4 { return true }
            anchor = time
        }
        return false
    }

    private static func logPosterior(_ parameters: [Double], data: Data, layout: Layout, count: Int, robust: Bool) -> Double {
        let draw = layout.draw(parameters)
        guard (FitMath.minLogK...FitMath.maxLogK).contains(draw.clearance),
              (absorptionKnots[0]...absorptionKnots[absorptionKnots.count - 1]).contains(draw.absorption) else {
            return -.infinity
        }
        let nu = FitMath.studentDegrees
        let prior = parameters[0] / FitMath.amplitudePriorSD
        var value = -(nu + 1) / 2 * log(1 + prior * prior / nu)
        if layout.hasRouteOffsets {
            for route in 0..<layout.routes {
                let offset = parameters[route + 1] / routePriorSD
                value -= 0.5 * offset * offset
            }
        }
        if layout.freeClearance {
            let clearance = draw.clearance / FitMath.clearancePriorSD
            value -= 0.5 * clearance * clearance
        }
        if layout.freeAbsorption {
            let absorption = draw.absorption / absorptionPriorSD
            value -= 0.5 * absorption * absorption
        }
        let weights = corners(clearance: draw.clearance, absorption: draw.absorption)
        for index in 0..<count {
            let predicted = data.logPrediction(amplitudes: draw.amplitudes, weights: weights, at: index)
            let residual = (data.observations[index] - predicted) / data.deviations[index]
            value += robust ? -(nu + 1) / 2 * log(1 + residual * residual / nu) : -0.5 * residual * residual
        }
        return value
    }

    private struct Random {
        var state: UInt32
        var spare: Double?

        mutating func uniform() -> Double {
            state &+= 0x6d2b79f5
            var value = (state ^ (state >> 15)) &* (state | 1)
            value ^= value &+ ((value ^ (value >> 7)) &* (value | 61))
            return Double(value ^ (value >> 14)) / 4_294_967_296
        }

        mutating func normal() -> Double {
            if let spare {
                self.spare = nil
                return spare
            }
            var u = uniform()
            while u <= 1e-300 { u = uniform() }
            let angle = 2 * Double.pi * uniform()
            let radius = sqrt(-2 * log(u))
            spare = radius * sin(angle)
            return radius * cos(angle)
        }
    }

    private static func seed(_ data: Data, count: Int) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for value in [Double(count)] + data.observations.prefix(count) + data.hours.prefix(count) {
            for byte in precision12(value).utf8 {
                hash = (hash ^ UInt32(byte)) &* 16_777_619
            }
        }
        return hash
    }

    // JavaScript Number.toPrecision(12) preserves trailing zeroes, including
    // in the fixed-point representation used by the seeded Web sampler.
    private static func precision12(_ value: Double) -> String {
        let scientific = String(format: "%.11e", locale: Locale(identifier: "en_US_POSIX"), abs(value))
            .lowercased().split(separator: "e")
        let exponent = Int(scientific[1]) ?? 0
        let sign = value < 0 ? "-" : ""
        if exponent >= 12 || exponent < -6 {
            return sign + scientific[0] + "e" + (exponent >= 0 ? "+" : "") + String(exponent)
        }
        let digits = scientific[0].filter { $0 != "." }
        let decimal = exponent + 1
        if decimal <= 0 { return sign + "0." + String(repeating: "0", count: -decimal) + digits }
        if decimal == digits.count { return sign + digits }
        return sign + digits.prefix(decimal) + "." + digits.dropFirst(decimal)
    }

    fileprivate struct Fit {
        let layout: Layout
        let draws: [[Double]]
        let rHat: Double
        let discounted: Int
    }

    private static func sample(_ data: Data, count: Int) -> Fit {
        let hours = data.hours.prefix(count)
        let layout = Layout(
            routes: data.routes, freeClearance: FitMath.clearanceIdentifiable(hours),
            freeAbsorption: enoughAbsorptionClusters(hours)
        )
        let robust = count >= FitMath.minimumClusters
        let axes = corners(clearance: 0, absorption: 0)
        let ones = Array(repeating: 1.0, count: data.routes)
        let center = (0..<count).reduce(0.0) {
            $0 + (data.observations[$1] - data.logPrediction(amplitudes: ones, weights: axes, at: $1))
        } / Double(count)
        var random = Random(state: seed(data, count: count))
        var chains: [[[Double]]] = []
        for _ in 0..<chainCount {
            chains.append(chain(data: data, layout: layout, count: count, robust: robust, center: center, random: &random))
        }
        let draws = chains.flatMap { $0 }
        var discounted = 0
        if robust {
            var means = Array(repeating: 0.0, count: count)
            let nu = FitMath.studentDegrees
            for parameters in draws {
                let draw = layout.draw(parameters)
                let weights = corners(clearance: draw.clearance, absorption: draw.absorption)
                for index in 0..<count {
                    let predicted = data.logPrediction(amplitudes: draw.amplitudes, weights: weights, at: index)
                    let z = (data.observations[index] - predicted) / data.deviations[index]
                    means[index] += (nu + 1) / (nu + z * z) / Double(draws.count)
                }
            }
            discounted = means.filter { $0 < 0.5 }.count
        }
        return Fit(layout: layout, draws: draws, rHat: splitRHat(chains, dimensions: layout.dimensions), discounted: discounted)
    }

    private static func chain(
        data: Data, layout: Layout, count: Int, robust: Bool, center: Double, random: inout Random
    ) -> [[Double]] {
        let dimensions = layout.dimensions
        var position = Array(repeating: 0.0, count: dimensions)
        position[0] = center + 0.3 * random.normal()
        for index in 1..<dimensions { position[index] = 0.15 * random.normal() }
        var probability = logPosterior(position, data: data, layout: layout, count: count, robust: robust)
        if !probability.isFinite {
            position = Array(repeating: 0.0, count: dimensions)
            position[0] = center
            probability = logPosterior(position, data: data, layout: layout, count: count, robust: robust)
        }

        var factor = Array(repeating: 0.0, count: dimensions * dimensions)
        for row in 0..<dimensions { factor[row * dimensions + row] = 0.1 }
        var logScale = 0.0
        var mean = Array(repeating: 0.0, count: dimensions)
        var covariance = Array(repeating: 0.0, count: dimensions * dimensions)
        var acceptedInWindow = 0
        var kept: [[Double]] = []
        kept.reserveCapacity(keptIterations / thin)
        for iteration in 0..<(burnIn + keptIterations) {
            let normals = (0..<dimensions).map { _ in random.normal() }
            let scale = exp(logScale)
            var candidate = Array(repeating: 0.0, count: dimensions)
            for row in 0..<dimensions {
                var delta = 0.0
                for column in 0...row {
                    delta += factor[row * dimensions + column] * normals[column]
                }
                candidate[row] = position[row] + scale * delta
            }
            let proposed = logPosterior(candidate, data: data, layout: layout, count: count, robust: robust)
            let accepted = proposed.isFinite && log(random.uniform()) < proposed - probability
            if accepted {
                position = candidate
                probability = proposed
            }
            if iteration < burnIn {
                if accepted { acceptedInWindow += 1 }
                let seen = iteration + 1
                let delta = zip(position, mean).map { $0 - $1 }
                for row in 0..<dimensions { mean[row] += delta[row] / Double(seen) }
                for row in 0..<dimensions {
                    for column in 0..<dimensions {
                        covariance[row * dimensions + column] += delta[row] * (position[column] - mean[column])
                    }
                }
                if seen.isMultiple(of: 100) {
                    logScale += Double(acceptedInWindow) / 100 > 0.234 ? 0.2 : -0.2
                    acceptedInWindow = 0
                    if seen > 400 {
                        let scale = 2.38 * 2.38 / Double(dimensions)
                        let sample = covariance.enumerated().map { index, value in
                            scale * (value / Double(seen - 1)) + (index.isMultiple(of: dimensions + 1) ? 1e-6 : 0)
                        }
                        if let next = cholesky(sample, dimensions: dimensions) { factor = next }
                    }
                }
            } else if (iteration - burnIn).isMultiple(of: thin) {
                kept.append(position)
            }
        }
        return kept
    }

    private static func cholesky(_ matrix: [Double], dimensions: Int) -> [Double]? {
        var factor = Array(repeating: 0.0, count: dimensions * dimensions)
        for row in 0..<dimensions {
            for column in 0...row {
                var value = matrix[row * dimensions + column]
                for prior in 0..<column {
                    value -= factor[row * dimensions + prior] * factor[column * dimensions + prior]
                }
                if row == column {
                    guard value > 0 else { return nil }
                    factor[row * dimensions + row] = sqrt(value)
                } else {
                    factor[row * dimensions + column] = value / factor[column * dimensions + column]
                }
            }
        }
        return factor
    }

    private static func splitRHat(_ chains: [[[Double]]], dimensions: Int) -> Double {
        let halves = chains.flatMap { chain -> [ArraySlice<[Double]>] in
            let size = chain.count / 2
            return [chain[..<size], chain[size..<(size * 2)]]
        }
        guard let size = halves.first?.count, size >= 2 else { return 1 }
        let length = Double(size)
        let groupCount = Double(halves.count)
        var worst = 1.0
        for dimension in 0..<dimensions {
            let means = halves.map { draws in draws.reduce(0.0) { $0 + $1[dimension] } / length }
            let grand = means.reduce(0, +) / groupCount
            let between = means.reduce(0.0) { $0 + pow($1 - grand, 2) } * (length / (groupCount - 1))
            let within = zip(halves, means).reduce(0.0) { total, group in
                total + group.0.reduce(0.0) { $0 + pow($1[dimension] - group.1, 2) } / (length - 1)
            } / groupCount
            if within >= 1e-14 {
                let estimate = ((length - 1) / length) * within + between / length
                worst = max(worst, sqrt(estimate / within))
            }
        }
        return worst
    }
}

private extension PersonalPKCalibration {
    struct CurveDraw: Sendable {
        let amplitudes: [Double]
        let weights: [Weight]
    }

    struct Coefficients: Sendable {
        let knot: Int
        var routes: [Double]
    }

    struct CurveSection: Sendable {
        let deviations: [CurveDraw]
        let coefficients: [Coefficients]
        let level: Double

        init(_ draws: [CurveDraw], routeCount: Int) {
            deviations = every(draws, count: 150)
            let sum = draws.reduce(0.0) { $0 + log($1.amplitudes.reduce(0, +) / Double(routeCount)) }
            level = exp(sum / Double(draws.count))
            var indices: [Int: Int] = [:]
            var coefficients: [Coefficients] = []
            for draw in draws {
                for weight in draw.weights {
                    let index: Int
                    if let seen = indices[weight.knot] {
                        index = seen
                    } else {
                        index = coefficients.count
                        indices[weight.knot] = index
                        coefficients.append(Coefficients(knot: weight.knot, routes: Array(repeating: 0, count: routeCount)))
                    }
                    for route in 0..<routeCount {
                        coefficients[index].routes[route] += weight.value * draw.amplitudes[route] / Double(draws.count)
                    }
                }
            }
            self.coefficients = coefficients
        }
    }

    struct CurveEstimate: Sendable {
        let times: [Double]
        let population: [Double]
        let knotCurves: [Int: [[Double]]]
        let sections: [CurveSection]
        let labHours: [Double]

        init(simulation: Simulation, model: RouteField, fits: [Fit], labHours: [Double]) {
            let times = simulation.points.map(\.timeH)
            self.times = times
            population = simulation.points.map(\.e2)
            self.labHours = labHours

            let curveDraws = fits.map { fit in
                every(fit.draws, count: 400).map { parameters in
                    let draw = fit.layout.draw(parameters)
                    return CurveDraw(
                        amplitudes: draw.amplitudes, weights: corners(clearance: draw.clearance, absorption: draw.absorption)
                    )
                }
            }
            let knots = majorKnots(curveDraws)
            let available = Set(knots)
            knotCurves = Dictionary(uniqueKeysWithValues: knots.map { ($0, model.curves(knot: $0, at: times)) })
            sections = curveDraws.map { draws in
                CurveSection(draws.map { restrict($0, to: knots, available: available) }, routeCount: model.routes.count)
            }
        }

        func factor(at time: Double) -> Double {
            guard let section = section(at: time) else { return 1 }
            guard let point = locate(time), point.value(in: population) >= 1 else { return FitMath.clampFactor(section.level) }

            var mean = 0.0
            for coefficients in section.coefficients {
                let curves = knotCurves[coefficients.knot]!
                for route in coefficients.routes.indices {
                    mean += coefficients.routes[route] * point.value(in: curves[route])
                }
            }
            return FitMath.clampFactor(mean / point.value(in: population))
        }

        func deviation(at time: Double) -> Double {
            guard let section = section(at: time) else { return 0 }
            let point = locate(time)
            let baseline = point?.value(in: population) ?? 0
            let values = section.deviations.map { draw -> Double in
                guard let point, baseline >= 1 else {
                    return log(draw.amplitudes.reduce(0, +) / Double(draw.amplitudes.count))
                }
                var value = 0.0
                for weight in draw.weights {
                    let curves = knotCurves[weight.knot]!
                    for route in draw.amplitudes.indices {
                        value += weight.value * draw.amplitudes[route] * point.value(in: curves[route])
                    }
                }
                return log(max(value, 1e-9) / baseline)
            }
            let mean = values.reduce(0, +) / Double(values.count)
            return sqrt(values.reduce(0.0) { $0 + pow($1 - mean, 2) } / Double(max(1, values.count - 1)))
        }

        private func section(at time: Double) -> CurveSection? {
            guard let firstLab = labHours.first else { return sections[0] }
            guard time >= firstLab else { return nil }
            let index = labHours.lastIndex { $0 <= time } ?? 0
            return sections[index]
        }

        private struct Position {
            let index: Int
            let fraction: Double

            func value(in samples: [Double]) -> Double {
                fraction == 0 ? samples[index] : samples[index] * (1 - fraction) + samples[index + 1] * fraction
            }
        }

        private func locate(_ time: Double) -> Position? {
            guard let first = times.first, let last = times.last, time >= first, time <= last else { return nil }
            var low = 0
            var high = times.count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if times[middle] <= time { low = middle } else { high = middle }
            }
            let span = times[high] - times[low]
            return Position(index: low, fraction: span > 0 ? (time - times[low]) / span : 0)
        }
    }

    static func majorKnots(_ segments: [[CurveDraw]]) -> [Int] {
        var mass: [Int: Double] = [:]
        var order: [Int] = []
        for draws in segments {
            for draw in draws {
                for weight in draw.weights {
                    if mass[weight.knot] == nil { order.append(weight.knot) }
                    mass[weight.knot, default: 0] += weight.value / Double(draws.count)
                }
            }
        }
        return order.enumerated().sorted { left, right in
            let leftMass = mass[left.element, default: 0]
            let rightMass = mass[right.element, default: 0]
            return leftMass == rightMass ? left.offset < right.offset : leftMass > rightMass
        }.prefix(16).map(\.element)
    }

    static func restrict(_ draw: CurveDraw, to knots: [Int], available: Set<Int>) -> CurveDraw {
        let inside = draw.weights.filter { available.contains($0.knot) }
        let sum = inside.reduce(0.0) { $0 + $1.value }
        if sum > 1e-9 {
            return CurveDraw(amplitudes: draw.amplitudes, weights: inside.map { Weight(knot: $0.knot, value: $0.value / sum) })
        }
        let main = draw.weights.dropFirst().reduce(draw.weights[0]) { $0.value >= $1.value ? $0 : $1 }.knot
        let stride = absorptionKnots.count
        func distance(_ knot: Int) -> Int {
            let clearance = knot / stride - main / stride
            let absorption = knot % stride - main % stride
            return clearance * clearance + absorption * absorption
        }
        let nearest = knots.dropFirst().reduce(knots[0]) { distance($0) <= distance($1) ? $0 : $1 }
        return CurveDraw(amplitudes: draw.amplitudes, weights: [Weight(knot: nearest, value: 1)])
    }

    static func every<T>(_ values: [T], count: Int) -> [T] {
        guard values.count > count else { return values }
        let step = Double(values.count) / Double(count)
        return (0..<count).map { values[Int(Double($0) * step)] }
    }

    struct Summary {
        let scale: Double
        let clearance: Double
        let absorption: Double
        let routeScales: [Double]
        let interval: ClosedRange<Double>
    }

    static func summarize(_ fit: Fit, data: Data) -> Summary {
        let last = data.hours.count - 1
        let ones = Array(repeating: 1.0, count: data.routes)
        let baseline = exp(data.logPrediction(amplitudes: ones, weights: corners(clearance: 0, absorption: 0), at: last))
        var levels: [Double] = []
        var amplitude = 0.0
        var clearance = 0.0
        var absorption = 0.0
        var routes = Array(repeating: 0.0, count: data.routes)
        for parameters in fit.draws {
            let draw = fit.layout.draw(parameters)
            let weights = corners(clearance: draw.clearance, absorption: draw.absorption)
            let prediction = exp(data.logPrediction(amplitudes: draw.amplitudes, weights: weights, at: last))
            let shape = exp(data.logPrediction(amplitudes: ones, weights: weights, at: last))
            levels.append(prediction / baseline)
            amplitude += log(prediction / shape)
            clearance += draw.clearance
            absorption += draw.absorption
            for route in routes.indices { routes[route] += log(draw.amplitudes[route]) }
        }
        let samples = Double(fit.draws.count)
        levels.sort()
        let interval = FitMath.clampFactor(quantile(levels, 0.05))...FitMath.clampFactor(quantile(levels, 0.95))
        return Summary(
            scale: FitMath.clampFactor(exp(amplitude / samples)), clearance: exp(clearance / samples),
            absorption: exp(absorption / samples), routeScales: routes.map { FitMath.clampFactor(exp($0 / samples)) },
            interval: interval
        )
    }

    static func quantile(_ sorted: [Double], _ probability: Double) -> Double {
        let position = Double(sorted.count - 1) * probability
        let low = Int(floor(position))
        let high = Int(ceil(position))
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }

    // Calculations can call the same calibration from several model tasks.
    // The lock protects the bounded cache, not the independent evaluation.
    final class TimeMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Double: Double] = [:]

        func value(at time: Double, calculate: () -> Double) -> Double {
            lock.lock()
            let cached = results[time]
            lock.unlock()
            if let cached { return cached }
            let value = calculate()
            lock.lock()
            if results.count >= 20_000 { results.removeAll(keepingCapacity: true) }
            results[time] = value
            lock.unlock()
            return value
        }
    }
}
