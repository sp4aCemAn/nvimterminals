package.path = "./lua/?/init.lua;" .. package.path
package.path = "./lua/?.lua;" .. package.path
local t = require("nvimterminals.terminals")
local c = require("nvimterminals.config")
local P = require("nvimterminals")

-- Pins for the :TermPolicy presentation (W1 whitelist cleanup): float by
-- default, "split" opt-out, and UNCHANGED storage semantics (the buffer is
-- the policy; opening/closing windows never changes gating).

vim.cmd("edit /tmp/opencode_policy_win_test.txt")
local ed_win = vim.api.nvim_get_current_win()

local function wins_for(buf)
  local fl, sp = {}, {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        table.insert(fl, w)
      else
        table.insert(sp, w)
      end
    end
  end
  return fl, sp
end

local function policy_bufname_exists(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == "nvimterminals://policy/" .. name then
      return b
    end
  end
  return nil
end

P.setup({ terminal_cmd = "/bin/cat", size = 0.4, agent = { enabled = true, allow = { "*" } } })
assert(c.get("policy_window") == "float", "default policy_window is float")
t.toggle("p")
t.agent_toggle("p")

-- ---------------------------------------------------------------------------
-- 1. default: one centered float showing the policy buffer, focus inside,
--    no duplicate window
-- ---------------------------------------------------------------------------
vim.api.nvim_set_current_win(ed_win)
vim.api.nvim_cmd({ cmd = "TermPolicy", args = { "p" } }, {})
local buf = t.terminals.p.policy
assert(buf and vim.api.nvim_buf_is_valid(buf), "policy buffer attached via command")
local fl, sp = wins_for(buf)
assert(#fl == 1 and #sp == 0, "exactly one FLOAT, no split: " .. vim.inspect({ fl, sp }))
assert(vim.api.nvim_get_current_win() == fl[1], "focus moved into the float")
local cfg = vim.api.nvim_win_get_config(fl[1])
assert(cfg.relative == "editor", "editor-relative")
assert(cfg.width > 0 and cfg.height > 0, "sized float")
-- win_get_config returns title as a chunk list: { { text, hl? }, ... }
local title_text = type(cfg.title) == "table" and cfg.title[1] and cfg.title[1][1] or cfg.title
assert(type(title_text) == "string" and title_text:find("policy: p", 1, true), "titled: " .. tostring(title_text))

-- 2. re-open while visible: focused, never duplicated
vim.api.nvim_set_current_win(ed_win)
vim.api.nvim_cmd({ cmd = "TermPolicy", args = { "p" } }, {})
fl, sp = wins_for(buf)
assert(#fl == 1 and #sp == 0, "still exactly one float after reopen")
assert(vim.api.nvim_get_current_win() == fl[1], "reopen refocuses the SAME float")

-- 3. storage semantics UNCHANGED: edits gate sends, closing the float does
--    not detach nor lose them
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "^ls" })
vim.api.nvim_win_close(fl[1], true)
assert(t.terminals.p and t.terminals.p.policy == buf, "state keeps policy ref after float close")
assert(vim.api.nvim_buf_is_valid(buf), "buffer survives its float window")
local r = t.send("p", "ls")
assert(r.ok, vim.inspect(r))
r = t.send("p", "rm x")
assert(r.ok == false and r.reason == "policy_denied", vim.inspect(r))

-- 4. "split" opt-out presents in a real window; existing view wins over mode
--    (reopen keeps focusing the already-shown window, float or split)
c.setup({ terminal_cmd = "/bin/cat", size = 0.4, agent = { enabled = true, allow = { "*" } }, policy_window = "split" })
vim.api.nvim_cmd({ cmd = "TermPolicy", args = { "p" } }, {})
fl, sp = wins_for(buf)
assert(#fl == 0 and #sp == 1, "split mode opens a window split: " .. vim.inspect({ fl, sp }))
assert(vim.api.nvim_get_current_win() == sp[1], "split focused")
-- a visible split wins even when the mode is float again:
c.setup({ terminal_cmd = "/bin/cat", size = 0.4, agent = { enabled = true, allow = { "*" } }, policy_window = "float" })
vim.api.nvim_cmd({ cmd = "TermPolicy", args = { "p" } }, {})
fl, sp = wins_for(buf)
assert(#fl == 0 and #sp == 1, "existing display is never converted behind the user's back")
-- once nothing shows it, float mode applies again:
vim.api.nvim_win_close(sp[1], true)
vim.api.nvim_cmd({ cmd = "TermPolicy", args = { "p" } }, {})
fl, sp = wins_for(buf)
assert(#fl == 1 and #sp == 0, "float again when unshown")

-- 5. unknown name: pre-creates the buffer AND floats it (existing contract)
vim.api.nvim_set_current_win(ed_win)
vim.api.nvim_cmd({ cmd = "TermPolicy", args = { "ghostq" } }, {})
assert(t.terminals.ghostq == nil, "still no such terminal")
local gb = policy_bufname_exists("ghostq")
assert(gb, "policy buffer pre-created for unknown name")
fl = wins_for(gb)
assert(#fl == 1, "ghost policy floated")
vim.api.nvim_buf_delete(gb, { force = true })

-- 6. no current terminal + no args: error notify, no windows opened
t.close("p")
assert(t.get_current() == nil, "current cleared")
local wins0 = #vim.api.nvim_list_wins()
local real_notify = vim.notify
local notified = {}
vim.notify = function(msg, level, o)
  table.insert(notified, msg)
end
vim.api.nvim_cmd({ cmd = "TermPolicy", args = {} }, {})
vim.notify = real_notify
assert(#notified == 1 and notified[1]:find("no terminal", 1, true), vim.inspect(notified))
assert(#vim.api.nvim_list_wins() == wins0, "no window opened on error")

print("POLICY-WINDOW TESTS PASSED")
