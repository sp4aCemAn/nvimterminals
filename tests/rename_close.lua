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
--   - surgical (manual table-surgery) renames show which subsystems are
--     rename-agnostic (wipeout autocmd, list/select/get/send/lines,
--     VimLeavePre) and which are NOT (the on_exit name closure -> KNOWN-ISSUE
--     below, flipped by R2's job-id resolution).

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
-- 3. KNOWN-ISSUE (R2 flips this pin): on_exit_cb captures the terminal NAME
--    at spawn (terminals.lua:102). A rename done ANY other way than key-identity
--    preservation strands the exit update under the old key: after surgical
--    rename + jobstop, today the state never sees dead/exit_code and NO event
--    fires. R2's flip asserts, with M.rename("k1", "k2") then jobstop of the
--    renamed job: state.dead == true, state.exit_code == 129 (SIGTERM via the
--    pty shell, probed), and NvimterminalsExit carries ev.name == "k2".
-- ---------------------------------------------------------------------------
c.setup({ terminal_cmd = "/bin/cat", size = 0.4 })
t.toggle("k1")
local k = t.terminals.k1
t.terminals.k2 = k
t.terminals.k1 = nil
assert(pcall(vim.api.nvim_buf_set_name, k.buf, "term://k2"), "surgical bufname set")
vim.fn.jobstop(k.job_id)
vim.wait(500, function() return false end)
assert(k.dead ~= true, "KNOWN-ISSUE still open: dead must stay unset today, got " .. tostring(k.dead))
assert(k.exit_code == nil, "KNOWN-ISSUE still open: exit_code must stay unset today")
assert(#exits == 1, "KNOWN-ISSUE still open: no exit event for renamed-away job today (dd's is the only one), got " .. vim.inspect(exits))

-- ---------------------------------------------------------------------------
-- 4. rename-agnosticism after surgical rename: identity, lookups, gating,
--    wipeout-autocmd, picker, VimLeavePre echo
-- ---------------------------------------------------------------------------
drop("k2")
t.toggle("v1")
local v = t.terminals.v1
local v_id = v
t.terminals.v2 = v
t.terminals.v1 = nil
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
-- 5. term:// bufname: set at spawn, never re-taken by nvim (rename relies on
--    this holding after nvim_buf_set_name too)
-- ---------------------------------------------------------------------------
t.toggle("nm")
assert(vim.api.nvim_buf_get_name(t.terminals.nm.buf) == "term://nm", "spawn name")
vim.wait(300, function() return false end)
assert(vim.api.nvim_buf_get_name(t.terminals.nm.buf) == "term://nm", "name not re-taken")
drop("nm")

print("RENAME-CLOSE TESTS PASSED")
