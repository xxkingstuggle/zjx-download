import Foundation

/// macOS locale identifiers shipped by the pinned AB Download Manager
/// translation catalog. Locale names stay in their native script so the
/// Settings picker remains recognizable regardless of the currently selected
/// language.
public struct SupportedAppLanguage: Codable, Sendable, Hashable, Identifiable {
    public let code: String
    public let nativeName: String
    public var id: String { code }

    public init(code: String, nativeName: String) {
        self.code = code
        self.nativeName = nativeName
    }

    public static let defaultCode = "zh-Hans"
    public static let all: [SupportedAppLanguage] = [
        .init(code: "ar_SA", nativeName: "العربية"),
        .init(code: "bn_BD", nativeName: "বাংলা"),
        .init(code: "bqi_IR", nativeName: "بختیاری"),
        .init(code: "ckb_IR", nativeName: "کوردی"),
        .init(code: "cs_CZ", nativeName: "Čeština"),
        .init(code: "de_DE", nativeName: "Deutsch"),
        .init(code: "en", nativeName: "English"),
        .init(code: "en_US", nativeName: "English (United States)"),
        .init(code: "es_ES", nativeName: "Español"),
        .init(code: "fa_IR", nativeName: "فارسی"),
        .init(code: "fi_FI", nativeName: "Suomi"),
        .init(code: "fr_FR", nativeName: "Français"),
        .init(code: "hu_HU", nativeName: "Magyar"),
        .init(code: "id_ID", nativeName: "Bahasa Indonesia"),
        .init(code: "it_IT", nativeName: "Italiano"),
        .init(code: "ja_JP", nativeName: "日本語"),
        .init(code: "ka_GE", nativeName: "ქართული"),
        .init(code: "ko_KR", nativeName: "한국어"),
        .init(code: "lt_LT", nativeName: "Lietuvių"),
        .init(code: "pl_PL", nativeName: "Polski"),
        .init(code: "pt_BR", nativeName: "Português (Brasil)"),
        .init(code: "ru_RU", nativeName: "Русский"),
        .init(code: "sq_AL", nativeName: "Shqip"),
        .init(code: "th_TH", nativeName: "ไทย"),
        .init(code: "tr_TR", nativeName: "Türkçe"),
        .init(code: "uk_UA", nativeName: "Українська"),
        .init(code: "vi_VN", nativeName: "Tiếng Việt"),
        .init(code: "zh-Hans", nativeName: "简体中文"),
        .init(code: "zh_CN", nativeName: "简体中文（中国）"),
        .init(code: "zh_TW", nativeName: "繁體中文"),
    ]

    /// Foundation and SwiftUI use BCP-47 hyphens while the original resource
    /// directories use underscores for regional locales.
    public static func foundationIdentifier(for code: String) -> String {
        code.replacingOccurrences(of: "_", with: "-")
    }
}
