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
  per line). While that buffer exists it REPLACES the global fallback.
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
false) left-strips each outgoing line; `opts.timeout_ms` is accepted but
currently unused (non-blocking). Returns one of:

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
agent_enabled, policy`) or nil; treat as read-only. `M.agent_enabled(name)`
is the per-terminal switch getter; `M.agent_toggle(name)` flips it.

When nvim exits, any still-running terminals are echoed (`VimLeavePre`) for
observability; this never affects the term tools' output shape.

## Commands

| Command | Description |
| --- | --- |
| `:TermToggle [name]` | toggle/create a named terminal |
| `:Terms` | picker of all terminals |
| `:TermAgent [name]` | toggle agent control for a terminal |
| `:TermPolicy [name]` | edit a terminal's agent command whitelist |

## Events

- `User NvimterminalsExit` — fires when a terminal's process exits.
  `ev.data = { name, buf, job_id, pid, exit_code, event }`. The terminal
  state (and scrollback) stays until the terminal buffer is deleted.

## Install

With lazy.nvim:

```lua
{
  "sp4aCemAn/nvimterminals",
  config = function()
    require("nvimterminals").setup({
      position = "right", -- "left" | "top" | "bottom"
      size = 0.35,
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
```

Each script prints `... PASSED` on success or a failing assertion.
