import Foundation

enum BodyMetric: String, CaseIterable, Codable, Identifiable {
    case height, weight, chest, waist, hips
    case shoulder, neck, underbust, abdomen
    case armLength, upperArm
    case inseam, thigh, calf

    var id: String { rawValue }
    var unit: String { self == .weight ? "kg" : "cm" }
    var validRange: ClosedRange<Double> { self == .weight ? 20...400 : 0.1...999.9 }
}

struct BodyMeasurementRevision: Identifiable, Codable, Equatable {
    let id: String
    let value: Double
    let measuredAt: Date?
    let savedAt: Date

    static func isValidDate(_ date: Date) -> Bool {
        (Date.distantPast...Date.distantFuture).contains(date)
    }

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.savedAt == rhs.savedAt ? lhs.id < rhs.id : lhs.savedAt < rhs.savedAt
    }
}

struct BodyMeasurement: Identifiable, Codable, Equatable {
    let id: String
    let metric: BodyMetric
    let revisions: [BodyMeasurementRevision]

    var current: BodyMeasurementRevision? { revisions.last }
    var createdAt: Date? { revisions.first?.savedAt }

    var isValid: Bool {
        !id.isEmpty && !revisions.isEmpty &&
            Set(revisions.map(\.id)).count == revisions.count &&
            revisions.allSatisfy { revision in
                !revision.id.isEmpty && metric.validRange.contains(revision.value) &&
                    BodyMeasurementRevision.isValidDate(revision.savedAt) &&
                    (revision.measuredAt.map { date in
                        BodyMeasurementRevision.isValidDate(date) && date <= revision.savedAt
                    } ?? true)
            } &&
            revisions == revisions.sorted(by: BodyMeasurementRevision.precedes)
    }

    init(id: String, metric: BodyMetric, revisions: [BodyMeasurementRevision]) {
        self.id = id
        self.metric = metric
        self.revisions = revisions
    }

    init(metric: BodyMetric, value: Double, measuredAt: Date, savedAt: Date) {
        self.init(id: UUID().uuidString, metric: metric, revisions: [
            BodyMeasurementRevision(id: UUID().uuidString, value: value, measuredAt: measuredAt, savedAt: savedAt)
        ])
    }

    static func latestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        switch (lhs.current?.measuredAt, rhs.current?.measuredAt) {
        case let (left?, right?) where left != right: return left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            let left = lhs.createdAt ?? .distantPast
            let right = rhs.createdAt ?? .distantPast
            return left == right ? lhs.id > rhs.id : left > right
        }
    }

    func appending(_ revision: BodyMeasurementRevision) -> Self {
        Self(id: id, metric: metric, revisions: revisions + [revision])
    }

    func merging(_ incoming: Self) -> Self {
        let knownIDs = Set(revisions.map(\.id))
        let additions = incoming.revisions.filter { !knownIDs.contains($0.id) }
        return Self(id: id, metric: metric, revisions: (revisions + additions).sorted(by: BodyMeasurementRevision.precedes))
    }

    static let defaultWeight = 70.0

    static func legacyWeight(_ value: Double, timestamp: Double?, importedAt: Date) -> Self? {
        guard BodyMetric.weight.validRange.contains(value),
              value != defaultWeight || timestamp != nil else { return nil }
        let id = "legacy-weight-\(timestamp?.bitPattern ?? 0)-\(value.bitPattern)"
        let originalSave = timestamp.map { Date(timeIntervalSince1970: $0 / 1_000) }
        let savedAt = originalSave.flatMap {
            BodyMeasurementRevision.isValidDate($0) && $0 <= importedAt ? $0 : nil
        } ?? importedAt
        return Self(id: id, metric: .weight, revisions: [
            BodyMeasurementRevision(id: id + "-original", value: value, measuredAt: nil, savedAt: savedAt)
        ])
    }
}
