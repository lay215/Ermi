import Foundation
import Testing
@testable import Ermi

@MainActor struct LocalizationTests {
    @Test func systemLanguageResolutionAndPersistence() {
        #expect(AppLanguage.resolve(.system, preferred: ["zh-HK"]) == .traditional)
        #expect(AppLanguage.resolve(.system, preferred: ["zh-Hans-CN"]) == .simplified)
        #expect(AppLanguage.resolve(.system, preferred: ["fr-FR"]) == .english)
        #expect(AppLanguage.resolve(.english, preferred: ["zh-Hant"]) == .english)
        let name = "app.ermi.language.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppLocalization(defaults: defaults, preferred: ["zh-HK"])
        #expect(first.resolved == .traditional)
        first.language = .english
        #expect(AppLocalization(defaults: defaults).resolved == .english)
        first.language = .simplified
        #expect(first.text("系统设置") == "系统设置")
    }

    @Test func placeholdersPreserveUserNamesAndDoNotCascade() {
        let catalog = TranslationCatalog(entries: [
            .init(source: "结束 {0}？", en: "Quit {0}?", traditional: "結束 {0}？"),
            .init(source: "值 {0} 和 {1}", en: "{1} then {0}", traditional: "值 {0} 和 {1}"),
            .init(source: "共 %.0f GB · 已用 %.0f%%", en: "%.0f GB total · %.0f%% used", traditional: "共 %.0f GB · 已用 %.0f%%")
        ])
        #expect(catalog.translate("结束 我的方案{1}？", language: .english) == "Quit 我的方案{1}?")
        #expect(catalog.translate("值 {1} 和 9", language: .english) == "9 then {1}")
        #expect(catalog.translate("unknown error", language: .english) == "unknown error")
    }

    @Test func catalogHasValidUniqueTemplatesAndAllTranslations() throws {
        let entries = AppLocalization.loadEntries()
        #expect(entries.count > 400)
        #expect(Set(entries.map(\.source)).count == entries.count)
        let regex = try NSRegularExpression(pattern: #"\{\d+\}|(?<!%)%(?:\d+\$)?[-+0#]*\d*(?:\.\d+)?(?:ll|l)?[@dfius]"#)
        func placeholders(_ text: String) -> [String] {
            regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
                .map { (text as NSString).substring(with: $0.range) }.sorted()
        }
        for entry in entries {
            #expect(!entry.en.isEmpty, "\(entry.source)")
            #expect(!entry.traditional.isEmpty, "\(entry.source)")
            #expect(placeholders(entry.source) == placeholders(entry.en), "English placeholders: \(entry.source)")
            #expect(placeholders(entry.source) == placeholders(entry.traditional), "Traditional placeholders: \(entry.source)")
        }
        let catalog = TranslationCatalog(entries: entries)
        #expect(catalog.translate("系统设置", language: .english) != "系统设置")
        #expect(catalog.translate("日常均衡", language: .traditional) == "日常均衡")
    }
}
