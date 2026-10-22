import Foundation

// 다국어 지원
// - 원문(키)은 한국어. 번역은 Resources/Localization/<언어>.lproj/Localizable.strings
// - macOS가 사용자의 시스템 언어(또는 설정에서 고른 언어)에 맞는 번역을 자동으로 고른다.
// - 지원하지 않는 언어면 영어(개발 지역)로 표시된다.

/// 번역된 문자열
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// 번역된 형식 문자열 (%@, %ld 등)
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

struct AppLanguage: Identifiable, Hashable {
    let code: String
    let name: String   // 그 언어로 쓴 언어 이름 (번역하지 않음)
    var id: String { code }

    static let all: [AppLanguage] = [
        AppLanguage(code: "en", name: "English"),
        AppLanguage(code: "ko", name: "한국어"),
        AppLanguage(code: "ja", name: "日本語"),
        AppLanguage(code: "zh-Hans", name: "简体中文"),
        AppLanguage(code: "zh-Hant", name: "繁體中文"),
        AppLanguage(code: "es", name: "Español"),
        AppLanguage(code: "fr", name: "Français"),
        AppLanguage(code: "de", name: "Deutsch"),
    ]

    /// 현재 화면에 쓰이는 언어 코드 (HTML lang 속성 등)
    static var current: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    /// 앱 전용으로 고른 언어. 비어 있으면 시스템 언어를 따른다.
    static var override: String {
        get {
            guard let id = Bundle.main.bundleIdentifier,
                  let langs = UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String],
                  let first = langs.first else { return "" }
            return all.contains { $0.code == first } ? first : ""
        }
        set {
            // 허용 목록에 있는 언어 코드만 저장 (임의 값 주입 방지)
            if newValue.isEmpty || !all.contains(where: { $0.code == newValue }) {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
            }
        }
    }
}
