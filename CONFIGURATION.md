# Configuration

editxr has one configuration: `~/.config/editxr/config.json` (or the path in
`$EDITXR_CONFIG`). The settings menu and the file always describe the same
state. Use whichever you like:

- **Settings menu:** `Ctrl+P` → **Settings**, or `:config` in Vim mode. Arrows
  or `j` / `k` move, `Enter` / `l` selects or edits, `h` / `Esc` goes back,
  `/` searches. Toggles flip in place, choices open a list (current one
  marked), numbers and text open an input with validation. Changes apply
  immediately and are saved.
- **The file:** **Settings → Configuration → Open Config File** opens it in a
  tab (creating it with every key if it doesn't exist yet); saving the tab
  applies it. Edits from any other editor are picked up within a couple of
  seconds, or immediately with **Reload Config From Disk**.

## How the file is handled

- **Partial files are fine.** Every key is optional; a missing key takes its
  default. `{}` is a valid config.
- **Invalid values are reported, not fatal.** A wrong type or unknown value is
  ignored (out-of-range numbers are clamped) and listed under **Settings →
  Configuration**. The rest of the file still applies.
- **Invalid JSON is never overwritten.** If the file doesn't parse, the
  previous settings stay in effect, the error is shown, and setting changes
  apply for the session only until the file is fixed.
- **Your edits are kept.** Saving a setting re-reads the file and changes only
  that key, so hand edits made in the meantime survive. Keys editxr doesn't
  know are preserved.
- **Saves are atomic** (temp file + rename) and keep the file's permissions; a
  new file is created owner-only (`0600`) because it may hold API keys.
- **Secrets stay out of output.** Keys and tokens are masked in the UI and
  never echoed in error messages.

## Keys

| Key | Default | |
| --- | --- | --- |
| `vimMode` | `false` | Vim-style modal editing (see VIM_MODE.md) |
| `wordWrap` | `true` | Wrap long lines |
| `showLineNumbers` | `false` | Line-number gutter |
| `scrollPastEnd` | `true` | Allow scrolling half a screen past the last line |
| `tabWidth` | `8` | Tab display width, 1–16 |
| `leftMargin` | `1` | Blank columns left of the text, 0–8 |
| `scrollOff` | `4` | Rows kept between cursor and edge, 0–20 |
| `blockMode` | `true` | Structured lines stay rendered at column 0 |
| `contextHelp` | `true` | Status-bar hints for the current line |
| `sidebar` | `"off"` | `"off"`, `"outline"`, or `"files"` |
| `theme` | `"clay"` | A theme name (see Settings → Appearance) |
| `appearance` | `"auto"` | `"auto"`, `"light"`, or `"dark"` |
| `statusBarBig` | `true` | Boxed (`true`) or slim (`false`) status bar |
| `renderMarkdown` | `true` | Rendered (`true`) or raw (`false`) view |
| `fullTable` | `true` | Full table borders |
| `alignTables` | `true` | Pad tables to the widest one |
| `vaultPath` | — | Vault folder (absent: follow the open file) |
| `recentVaults` | — | Most-recent-first list |
| `vaultSemanticSearch` | `true` | |
| `vaultEmbedBackend` | `"auto"` | |
| `vaultIncludeTxt` | `true` | |
| `vaultIndexOnOpen` | `true` | |
| `vaultMaxResults` | `10` | 1–50 |
| `ai.enabled` | `false` | AI features on/off (see below) |
| `ai.provider` | `"lmStudio"` | `"lmStudio"`, `"openaiOAuth"`, `"openRouter"`, `"mock"` |
| `ai.endpoint` | `"http://localhost:1234"` | Base URL for the LM Studio provider |
| `ai.model` | — | LM Studio model (absent: `qwen2.5-7b-instruct`) |
| `ai.openAIModel` | — | OpenAI model (absent: `$OPENAI_MODEL`, then `gpt-4o-mini`) |
| `ai.openRouterKey` | — | OpenRouter API key |
| `ai.openRouterModel` | — | OpenRouter model (absent: `openai/gpt-4o-mini`) |
| `ai.openAIAccessToken`, `ai.openAIRefreshToken`, `ai.openAIExpiresAt` | — | Written by OpenAI sign-in |
| `vim.ignoreCase` | `false` | Default for `:set ignorecase` |
| `vim.smartCase` | `false` | Default for `:set smartcase` |
| `vim.systemClipboard` | `false` | Unnamed register uses the system clipboard |
| `vim.startupCommands` | `[]` | Ex commands run when Vim mode starts (mappings, `set …`) |

Focus mode is per session and isn't saved.

Example:

```json
{
  "vimMode": true,
  "tabWidth": 4,
  "theme": "nord",
  "ai": {
    "enabled": true,
    "provider": "lmStudio",
    "endpoint": "http://192.168.1.20:1234",
    "model": "llama-3.1-8b-instruct"
  },
  "vim": { "ignoreCase": true, "smartCase": true }
}
```

## AI is optional

With `ai.enabled` off, no AI service is created and no AI request is made; the
AI actions, `Ctrl+Space` and the provider label are hidden, and **Test
Connection** refuses to run. The editor needs no network and no AI
configuration. Provider, model and credentials stay in the file, so turning AI
back on restores them. All AI configuration lives in **Settings → AI**.

## Migrating from earlier versions

Older configs (flat `llmProvider`, `openRouterKey`, `openRouterModel`,
`openAIAccessToken`, `openAIRefreshToken`, `openAIExpiresAt` keys; legacy
`showOutline`) are read as before. A config without an `ai` section was
written by a version where AI was always on, so it migrates with `ai.enabled:
true` and its provider and credentials intact; a fresh install starts with AI
off. On the next save the AI keys move into the `ai` section and the legacy
keys are removed; everything else is kept.

## Breaking changes

- The command palette's **Editor settings**, **LLM settings**, **Theme &
  appearance** and **Vault settings** submenus are replaced by one
  **Settings** entry (their rows still turn up in palette search).
- New installs start with AI disabled.
- After the first save, a config is in the new layout (`ai` section). An
  older editxr reading it won't find its flat AI keys and will use its
  defaults for them; older versions also required `wordWrap` /
  `renderMarkdown` / `llmProvider` to be present, so hand-trimmed partial
  files only work with this version.
