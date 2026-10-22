# Dev Notes

## Current State (Oct 20, 2026)

Published on GitHub: `git@github:sp4aCemAn/nvimterminals.git`
Remote `origin` is set up. IS the execution backend for nvimcp (an MCP server
exposing nvim to AI agents): stable programmatic API + agent-permission layer
landed and consumed live (`~/vsc/nvimcp/lua/nvimcp/tools/term.lua` compiles
against `send/lines/get` and the reason strings below — EXTEND-only there).
Rename/close (R series) landed: `:TermRename`/`:TermClose` + `M.rename`/
`M.close` (command surface only — not part of the nvimcp contract).

### Files

- `lua/nvimterminals/init.lua` — `setup(opts)`, commands `:TermToggle` (name
  completion), `:Terms`, `:TermAgent` (toggle + completion), `:TermPolicy`
  (edit whitelist buffer), keymaps (`<C-\>` toggle, `<leader>tt` menu)
- `lua/nvimterminals/config.lua` — defaults + merge: `position`, `size`,
  `terminal_cmd` (lazy function -> resolved in `M.get`, no require-time
  `vim.o.shell` capture), `keymaps.*`, `policy_window` ("float"|"split"),
  `narrow_min_width`/`narrow_position` (N1 adaptive narrow-pane fallback),
  `agent = { enabled=false, allow={} }`
- `lua/nvimterminals/terminals.lua` — core: `toggle()`, `list()`, `select()`
  (`[open]/[hidden]/[dead]` + `[agent]` markers), `find_open_win()` (skips
  floats, searches ALL tabpages, current tab preferred), `show_buffer` with
  the N1 narrow-pane fallback (left/right -> `narrow_position` when the pane
  would be < `narrow_min_width` cols), `rename()`
  (identity-preserving, atomic, ghost-evicting), `close()` (successor swap ->
  jobstop+settle -> buffer delete); re-exports the frozen agent facade
  (`send/lines/policy_buffer/agent_toggle/agent_enabled`) from agent_api via
  `bind(M, job_running)` — nvimcp's entry path, unchanged
- `lua/nvimterminals/agent_api.lua` — agent control layer implementation
  (extracted from terminals.lua in C3, behavior-preserving; reads live
  `terminals` module state through the bind, owns no state)
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
- rename/close (R series): identity-preserving rename + job-id exit naming +
  rename-ghost eviction + rollback (stubbed `set_name`) pinned in
  `tests/rename_close.lua`; close successor-swap (live-preferred),
  focus/tabpage untouched, no-exit-event parity with `:bd`, post-send close
  deadlock probe, and policy-survival/re-attach pins all green

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
  buftype=acwrite, filetype=`nvimterminals_policy`); read fresh each send —
  deliberately NO
  caching/invalidation. `:w` is a no-op save: the BufWriteCmd handler only
  clears `modified` (acwrite keeps writes off disk; the old plain-buftype
  buffers tried to CREATE a file named `nvimterminals://policy/<name>` and
  raised E212). Seeding the header clears `modified` too.
  While it exists it REPLACES the global fallback (empty buffer => deny all).
  `:TermPolicy` on an unknown name pre-creates the buffer; it attaches to the
  terminal by name at send time; explicit buffer deletion resets to fallback
- W3 BREAKING change: policy buffers are no longer `filetype=lua` — pattern
  lines like `^ls` rendered as Lua SYNTAX ERRORS (red). Shipped
  `syntax/nvimterminals_policy.vim` (comment/deny/wildcard highlight groups,
  plain allows as Normal); autocmds keyed to the old filetype must retarget
  to `nvimterminals_policy`. Syntax file RE-CLAIMS the buffer (only finishes
  early when its OWN syntax is already active) because `:syntax on`'s BufRead
  machinery re-guesses a filetype from the buffer NAME (gotcha below).
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
- Rename (R2): `M.rename` keeps the state-table IDENTITY (only the key moves,
  so nvimcp callers holding `M.get` results keep working); `term://` bufname,
  policy buffer name and `M.current` follow; `on_exit` resolves the name by
  JOB ID so post-rename exits report the CURRENT name (the old captured-name
  closure stranded updates). Atomic: pre-check reasons
  `no_such_terminal | invalid_name | same_name | terminal_exists |
  buffer_name_exists | policy_name_exists` before any mutation, full rollback
  on a mid-rename `set_name` failure. These reasons are the COMMAND surface —
  NOT part of the nvimcp `send/lines` reason contract.
- Close (R3): `M.close` = swap a successor into the pane (alphabetically-first
  LIVE, dead fallback; focus and tabpage never moved — the pane window
  survives ON A TERMINAL instead of dying with the buffer as raw `:bd` does),
  then jobstop + bounded settle, then the forced buffer delete (still the
  ONLY state-drop path). Transient `state.closing` flag keeps the exit
  callback silent — close matches the forced-delete baseline (no event).
  Last-visible terminal follows the toggle-hide window rule. Policy buffer
  SURVIVES close; respawn re-attaches it by name; deleting it resets to the
  global fallback.
- Policy window (W1-W4 cleanup): `:TermPolicy` shows the policy buffer in a
  centered editor-relative float (`policy_window="float"` default; `"split"`
  restores the legacy `botright 20vsplit`). An already-visible policy buffer
  is just FOCUSSED regardless of mode — never converted or duplicated. Pure
  presentation: the buffer stays the storage, gating semantics unchanged
  (pinned in `tests/policy_window.lua`). W2: acwrite, unmodified at seed, `:w`
  clears the flag and writes nothing to disk. W4: buffer-local `q`/`<Esc>`
  close the policy FLOAT (`agent_api.close_floats`; splits never closed);
  `:w` also closes floats (save-and-done) but keeps splits — the buffer
  survives every gesture either way.
  `nvim_win_get_config` returns `title` as a CHUNK LIST `{{text, hl}}`, not a string.
- Narrow-pane fallback (N1, owner QoL): `show_buffer` NEW-SPLIT path only —
  pane reuse, hide, respawn, close-successor and policy floats are untouched.
  A left/right primary whose `floor(columns*size)` pane width would fall below
  `narrow_min_width` (default 60; only a NUMBER enables — 0/false/nil disable)
  opens horizontally at `narrow_position`; only "top"/"bottom" convert, a
  bogus value keeps the primary, and top/bottom primaries are never converted
  (the check only sees left/right). `size` applies to the ACTUAL split
  dimension via the existing cmds table. Evaluated per split, never cached:
  resizing nvim does not re-orient an existing pane (deliberate). Pinned in
  tests/lifecycle.lua N1 section: headless is fixed 80x24, so explicit sizes
  are the lever (0.8 -> 64 cols stays right; 0.35 -> 28 falls back; F pins
  that reuse switches the SAME fallback window).

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
- nvim 0.12.5: force-deleting a terminal buffer while pty output is IN FLIGHT
  deadlocks the NEXT `vim.wait` (plain-repro, no plugin: `jobstart(term=true)`
  + `chansend` + `buf_delete(force)` + `wait` hangs). Settle output — or
  jobstop and wait until not-running — BEFORE deleting. Tests that send must
  settle before any teardown.
- renaming a buffer that carries a custom `term://`-style name leaves a GHOST
  buffer re-taking the vacated name (empty, unlisted, harmless but it blocks
  the name; raw nvim behavior). Evict it after renames or old names become
  permanently un-usable.
- `nvim_create_user_command` opts.nargs accepts only `"*"|"+"|"`?" on 0.12 —
  the `"0"/"1"/"2"` numeric-string forms are rejected; enforce exact arg
  counts via `#e.fargs` (and user commands cannot contain digits in names)
- `vim.ui_attach` needs a real RPC channel — unavailable in `-l` scripts;
  stub `vim.api.*` functions instead and restore BY REFERENCE (`= nil`
  corrupts the lazy api dispatcher)
- `:syntax on` (and filetype auto-detect machinery) can RE-GUESS a filetype
  from the buffer NAME and set a foreign b:current_syntax over an explicitly
  assigned one — headless syntax tests should source the syntax file directly
  (via an rtp entry), skipping `:syntax on` entirely
- typeahead is NOT processed inside `-l` scripts: `nvim_input` / `feedkeys`
  plus `vim.wait` leave keymaps unfired (probed 2s) — drive normal-mode maps
  in tests with `vim.cmd("normal q")` (`:normal` respects mappings and runs
  synchronously)
- `vim.fn.maparg(name, mode, false, false)` = 4 args is fine; the 5-arg form
  (buffer as 5th) raises E118 from Lua like `bufnr` — check the CURRENT
  buffer's map or use the dict form
- `nvim_win_get_position` returns ONE `{row, col}` TABLE to Lua (not two
  return values) — comparing it directly errors "attempt to compare two
  table values"; index `[1]`/`[2]` (split-geometry pins in lifecycle)
- split-ORIENTATION geometry pins in headless: vsplit <=> term and sibling
  share the full HEIGHT and differ in WIDTH; horizontal split <=> share the
  full WIDTH and differ in HEIGHT (`nvim_win_get_width/height`) — robust vs
  exact-size asserts, which fight nvim's width redistribution

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
