# Dev Notes

## Current State (Sep 22, 2026)

Plugin skeleton exists in a fresh git repo (nothing committed yet).

### Files

- `lua/nvimterminals/init.lua` — `setup(opts)`, registers `:TermToggle [name]` command and `<C-\>` toggle_last keymap (normal + terminal mode)
- `lua/nvimterminals/config.lua` — defaults + merge: `position` ("right"), `size` (0.35), `terminal_cmd` (vim.o.shell), `keymaps.toggle_last`
- `lua/nvimterminals/terminals.lua` — core: `M.terminals` (name -> {buf, job_id}), `M.current`, `toggle(name)`
- `plugin/nvimterminals.lua` — double-load guard (`vim.g.loaded_nvimterminals`)
- `README.md` — install/usage docs

### Design decisions made

- Split terminals (not floats — decided for now): position = right / left / top / bottom
- Named terminals: `:TermToggle build`, `:TermToggle repl`, default name `main`
- Terminal buffers are `buflisted = false` so they stay out of `:ls` / bufferline / pickers
- Toggle semantics: visible -> hide window (job keeps running); hidden -> reopen split; dead/missing -> spawn fresh
- On exit, terminal state is cleaned up (on_exit callback)

### Verified working (headless tests)

- Modules load, config merge works
- `toggle("test")` spawns split + `/bin/cat` job, buffer unlisted, bufname `term://test`
- Hide works: `win_findbuf` empty after second toggle, job still alive (`jobwait ... == -1`)
- Reopen works: third toggle brings the SAME buffer back in a new split

### OPEN BUG — found in last session

`win_findbuf(buf)` can return MORE than one window id (e.g. `{ 1000, 1001 }`).
Cause: `create_split()` runs `vsplit` while the terminal buffer may already be
displayed somewhere, or stale windows linger. Since we only ever check
`win_findbuf(buf)[1]`, a second hidden/ghost window breaks hide logic (test
assertion "should be hidden" failed: after 2nd toggle a window still showed it).

Next steps to fix:
1. In the "hidden -> reopen" branch, before `vim.cmd("buffer "..buf)`, check ALL
   windows: `for _, w in ipairs(vim.fn.win_findbuf(buf)) do ... end` — the
   split may be unnecessary if a window already exists in this tabpage.
2. Or simpler: on reopen, don't create a split first; just find any window
   showing buf; if none, split THEN switch. Track visibility per-tabpage.
3. Also verify `nvim_win_close(win, false)` actually closes the right window —
   log win ids during hide.
4. Headless quirk to recheck: in headless mode `winnr("$")` was 2 after first
   toggle, which may itself be the artifact (initial empty buffer window + term
   window). Test interactively too.

### TODO / Ideas

- [ ] Fix the multi-window hide/reopen bug above
- [ ] Esc / jk to leave terminal mode inside the term split
- [ ] Tab awareness: terminal visible in another tab -> focus vs reopen vs hide
- [ ] Guard: closing last window in a tab (`nvim_win_close` errors on sole window)
- [ ] Session persistence (reopen named terms on restart)
- [ ] Picker integration: Telescope/fzf-lua source listing open terminals
- [ ] Per-terminal position/size overrides
- [ ] `on_exit` notification instead of silently dropping state
- [ ] `TermToggle <name> <cmd>` / rerun support (e.g. re-run `make test`)
- [ ] `persist_mode`: return to insert mode when refocusing term split
- [ ] Optional float mode later (user still undecided)

### Usage recap

- `:TermToggle` — toggle `main`
- `:TermToggle <name>` — toggle named terminal
- `<C-\>` — toggle last used terminal

### Testing gotchas (learned the hard way)

- Headless nvim hangs if the `+{cmd}` never calls `qa` — ALWAYS end with `+qa`
- Use `-u NONE` + `set shell=/bin/sh` + a harmless `terminal_cmd` like `/bin/cat`
  for tests; never spawn an interactive shell headless
- Use timeouts on any headless nvim invocation

Run tests like:

```
nvim --headless -u NONE +'set shell=/bin/sh' \
  +'lua package.path="./lua/?.lua;"..package.path; ...asserts...; print("OK")' \
  +qa
```
