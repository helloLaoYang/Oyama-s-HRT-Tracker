import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case german = "de"
    case french = "fr"
    case japanese = "ja"

    static let preferenceKey = "appLanguage"

    static var selection: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    var id: String { rawValue }

    var locale: Locale? { self == .system ? nil : Locale(identifier: rawValue) }

    var title: String {
        switch self {
        case .system: label("Follow system")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .german: "Deutsch"
        case .french: "Français"
        case .japanese: "日本語"
        }
    }

    fileprivate var bundle: Bundle {
        guard self != .system, let url = Bundle.main.url(forResource: rawValue, withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return .main }
        return bundle
    }
}

func label(_ key: String.LocalizationValue, table: String? = nil) -> String {
    let language = AppLanguage.selection
    return String(localized: key, table: table, bundle: language.bundle, locale: language.locale ?? .current)
}
