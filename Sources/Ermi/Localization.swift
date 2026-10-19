import Foundation
import SwiftUI
import Observation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, simplified = "zh-Hans", traditional = "zh-Hant", english = "en"
    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .system: "跟随系统"
        case .simplified: "简体中文"
        case .traditional: "繁體中文"
        case .english: "English"
        }
    }
    static func resolve(_ selection: AppLanguage, preferred: [String]) -> AppLanguage {
        guard selection == .system else { return selection }
        // 未支持的系统语言使用英文；中文按脚本及地区区分，不能把繁体全部归为简体。
        for raw in preferred {
            let code = raw.lowercased().replacingOccurrences(of: "_", with: "-")
            if code.hasPrefix("zh") {
                return code.contains("hant") || code.contains("-tw") || code.contains("-hk") || code.contains("-mo") ? .traditional : .simplified
            }
            if code.hasPrefix("en") { return .english }
        }
        return .english
    }
}

struct TranslationEntry: Decodable {
    let source: String
    let en: String
    let traditional: String
    enum CodingKeys: String, CodingKey { case source, en; case traditional = "zh-Hant" }
}

/// 文案只在展示边界转换，不改变模型中的枚举、方案匹配值或用户输入。
struct TranslationCatalog {
    let entries: [TranslationEntry]
    private let exact: [String: TranslationEntry]
    private let patterns: [(NSRegularExpression, TranslationEntry, [String])]
    init(entries: [TranslationEntry]) {
        self.entries = entries
        exact = Dictionary(entries.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
        let tokens = try! NSRegularExpression(pattern: #"\{\d+\}|(?<!%)%(?:\d+\$)?[-+0#]*\d*(?:\.\d+)?(?:ll|l)?[@dfius]"#)
        patterns = entries.compactMap { entry in
            let ns = entry.source as NSString
            let matches = tokens.matches(in: entry.source, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return nil }
            var pattern = "\\A", cursor = 0, names: [String] = []
            for match in matches {
                pattern += NSRegularExpression.escapedPattern(for: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                pattern += "([\\s\\S]*?)"
                names.append(ns.substring(with: match.range))
                cursor = NSMaxRange(match.range)
            }
            pattern += NSRegularExpression.escapedPattern(for: ns.substring(from: cursor)) + "\\z"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, entry, names)
        }.sorted { $0.1.source.count > $1.1.source.count }
    }
    func translate(_ value: String, language: AppLanguage, depth: Int = 0) -> String {
        guard language != .simplified else { return value }
        func translated(_ entry: TranslationEntry) -> String { language == .traditional ? entry.traditional : entry.en }
        if let entry = exact[value] { return translated(entry) }
        let ns = value as NSString
        for (pattern, entry, tokens) in patterns {
            guard let match = pattern.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else { continue }
            // 一次性替换模板占位符，插入的 App 名/自定义名称即使含 {0} 也不被二次替换。
            let template = translated(entry)
            let tokenPattern = tokens.map(NSRegularExpression.escapedPattern).joined(separator: "|")
            guard let replacements = try? NSRegularExpression(pattern: tokenPattern) else { return template }
            let output = NSMutableString(string: template)
            var usedPrintf: [String: Int] = [:]
            let ranges = replacements.matches(in: template, range: NSRange(location: 0, length: (template as NSString).length))
            var values: [(NSRange, String)] = []
            for range in ranges {
                let token = (template as NSString).substring(with: range.range)
                let indices = tokens.indices.filter { tokens[$0] == token }
                let occurrence = token.hasPrefix("%") ? usedPrintf[token, default: 0] : 0
                guard !indices.isEmpty else { continue }
                let index = indices[min(occurrence, indices.count - 1)]
                usedPrintf[token] = occurrence + 1
                let raw = ns.substring(with: match.range(at: index + 1))
                // 只有明确的错误包装才递归翻译内层原因；其他占位符（用户名称等）一律原样保留。
                let errorWrappers: Set<String> = ["无法更新登录启动：{0}", "收起失败，图标保持显示：{0}", "重新打开失败：{0}", "控制连接不可用：{0}", "删除失败：{0}", "无法结束：{0}", "恢复回读失败：{0}", "代码签名校验失败：{0}"]
                let replacement = depth < 3 && errorWrappers.contains(entry.source) ? translate(raw, language: language, depth: depth + 1) : raw
                values.append((range.range, replacement))
            }
            for (range, value) in values.reversed() { output.replaceCharacters(in: range, with: value) }
            return output as String
        }
        // 未覆盖的系统错误保留原文，不能把真实错误换成笼统的成功或空白。
        return value
    }
}

@MainActor @Observable
final class AppLocalization {
    static let shared = AppLocalization()
    private let defaults: UserDefaults
    var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: "ermi.language"); cache.removeAll() } }
    var systemLanguages: [String]
    var previewLanguage: AppLanguage?
    var resolved: AppLanguage { previewLanguage ?? AppLanguage.resolve(language, preferred: systemLanguages) }
    var locale: Locale { Locale(identifier: resolved.rawValue) }
    @ObservationIgnored private var cache: [String: String] = [:]
    @ObservationIgnored let catalog: TranslationCatalog
    init(defaults: UserDefaults = .standard, preferred: [String] = Locale.preferredLanguages, entries: [TranslationEntry]? = nil) {
        self.defaults = defaults
        self.systemLanguages = preferred
        language = AppLanguage(rawValue: defaults.string(forKey: "ermi.language") ?? "") ?? .system
        let loaded = entries ?? Self.loadEntries()
        catalog = TranslationCatalog(entries: loaded)
    }
    static func loadEntries() -> [TranslationEntry] {
        guard let url = ErmiResources.bundle.url(forResource: "Translations", withExtension: "json"),
              let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([TranslationEntry].self, from: data) else { return [] }
        return entries
    }
    func text(_ value: String) -> String {
        // 先读取可观察语言值，使已显示的 SwiftUI 文案在切换时失效，不重建页面或控制器。
        let selected = resolved
        guard selected != .simplified else { return value }
        let key = selected.rawValue + "|" + value
        if let cached = cache[key] { return cached }
        let translated = catalog.translate(value, language: selected)
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = translated
        return translated
    }
}

@MainActor func L(_ text: String) -> String { AppLocalization.shared.text(text) }

struct LanguageSettings: View {
    @Bindable private var localization = AppLocalization.shared
    var body: some View {
        SettingsRow("界面语言", description: "语言切换立即生效并自动保存。") {
            DetailMenu(title: "界面语言", selection: $localization.language,
                       options: AppLanguage.allCases.map { ($0, $0.nativeName) })
                .frame(width: 100)
        }
    }
}
