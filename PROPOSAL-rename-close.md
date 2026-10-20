# Proposal: `:TermRename` + `:TermClose` — IMPLEMENTED (R1-R4)

Implemented in: `4b8b31c` (R1 characterize, incl. nvim 0.12.5 wait-deadlock
finding), `1451f49` (R2 rename + exit-closure flip + ghost eviction),
`d28e725` (R3 close + successor swap + jobstop-settle hardening), R4 docs.
All deltas vs the original plan: close additionally sets a transient
`state.closing` flag to keep exit events silent (forced-delete parity),
`nargs="+"` + argc check (0.12 API rejects `"2"`), and rename evicts the
nvim rename-ghost buffers to allow round-trip renames (raw-nvim repro).

Add two terminal-lifecycle operations to nvimterminals. Both are additive:
zero changes to the frozen nvimcp-facing surface (`send/lines/get`, reason
strings, result shapes) except where noted EXTEND-only.

## Goals

1. `M.rename(name, new)` / `:TermRename <old> <new>` — rename a live or dead
   terminal in place, keeping its buffer, job, pane, agent settings, and
   policy attached.
2. `M.close(name)` / `:TermClose [name]` — programmatic equivalent of what
   `:bd` already does: buffer dies -> existing autocmd path jobstops + drops
   state. Close must not introduce a second removal path.

## Non-goals

- Rerun-on-rename, per-tab rename semantics, nvimcp tool exposure (its tools
  key by name and will pick both up for free later — no contract change now).
- The pre-existing sole-window TODO (toggle's `nvim_win_close` limitation) —
  close and rename must not make it worse; fixing it stays a separate item.

## Design decisions (defaults chosen; flag if you disagree)

**D1 — Rename resolves the exit-closure trap by job_id lookup (EXTEND-only).**
`on_exit_cb(name)` captures the name string at spawn; after a rename the
callback would write exit state under the stale key and `NvimterminalsExit`
would carry the old name. Fix: `on_exit` resolves
`name, state` by scanning `M.terminals` for `state.job_id == job`. Same
outcome as today's guard for every pre-rename flow (late events after respawn
still ignored: job ids are unique per process; scan just misses), and correct
after rename. No new public fields — `M.get`'s live table shape unchanged.
Alternative (mutable name slot stored in state) rejected: it would publish a
new field on the frozen state table.

**D2 — Rename is atomic and pre-checked.** Failure reasons (new API, not yet
nvimcp-facing — declared now, EXTEND-only later):
`no_such_terminal`, `same_name`, `terminal_exists` (key taken), `buffer_name_exists`
(some buffer already named `term://<new>` or the new name is not a valid bufname/
empty), `policy_name_exists` (orphan `nvimterminals://policy/<new>` buffer —
refuse; deleting the orphan buffer is the documented reset, matching the
existing policy-buffer semantics). Nothing mutates until all checks pass.
Pre-checks make the `nvim_buf_set_name` pcalls effectively infallible; if one
still errors mid-rename, rename must roll back key + buffer names and report
the reason (test-pinned).

**D3 — Rename follows state identity, not copies.** The state table object is
NOT cloned or replaced — only the `M.terminals` key changes (pin: `M.get(new)`
returns the SAME table identity captured before rename, so nvimcp's fallback
path that holds `M.get` results keeps working). `M.current` follows if it
pointed at the old name. `term://<bufname>` and, when present (by state.policy
reference OR by orphan scan of `nvimterminals://policy/<old>`), the policy
buffer are renamed too. Dead terminals rename like live ones (state lives
until buffer death — unchanged rule).

**D4 — Close = swap-in successor, then buffer-delete; policy buffer SURVIVES.**
If the closed terminal occupies the pane and OTHER terminals exist: the pane
is NEVER closed — it switches to a successor. Deterministic rule:
alphabetically-first remaining terminal that is LIVE; only if no live one
remains, alphabetically-first dead one (dead buffers survive for scrollback
and the picker already shows them), via
`nvim_win_set_buf` on the pane window only — focus and tabpage are NEVER
moved by close. If the closed terminal is visible and it's the LAST terminal:
close the pane window when the tab has >1 window (toggle-hide rule), sole
window keeps it and nvim's own buffer-replacement takes over (documented, not
guarded, consistent with the existing TODO). Hidden terminals: no window
effect at all. Then `nvim_buf_delete(state.buf, {force=true})` — the ONLY
state-drop path. R1 FINDING (nvim bug, not ours): force-deleting a terminal
buffer while pty output is in flight DEADLOCKS the next `vim.wait` (repro
without this plugin: `jobstart(term=true)` + `chansend` + `buf_delete(force)`
+ `wait` hangs; nvim 0.12.5). Therefore close() must `jobstop(state.job_id)`
+ bounded settle (jobwait until not-running, cap ~500ms) BEFORE deleting;
the BufWipeout handler's own jobstop then finds it dead. `:bd` remains
unsafe in that state — this hardening is another deliberate delta vs raw
`:bd` behavior, pinned by an R3 test that sends then closes immediately.
Equivalence pin (narrowed vs `:bd`): state gone, job dead,
`M.current` cleared, exit-event behavior identical (whether
`NvimterminalsExit` fires during a forced close of a LIVE job gets
characterized first in R1, current `:bd` behavior is the spec); the
pane-successor swap is deliberately BETTER than raw `:bd` and is what R3
tests. Policy buffer intentionally survives so re-spawning the same name
re-attaches it by name (existing documented behavior); renaming INTO such an
orphan name is refused per D2.

**D5 — Command shapes.** `:TermRename <old> <new>` — exactly two args; no
implicit "rename current" (avoids `''`/current/default-name ambiguity with
toggle; completion for arg1 = terminal names, none for arg2).
`:TermClose [name]` — one optional arg; defaults to `M.current or "main"`
matching `M.get_current` usage in `:TermPolicy`. Failure uses
`vim.notify(..., WARN)`? No — **`nvim_echo` err=true history=false is the
pinned convention only for VimLeavePre**; commands today use `vim.notify`
(the sole-window WARN at terminals.lua:194 is precedent). Decision: commands
report errors via `vim.notify` WARN (never in `-l` scripts' path; gate tests
drive the API directly, not the commands, so tail-1 safety is unaffected).

## Implementation sketch (touch points)

- `terminals.lua`: rewrite `on_exit_cb` closure to job_id resolution (D1);
  add `M.rename`/`M.close` near the picker (rename is lifecycle, not agent
  layer — does NOT go in agent_api.lua); `BufDelete/BufWipeout` handler and
  VimLeavePre need no change (both scan by buf/running — rename-agnostic by
  construction; add a test to prove it).
- `init.lua`: two new user commands + customlist completion (rename arg1
  names; close names). Double-load guard untouched.
- `agent_api.lua`: untouched (policy_bufname derives from the name argument
  at call time; rename already moved both state key and policy buffer name).

## Phase queue (execute in order; full gate after EVERY commit)

**R1 — characterize (test-only, one commit).** New `tests/rename_close.lua`:
pin current `:bd`-equivalent teardown observables (exit-event behavior for a
live forced delete included — whatever it does today is the spec D4 must
match); pin the OLD-name exit-closure failure mode as KNOWN-ISSUE with the
flip assertion named in its comment; pin state-table identity requirement;
pin rename-agnosticism of `BufWipeout`/VimLeavePre/`list()`/`select()` via a
manual table-surgery rename (key copy + buffer rename only — NOT the shipped
behavior). Gate: 4 suites green (new file counts as 5th line).

**R2 — rename (flip commit).** Implement D1–D3 + `:TermRename` + completion;
flip the KNOWN-ISSUE (post-rename `NvimterminalsExit` carries NEW name);
add all D2 failure-mode asserts (rollback included).

**R3 — close (feature commit).** Implement D4 + `:TermClose` + completion;
successor-swap asserts (alphabetical-first incl. dead-eligible, pane shows
successor, window count unchanged, focus+tabpage never moved); narrow `:bd`
equivalence asserts (state drop, jobstop, M.current cleared, exit-event
behavior per R1 pin); last-terminal cases (>1 window closes pane, sole window
keeps it); policy-survival + re-attach-by-name after respawn assert;
dead/hidden/visible cases.

**R4 — docs.** README (commands table, usage recap, Events note re: rename),
NOTES (design decisions + files list + testing gotchas for any new ones),
agent file repo-map. No code.

Commit style: `terminals:`/`config:`/`docs+tests:` prefixes; one commit per
phase; revertable individually.

## Gates

```sh
timeout 60 nvim --headless -u NONE +'set shell=/bin/sh noswapfile' -l tests/<x>.lua +qa
# lifecycle | split_override | agent_policy | leavenotify | rename_close (new)
```
All sentinels last-line-clean; counts grow, never regress.

## Risks / watch-fors

- `nvim_buf_set_name` on terminal buffers: already pcall'd at spawn
  (terminals.lua:249) — mirror that exact failure tolerance.
- Completion arg-position parsing in customlist (cmdline split, cursorpos) —
  pin `:TermRename main <TAB>` lists names but arg2 completes nothing.
- A renamed terminal's `term://` buffer name: nvim's own terminal naming does
  not re-take-control after rename (verify: read `nvim_buf_get_name` after
  rename + after respawn).
- Do NOT touch `send/lines` result shapes; `lines()` reads by state lookup,
  which rename already moved — assert `lines(new)` works and `lines(old)`
  returns `no_such_terminal` in R2.
- NOTES gotchas still apply (headless `-u NONE` + `/bin/cat`, `+qa` always,
  vim.wait on actual flags for async exit events, `= nil` breaks vim.api
  lazy lookup if any stubbing reappears in R1).

## Out of scope

`NvimterminalsRename` user event (no consumer today — nvimcp keys by name at
tool-call time; add only when a real consumer appears), tab-local renames,
nvimcp term tools for rename/close, sole-window guard fix, picker rename UI.
