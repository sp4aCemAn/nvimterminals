# Dev Notes

## Current State (Sep 23, 2026)

Published on GitHub: `git@github:sp4aCemAn/nvimterminals.git`
Remote `origin` is set up. Committed so far:

- `c0bfb6b` init — full plugin skeleton (lua/, plugin/, NOTES.md, README.md)
- `8fa88da` MIT License

License: MIT.

### Files

- `lua/nvimterminals/init.lua` — `setup(opts)`, `:TermToggle` (with name completion), `:Terms` picker command, keymaps (`<C-\>` toggle, `<leader>tt` menu)
- `lua/nvimterminals/config.lua` — defaults + merge: `position`, `size`, `terminal_cmd`, `keymaps.toggle_last`, `keymaps.menu`
- `lua/nvimterminals/terminals.lua` — core rewritten with `nvim_create_buf` + `nvim_win_set_buf` (fixes E95 and buffer-override); `anchor_win()` so spawning from inside a term window anchors the split to an editor window; `show_buffer()` reuses the open term pane for hidden->visible and fresh spawns (single visible pane, VSCode-style); `toggle()`, `list()`, `select()`, `find_open_win()`, `M.current`
- `plugin/nvimterminals.lua` — double-load guard (`vim.g.loaded_nvimterminals`)
- `tests/lifecycle.lua`, `tests/split_override.lua` — headless regression scripts (see README "Tests")
- `README.md` — install/usage docs

### Verified working (headless tests, both PASS)

- Modules load, config merge works
- Spawn -> hide (job keeps running) -> reopen SAME buffer -> second/third named terminal coexist
- Terminal buffer always in exactly ONE window; editor buffer never overridden
- Spawn from inside a term window anchors the split to the editor window (anchor_win)

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

### OPEN BUG — RESOLVED (Sep 23, 2026)

Previous multi-window/E95 issues were caused by `buf_set_name(0, ...)` renaming
the CURRENT buffer into a terminal. Fixed by giving every terminal its own
buffer via `nvim_create_buf(false, false)` + `nvim_win_set_buf` in the split
window, plus `pcall(vim.api.nvim_buf_set_name, ...)` safely after termopen.
Headless regression: `tests/lifecycle.lua`, `tests/split_override.lua` — both
print "PASSED".

### TODO / Ideas

- [ ] Fix the multi-window hide/reopen bug above  (DONE — see above)
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
