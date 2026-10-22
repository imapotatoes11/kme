# Vim mode

An optional modal editing layer. The WYSIWYG editor stays exactly as it is:
Markdown still renders live, list items continue on `Enter`, tasks toggle,
and every non-Vim feature (tabs, vault, outline, AI review) works the same.

Turn it on in **Settings → Editor → Vim Mode** (`Ctrl+P` → Settings), or set
`"vimMode": true` in `~/.config/kme/config.json`. It applies immediately.
`:config` opens the settings from inside Vim mode.

The status bar shows the mode (`NORMAL`, `INSERT`, `REPLACE`, `VISUAL`,
`V-LINE`), a half-typed command (`2d`), `recording @q` while recording a
macro, and the command line itself while you type `:` / `/` / `?`.

## What's supported

**Modes:** Normal, Insert, Replace (`R`), Visual (`v`), Visual Line (`V`),
command line (`:`, `/`, `?`), Ctrl+O (one Normal command from Insert).

**Counts** everywhere they make sense (`3dd`, `d3w`, `2d3w`, `5x`, `3p`,
`4J`, `3ia<Esc>`, `2@q`, `3.`), and **registers** (`"a`–`"z`, `"A`–`"Z`
append, `"0` last yank, `"1`–`"9` delete ring, `"-` small delete, `"_` black
hole, `"+`/`"*` system clipboard, read-only `".` `":` `"/` `"%`).

### Motions

| Keys | Motion |
| --- | --- |
| `h` `j` `k` `l`, arrows, `Space`, `Backspace` | Character / line |
| `w` `W` `b` `B` `e` `E` `ge` `gE` | Words and WORDs (empty lines count as words, as in Vim) |
| `0` `^` `$` `g_` `\|` | Line start, first non-blank, end, last non-blank, column |
| `+` `-` `Enter` `_` | First non-blank of next / previous / current line |
| `gg` `G` `{N}G` `{N}gg` `{N}%` | Lines and percentage |
| `f` `F` `t` `T` `;` `,` | Character in line, and repeat |
| `%` | Matching `()` `[]` `{}` (across lines) |
| `{` `}` `(` `)` | Paragraphs and sentences |
| `H` `M` `L` | Top / middle / bottom of the window |
| `/` `?` `n` `N` `*` `#` `g*` `g#` | Search (incremental; Vim regex syntax) |
| `'{a}` `` `{a} `` `''` ` `` ` `'<` `'>` `'.` `'^` | Marks |
| `gj` `gk` | Display lines (follow word wrap) |
| `Ctrl+O` / `Tab` | Jump list back / forward |
| `g;` `g,` | Change list back / forward |

Search offsets work: `/foo/e`, `/foo/e-1`, `/foo/s+2`, `/foo/b`, `/foo/+1`.

### Operators and text objects

Operators: `d` `c` `y` `>` `<` `g~` `gu` `gU` `g?` `gq` `gw`, combined with
any motion, doubled for whole lines (`dd`, `cc`, `yy`, `>>`, `guu`, `gUU`,
`g~~`, `gqq`), or with a text object. `gq` / `gw` re-wrap to `textwidth`
(79 when 0), keeping a list marker or quote bar on the first line and
indenting the rest to match.

Text objects:

`iw` `aw` `iW` `aW` `is` `as` `ip` `ap` `i(` `a(` `ib` `ab` `i[` `a[` `i{`
`a{` `iB` `aB` `i<` `a<` `i"` `a"` `i'` `a'` `` i` `` `` a` ``

Vim's operator rules are followed: `cw` changes to the end of the word,
`dw` on the last word of a line doesn't join lines, exclusive motions ending
in column 0 become inclusive / linewise (`d}`), `d/pattern<CR>` works.

### Editing commands

`i` `a` `I` `A` `gi` `gI` `o` `O` `x` `X` `s` `S` `C` `D` `Y` `p` `P` `gp`
`gP` `J` `gJ` `r{c}` `R` `~` `u` `Ctrl+R` `.` `Ctrl+A` `Ctrl+X` `&` `g&`
`q{reg}` … `q` `@{reg}` `@@` `@:` `m{a-zA-Z}` `ZZ` `ZQ`.

`o` / `O` continue a Markdown list item or quote the way `Enter` does
(`- item` → `- `, `- [x] done` → `- [ ] `).

**Insert mode:** `Esc` / `Ctrl+[` / `Ctrl+C`, `Backspace` / `Ctrl+H`,
`Ctrl+W`, `Ctrl+U`, `Ctrl+T` / `Ctrl+D` (indent / outdent line), `Ctrl+R
{reg}`, `Ctrl+A` (repeat last insert), `Ctrl+E` / `Ctrl+Y` (copy char from
below / above), `Ctrl+V {key}` (literal), `Ctrl+O`, arrows, `Home`, `End`,
`Delete`, `Ctrl+N` / `Ctrl+P` (complete a word from the document; press again
to cycle). `Enter` and `Tab` keep their WYSIWYG behaviour (list continuation,
task cycling, heading promotion).

**Visual mode:** motions and text objects extend the selection; `o` swaps
ends; `d` `x` `X` `D` `y` `Y` `c` `s` `C` `S` `R` `r{c}` `J` `gJ` `~` `u` `U`
`g~` `gu` `gU` `g?` `>` `<` `p` `P` `I` `A` `:` `gv`. A mouse drag starts a
Visual selection.

**Scrolling:** `Ctrl+D` `Ctrl+U` `Ctrl+F` `Ctrl+B` `Ctrl+E` `Ctrl+Y` `zz`
`zt` `zb` `z.` `z<CR>` `z-`. Other: `Ctrl+G` (file info), `ga` (character
code), `gt` / `gT` / `{N}gt` (tabs), `Ctrl+^` (alternate file), `gx` / `gf`
(follow the link under the cursor).

### Undo

An Insert session is one undo step, and so is every compound command: a
counted command (`3dd`, `4J`), a change plus what you typed (`ciwfoo<Esc>`),
a `.` repeat, a macro run, and every Ex command (`:%s`, `:g`, `:normal`).

### Ex commands

Ranges: `N`, `.`, `$`, `%`, `'a`, `'<,'>`, `/pat/`, `?pat?`, `+N`, `-N`,
`a,b`, `a;b`. Commands can be chained with `|`.

| Command | |
| --- | --- |
| `:w [file]` `:w!` `:{range}w file` `:wq` `:x` `:up` `:wa` `:q` `:q!` `:qa` `:wqa` `:xa` | Write / quit (`:q` closes the tab; the last tab quits) |
| `:e[!] [file]` `:tabe file` `:r file` `:f` `:pwd` | Files |
| `:s/pat/rep/[gieIn] [count]` `:&` `:&&` `:~` | Substitute (`&`, `\0`–`\9`, `\r`, `\u` `\U` `\l` `\L` `\e` in the replacement) |
| `:g/pat/cmd` `:g!/pat/cmd` `:v/pat/cmd` | Global (default command `p` lists the lines) |
| `:d [x] [N]` `:y [x] [N]` `:pu[!] [x]` `:m {addr}` `:t {addr}` `:co {addr}` `:j[!]` `:>` `:<` | Lines |
| `:norm[al][!] {keys}` | Run Normal keys on each line of the range |
| `:sort[!] [n] [u] [i]` `:retab[!] [N]` | Sort, retab |
| `:u` `:red` `:noh` `:startinsert[!]` | |
| `:k{a}` `:ma {a}` `:marks` `:reg [names]` `:jumps` `:ls` `:mes` `:ve` `:=` `:p` `:nu` `:#` `:echo` | Info (lists open in the panel) |
| `:bn` `:bp` `:b N` `:bd` `:tabn [N]` `:tabp` `:tabfirst` `:tablast` `:tabc` | Tabs |
| `:set` `:set all` | Options (below) |
| `:map` `:nmap` `:vmap` `:xmap` `:omap` `:imap` `:cmap`, `:noremap` `:nnoremap` `:vnoremap` `:xnoremap` `:onoremap` `:inoremap` `:cnoremap`, `:unmap` … `:mapclear` | Key mappings (below) |
| `:config` `:help` `:o` `:find` | Settings, shortcuts help, quick file switcher |
| `:{N}` | Go to line |

Command line editing: `Backspace`, `Ctrl+W`, `Ctrl+U`, `Ctrl+R {reg}`,
`Ctrl+R Ctrl+W` (word under cursor), `↑` / `↓` history, `Esc`.

### Options (`:set`)

`number`/`nu`, `wrap`, `tabstop`/`ts`, `scrolloff`/`so` change the editor
setting of the same name and are saved like any other setting.
`ignorecase`/`ic`, `smartcase`/`scs`, `wrapscan`/`ws`, `incsearch`/`is`,
`expandtab`/`et`, `shiftwidth`/`sw`, `autoindent`/`ai`, `textwidth`/`tw`,
`relativenumber`/`rnu`, `clipboard=unnamedplus` last for the session; set
their defaults (ignore case, smart case, system clipboard) in **Settings →
Editor → Vim**, or put `:set` lines in `vim.startupCommands`. Forms: `opt`,
`noopt`, `opt!`, `invopt`, `opt?`, `opt=N`. `hlsearch`, `softtabstop`,
`timeoutlen` are accepted for compatibility but have no effect.

### Mappings and startup commands

`:inoremap jk <Esc>`, `:nnoremap <leader>w :w<CR>`, `:onoremap p i(` … work
as in Vim: recursive (`map`) or not (`noremap`), per mode (Normal, Visual,
operator-pending, Insert, command line), with `<Leader>` = `\`, the usual key
notation, and a 1-second timeout when a typed key could start a longer
mapping. Normal/Visual mappings apply at the start of a command; a character
argument (after `f`, `r`, `m`…) is never mapped. `<silent>` / `<buffer>` /
`<nowait>` are accepted and ignored; `<expr>` isn't supported.

To keep mappings and options across sessions, list Ex commands in
`vim.startupCommands` in config.json — a small vimrc:

```json
"vim": { "startupCommands": ["inoremap jk <Esc>", "set ic scs", "nnoremap <leader>w :w<CR>"] }
```

## Shortcut conflicts

In Vim mode a key means what it means in Vim. The editor shortcuts that don't
collide stay available between commands (never in the middle of one):

| Key | In Vim mode |
| --- | --- |
| `Ctrl+S` | Save (also `:w`) |
| `Ctrl+Q` | Quit (also `:q`, `:qa`) |
| `Ctrl+P` | Command palette (in Insert mode: completion, with `Ctrl+N`) |
| `Ctrl+K` | Vault search |
| `Ctrl+Space` | AI assist (when AI is enabled; uses the Visual selection) |
| `Ctrl+/` | Keyboard shortcuts (includes a Vim section) |
| `Ctrl+]` | Follow link |
| `Ctrl+T` | Normal/Visual: cycle task state. Insert: indent |

Taken over by Vim: `Ctrl+R` (redo, not raw view — use **Settings → Markdown**
or `:set` equivalents), `Ctrl+D` / `Ctrl+U` (scroll, not quit / undo),
`Ctrl+F` / `Ctrl+B` (page, not find / focus mode — use `/`), `Ctrl+O` (jump
back, not open file — use `:e`, `:o`), `Ctrl+A` / `Ctrl+X` (increment, not
select all / cut), `Ctrl+V` (literal insert; Visual block isn't supported),
`Ctrl+E` / `Ctrl+Y` (scroll), `Ctrl+G` (file info), `Ctrl+L` (redraw, not
line numbers — use `:set nu`), `Ctrl+N` / `Ctrl+J` (down; in Insert, `Ctrl+N` completes and `Ctrl+J` is Enter), `Ctrl+W` / `Ctrl+H`
(Insert-mode delete), `Esc` (Normal mode, not "previous file" — use `Ctrl+^`
or `:bp`). With Vim mode off, every key behaves as before.

## Markdown and the cursor

Vim works on the raw text, so a motion's column is a column in the source.
When the cursor enters a collapsed span (`**bold**`, `[link](url)`), that line
shows raw and the block cursor sits on the exact source character; leaving it
collapses it again. `j` / `k` move by real lines, `gj` / `gk` by wrapped
display lines. Wide characters (CJK, emoji) count as one character for motions
and edits. The editor's trailing empty "final newline" line isn't a Vim line,
so `G` and `$` ranges stop at the last real line.

## Not supported (yet)

Skipped deliberately, mostly because they need UI the editor doesn't have or
don't fit a single-pane Markdown editor:

- **Visual block mode** (`Ctrl+V`) and block operations: the renderer only
  draws one contiguous selection.
- **Windows and splits** (`Ctrl+W …`, `:split`, `:vsplit`): tabs only.
- **Abbreviations** (`:ab`), a vimrc file / `:source` (use
  `vim.startupCommands`), `:let`, expressions and Vimscript, `<expr>`
  mappings, `=` registers.
- **Shell access** (`:!cmd`, `:r !cmd`, `:w !cmd`, `!` filter operator).
- **Folding** (`zf`, `zo`, …), **spell checking**, a completion popup and the
  `Ctrl+X` sub-modes (plain `Ctrl+N` / `Ctrl+P` word completion works),
  digraphs (`Ctrl+K` stays the vault).
- **Search highlighting** (`hlsearch`), `\zs` / `\ze`, multi-line patterns,
  `:s` with the `c` (confirm) flag, `:sort /pat/`, offsets on `n` / `N` after
  an `e` offset backwards.
- **Undo tree** (`g-`, `g+`, `:earlier`, `:later`), `U` (undo line),
  persistent undo.
- `=` (reindent), `K`, `it` / `at` (tag objects), `:changes` (the list
  itself; `g;` / `g,` work), Ex mode (`Q`), `:saveas`, `:enew`.
- Marks don't shift when lines above them are inserted or deleted, and `.`
  after a multi-line charwise Visual operation re-selects an approximation of
  the original region.
