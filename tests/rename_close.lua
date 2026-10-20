package.path = "./lua/?.lua;" .. package.path
local t = require("nvimterminals.terminals")
local c = require("nvimterminals.config")

-- Characterization pins for the rename/close work (R1; see
-- PROPOSAL-rename-close.md). These assert CURRENT behavior as the spec:
--   - forced buffer delete is the only state-drop path and is SILENT (no
--     NvimterminalsExit ever fires for it, for live or dead terminals);
--   - M.current after a delete is only pinned to "never points at the
--     deleted name" (the autocmd clears exactly its own name; stale-current
--     from earlier closes is the pre-existing state and stays untouched);
--   - nvim's own fate for a window whose displayed buffer is force-deleted:
--     the window DIES with the buffer, even when other terminals exist --
--     nvim never swaps a successor in. R3's close() makes the outcome
--     deterministic and better by swapping a LIVE (else dead) successor into
--     the pane via nvim_win_set_buf BEFORE deleting the buffer, keeping the
--     window alive on a terminal;
--   - rename subsystems: identity + keying + exit closure are exercised via
--     M.rename (R2+); sections 1-2 pin the forced-delete baseline that close()
--     must match (plus the R1 FINDING: nvim 0.12.5 deadlocks a later vim.wait
--     if a term buffer is force-deleted while pty output is in flight -- all
--     sends here are settled before any delete; M.close will jobstop+settle);

local real_echo = vim.api.nvim_echo
local real_uis = vim.api.nvim_list_uis

vim.cmd("edit /tmp/opencode_rename_test.txt")
c.setup({ terminal_cmd = "/bin/cat", size = 0.4 })

local exits = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "NvimterminalsExit",
  callback = function(ev)
    table.insert(exits, ev.data)
  end,
})

local function drop(name)
  local st = t.terminals[name]
  if st and st.buf and vim.api.nvim_buf_is_valid(st.buf) then
    vim.api.nvim_buf_delete(st.buf, { force = true })
  end
  assert(vim.wait(2000, function() return t.terminals[name] == nil end), name .. " state must drop")
end

local function exists_bufname(nm)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == nm then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- 1. forced delete of a VISIBLE live terminal: state gone, current never
--    points at it, NO exit event; the pane window survives and is
--    re-pointed to an alternate buffer (here: the editor window's buffer)
-- ---------------------------------------------------------------------------
t.toggle("q1")
t.toggle("q2") -- q2 holds the pane, q1 hidden
local wins0 = #vim.api.nvim_list_wins()
local q1_buf = t.terminals.q1.buf
local q2_win = vim.fn.win_findbuf(t.terminals.q2.buf)[1]
vim.api.nvim_buf_delete(t.terminals.q2.buf, { force = true })
vim.wait(300, function() return false end)
assert(t.terminals.q2 == nil, "closed state must drop")
assert(t.current ~= "q2", "current must not stay on the closed name: " .. tostring(t.current))
assert(#exits == 0, "forced delete must fire no NvimterminalsExit: " .. vim.inspect(exits))
assert(not vim.api.nvim_win_is_valid(q2_win), "baseline: the pane window dies with its buffer")
assert(#vim.api.nvim_list_wins() == wins0 - 1, "baseline: exactly one window closed")
assert(#vim.fn.win_findbuf(q1_buf) == 0, "baseline: hidden q1 is NOT swapped in automatically")
drop("q1")

-- ---------------------------------------------------------------------------
-- 2. forced delete of a DEAD terminal: natural event pinned, no extra event
-- ---------------------------------------------------------------------------
c.setup({ terminal_cmd = "exit 7", size = 0.4 })
t.toggle("dd")
assert(vim.wait(3000, function() return t.terminals.dd and t.terminals.dd.dead end), "dd never died")
assert(#exits == 1 and exits[1].name == "dd" and exits[1].exit_code == 7, "natural exit event pinned: " .. vim.inspect(exits))
local e_before = #exits
vim.api.nvim_buf_delete(t.terminals.dd.buf, { force = true })
vim.wait(300, function() return false end)
assert(t.terminals.dd == nil, "dead state must drop on buffer delete")
assert(#exits == e_before, "buffer delete adds no event")

-- ---------------------------------------------------------------------------
-- 3. exit-closure FLIP (R2): on_exit resolves name via job_id, so a
--    renamed terminal records dead/exit_code under its CURRENT key and
--    NvimterminalsExit carries the new name. (R1 pinned the old stranded-
--    update behavior: dead unset, no event.)
-- ---------------------------------------------------------------------------
c.setup({ terminal_cmd = "/bin/cat", size = 0.4 })
t.toggle("k1")
local k = t.terminals.k1
local okk, rname = t.rename("k1", "k2")
assert(okk == true and rname == "k2", vim.inspect({ okk, rname }))
assert(t.terminals.k2 == k and t.terminals.k1 == nil, "rename keeps state identity")
assert(vim.api.nvim_buf_get_name(k.buf) == "term://k2", "bufname follows rename")
vim.fn.jobstop(k.job_id)
assert(vim.wait(3000, function() return k.dead end), "renamed exit must record dead")
assert(k.exit_code == 129, "exit code: " .. tostring(k.exit_code))
assert(#exits == 2, "renamed exit must fire exactly one new event: " .. vim.inspect(exits))
local kev = exits[2]
assert(kev.name == "k2" and kev.exit_code == 129 and kev.job_id == k.job_id and kev.buf == k.buf, vim.inspect(kev))

-- ---------------------------------------------------------------------------
-- 4. rename invariance via M.rename: identity, lookups, gating,
--    wipeout-autocmd, picker, VimLeavePre echo
-- ---------------------------------------------------------------------------
drop("k2")
t.toggle("v1")
local v = t.terminals.v1
local v_id = v
assert(t.rename("v1", "v2"))
assert(t.get("v2") == v_id, "M.get must resolve the same live table under new key")
assert(t.get("v1") == nil, "old key must be gone")
local lr = t.lines("v2", { n = 5 })
assert(lr.ok and lr.running == true, vim.inspect(lr))
local lr_old = t.lines("v1", {})
assert(lr_old.ok == false and lr_old.reason == "no_such_terminal", vim.inspect(lr_old))

c.setup({ terminal_cmd = "/bin/cat", size = 0.4, agent = { enabled = true, allow = { "^ls" } } })
v.agent_enabled = true
local sr = t.send("v2", "ls\n")
assert(sr.ok, "send through new key: " .. vim.inspect(sr))
sr = t.send("v1", "ls\n")
assert(sr.ok == false and sr.reason == "no_such_terminal", vim.inspect(sr))

local names = t.list()
assert(table.concat(names, ",") == "v2", "list() keyed by new name: " .. table.concat(names, ","))

-- MUST settle the pty echo before the forced delete: nvim 0.12.5 deadlocks a
-- later vim.wait if a terminal buffer with in-flight output is force-deleted
-- (repro without this plugin: jobstart term + chansend + buf_delete + wait).
-- This is exactly why M.close() will jobstop + bounded-settle BEFORE deleting.
assert(vim.wait(1000, function()
  for _, l in ipairs(t.lines("v2", { n = 200 }).lines) do
    if l.text:find("ls", 1, true) then
      return true
    end
  end
end), "send did not echo")

-- VimLeavePre echo reports the NEW key (it scans M.terminals names live)
local echoed = {}
vim.api.nvim_list_uis = function()
  return { [1] = 7 }
end
vim.api.nvim_echo = function(content, err, opts)
  table.insert(echoed, { content, err, opts })
end
vim.api.nvim_exec_autocmds("VimLeavePre", { group = "nvimterminals" })
vim.api.nvim_list_uis = real_uis
vim.api.nvim_echo = real_echo
assert(#echoed == 1, "one leave echo expected: " .. vim.inspect(echoed))
local leave_text = echoed[1][1][1][1]
assert(leave_text == "nvimterminals: still running at exit: v2", "got: " .. tostring(leave_text))

-- BufWipeout scan is by BUF, so the new key drops cleanly
vim.api.nvim_buf_delete(v.buf, { force = true })
assert(vim.wait(2000, function() return t.terminals.v2 == nil end), "wipeout autocmd rename-agnostic")

-- ---------------------------------------------------------------------------
-- 4b. rename failure modes (D2), policy follow (D3), rollback, command path
-- ---------------------------------------------------------------------------
c.setup({ terminal_cmd = "/bin/cat", size = 0.4 })
t.toggle("f1")
t.toggle("f2")
local okr, err
okr, err = t.rename("ghost", "x")
assert(okr == false and err == "no_such_terminal", tostring(err))
okr, err = t.rename("f1", "f2")
assert(okr == false and err == "terminal_exists", tostring(err))
okr, err = t.rename("f1", "f1")
assert(okr == false and err == "same_name", tostring(err))
okr, err = t.rename("f1", "")
assert(okr == false and err == "invalid_name", tostring(err))
okr, err = t.rename("f1", "a\nb")
assert(okr == false and err == "invalid_name", tostring(err))

-- orphan policy buffer blocks the TARGET name; other names stay free
local _, porph = t.policy_buffer("z2", true)
assert(porph and porph > 0, "orphan policy pre-created")
okr, err = t.rename("f1", "z2")
assert(okr == false and err == "policy_name_exists", tostring(err))
-- nvim 0.12.5 renames leave a GHOST buffer re-taking the vacated name
-- (raw-repro without this plugin). M.rename must evict it so round-trip
-- renames work and old names free up immediately:
okr, err = t.rename("f1", "f9")
assert(okr == true, tostring(err))
assert(not exists_bufname("term://f1"), "ghost of vacated term://f1 must be evicted")
assert((t.rename("f9", "f1")))
assert(not exists_bufname("term://f9"), "ghost of vacated term://f9 must be evicted")

-- buffer-name collision blocks the target
local bcol = vim.api.nvim_create_buf(false, false)
vim.api.nvim_buf_set_name(bcol, "term://collide")
okr, err = t.rename("f1", "collide")
assert(okr == false and err == "buffer_name_exists", tostring(err))
vim.api.nvim_buf_delete(bcol, { force = true })

-- policy buffer follows the rename by reference (D3)
local _, pf = t.policy_buffer("f1", true)
assert((t.rename("f1", "rr")))
assert(vim.api.nvim_buf_get_name(pf) == "nvimterminals://policy/rr", vim.api.nvim_buf_get_name(pf))
assert(t.terminals.rr.policy == pf, "state.policy reference survives")
assert(not exists_bufname("nvimterminals://policy/f1"), "policy-name ghost must be evicted too")

-- rollback: first nvim_buf_set_name fails -> key+current+bufname all restored
local real_setname = vim.api.nvim_buf_set_name
local sn_calls = 0
vim.api.nvim_buf_set_name = function(buf, nm)
  sn_calls = sn_calls + 1
  if sn_calls == 1 then
    error("stubbed set_name failure")
  end
  return real_setname(buf, nm)
end
local cur_before = t.current
okr, err = t.rename("f2", "f2b")
vim.api.nvim_buf_set_name = real_setname
assert(okr == false and err:find("buffer_name_exists", 1, true), tostring(err))
assert(t.terminals.f2 ~= nil and t.terminals.f2b == nil, "rollback restores key")
assert(t.current == cur_before, "rollback restores current: " .. tostring(t.current))
assert(vim.api.nvim_buf_get_name(t.terminals.f2.buf) == "term://f2", "rollback restores bufname")
-- and the same rename succeeds once the failure is gone:
assert((t.rename("f2", "f2b")))

-- command path: setup() registers TermRename; nvim_cmd goes through it
package.path = "./lua/?/init.lua;" .. package.path -- real installs get this pattern via runtimepath
require("nvimterminals").setup({ terminal_cmd = "/bin/cat", size = 0.4 })
assert(vim.api.nvim_get_commands({}).TermRename ~= nil, "TermRename registered")
local notified = {}
local real_notify = vim.notify
vim.notify = function(msg, level, o)
  table.insert(notified, { msg, level })
end
vim.api.nvim_cmd({ cmd = "TermRename", args = { "f2b", "cmd1" } }, {})
vim.notify = real_notify
assert(t.terminals.cmd1 ~= nil and t.terminals.f2b == nil, "command renamed")
assert(notified[1] and notified[1][1]:find("'f2b' -> 'cmd1'", 1, true), vim.inspect(notified))
-- completion: names offered for arg1, nothing for arg2 (getcompletion on the
-- command line; built-in noise like flags is tolerated, names must appear)
local comp1 = table.concat(vim.fn.getcompletion("TermRename ", "cmdline"), ",")
assert(comp1:find("cmd1", 1, true), "arg1 completion missing names: " .. comp1)

drop("rr")
drop("cmd1")
vim.api.nvim_buf_delete(porph, { force = true })

-- ---------------------------------------------------------------------------
-- 5. term:// bufname: set at spawn, never re-taken by nvim (rename relies on
--    this holding after nvim_buf_set_name too)
-- ---------------------------------------------------------------------------
t.toggle("nm")
assert(vim.api.nvim_buf_get_name(t.terminals.nm.buf) == "term://nm", "spawn name")
vim.wait(300, function() return false end)
assert(vim.api.nvim_buf_get_name(t.terminals.nm.buf) == "term://nm", "name not re-taken")
drop("nm")

-- ---------------------------------------------------------------------------
-- 6. close(): unknown, successor swap (live preferred, dead fallback), pane
--    window survives the swap / dies with the LAST terminal, focus untouched,
--    still no exit events (forced-delete baseline preserved)
-- ---------------------------------------------------------------------------
c.setup({ terminal_cmd = "/bin/cat", size = 0.4 })
local okc, erc = t.close("ghost")
assert(okc == false and erc == "no_such_terminal", tostring(erc))

local ed_win = vim.api.nvim_get_current_win()
assert(vim.bo[vim.api.nvim_win_get_buf(ed_win)].buftype == "", "test must sit at an editor window")

t.toggle("a")
t.toggle("b")
c.setup({ terminal_cmd = "exit 3", size = 0.4 })
t.toggle("cc")
assert(vim.wait(3000, function() return t.terminals.cc and t.terminals.cc.dead end), "cc never died")
c.setup({ terminal_cmd = "/bin/cat", size = 0.4 })
t.toggle("b") -- b back into the pane; a live-hidden, cc dead-hidden

local pane_win = t.find_open_win()
assert(pane_win and vim.fn.win_findbuf(t.terminals.b.buf)[1] == pane_win, "b visible")
vim.api.nvim_set_current_win(ed_win)
local wins_before = #vim.api.nvim_list_wins()
local e_before = #exits
okc, erc = t.close("b")
assert(okc == true and erc == "b", tostring(erc))
assert(t.terminals.b == nil, "state dropped")
assert(#exits == e_before, "close fires no exit event (forced-delete baseline kept): " .. vim.inspect(exits))
assert(vim.api.nvim_win_is_valid(pane_win), "successor swap keeps the pane window")
assert(vim.fn.win_findbuf(t.terminals.a.buf)[1] == pane_win, "LIVE successor a swapped in (dead cc skipped)")
assert(#vim.api.nvim_list_wins() == wins_before, "no window closed on swap path")
assert(vim.api.nvim_get_current_win() == ed_win, "focus untouched")

okc = t.close("a")
assert(okc == true)
assert(vim.fn.win_findbuf(t.terminals.cc.buf)[1] == pane_win, "dead successor cc swapped in (no live left)")

okc = t.close("cc")
assert(okc == true and t.terminals.cc == nil)
assert(not vim.api.nvim_win_is_valid(pane_win), "last-term pane window dies")
assert(#vim.api.nvim_list_wins() == wins_before - 1)

-- ---------------------------------------------------------------------------
-- 7. close IMMEDIATELY after a send: internal jobstop+settle must prevent the
--    nvim 0.12.5 in-flight-output delete deadlock (R1 FINDING). The probe is
--    simply that vim.wait RETURNS afterwards.
-- ---------------------------------------------------------------------------
c.setup({ terminal_cmd = "/bin/cat", size = 0.4, agent = { enabled = true, allow = { "*" } } })
t.toggle("s")
t.agent_toggle("s")
local rs = t.send("s", "echo close-me\r")
assert(rs.ok, vim.inspect(rs))
vim.api.nvim_set_current_win(ed_win)
okc = t.close("s")
assert(okc == true, "close after send")
assert(t.terminals.s == nil)
vim.wait(200, function() return false end)
print("post-close-deadlock probe survived")

-- ---------------------------------------------------------------------------
-- 8. policy buffer survives close; respawn re-attaches by name; explicit
--    policy delete resets to the global fallback
-- ---------------------------------------------------------------------------
local _, pb = t.policy_buffer("pp", true)
vim.api.nvim_buf_set_lines(pb, 0, -1, false, { "^ls" })
t.toggle("pp")
t.agent_toggle("pp")
assert(t.send("pp", "ls").ok, "pre-attached policy found by name")
assert(t.send("pp", "rm x").ok == false, "policy denies rm")
okc = t.close("pp")
assert(okc == true)
assert(vim.api.nvim_buf_is_valid(pb), "policy buffer survives close")
t.toggle("pp")
t.agent_toggle("pp")
assert(t.send("pp", "ls").ok, "respawn re-attaches surviving policy")
assert(t.send("pp", "rm x").ok == false)
c.setup({ terminal_cmd = "/bin/cat", size = 0.4, agent = { enabled = true, allow = { "*" } } })
vim.api.nvim_buf_delete(pb, { force = true })
assert(t.send("pp", "rm x").ok, "global fallback after policy reset")
okc = t.close("pp")
assert(okc == true)

-- ---------------------------------------------------------------------------
-- 9. :TermClose command path (setup() ran in 4b; commands are registered)
-- ---------------------------------------------------------------------------
t.toggle("cm")
local notified2 = {}
local real_notify2 = vim.notify
vim.notify = function(msg, level, o)
  table.insert(notified2, msg)
end
vim.api.nvim_cmd({ cmd = "TermClose", args = { "cm" } }, {})
assert(t.terminals.cm == nil, "command closed")
assert(notified2[1] and notified2[1]:find("closed 'cm'", 1, true), vim.inspect(notified2))
vim.api.nvim_cmd({ cmd = "TermClose", args = { "ghost" } }, {})
assert(notified2[2] and notified2[2]:find("no_such_terminal", 1, true), vim.inspect(notified2))
vim.notify = real_notify2

print("RENAME-CLOSE TESTS PASSED")
