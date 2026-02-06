import SwiftUI

/// 国际化管理器：管理当前语言 Bundle，支持运行时切换语言
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @AppStorage("appLanguage") var appLanguage: String = "system" {
        didSet {
            applyLanguage(appLanguage)
        }
    }

    @Published var locale: Locale
    @Published var bundle: Bundle

    private init() {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let resolved = LocalizationManager.resolveLanguage(lang)
        self.locale = Locale(identifier: resolved)
        self.bundle = LocalizationManager.bundle(for: resolved)
    }

    /// 切换语言，更新 bundle 和 locale
    func setLanguage(_ lang: String) {
        appLanguage = lang
    }

    private func applyLanguage(_ lang: String) {
        let resolved = LocalizationManager.resolveLanguage(lang)
        let newBundle = LocalizationManager.bundle(for: resolved)
        let newLocale = Locale(identifier: resolved)
        DispatchQueue.main.async {
            self.bundle = newBundle
            self.locale = newLocale
        }
    }

    /// 将 "system" 解析为实际语言代码
    static func resolveLanguage(_ lang: String) -> String {
        if lang == "system" {
            let preferred = Locale.preferredLanguages.first ?? "en"
            if preferred.hasPrefix("zh") {
                return "zh-Hans"
            }
            return "en"
        }
        return lang
    }

    /// 获取指定语言的 Bundle
    static func bundle(for language: String) -> Bundle {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main
        }
        return bundle
    }
}

// MARK: - String 国际化扩展

extension String {
    /// 从当前语言 Bundle 获取翻译
    var localized: String {
        NSLocalizedString(self, bundle: LocalizationManager.shared.bundle, comment: "")
    }
}
