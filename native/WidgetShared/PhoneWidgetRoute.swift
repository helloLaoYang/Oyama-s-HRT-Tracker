import Foundation

enum PhoneWidgetRoute: Hashable {
    case overview
    case estimate(WatchMetric)
    case trend(WatchMetric)

    private static let scheme = "hrttracker"
    private static let host = "concentration"

    var url: URL {
        let path: String
        switch self {
        case .overview: path = ""
        case .estimate(let metric): path = "/estimate/\(metric.rawValue)"
        case .trend(let metric): path = "/trend/\(metric.rawValue)"
        }
        return URL(string: "\(Self.scheme)://\(Self.host)\(path)")!
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == Self.scheme, components.host == Self.host,
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil
        else { return nil }

        let path = components.percentEncodedPath
        if path.isEmpty || path == "/" {
            self = .overview
            return
        }

        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 3, segments[0].isEmpty,
              let metric = WatchMetric(rawValue: String(segments[2]))
        else { return nil }
        switch segments[1] {
        case "estimate": self = .estimate(metric)
        case "trend": self = .trend(metric)
        default: return nil
        }
    }
}
