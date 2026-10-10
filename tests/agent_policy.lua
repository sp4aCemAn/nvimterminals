package.path = "./lua/?.lua;" .. package.path
local t = require("nvimterminals.terminals")
local c = require("nvimterminals.config")
local agent = require("nvimterminals.agent")

vim.cmd("edit /tmp/opencode_agent_test.txt")

-- ---------------------------------------------------------------------------
-- 1. jobstart migration: numeric job id + pid captured, buffer converted
-- ---------------------------------------------------------------------------
c.setup({ terminal_cmd = "/bin/cat", size = 0.4 })
t.toggle("pty")
local pty = t.terminals.pty
assert(type(pty.job_id) == "number" and pty.job_id > 0, "job id")
assert(type(pty.pid) == "number" and pty.pid > 0, "pid: " .. tostring(pty.pid))
assert(vim.bo[pty.buf].buftype == "terminal", "term buffer")

-- ---------------------------------------------------------------------------
-- 2. send -> chansend actually lands in the pty (read buffer back)
-- ---------------------------------------------------------------------------
c.setup({ terminal_cmd = "/bin/cat", size = 0.4, agent = { enabled = true, allow = { "*" } } })
t.agent_toggle("pty")
local r = t.send("pty", "hello-pty-xyz\r")
assert(r.ok, vim.inspect(r))
local found = vim.wait(3000, function()
  local read = t.lines("pty", { n = 200 })
  for _, l in ipairs(read.lines) do
    if l.text:find("hello-pty-xyz", 1, true) then
      return true
    end
  end
end)
assert(found, "sent bytes did not land in the pty")
local read = t.lines("pty", { n = 5 })
assert(read.ok and read.start > 0 and read.lines[1].lnum >= read.start, "lines carry buffer line numbers")

-- ---------------------------------------------------------------------------
-- 3. gating matrix: BOTH switches required; global kill switch beats all
-- ---------------------------------------------------------------------------
c.setup({ terminal_cmd = "/bin/cat", size = 0.4, agent = { enabled = true, allow = { "*" } } })
t.toggle("gate")
r = t.send("gate", "ls")
assert(r.ok == false and r.reason == "agent_disabled", "terminal switch off: " .. vim.inspect(r))
t.agent_toggle("gate")
assert(t.terminals.gate.agent_enabled, "gate agent on")
r = t.send("gate", "ls")
assert(r.ok, "both switches on + wildcard: " .. vim.inspect(r))
c.setup({ terminal_cmd = "/bin/cat", size = 0.4, agent = { enabled = false, allow = {} } })
r = t.send("gate", "ls")
assert(r.ok == false and r.reason == "agent_disabled", "global kill switch beats terminal+wildcard: " .. vim.inspect(r))

-- no_such_terminal contract
r = t.send("ghost", "ls")
assert(r.ok == false and r.reason == "no_such_terminal", vim.inspect(r))
local lr = t.lines("ghost", {})
assert(lr.ok == false and lr.reason == "no_such_terminal", vim.inspect(lr))
local ok_tog, err_name = t.agent_toggle("ghost")
assert(ok_tog == nil and err_name == "ghost", vim.inspect({ ok_tog, err_name }))

-- read is NOT gated: works even with global disabled
lr = t.lines("gate", { n = 10 })
assert(lr.ok, vim.inspect(lr))

-- ---------------------------------------------------------------------------
-- 4. policy semantics
-- ---------------------------------------------------------------------------
-- global fallback (no policy buffer) uses config.agent.allow
c.setup({ terminal_cmd = "/bin/cat", size = 0.4, agent = { enabled = true, allow = { "^ls", "^echo" } } })
t.toggle("pol")
t.agent_toggle("pol")
assert(t.send("pol", "ls -la").ok, "global fallback allow")
r = t.send("pol", "rm -rf /")
assert(r.ok == false and r.reason == "policy_denied" and r.detail == "rm -rf /", vim.inspect(r))

-- policy buffer overrides global
local bufname, pbuf = t.policy_buffer("pol", true)
assert(bufname == "nvimterminals://policy/pol", bufname)
assert(pbuf and vim.api.nvim_buf_is_valid(pbuf))
assert(vim.bo[pbuf].buflisted == false, "policy buffer unlisted")
vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { "^git", "deny ls" })
assert(t.send("pol", "git status").ok, "buffer allow")
r = t.send("pol", "ls")
assert(r.ok == false and r.reason == "policy_denied" and r.detail == "pattern: ls", vim.inspect(r))
r = t.send("pol", "echo hi")
assert(r.ok == false and r.detail == "echo hi", "global allow ignored once buffer exists: " .. vim.inspect(r))

-- '*' wildcard + deny precedence over allows
vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { "*", "deny secret" })
assert(t.send("pol", "anything at all").ok, "wildcard")
r = t.send("pol", "rm secret thing")
assert(r.ok == false and r.reason == "policy_denied" and r.detail == "pattern: secret", vim.inspect(r))

-- every line of a multi-line send must pass
r = t.send("pol", "ok line\rsecret here\r")
assert(r.ok == false and r.reason == "policy_denied", vim.inspect(r))

-- empty / comment-only policy denies everything
vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { "# nothing here", "" })
r = t.send("pol", "ls")
assert(r.ok == false and r.reason == "policy_denied", vim.inspect(r))

-- patterns are plain Lua patterns, matched with find(line, pat, 1, false)
local pol = agent.parse({ "^echo hello$" })
assert(agent.check("echo hello", pol))
assert(not (agent.check("say echo hello", pol)))

-- lstrip strips leading whitespace of outgoing lines
c.setup({ terminal_cmd = "/bin/cat", size = 0.4, agent = { enabled = true, allow = { "*" } } })
local lpty = t.terminals.pty
local before = vim.api.nvim_buf_line_count(lpty.buf)
r = t.send("pty", "  \tleft-pad-test\r", { lstrip = true })
assert(r.ok, vim.inspect(r))
local landed = vim.wait(3000, function()
  for _, l in ipairs(t.lines("pty", { n = 200 }).lines) do
    if l.text:find("left-pad-test", 1, true) then
      return true
    end
  end
end)
assert(landed, "lstrip send did not land")
assert(vim.api.nvim_buf_line_count(lpty.buf) >= before)

-- ---------------------------------------------------------------------------
-- 5. dead-state persistence + NvimterminalsExit event + respawn cleanup
-- ---------------------------------------------------------------------------
local exits = {}
vim.api.nvim_create_autocmd("User", {
  pattern = "NvimterminalsExit",
  callback = function(ev)
    table.insert(exits, ev.data)
  end,
})

c.setup({ terminal_cmd = "exit 7", size = 0.4, agent = { enabled = true, allow = { "*" } } })
t.toggle("dying")
local dying = t.terminals.dying
local dying_buf = dying.buf
assert(vim.wait(3000, function() return t.terminals.dying and t.terminals.dying.dead end), "never died")
assert(t.terminals.dying.exit_code == 7, "exit code: " .. tostring(t.terminals.dying.exit_code))
assert(vim.api.nvim_buf_is_valid(dying_buf), "buffer must survive for scrollback")
local d0 = t.lines("dying", { n = 50 })
assert(d0.ok and d0.dead, "lines() sees dead terminal")
r = t.send("dying", "ls")
assert(r.ok == false and r.reason == "no_such_terminal", "send to dead: " .. vim.inspect(r))

local ev = exits[1]
assert(ev and ev.name == "dying" and ev.exit_code == 7 and ev.buf == dying_buf and ev.job_id == dying.job_id, vim.inspect(exits))

-- respawn: old buffer deleted BEFORE the new one, single window
t.toggle("dying") -- spawns exit 7 again
local dying2 = t.terminals.dying
assert(dying2.buf ~= dying_buf, "respawn got a new buffer")
assert(not vim.api.nvim_buf_is_valid(dying_buf), "old buffer leaked on respawn")
assert(#vim.fn.win_findbuf(dying2.buf) == 1, "exactly one window for respawned term")

-- explicit buffer deletion is the ONLY thing that drops state
local pty_buf = t.terminals.pty.buf
vim.api.nvim_buf_delete(pty_buf, { force = true })
assert(vim.wait(3000, function() return t.terminals.pty == nil end), "state must drop on BufDelete")
r = t.send("pty", "ls")
assert(r.ok == false and r.reason == "no_such_terminal", vim.inspect(r))

-- ---------------------------------------------------------------------------
-- 6. respawn inherits agent settings; dead-state jobstop does not fire twice
-- ---------------------------------------------------------------------------
c.setup({ terminal_cmd = "/bin/cat", size = 0.4, agent = { enabled = true, allow = {} } })
t.toggle("carry")
t.agent_toggle("carry")
assert(t.terminals.carry.agent_enabled, "carry enabled")
local carry_buf_old = t.terminals.carry.buf
vim.fn.jobstop(t.terminals.carry.job_id)
assert(vim.wait(3000, function() return t.terminals.carry.dead end), "carry died")
t.toggle("carry") -- respawn cat
local carry = t.terminals.carry
assert(carry.buf ~= carry_buf_old and not vim.api.nvim_buf_is_valid(carry_buf_old), "carry respawn clean")
assert(carry.agent_enabled == true, "agent_enabled survives respawn")
r = t.send("carry", "anything")
assert(r.ok == false and r.reason == "policy_denied", "empty global allow denies: " .. vim.inspect(r))

-- the respawned "exit 7" job must die again on its own (async delivery)
assert(vim.wait(4000, function() return t.terminals.dying and t.terminals.dying.dead end), "respawned dying never died")

-- ---------------------------------------------------------------------------
-- 7. malformed Lua patterns fail CLOSED (send must never raise)
-- ---------------------------------------------------------------------------
c.setup({ terminal_cmd = "/bin/cat", size = 0.4, agent = { enabled = true, allow = { "*" } } })
t.toggle("badpat")
t.agent_toggle("badpat")
local _, badbuf = t.policy_buffer("badpat", true)
-- malformed ALLOW -> treated as a miss -> no allow matches -> policy_denied
vim.api.nvim_buf_set_lines(badbuf, 0, -1, false, { "[" })
local ok_call, res_bad = pcall(t.send, "badpat", "ls")
assert(ok_call, "send raised on malformed allow pattern: " .. tostring(res_bad))
assert(res_bad.ok == false and res_bad.reason == "policy_denied", vim.inspect(res_bad))
-- malformed DENY -> treated as a match -> denies even when '*' would allow
vim.api.nvim_buf_set_lines(badbuf, 0, -1, false, { "*", "deny [" })
local ok_call2, res_bad2 = pcall(t.send, "badpat", "ls")
assert(ok_call2, "send raised on malformed deny pattern: " .. tostring(res_bad2))
assert(res_bad2.ok == false and res_bad2.reason == "policy_denied" and res_bad2.detail == "pattern: [", vim.inspect(res_bad2))
vim.fn.jobstop(t.terminals.badpat.job_id)

-- ---------------------------------------------------------------------------
-- 8. M.get + lines() runtime fields (pid / running / exit_code)
-- ---------------------------------------------------------------------------
assert(t.get("carry") == t.terminals.carry, "M.get returns the live state table")
assert(t.get("ghost") == nil, "M.get on unknown -> nil")

-- running terminal: running=true, numeric pid, no exit code yet
t.toggle("cat8")
local r_live = t.lines("cat8", { n = 10 })
assert(r_live.ok and r_live.running == true, vim.inspect(r_live.running))
assert(type(r_live.pid) == "number", "lines() pid: " .. tostring(r_live.pid))
assert(r_live.exit_code == nil, "running has no exit_code")

-- exited terminal: running=false, dead=true, exit_code surfaced
c.setup({ terminal_cmd = "exit 42", size = 0.4, agent = { enabled = true, allow = { "*" } } })
t.toggle("gone")
assert(vim.wait(4000, function() return t.terminals.gone and t.terminals.gone.dead end), "gone never died")
local r_dead = t.lines("gone", { n = 10 })
assert(r_dead.ok and r_dead.running == false and r_dead.dead == true, vim.inspect(r_dead))
assert(r_dead.exit_code == 42, "lines() exit_code: " .. tostring(r_dead.exit_code))

-- ---------------------------------------------------------------------------
-- 9. picker formatting: [agent] marker, [dead] marker, no race on vanished state
-- ---------------------------------------------------------------------------
local real_select = vim.ui.select
local sel_fmt
vim.ui.select = function(items, opts, cb)
  sel_fmt = {}
  for _, it in ipairs(items) do
    table.insert(sel_fmt, opts.format_item(it))
  end
  cb(nil)
end
t.select()
vim.ui.select = real_select
local has_agent, has_dead = false, false
for _, line in ipairs(sel_fmt) do
  if line:find("carry", 1, true) and line:find("[agent]", 1, true) then
    has_agent = true
  end
  if line:find("[dead]", 1, true) then
    has_dead = true
  end
end
assert(has_agent, "[agent] marker missing: " .. vim.inspect(sel_fmt))
assert(has_dead, "[dead] marker missing: " .. vim.inspect(sel_fmt))

print("AGENT-POLICY TESTS PASSED")
