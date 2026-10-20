# Dev Notes

## Current State (Oct 20, 2026)

Published on GitHub: `git@github:sp4aCemAn/nvimterminals.git`
Remote `origin` is set up. IS the execution backend for nvimcp (an MCP server
exposing nvim to AI agents): stable programmatic API + agent-permission layer
landed and consumed live (`~/vsc/nvimcp/lua/nvimcp/tools/term.lua` compiles
against `send/lines/get` and the reason strings below — EXTEND-only there).

### Files

- `lua/nvimterminals/init.lua` — `setup(opts)`, commands `:TermToggle` (name
  completion), `:Terms`, `:TermAgent` (toggle + completion), `:TermPolicy`
  (edit whitelist buffer), keymaps (`<C-\>` toggle, `<leader>tt` menu)
- `lua/nvimterminals/config.lua` — defaults + merge: `position`, `size`,
  `terminal_cmd` (lazy function -> resolved in `M.get`, no require-time
  `vim.o.shell` capture), `keymaps.*`, `agent = { enabled=false, allow={} }`
- `lua/nvimterminals/terminals.lua` — core: `toggle()`, `list()`, `select()`
  (`[open]/[hidden]/[dead]` + `[agent]` markers), `find_open_win()` (skips
  floats, searches ALL tabpages, current tab preferred), agent API: `send()`,
  `lines()`, `agent_toggle()`, `policy_buffer()`
- `lua/nvimterminals/agent.lua` — pure whitelist semantics: `parse(lines)` /
  `check(line, pol)`; `*` wildcard, `deny <pat>` before allows, empty=deny-all;
  malformed patterns fail closed (pcall'd find, never raises)
- `plugin/nvimterminals.lua` — double-load guard
- `tests/lifecycle.lua` (+ multi-tab section), `tests/split_override.lua`,
  `tests/agent_policy.lua` — headless regression scripts (see README "Tests")

### Verified working (headless tests, all PASS)

- Everything from before (pane reuse, no editor override, anchor_win, hide
  keeps job) plus:
- multi-tab: one GLOBAL term pane; toggling a term visible in another tab
  hides/reuses that pane across tabs — never a second window for one terminal
- jobstart migration: numeric `job_id`, `pid` captured via `jobpid`, dead
  state (`dead=true, exit_code`) kept on exit with `User NvimterminalsExit`
  event data `{name, buf, job_id, pid, exit_code, event}`; state drops ONLY
  when the terminal buffer is deleted
- respawn of a dead terminal deletes the old buffer (no leak) and reuses the
  visible pane; inherits `agent_enabled` + `policy`
- send gating matrix: global kill switch beats per-terminal switch; unknown/
  dead terminals -> `no_such_terminal`; dead keeps scrollback readable via
  `lines()`
- policy semantics incl. buffer-over-global, deny-before-allow, `*`,
  multi-line send (every line must pass), empty/comment-only = deny all
- send -> `nvim_chan_send(job_id, ...)` lands in the pty (`/bin/cat` echo
  read back through `lines()`); `lstrip` verified
- review follow-ups: malformed policy patterns fail closed (send never
  raises), `M.get(name)` exposes live state, `lines()` carries
  `running/pid/exit_code` (extend-only, no renames — nvimcp compiles against
  the landed shapes), VimLeavePre echoes still-running terminals

### Design decisions made

- Split terminals (not floats): position = right / left / top / bottom; one
  terminal pane globally; floats never count as panes
- Named terminals: `:TermToggle build`, default `main`; unlisted buffers
- Toggle: visible -> hide (job keeps running); hidden -> reopen; dead/missing
  -> respawn (old buffer deleted first)
- Dead-state: on_exit marks `{buf, job_id, pid, dead, exit_code}` — NEVER
  deletes state; the BufDelete/BufWipeout autocmd is the only removal path
  (and jobstops a still-running job, e.g. when the user `:bd`s a live term)
- `termopen` only as the sub-0.11 fallback; 0.11+ uses
  `jobstart(cmd, {term=true})` which converts the CURRENT empty unmodified
  buffer (same trick termopen used) and returns the job id
- Agent gating order: existence/live -> global `agent.enabled` -> terminal
  `agent_enabled` -> per-line policy check. Reason strings
  `agent_disabled | no_such_terminal | policy_denied` are the contract for
  nvimcp tool errors — dead terminals map to `no_such_terminal` (detail says
  so); do not add new reason strings without coordinating with nvimcp
- Reads are never gated: `lines()` works on dead terminals too (scrollback)
- Policy buffer `nvimterminals://policy/<name>` IS the storage (buflisted=false,
  filetype=lua); read fresh each send — deliberately NO caching/invalidation.
  While it exists it REPLACES the global fallback (empty buffer => deny all).
  `:TermPolicy` on an unknown name pre-creates the buffer; it attaches to the
  terminal by name at send time; explicit buffer deletion resets to fallback
- `send` passes bytes verbatim (`\r` = caller's job to include); `lstrip`
  default false; `wait_ms` (default 0) settles after sending: yields into nvim's
  event loop until the terminal buffer commits output (buffer signature
  changes, detected anywhere — fresh screens paint at the top), then a 50ms
  tail; result gains `settled=true|false`
- Malformed user patterns in policies FAIL CLOSED (pcall'd find): a broken
  allow never grants, a broken deny still denies — `send` never raises
- Cross-repo contract with nvimcp (`~/vsc/nvimcp/lua/nvimcp/tools/term.lua`):
  its term_read normalizer already consumes BOTH the {lnum,text} and
  string-array line shapes, reads `res.total`/`res.start`/`res["end"]` and
  `res.running/pid/exit_code` (falling back to `M.get`/`M.terminals`).
  Rule: EXTEND these shapes, do not rename what landed — send()'s reason
  strings + {ok=...}, agent_toggle()/agent_enabled(), lines() field names are
  what their tools compile against. `M.get(name)` returns the LIVE state
  table (their fallback path mutates it on older builds).
- VimLeavePre echoes still-running terminals via nvim_echo (NOT vim.notify —
  notify could emit trailing lines that break `tail -1` test checks)
- Multi-tab: reuse the pane in another tab (jump to it) instead of opening a
  second window; per-tab independent panes are NOT supported (deliberate)

### Testing gotchas (learned the hard way)

- Headless nvim hangs if the `+{cmd}` never calls `qa` — ALWAYS end with `+qa`
- Use `-u NONE` + `set shell=/bin/sh` + a harmless `terminal_cmd` like
  `/bin/cat`; never spawn an interactive shell headless
- Use timeouts on any headless nvim invocation
- `nvim_buf_delete(force=true)` on a HIDDEN buffer fires BufUnload+BufWipeout,
  NOT BufDelete — listen to both or state leaks
- `vim.fn.jobstart(cmd, {term=true})` errors ("requires unmodified buffer")
  unless the CURRENT buffer is empty+unmodified; the returned number is the
  job id, which doubles as the terminal channel for `nvim_chan_send`
- `vim.fn.bufnr(name, 0, 1)` -> E118 from Lua here; scan `nvim_list_bufs()`
  for `nvimterminals://...` names instead
- Job exit events are delivered asynchronously: a respawned `exit 7` process
  may NOT show `dead=true` until the event loop really spins — vim.wait with a
  predicate whose callback is already true may process ZERO events; always
  wait on the actual flag before asserting on it
- `string.find(text, needle, 1, true)` with `true` = PLAIN match — don't
  escape `%` in that case (test bug we actually hit)
- `user commands` are keyed by their Cased name in `nvim_get_commands({})`

Run tests like:

```
nvim --headless -u NONE +'set shell=/bin/sh noswapfile' -l tests/agent_policy.lua +qa
```

### TODO / Ideas

- [x] `on_exit` notification instead of silently dropping state (NvimterminalsExit)
- [x] Tab awareness -> resolved as "one global pane, reuse across tabs"
- [x] Agent API: send/lines + whitelists + commands (nvimcp backend)
- [ ] Esc / jk to leave terminal mode inside the term split
- [ ] Guard: closing last window in a tab (`nvim_win_close` errors on sole window)
- [ ] Session persistence (reopen named terms on restart)
- [ ] Picker integration: Telescope/fzf-lua source listing open terminals
- [ ] Per-terminal position/size overrides
- [ ] `TermToggle <name> <cmd>` / rerun support (e.g. re-run `make test`)
- [ ] `persist_mode`: return to insert mode when refocusing term split
- [ ] Optional float mode later (user still undecided)

### Usage recap

- `:TermToggle` — toggle `main`
- `:TermToggle <name>` — toggle named terminal
- `:Terms` / `<leader>tt` — picker (`[open]/[hidden]/[dead] [agent]`)
- `<C-\>` — toggle last used terminal
- `:TermAgent <name>` — toggle agent control for that terminal
- `:TermPolicy <name>` — edit that terminal's command whitelist
- `require("nvimterminals.terminals").send/lines` — nvimcp-facing API
