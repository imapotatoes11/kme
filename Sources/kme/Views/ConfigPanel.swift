import Foundation

/// What the configuration UI needs from the app. Settings are read from and
/// written to `ConfigStore` through `changeConfig`, which also applies the
/// change to every open document; the rest are actions with side effects.
protocol ConfigPanelHost: AnyObject {
    var configStore: ConfigStore { get }
    /// Persist `change` and apply the result to the running editor.
    func changeConfig(_ change: @escaping (inout Config) -> Void)
    /// Focus mode is per-session (never saved), so it isn't part of Config.
    var focusModeLabel: String { get }
    func cycleFocusMode()
    func promptInput(prompt: String, value: String, isSecret: Bool,
                     validate: ((String) -> String?)?, onSubmit: @escaping (String) -> Void)
    func openConfigFile()
    func reloadConfigFromDisk()
    func resetConfigToDefaults()
    func testAIConnection()
    var openAISignInSupported: Bool { get }
    func signInToOpenAI()
    func signOutOfOpenAI()
    func vaultSettingsCommands() -> [PaletteCommand]
}

/// The unified settings menu. One implementation, two entry points: Vim's
/// `:config` and the command palette's Settings entry both open the panel on
/// `rootCommands()`, so there's no second copy of any setting.
final class ConfigPanel {
    static let rootTitle = "\(AppInfo.name) / Configuration"

    private weak var host: ConfigPanelHost?

    init(host: ConfigPanelHost) {
        self.host = host
    }

    private var config: Config { host?.configStore.current ?? Config() }

    // MARK: - Root

    func rootCommands() -> [PaletteCommand] {
        var cmds: [PaletteCommand] = [
            section("Editor", summary: config.vimMode ? "Vim" : "Standard",
                    detail: "Editing mode, wrapping, margins, sidebar") { [weak self] in self?.editorCommands() ?? [] },
            section("Appearance", summary: ConfigPanel.themeName(of: config).displayName,
                    detail: "Theme, light/dark appearance, status bar") { [weak self] in self?.appearanceCommands() ?? [] },
            section("Markdown", summary: config.renderMarkdown ? "Rendered" : "Raw",
                    detail: "Rendered or raw view, tables") { [weak self] in self?.markdownCommands() ?? [] },
            section("AI", summary: config.ai.enabled ? "Enabled" : "Disabled",
                    detail: "AI-assisted editing, provider, model, credentials") { [weak self] in self?.aiCommands() ?? [] },
            section("Vault", summary: "",
                    detail: "Vault folder, search and index") { [weak self] in self?.host?.vaultSettingsCommands() ?? [] },
            section("Configuration", summary: issueSummary,
                    detail: "Open, reload, or reset config.json") { [weak self] in self?.fileCommands() ?? [] },
        ]
        if let error = host?.configStore.lastError {
            cmds.insert(.header("⚠ \(error.localizedDescription)"), at: 0)
        }
        return cmds
    }

    private var issueSummary: String {
        guard let store = host?.configStore else { return "" }
        if store.lastError != nil { return "[Error]" }
        return store.issues.isEmpty ? "" : "[\(store.issues.count) issue\(store.issues.count == 1 ? "" : "s")]"
    }

    // MARK: - Sections

    func editorCommands() -> [PaletteCommand] {
        let c = config
        var cmds: [PaletteCommand] = [
            toggle("Vim Mode", c.vimMode,
                   detail: "Modal editing (Normal/Insert/Visual). In Vim mode, :config opens this panel.") { $0.vimMode.toggle() },
            toggle("Word Wrap", c.wordWrap, detail: "Wrap long lines to the window width") { $0.wordWrap.toggle() },
            toggle("Line Numbers", c.showLineNumbers, detail: "Show a line-number gutter") { $0.showLineNumbers.toggle() },
            toggle("Scroll Past End", c.scrollPastEnd, detail: "Allow scrolling half a screen below the last line") { $0.scrollPastEnd.toggle() },
            number("Tab Width", c.tabWidth, range: Config.tabWidthRange,
                   detail: "Columns a tab advances to (display only; the file keeps its tabs)") { $0.tabWidth = $1 },
            number("Left Margin", c.leftMargin, range: Config.leftMarginRange,
                   detail: "Blank columns left of the text") { $0.leftMargin = $1 },
            number("Scroll-off", c.scrollOff, range: Config.scrollOffRange,
                   detail: "Rows kept between the cursor and the top/bottom edge") { $0.scrollOff = $1 },
            toggle("Block Mode", c.blockMode,
                   detail: "At column 0 a structured line stays rendered until you move into it") { $0.blockMode.toggle() },
            toggle("Contextual Hints", c.contextHelp, detail: "Status-bar hints for the line under the cursor") { $0.contextHelp.toggle() },
            choice("Sidebar", get: { $0.sidebar }, options: [SidebarMode.off, .outline, .files],
                   label: { $0.rawValue.capitalized },
                   detail: "Docked left panel: document outline or file explorer") { $0.sidebar = $1 },
            PaletteCommand(title: "Focus Mode", shortcut: "[\(host?.focusModeLabel.capitalized ?? "Off")]", keepsOpen: true,
                           detail: "Dim everything but the current line or word (this session only)") { [weak self] in
                self?.host?.cycleFocusMode()
            },
        ]
        if c.vimMode {
            cmds.append(.spacer)
            cmds.append(.header("Vim"))
            cmds.append(toggle("Ignore Case", c.vim.ignoreCase,
                               detail: "Default for :set ignorecase (case-insensitive / searches)") { $0.vim.ignoreCase.toggle() })
            cmds.append(toggle("Smart Case", c.vim.smartCase,
                               detail: "Default for :set smartcase (an uppercase letter makes a search case-sensitive)") { $0.vim.smartCase.toggle() })
            cmds.append(toggle("System Clipboard", c.vim.systemClipboard,
                               detail: "Yank/delete/put use the system clipboard (clipboard=unnamedplus)") { $0.vim.systemClipboard.toggle() })
            let n = c.vim.startupCommands.count
            cmds.append(PaletteCommand(title: "Startup Commands", shortcut: "[\(n) command\(n == 1 ? "" : "s")]",
                                       keepsOpen: true,
                                       detail: "Ex commands run at start (mappings, :set) — edit vim.startupCommands in config.json",
                                       action: {}))
        }
        return cmds
    }

    func appearanceCommands() -> [PaletteCommand] {
        return [
            choice("Theme", get: { ConfigPanel.themeName(of: $0) }, options: ThemeName.allCases, label: { $0.displayName },
                   detail: "Colour theme (previews as you move through the list)") { $0.theme = $1.rawValue },
            choice("Appearance", get: { ConfigPanel.appearance(of: $0) }, options: Appearance.allCases, label: { $0.displayName },
                   detail: "Light, dark, or follow the terminal") { $0.appearance = $1.rawValue },
            choice("Status Bar", get: { $0.statusBarBig }, options: [true, false],
                   label: { $0 ? "Big" : "Slim" },
                   detail: "Boxed three-row status bar or a single slim row") { $0.statusBarBig = $1 },
        ]
    }

    func markdownCommands() -> [PaletteCommand] {
        let c = config
        return [
            choice("Rendered / Raw View", get: { $0.renderMarkdown }, options: [true, false],
                   label: { $0 ? "Rendered" : "Raw" },
                   detail: "Render Markdown inline or show the source as-is") { $0.renderMarkdown = $1 },
            toggle("Full Tables", c.fullTable, detail: "Draw full borders around table rows") { $0.fullTable.toggle() },
            toggle("Align Tables", c.alignTables, detail: "Pad every table to the widest table's width") { $0.alignTables.toggle() },
        ]
    }

    func aiCommands() -> [PaletteCommand] {
        let ai = config.ai
        var cmds: [PaletteCommand] = [
            toggle("Enable AI Features", ai.enabled,
                   detail: "Off: no AI services start and no AI requests are made. Credentials are kept.") { $0.ai.enabled.toggle() },
            .spacer,
            choice("Provider", get: { $0.ai.provider }, options: LLMProvider.allCases, label: { $0.displayName },
                   detail: "Which service handles AI requests") { $0.ai.provider = $1 },
        ]
        switch ai.provider {
        case .lmStudio:
            cmds.append(text("Endpoint", ai.endpoint, shown: ai.endpoint,
                             detail: "Base URL of the OpenAI-compatible server",
                             validate: { ConfigCodec.validateEndpoint($0) }) { $0.ai.endpoint = $1 })
            cmds.append(text("Model", ai.model ?? "", shown: ai.model ?? "\(AIConfig.defaultLMStudioModel) (default)",
                             detail: "Model name as the server knows it (empty = default)") { $0.ai.model = $1.isEmpty ? nil : $1 })
        case .openRouter:
            cmds.append(text("Model", ai.openRouterModel ?? "",
                             shown: ai.openRouterModel ?? "\(AIConfig.defaultOpenRouterModel) (default)",
                             detail: "OpenRouter model id, e.g. openai/gpt-4o-mini") { $0.ai.openRouterModel = $1.isEmpty ? nil : $1 })
            cmds.append(secret("API Key", isSet: !(ai.openRouterKey ?? "").isEmpty,
                               detail: "OpenRouter API key (stored in config.json, shown masked)") { $0.ai.openRouterKey = $1.isEmpty ? nil : $1 })
        case .openaiOAuth:
            cmds.append(text("Model", ai.openAIModel ?? "",
                             shown: ai.openAIModel ?? "\(AIConfig.defaultOpenAIModel) (default)",
                             detail: "OpenAI model id (empty = $OPENAI_MODEL or the default)") { $0.ai.openAIModel = $1.isEmpty ? nil : $1 })
            cmds.append(PaletteCommand(title: "Account", shortcut: ai.openAISignedIn ? "[Signed in]" : "[Not signed in]",
                                       keepsOpen: true, detail: "OpenAI sign-in status", action: {}))
        case .mock:
            cmds.append(PaletteCommand(title: "Mock provider", shortcut: "[Offline]",
                                       detail: "Upper-cases the section: exercises the review flow without a server", action: {}))
        }
        cmds.append(.spacer)
        if ai.provider == .openaiOAuth {
            if ai.openAISignedIn {
                cmds.append(PaletteCommand(title: "[Sign Out of OpenAI]", shortcut: "", keepsOpen: true,
                                           detail: "Forget the stored OpenAI tokens") { [weak self] in self?.host?.signOutOfOpenAI() })
            } else if host?.openAISignInSupported == true {
                cmds.append(PaletteCommand(title: "[Sign In to OpenAI]", shortcut: "", keepsOpen: true,
                                           detail: "Browser sign-in (needs OPENAI_OAUTH_CLIENT_ID)") { [weak self] in self?.host?.signInToOpenAI() })
            }
        }
        cmds.append(PaletteCommand(title: "[Test Connection]", shortcut: ai.enabled ? "" : "AI off", keepsOpen: true,
                                   detail: ai.enabled ? "Check that the provider is reachable"
                                                      : "Enable AI first — nothing is contacted while it's off") { [weak self] in
            self?.host?.testAIConnection()
        })
        return cmds
    }

    func fileCommands() -> [PaletteCommand] {
        guard let store = host?.configStore else { return [] }
        var cmds: [PaletteCommand] = [.header(Vault.displayPath(store.path))]
        if let error = store.lastError {
            cmds.append(.header("⚠ \(error.localizedDescription)"))
        }
        for issue in store.issues.prefix(8) {
            cmds.append(.header("⚠ \(issue)"))
        }
        cmds += [
            PaletteCommand(title: "[Open Config File]", shortcut: "",
                           detail: "Edit config.json in a new tab; saving it applies the changes") { [weak self] in
                self?.host?.openConfigFile()
            },
            PaletteCommand(title: "[Reload Config From Disk]", shortcut: "", keepsOpen: true,
                           detail: "Re-read config.json and apply it without restarting") { [weak self] in
                self?.host?.reloadConfigFromDisk()
            },
            PaletteCommand(title: "[Reset to Defaults]", shortcut: "→",
                           detail: "Restore every setting's default (keeps AI credentials and recent vaults)",
                           submenu: { [weak self] in self?.resetConfirmCommands() ?? [] }, action: {}),
        ]
        return cmds
    }

    private func resetConfirmCommands() -> [PaletteCommand] {
        [
            .header("Reset all settings to their defaults?"),
            PaletteCommand(title: "Reset", shortcut: "", keepsOpen: true) { [weak self] in
                self?.host?.resetConfigToDefaults()
            },
            PaletteCommand(title: "Cancel", shortcut: "", keepsOpen: true, action: {}),
        ]
    }

    // MARK: - Row builders

    static func themeName(of config: Config) -> ThemeName {
        config.theme.flatMap(ThemeName.init(rawValue:)) ?? .clay
    }

    static func appearance(of config: Config) -> Appearance {
        config.appearance.flatMap(Appearance.init(rawValue:)) ?? .auto
    }

    private func section(_ title: String, summary: String, detail: String,
                         _ generate: @escaping () -> [PaletteCommand]) -> PaletteCommand {
        let label = summary.isEmpty ? "→" : (summary.hasPrefix("[") ? "\(summary) →" : "[\(summary)] →")
        return PaletteCommand(title: title, shortcut: label, detail: detail, submenu: generate, action: {})
    }

    private func toggle(_ title: String, _ value: Bool, detail: String,
                        _ flip: @escaping (inout Config) -> Void) -> PaletteCommand {
        PaletteCommand(title: title, shortcut: value ? "[Enabled]" : "[Disabled]", keepsOpen: true,
                       detail: detail) { [weak self] in
            self?.host?.changeConfig(flip)
        }
    }

    private func number(_ title: String, _ value: Int, range: ClosedRange<Int>, detail: String,
                        _ set: @escaping (inout Config, Int) -> Void) -> PaletteCommand {
        PaletteCommand(title: title, shortcut: "[\(value)]", keepsOpen: true,
                       detail: "\(detail) (\(range.lowerBound)–\(range.upperBound))") { [weak self] in
            self?.host?.promptInput(
                prompt: "\(title) (\(range.lowerBound)–\(range.upperBound))", value: "\(value)", isSecret: false,
                validate: { text in
                    guard let n = Int(text.trimmingCharacters(in: .whitespaces)) else { return "Enter a whole number" }
                    return range.contains(n) ? nil : "Must be between \(range.lowerBound) and \(range.upperBound)"
                },
                onSubmit: { [weak self] text in
                    guard let n = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
                    self?.host?.changeConfig { set(&$0, n) }
                })
        }
    }

    private func text(_ title: String, _ value: String, shown: String, detail: String,
                      validate: ((String) -> String?)? = nil,
                      _ set: @escaping (inout Config, String) -> Void) -> PaletteCommand {
        PaletteCommand(title: title, shortcut: "[\(shown)]", keepsOpen: true, detail: detail) { [weak self] in
            self?.host?.promptInput(prompt: title, value: value, isSecret: false, validate: validate) { [weak self] text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                self?.host?.changeConfig { set(&$0, trimmed) }
            }
        }
    }

    /// A credential: the value is never displayed, only whether it's set, and
    /// the input field masks it.
    private func secret(_ title: String, isSet: Bool, detail: String,
                        _ set: @escaping (inout Config, String) -> Void) -> PaletteCommand {
        PaletteCommand(title: title, shortcut: isSet ? "[Configured]" : "[Not set]", keepsOpen: true,
                       detail: detail) { [weak self] in
            self?.host?.promptInput(prompt: "\(title) (empty to remove)", value: "", isSecret: true, validate: nil) { [weak self] text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                self?.host?.changeConfig { set(&$0, trimmed) }
            }
        }
    }

    /// An enumerated setting: the row shows the current value and opens a
    /// submenu of options (the current one marked). Choosing keeps the submenu
    /// open so themes preview live; Esc returns.
    private func choice<T: Equatable>(_ title: String, get: @escaping (Config) -> T, options: [T],
                                      label: @escaping (T) -> String, detail: String,
                                      _ set: @escaping (inout Config, T) -> Void) -> PaletteCommand {
        PaletteCommand(title: title, shortcut: "[\(label(get(config)))] →", detail: detail, submenu: { [weak self] in
            guard let self = self else { return [] }
            let now = get(self.config)
            return options.map { option in
                PaletteCommand(title: label(option), shortcut: option == now ? "● current" : "", keepsOpen: true,
                               detail: detail) { [weak self] in
                    self?.host?.changeConfig { set(&$0, option) }
                }
            }
        }, action: {})
    }
}
