package.path = "./lua/?.lua;" .. package.path
local t = require("nvimterminals.terminals")
local c = require("nvimterminals.config")

-- Characterization pins for the VimLeavePre "still running at exit" echo
-- (terminals.lua). The echo is UI-gated (#nvim_list_uis() > 0) and headless
-- has NO UI, so the message never reaches stdout here — that is precisely why
-- the other suites' `tail -1` sentinel checks are safe. Section 3 pins that
-- gate. Sections 1-2 stub the UI + echo surface and fire the autocmd directly
-- to pin WHICH names get reported and in what shape.
-- Restore stubs BY REFERENCE: setting vim.api fields to = nil leaves the lazy
-- api dispatcher broken (probe: nvim_list_uis became a nil value at exit).

local real_echo = vim.api.nvim_echo
local real_uis = vim.api.nvim_list_uis
local real_notify = vim.notify

vim.cmd("edit /tmp/opencode_leave_test.txt")
c.setup({ terminal_cmd = "/bin/cat", size = 0.4 })

-- ---------------------------------------------------------------------------
-- 1. no terminals yet -> autocmd runs silently even with a UI present
-- ---------------------------------------------------------------------------
local echoed = {}
vim.api.nvim_list_uis = function()
  return { [1] = 7 }
end
vim.api.nvim_echo = function(content, err, opts)
  table.insert(echoed, { content, err, opts })
end
vim.notify = function(msg, level, opts)
  error("unexpected vim.notify during leave echo: " .. tostring(msg))
end
vim.api.nvim_exec_autocmds("VimLeavePre", { group = "nvimterminals" })
assert(#echoed == 0, "echoed with zero terminals: " .. vim.inspect(echoed))

-- ---------------------------------------------------------------------------
-- 2. running + dead terminals -> sorted running names only, exact text
-- ---------------------------------------------------------------------------
t.toggle("zeta")
t.toggle("alpha")
c.setup({ terminal_cmd = "exit 3", size = 0.4 })
t.toggle("gone")
assert(vim.wait(3000, function() return t.terminals.gone and t.terminals.gone.dead end), "gone never died")
local gone_exit = t.terminals.gone.exit_code
assert(gone_exit == 3, "gone exit code: " .. tostring(gone_exit))

echoed = {}
vim.api.nvim_exec_autocmds("VimLeavePre", { group = "nvimterminals" })
assert(#echoed == 1, "expected exactly one echo: " .. vim.inspect(echoed))
local content, err, opts = echoed[1][1], echoed[1][2], echoed[1][3]
assert(err == false, "echo must use err=false (stderr would break headless tail): " .. tostring(err))
assert(type(opts) == "table" and next(opts) == nil, "echo opts must be empty: " .. vim.inspect(opts))
assert(type(content) == "table" and #content == 1, "single echo chunk expected: " .. vim.inspect(content))
local text = content[1][1]
assert(text == "nvimterminals: still running at exit: alpha, zeta", "got: " .. tostring(text))
-- gone is dead and must not be reported (and job_running must beat buf validity)
assert(not text:find("gone", 1, true), "dead terminal reported: " .. text)

-- ---------------------------------------------------------------------------
-- 3. headless reality check: with the REAL ui list, nothing is echoed even
--    while terminals run (the #nvim_list_uis() > 0 gate)
-- ---------------------------------------------------------------------------
vim.api.nvim_list_uis = real_uis
echoed = {}
vim.api.nvim_exec_autocmds("VimLeavePre", { group = "nvimterminals" })
assert(#echoed == 0, "echoed despite no UI (headless): " .. vim.inspect(echoed))

vim.api.nvim_echo = real_echo
vim.notify = real_notify
-- the real `qa` below now fires the autocmd with no UI: no stdout after the
-- sentinel, which this test's own runner check relies on (`tail -1`).
print("LEAVE-NOTIFY TESTS PASSED, running=alpha,zeta")
