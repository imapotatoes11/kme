# kme agent guide

This repository is a Swift Package Manager (SPM) project for a
terminal-based Markdown editor. The codebase is small and mostly lives
under Sources/kme.

If there are cursor or copilot rules, follow them first. None were found
in this repo.

## Build, run, test

Build (debug):
- swift build

Run (debug):
- swift run kme path/to/file.md
- ./.build/debug/kme path/to/file.md

Build (release):
- swift build -c release

Run (release):
- ./.build/release/kme path/to/file.md

Tests:
- swift test
- On this machine plain `swift build`/`swift test` may hit a beta-SDK issue; use
  the Command Line Tools SDK: `xcrun --sdk macosx swift test`.
- Test target: `kmeTests` (Tests/kmeTests), `@testable import kme`.

Single test:
- swift test --filter <TestCase>/<testMethod>
- Example: swift test --filter RenderTests/testWrappedRowsWithEmojiNeverExceedWidth

Lint/format:
- No lint or formatter configured (no SwiftLint or SwiftFormat config).
- Do not introduce new tooling without asking.

## Repo layout

- Package.swift: SPM manifest (Swift 5.9, macOS 12+).
- Sources/kme/main.swift: CLI entry point.
- Sources/kme/App: editor app lifecycle and rendering.
- Sources/kme/Models: editor state and data models.
- Sources/kme/Services: network and OAuth integration.
- Sources/kme/Views: TUI overlays and panels (CommandPanel, ConfigPanel).
- Sources/kme/Utils: key bindings, theming, markdown parsing.
- Sources/kme/Vim: optional Vim mode — VimEngine (modes, parser,
  operators, registers), VimExCommands (`:` commands), VimText (pure motion /
  text-object math), VimRegex (Vim pattern → ICU), VimKey (input tokens).

## Releasing

- See RELEASING.md for the full process and caveats. In short: macOS is a manual
  signed/notarised local build (scripts/release.sh); the static Linux binaries
  (x86_64 + aarch64) are built in CI on tag (.github/workflows/release.yml via
  scripts/release-linux.sh). install.sh downloads the prebuilt for the platform
  and falls back to building from source.
- The Static Linux SDK version must match the Swift toolchain version exactly
  (currently Swift 6.3.2 / static-linux 0.1.0); bump them together.

## Configuration and runtime behavior

- User config file: ~/.config/kme/config.json ($KME_CONFIG overrides).
  `ConfigStore.shared` owns it: typed `Config`, per-key validation, patch
  saves (`update { $0.x = … }`), atomic writes, reload. Never write the file
  directly. See CONFIGURATION.md.
- AI is optional (`ai.enabled`, default off for new installs). With it off,
  EditorApp creates no LLMService / LLMModal / OpenAIOAuth.
- LLM provider defaults to LM Studio (`ai.endpoint`, http://localhost:1234).
- OpenAI OAuth is optional and driven by env vars.
- Vim mode (`vimMode`) routes input through VimEngine; see VIM_MODE.md.

## Memory policy (SimpleMem)

- Before responding, if user/project context is missing: query memory (search).
- After important decisions (naming, architecture, preferences): store a short summary (add).
- Do not store secrets, tokens, or sensitive data.

## Code style and conventions

### Imports

- Prefer the minimal set of imports per file.
- Standard pattern is `import Foundation` first.
- Keep imports at the very top of the file, no blank lines above.

### Formatting

- Indent with 4 spaces.
- Keep line length reasonable; wrap long parameter lists.
- One blank line between type definitions and major sections.
- No trailing whitespace.
- Use trailing commas only where already present (rare here).

### Types and structure

- Use `struct` for plain data (e.g., models, spans).
- Use `class` for stateful services and controllers.
- Prefer `final class` unless subclassing is required.
- Use `enum` for finite states and configuration options.
- Keep helper types `private` or file-scoped where possible.

### Naming

- Types: PascalCase (EditorState, LLMService).
- Members and functions: lowerCamelCase (toggleViewMode).
- Enum cases: lowerCamelCase (openaiOAuth, processing).
- Use descriptive, domain-specific names over abbreviations.

### Access control

- Default to `private` for helpers and internal state.
- Expose only what other modules need.
- Use `private(set)` for publicly readable but internally mutable state.

### Optionals and guards

- Prefer `guard` for early returns.
- Avoid force unwraps; use `if let` or `guard let`.
- Treat optional state explicitly (e.g., selectionRange).

### Error handling

- Use `Result` and `LocalizedError` for user-facing operations.
- Map network failures to typed errors (see LLMError, OAuthError).
- Avoid silent failures unless intentionally non-fatal.
- If you must ignore an error, add a brief reason.

### Concurrency and callbacks

- UI/state updates should occur on the main queue.
- Use `[weak self]` in escaping closures to avoid retain cycles.
- Avoid adding async/await unless used consistently across files.

### State management

- EditorState is the single source of truth for UI state.
- Keep view rendering pure: compute strings from state.
- Update config via ConfigStore.shared.update { … } (or the app's
  changeConfig, which also applies it to every tab) when settings change.

### Rendering and terminal output

- ANSI escape sequences are hand-crafted in Theme and renderers.
- Preserve existing escape handling for width calculations.
- When updating render logic, keep cursor placement exact.

### Parsing and text editing

- Markdown parsing is minimal and inline; keep it simple and fast.
- For spans, keep raw vs content indexes consistent.
- Editing operations should preserve the trailing empty line.

### Networking

- OpenAI and LM Studio use OpenAI-compatible endpoints.
- Keep timeouts explicit (see LLMService).
- Use URLSession with completion handlers for now.

### Files and paths

- Use absolute paths only where required (config location).
- For file IO, prefer Foundation APIs with explicit encoding.

### Comments and docs

- Use `///` only for public-facing types or complex behavior.
- Avoid inline comments for obvious code.

## Testing policy (required for every change)

Every modification — feature, fix, or refactor — MUST ship with a test that
fails before the change and passes after, and `swift test` MUST be green before
the work is considered done. No exceptions for "it's just a one-liner".

- Reproduce first: write the failing test that captures the bug/behavior, then
  fix. This is how the wrap, ordered-list, and heading-emphasis bugs were caught.
- Prefer deterministic tests over manual/PTY checks. Rendering is testable
  headlessly via `EditorApp.renderContentLinesForTest(width:height:)`, which runs
  the real wrap/markup paths and returns the content rows as strings.
  - `RenderTests.plain(_:)` strips ANSI; assert on visible text.
  - For layout, assert each row's `.displayWidth` fits the padded budget (wide
    glyphs like emoji/CJK count as 2 columns — see RenderTests).
- Pure logic (parsing, file state) gets direct unit tests: see MarkupTests
  (MarkdownHTML / heading emphasis) and ReloadTests (external-change + reload).
- When adding a render/markup/parse seam, expose a minimal `internal` hook so the
  test target can reach it via `@testable` rather than loosening `private`.
- Tests that touch settings must use a throwaway store
  (`ConfigStore.shared = ConfigStore(path: tmp)`), never the real config.
- Vim tests subclass `VimTestCase` and drive keys with `app.vimKeysForTest`
  (Vim notation: `ciwfoo<Esc>`, `<C-r>`); `processInputForTest` delivers raw
  terminal input without the lone-ESC hold.

## Adding new features

- Follow the existing layout: Models, Services, Views, Utils.
- Keep the TUI responsive; avoid blocking work on the main thread.
- Add configuration flags to Config with sensible defaults.
- Add or update tests alongside the change (see Testing policy).

## Notes for agents

- No Cursor or Copilot rule files are present in the repo.
- The executable target is `kme`; tests live in the `kmeTests` target.
- Keep changes minimal and consistent with the current style.
- Use english for git messages.
- Use english for code and comments.
