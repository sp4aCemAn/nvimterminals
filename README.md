# nvimterminals

Persistent per-name terminal windows for Neovim — keeps terminals out of your
buffer list so your buffers and tabs stay organized. Doubles as the execution
backend for agents (nvimcp) with explicit, per-terminal command whitelists.

## Features

- `:TermToggle [name]` — open/hide a named terminal (`TermToggle build`, `TermToggle repl`...).
  Each new name spawns a fresh persistent terminal.
- Hidden terminals keep running; reopen with the same command.
- VS Code-style single pane: if a terminal pane is already open, toggling a
  (hidden) terminal switches that pane in place — no windows pile up. A new
  split is only opened when no terminal pane exists. There is exactly one
  terminal pane across all tabs; reusing it jumps to its tab.
- Opening a terminal always takes its own dedicated buffer — your current
  buffer is never replaced or renamed.
- Splitting anchors to your editor window even when you spawn from inside a
  terminal window, so terminals don't cascade nested.
- Terminal buffers are unlisted: they stay out of `:ls`, bufferline, and tab pickers.
- When a terminal's process exits, the terminal is kept as a dead
  `[dead]` entry (scrollback preserved); toggling respawns it cleanly.
  Fires `User NvimterminalsExit` (see Events).
- `<C-\>` toggles the last used terminal (normal + terminal mode).
- `<leader>tt` opens the terminal picker — all terminals listed with
  `[open]` / `[hidden]` / `[dead]` and an `[agent]` marker, like VS Code's
  terminal panel.

## Agent control

AI agents (e.g. nvimcp) can read and drive terminals — but only when the user
explicitly allows it. A send is gated by two switches AND a command whitelist:

```
allowed = config.agent.enabled  AND  terminal.agent_enabled  AND  policy allows the line
```

- `config.agent = { enabled = false, allow = {} }` — global kill switch plus
  the global fallback whitelist. With `enabled = false` no agent can send to
  any terminal, no matter what anything else says.
- `:TermAgent [name]` — toggle agent control for one terminal (the picker
  shows an `[agent]` marker).
- `:TermPolicy [name]` — open/edit a per-terminal whitelist in a dedicated
  scratch buffer `nvimterminals://policy/<name>` (unlisted; one Lua pattern
  per line, highlighted with the shipped `nvimterminals_policy` filetype —
  NOT `lua`, since pattern lines are not Lua code and would light up as
  syntax errors). Edits take effect on the next send — there is nothing to
  save; `:w` is a no-op that just clears the changed flag (the buffer is
  `acwrite`, no file is ever written). Shown in a centered float by default
  (`policy_window = "split"` for the legacy split; a buffer already on screen
  is just focused either way); in the float, `q`, `<Esc>` or `:w` dismiss it
  (splits are never auto-closed, and the buffer — the policy itself — always
  survives the window). While that buffer exists it REPLACES the
  global fallback.
- `M.lines(name, { n = 200 })` — read the terminal's screen lines; read-only
  and deliberately NOT gated by any whitelist.

### Policy file semantics

- Incoming command lines are trimmed, then matched with
  `string.find(line, pattern, 1, false)` (Lua patterns, user-authored).
- `*` — allow anything into this terminal.
- `deny <pattern>` — explicit denies, evaluated BEFORE allows.
- Empty or comment-only (`# ...`) policy — deny everything (safe default).
- A malformed Lua pattern fails CLOSED: a broken allow never grants, a broken
  deny still denies (matched via pcall; sends never raise).
- Each line of a multi-line `send` payload must pass.
- The policy buffer IS the storage: patterns are read fresh on every send.

## Programmatic API (`require("nvimterminals.terminals")`)

`M.send(name, data, opts)` — write raw bytes to the terminal's pty
(chansend; include `\r` yourself to press Enter). `opts.lstrip` (default
false) left-strips each outgoing line; `opts.wait_ms` (default 0) settles
after sending — waits up to that many ms (yielding into nvim's event loop)
for the terminal buffer to commit output anywhere, then a 50ms tail; the
success result gains `settled=true|false`. Returns one of:

```lua
{ ok = true }
{ ok = false, reason = "agent_disabled",   detail = <why> }
{ ok = false, reason = "no_such_terminal", detail = <name / why> }
{ ok = false, reason = "policy_denied",    detail = "<line>" | "pattern: <p>" }
```

The `reason` strings are a stable contract — nvimcp surfaces them as tool
errors. Dead terminals (and unknown names) report `no_such_terminal`.

`M.lines(name, { n = 200 })` — `{ ok = true, name, buf, total, start, end,
lines = { { lnum = <buffer line number>, text = ... }, ... }, dead, running,
pid, exit_code }`; `opts.start` / `opts.count` request an explicit range.
`{ ok = false, reason = "no_such_terminal" }` otherwise.

`M.get(name)` — live runtime state table (`buf, job_id, pid, dead, exit_code,
agent_enabled, policy`) or nil; treat it as read-only. `M.agent_enabled(name)`
is the per-terminal switch getter; `M.agent_toggle(name)` flips it.

`M.rename(name, new)` — rename in place: the state table keeps its IDENTITY
(only the key moves), the `term://` buffer name and the policy buffer follow,
`M.current` follows, and later exit events carry the NEW name. Atomic: all
pre-checks (`no_such_terminal`, `invalid_name`, `same_name`, `terminal_exists`,
`buffer_name_exists`, `policy_name_exists`) run before any mutation; a failure
mid-rename rolls everything back. Returns `(true, new)` or `(false, reason)`.
These reasons belong to the command surface — they are NOT part of the
nvimcp-facing `send/lines` reason contract.

`M.close(name)` — stop the job and forget the terminal (buffer death stays the
only state-drop path). If it held the pane, a successor terminal is swapped
into the SAME window (alphabetically-first live one, else first dead one);
focus and tabpage are never moved. The last visible terminal's pane window
closes when the tab has other windows (same rule as toggle-hide). The job is
stopped and settled before the buffer delete, so closing right after a send
cannot hang nvim. Never fires `NvimterminalsExit` (matches a forced `:bd`).
The policy buffer SURVIVES: respawning the same name re-attaches it; deleting
the policy buffer resets to the global fallback. Returns `(true, name)` or
`(false, "no_such_terminal")`.

When nvim exits, any still-running terminals are echoed (`VimLeavePre`) for
observability; this never affects the term tools' output shape.

## Commands

| Command | Description |
| --- | --- |
| `:TermToggle [name]` | toggle/create a named terminal |
| `:Terms` | picker of all terminals |
| `:TermRename <old> <new>` | rename a terminal (keeps job, buffer, agent settings, policy) |
| `:TermClose [name]` | stop a terminal's job and drop its state (pane shows the successor) |
| `:TermAgent [name]` | toggle agent control for a terminal |
| `:TermPolicy [name]` | edit a terminal's agent command whitelist (floating window by default) |

## Events

- `User NvimterminalsExit` — fires when a terminal's process exits.
  `ev.data = { name, buf, job_id, pid, exit_code, event }`. The name is the
  terminal's CURRENT name, even after `:TermRename`. The terminal state (and
  scrollback) stays until the terminal buffer is deleted. Forgetting a
  terminal via `:TermClose` or `:bd` never fires the event (the job is killed
  as part of the drop, not as a natural exit).

## Install

With lazy.nvim:

```lua
{
  "sp4aCemAn/nvimterminals",
  config = function()
    require("nvimterminals").setup({
      position = "right", -- "left" | "top" | "bottom"
      size = 0.35,
      policy_window = "float", -- or "split" for the legacy :TermPolicy window
      -- keymaps = {
      --   toggle_last = "<C-\\>",  -- nvim-terminals: last terminal
      --   menu = "<leader>tt",     -- set to false to disable
      -- },
      -- agent = {
      --   enabled = false,         -- global kill switch for agent sends
      --   allow = { "^ls", "^git status$" },  -- global fallback whitelist
      -- },
    })
  end,
}
```

## Usage

- `:TermToggle` — toggle `main` terminal
- `:TermToggle build` — toggle a terminal named `build` (name completion available)
- `:TermRename build compile` — rename `build` -> `compile` (keeps job, buffer, agent settings, whitelist)
- `:TermClose build` — stop `build`'s job and forget it (its pane shows the next terminal; whitelist survives for a future respawn under the same name)
- `:Terms` — list terminals and pick one
- `:TermAgent build` — allow/deny agent sends into `build`
- `:TermPolicy build` — edit `build`'s command whitelist
- `<C-\>` — toggle last used terminal
- `<leader>tt` — open terminal picker

## Tests

```sh
cd .../nvimterminals
nvim --headless -u NONE +'set shell=/bin/sh noswapfile' -l tests/lifecycle.lua +qa
nvim --headless -u NONE +'set shell=/bin/sh noswapfile' -l tests/split_override.lua +qa
nvim --headless -u NONE +'set shell=/bin/sh noswapfile' -l tests/agent_policy.lua +qa
nvim --headless -u NONE +'set shell=/bin/sh noswapfile' -l tests/leavenotify.lua +qa
nvim --headless -u NONE +'set shell=/bin/sh noswapfile' -l tests/rename_close.lua +qa
nvim --headless -u NONE +'set shell=/bin/sh noswapfile' -l tests/policy_window.lua +qa
```

Each script prints `... PASSED` on success or a failing assertion.
