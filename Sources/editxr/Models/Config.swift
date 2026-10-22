import Foundation

/// AI settings, stored as the nested `ai` object in config.json. Credentials
/// live here too, so they survive toggling AI off and on.
struct AIConfig: Equatable {
    static let defaultEndpoint = "http://localhost:1234"
    static let defaultLMStudioModel = "qwen2.5-7b-instruct"
    static let defaultOpenAIModel = "gpt-4o-mini"
    static let defaultOpenRouterModel = "openai/gpt-4o-mini"

    /// Off for new installs; migrated configs keep AI on (see ConfigCodec).
    var enabled: Bool = false
    var provider: LLMProvider = .lmStudio
    /// Base URL of the OpenAI-compatible server used by the LM Studio provider.
    var endpoint: String = AIConfig.defaultEndpoint
    /// Model for the LM Studio provider; nil uses the built-in default.
    var model: String? = nil
    /// Model for the OpenAI provider; nil falls back to $OPENAI_MODEL, then the default.
    var openAIModel: String? = nil
    var openRouterKey: String? = nil
    var openRouterModel: String? = nil
    var openAIAccessToken: String? = nil
    var openAIRefreshToken: String? = nil
    var openAIExpiresAt: Double? = nil

    var openAISignedIn: Bool { !(openAIAccessToken ?? "").isEmpty }
}

/// Defaults for Vim-only options (`:set` can still change them per session).
struct VimConfig: Equatable {
    var ignoreCase: Bool = false
    var smartCase: Bool = false
    /// Mirror the unnamed register to the system clipboard (`clipboard=unnamedplus`).
    var systemClipboard: Bool = false
    /// Ex commands run when Vim mode starts — a small vimrc, e.g.
    /// `["inoremap jk <Esc>", "set ic scs"]`.
    var startupCommands: [String] = []
}

/// The whole persisted configuration. Every field has a default, so a partial
/// (or empty) config.json decodes to sensible values; see ConfigCodec for the
/// on-disk format, validation, and migration of older files.
struct Config: Equatable {
    var vimMode: Bool = false
    var wordWrap: Bool = true
    var renderMarkdown: Bool = true
    var showLineNumbers: Bool = false
    var statusBarBig: Bool = true
    var scrollPastEnd: Bool = true
    var fullTable: Bool = true
    /// Render every table as wide as the widest.
    var alignTables: Bool = true
    var contextHelp: Bool = true
    var blockMode: Bool = true
    var sidebar: SidebarMode = .off
    var leftMargin: Int = 1
    var scrollOff: Int = 4
    /// Columns a tab advances to (display only: the file keeps its `\t`).
    var tabWidth: Int = 8
    // Stored as the raw string so renaming/removing a theme can't make the
    // whole config fail to decode; unknown values just fall back to default.
    var theme: String? = nil
    var appearance: String? = nil

    // Vault. nil path = follow the open file's folder.
    var vaultPath: String? = nil
    var recentVaults: [String]? = nil       // most-recent-first, capped
    var vaultSemanticSearch: Bool = true
    var vaultEmbedBackend: String? = nil    // EmbedBackend raw value
    var vaultIncludeTxt: Bool = true
    var vaultIndexOnOpen: Bool = true
    var vaultMaxResults: Int = 10

    var ai = AIConfig()
    var vim = VimConfig()

    static let leftMarginRange = 0...8
    static let scrollOffRange = 0...20
    static let tabWidthRange = 1...16
    static let vaultMaxResultsRange = 1...50

    /// Default location, overridable with $EDITXR_CONFIG (handy for testing a
    /// throwaway config without touching the real one).
    static var defaultPath: String {
        if let override = ProcessInfo.processInfo.environment["EDITXR_CONFIG"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/editxr/config.json"
    }
}

extension Config: CustomStringConvertible, CustomDebugStringConvertible {
    /// Credentials are redacted so a config never leaks into logs or errors.
    var description: String {
        var redacted = self
        redacted.ai.openRouterKey = redacted.ai.openRouterKey.map { _ in "<redacted>" }
        redacted.ai.openAIAccessToken = redacted.ai.openAIAccessToken.map { _ in "<redacted>" }
        redacted.ai.openAIRefreshToken = redacted.ai.openAIRefreshToken.map { _ in "<redacted>" }
        let data = (try? ConfigCodec.encodeObject(redacted)) ?? [:]
        let json = (try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
        return "Config(\(json ?? "?"))"
    }

    var debugDescription: String { description }
}

/// A problem found while reading config.json: the offending key and why its
/// value was ignored. Messages never include the value of a secret.
struct ConfigIssue: Equatable, CustomStringConvertible {
    let key: String
    let message: String

    var description: String { "\(key): \(message)" }
}

enum ConfigError: Error, LocalizedError, Equatable {
    case invalidJSON(String)
    case notAnObject
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail): return "config.json is not valid JSON (\(detail))"
        case .notAnObject: return "config.json must contain a JSON object"
        case .writeFailed(let detail): return "Couldn't save config.json: \(detail)"
        }
    }
}

/// Reads and writes the JSON form of Config. Decoding is per-key and lenient:
/// a missing key takes its default, a wrong-typed or out-of-range value is
/// reported as a ConfigIssue and replaced by the default (or clamped), and keys
/// this version doesn't know are preserved on save.
enum ConfigCodec {
    /// Top-level keys this version writes.
    static let knownKeys: Set<String> = [
        "vimMode", "wordWrap", "renderMarkdown", "showLineNumbers", "statusBarBig",
        "scrollPastEnd", "fullTable", "alignTables", "contextHelp", "blockMode",
        "sidebar", "leftMargin", "scrollOff", "tabWidth", "theme", "appearance",
        "vaultPath", "recentVaults", "vaultSemanticSearch", "vaultEmbedBackend",
        "vaultIncludeTxt", "vaultIndexOnOpen", "vaultMaxResults", "ai", "vim",
    ]
    /// Keys from older versions: read once for migration, dropped on save.
    static let legacyKeys: Set<String> = [
        "showOutline", "llmProvider", "openRouterKey", "openRouterModel",
        "openAIAccessToken", "openAIRefreshToken", "openAIExpiresAt",
    ]
    static let aiKeys: Set<String> = [
        "enabled", "provider", "endpoint", "model", "openAIModel", "openRouterKey",
        "openRouterModel", "openAIAccessToken", "openAIRefreshToken", "openAIExpiresAt",
    ]
    static let vimKeys: Set<String> = ["ignoreCase", "smartCase", "systemClipboard", "startupCommands"]
    private static let secretKeys: Set<String> = [
        "openRouterKey", "openAIAccessToken", "openAIRefreshToken",
    ]

    struct Decoded {
        var config: Config
        var issues: [ConfigIssue]
        /// The file predates the `ai` section (an older editxr wrote it).
        var migrated: Bool
    }

    // MARK: - Decoding

    static func parseObject(_ data: Data) throws -> [String: Any] {
        if data.isEmpty || String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [:]
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ConfigError.invalidJSON(jsonErrorDetail(error))
        }
        guard let object = raw as? [String: Any] else { throw ConfigError.notAnObject }
        return object
    }

    static func decode(_ data: Data) throws -> Decoded {
        decode(object: try parseObject(data))
    }

    static func decode(object: [String: Any]) -> Decoded {
        var reader = Reader(object: object, path: "")
        var c = Config()
        c.vimMode = reader.bool("vimMode", c.vimMode)
        c.wordWrap = reader.bool("wordWrap", c.wordWrap)
        c.renderMarkdown = reader.bool("renderMarkdown", c.renderMarkdown)
        c.showLineNumbers = reader.bool("showLineNumbers", c.showLineNumbers)
        c.statusBarBig = reader.bool("statusBarBig", c.statusBarBig)
        c.scrollPastEnd = reader.bool("scrollPastEnd", c.scrollPastEnd)
        c.fullTable = reader.bool("fullTable", c.fullTable)
        c.alignTables = reader.bool("alignTables", c.alignTables)
        c.contextHelp = reader.bool("contextHelp", c.contextHelp)
        c.blockMode = reader.bool("blockMode", c.blockMode)
        if let raw = reader.string("sidebar") {
            if let mode = SidebarMode(rawValue: raw) {
                c.sidebar = mode
            } else {
                reader.issue("sidebar", "expected one of off, outline, files")
            }
        } else if reader.bool("showOutline", false) {
            c.sidebar = .outline   // pre-sidebar configs
        }
        c.leftMargin = reader.int("leftMargin", c.leftMargin, range: Config.leftMarginRange)
        c.scrollOff = reader.int("scrollOff", c.scrollOff, range: Config.scrollOffRange)
        c.tabWidth = reader.int("tabWidth", c.tabWidth, range: Config.tabWidthRange)
        c.theme = reader.string("theme")
        if let theme = c.theme, ThemeName(rawValue: theme) == nil {
            reader.issue("theme", "unknown theme; using the default")
        }
        c.appearance = reader.string("appearance")
        if let appearance = c.appearance, Appearance(rawValue: appearance) == nil {
            reader.issue("appearance", "expected one of \(Appearance.allCases.map(\.rawValue).joined(separator: ", "))")
        }

        c.vaultPath = reader.string("vaultPath")
        c.recentVaults = reader.stringArray("recentVaults")
        c.vaultSemanticSearch = reader.bool("vaultSemanticSearch", c.vaultSemanticSearch)
        c.vaultEmbedBackend = reader.string("vaultEmbedBackend")
        c.vaultIncludeTxt = reader.bool("vaultIncludeTxt", c.vaultIncludeTxt)
        c.vaultIndexOnOpen = reader.bool("vaultIndexOnOpen", c.vaultIndexOnOpen)
        c.vaultMaxResults = reader.int("vaultMaxResults", c.vaultMaxResults, range: Config.vaultMaxResultsRange)

        let migrated: Bool
        if let aiObject = reader.object("ai") {
            var ai = Reader(object: aiObject, path: "ai.")
            c.ai = decodeAI(&ai)
            reader.issues += ai.issues
            migrated = false
        } else {
            // An older editxr wrote this file (or it's hand-written without an
            // `ai` section). AI was always on back then, so keep it on rather
            // than silently disabling a feature that may be in use.
            migrated = !object.isEmpty
            c.ai.enabled = migrated
            if let raw = reader.string("llmProvider") {
                if let provider = LLMProvider(rawValue: raw) { c.ai.provider = provider } else {
                    reader.issue("llmProvider", "unknown provider")
                }
            }
            c.ai.openRouterKey = reader.string("openRouterKey")
            c.ai.openRouterModel = reader.string("openRouterModel")
            c.ai.openAIAccessToken = reader.string("openAIAccessToken")
            c.ai.openAIRefreshToken = reader.string("openAIRefreshToken")
            c.ai.openAIExpiresAt = reader.double("openAIExpiresAt")
        }

        if let vimObject = reader.object("vim") {
            var vim = Reader(object: vimObject, path: "vim.")
            c.vim.ignoreCase = vim.bool("ignoreCase", c.vim.ignoreCase)
            c.vim.smartCase = vim.bool("smartCase", c.vim.smartCase)
            c.vim.systemClipboard = vim.bool("systemClipboard", c.vim.systemClipboard)
            c.vim.startupCommands = vim.stringArray("startupCommands") ?? []
            reader.issues += vim.issues
        }
        return Decoded(config: c, issues: reader.issues, migrated: migrated)
    }

    private static func decodeAI(_ r: inout Reader) -> AIConfig {
        var ai = AIConfig()
        ai.enabled = r.bool("enabled", ai.enabled)
        if let raw = r.string("provider") {
            if let provider = LLMProvider(rawValue: raw) { ai.provider = provider } else {
                r.issue("provider", "expected one of \(LLMProvider.allCases.map(\.rawValue).joined(separator: ", "))")
            }
        }
        if let endpoint = r.string("endpoint") {
            if let problem = validateEndpoint(endpoint) {
                r.issue("endpoint", problem)
            } else {
                ai.endpoint = endpoint
            }
        }
        ai.model = r.string("model")
        ai.openAIModel = r.string("openAIModel")
        ai.openRouterKey = r.string("openRouterKey")
        ai.openRouterModel = r.string("openRouterModel")
        ai.openAIAccessToken = r.string("openAIAccessToken")
        ai.openAIRefreshToken = r.string("openAIRefreshToken")
        ai.openAIExpiresAt = r.double("openAIExpiresAt")
        return ai
    }

    /// nil when `value` is a usable http(s) base URL, else why it isn't.
    static func validateEndpoint(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            return "expected an http(s) URL such as \(AIConfig.defaultEndpoint)"
        }
        return nil
    }

    /// Typed, issue-collecting access to one JSON object level.
    private struct Reader {
        let object: [String: Any]
        let path: String
        var issues: [ConfigIssue] = []

        init(object: [String: Any], path: String) {
            self.object = object
            self.path = path
        }

        mutating func issue(_ key: String, _ message: String) {
            issues.append(ConfigIssue(key: path + key, message: message))
        }

        private func present(_ key: String) -> Any? {
            guard let value = object[key], !(value is NSNull) else { return nil }
            return value
        }

        private func describe(_ key: String, _ value: Any) -> String {
            if ConfigCodec.secretKeys.contains(key) { return "a value of the wrong type" }
            if let s = value as? String { return "\"\(s)\"" }
            return "\(value)"
        }

        /// JSON `true`/`false` arrive as boolean NSNumbers (objCType "c"); a
        /// plain `1` also bridges to Bool, so the type has to be checked.
        private func isBoolean(_ value: Any) -> Bool {
            guard let number = value as? NSNumber else { return false }
            return String(cString: number.objCType) == "c"
        }

        mutating func bool(_ key: String, _ fallback: Bool) -> Bool {
            guard let value = present(key) else { return fallback }
            if isBoolean(value), let b = value as? Bool { return b }
            issue(key, "expected true or false, got \(describe(key, value))")
            return fallback
        }

        mutating func int(_ key: String, _ fallback: Int, range: ClosedRange<Int>) -> Int {
            guard let value = present(key) else { return fallback }
            guard !(value is String), !isBoolean(value), let number = value as? NSNumber else {
                issue(key, "expected a number, got \(describe(key, value))")
                return fallback
            }
            let n = number.intValue
            if !range.contains(n) {
                let clamped = min(range.upperBound, max(range.lowerBound, n))
                issue(key, "\(n) is outside \(range.lowerBound)–\(range.upperBound); using \(clamped)")
                return clamped
            }
            return n
        }

        mutating func double(_ key: String) -> Double? {
            guard let value = present(key) else { return nil }
            guard !(value is String), !isBoolean(value), let number = value as? NSNumber else {
                issue(key, "expected a number, got \(describe(key, value))")
                return nil
            }
            return number.doubleValue
        }

        mutating func string(_ key: String) -> String? {
            guard let value = present(key) else { return nil }
            if let s = value as? String { return s }
            issue(key, "expected a string, got \(describe(key, value))")
            return nil
        }

        mutating func stringArray(_ key: String) -> [String]? {
            guard let value = present(key) else { return nil }
            if let list = value as? [Any] {
                let strings = list.compactMap { $0 as? String }
                if strings.count != list.count { issue(key, "non-string entries were ignored") }
                return strings
            }
            issue(key, "expected a list of strings")
            return nil
        }

        mutating func object(_ key: String) -> [String: Any]? {
            guard let value = present(key) else { return nil }
            if let dict = value as? [String: Any] { return dict }
            issue(key, "expected an object")
            return nil
        }
    }

    private static func jsonErrorDetail(_ error: Error) -> String {
        let ns = error as NSError
        if let detail = ns.userInfo["NSDebugDescription"] as? String { return detail }
        return ns.localizedDescription
    }

    // MARK: - Encoding

    /// The JSON object for `config`: every known key, optional ones omitted
    /// when nil.
    static func encodeObject(_ c: Config) throws -> [String: Any] {
        var o: [String: Any] = [
            "vimMode": c.vimMode,
            "wordWrap": c.wordWrap,
            "renderMarkdown": c.renderMarkdown,
            "showLineNumbers": c.showLineNumbers,
            "statusBarBig": c.statusBarBig,
            "scrollPastEnd": c.scrollPastEnd,
            "fullTable": c.fullTable,
            "alignTables": c.alignTables,
            "contextHelp": c.contextHelp,
            "blockMode": c.blockMode,
            "sidebar": c.sidebar.rawValue,
            "leftMargin": c.leftMargin,
            "scrollOff": c.scrollOff,
            "tabWidth": c.tabWidth,
            "vaultSemanticSearch": c.vaultSemanticSearch,
            "vaultIncludeTxt": c.vaultIncludeTxt,
            "vaultIndexOnOpen": c.vaultIndexOnOpen,
            "vaultMaxResults": c.vaultMaxResults,
        ]
        o["theme"] = c.theme
        o["appearance"] = c.appearance
        o["vaultPath"] = c.vaultPath
        o["recentVaults"] = c.recentVaults
        o["vaultEmbedBackend"] = c.vaultEmbedBackend

        var ai: [String: Any] = [
            "enabled": c.ai.enabled,
            "provider": c.ai.provider.rawValue,
            "endpoint": c.ai.endpoint,
        ]
        ai["model"] = c.ai.model
        ai["openAIModel"] = c.ai.openAIModel
        ai["openRouterKey"] = c.ai.openRouterKey
        ai["openRouterModel"] = c.ai.openRouterModel
        ai["openAIAccessToken"] = c.ai.openAIAccessToken
        ai["openAIRefreshToken"] = c.ai.openAIRefreshToken
        ai["openAIExpiresAt"] = c.ai.openAIExpiresAt
        o["ai"] = ai

        o["vim"] = [
            "ignoreCase": c.vim.ignoreCase,
            "smartCase": c.vim.smartCase,
            "systemClipboard": c.vim.systemClipboard,
            "startupCommands": c.vim.startupCommands,
        ]
        return o
    }

    /// Serialize `config`, carrying over any keys in `existing` this version
    /// doesn't own (top-level and inside `ai` / `vim`), and dropping legacy keys
    /// that now live elsewhere.
    static func encode(_ config: Config, preserving existing: [String: Any] = [:]) throws -> Data {
        let encoded = try encodeObject(config)
        var merged = existing.filter { !knownKeys.contains($0.key) && !legacyKeys.contains($0.key) }
        for (key, value) in encoded { merged[key] = value }
        if let oldAI = existing["ai"] as? [String: Any], var ai = merged["ai"] as? [String: Any] {
            for (key, value) in oldAI where !aiKeys.contains(key) { ai[key] = value }
            merged["ai"] = ai
        }
        if let oldVim = existing["vim"] as? [String: Any], var vim = merged["vim"] as? [String: Any] {
            for (key, value) in oldVim where !vimKeys.contains(key) { vim[key] = value }
            merged["vim"] = vim
        }
        // Readable on disk so the file is comfortable to hand-edit.
        var data = try JSONSerialization.data(
            withJSONObject: merged,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(contentsOf: Array("\n".utf8))
        return data
    }
}
