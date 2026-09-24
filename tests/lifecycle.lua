package.path = "./lua/?.lua;" .. package.path
local t = require("nvimterminals.terminals")
local c = require("nvimterminals.config")
c.setup({ terminal_cmd = "/bin/cat", size = 0.4 })

-- spawn "main"
t.toggle("main")
local main = t.terminals.main
assert(main and vim.api.nvim_buf_is_valid(main.buf), "spawn failed")
local mainwin = vim.fn.win_findbuf(main.buf)
assert(#mainwin == 1, "term buffer should be in exactly ONE window, got " .. #mainwin)

-- user opens a second buffer/window (simulate their workflow)
vim.cmd("new")
local editor_buf = vim.api.nvim_get_current_buf()

-- toggle main again -> should hide, not touch editor buffer
t.toggle("main")
assert(#vim.fn.win_findbuf(main.buf) == 0, "main should be hidden")
assert(vim.api.nvim_buf_is_valid(editor_buf), "editor buffer must survive hide")
assert(vim.fn.jobwait({ main.job_id }, 0)[1] == -1, "job must keep running when hidden")

-- toggle main again -> reopens SAME buffer
t.toggle("main")
assert(#vim.fn.win_findbuf(main.buf) == 1, "main should reopen in one window")

-- second named terminal coexists
t.toggle("build")
assert(t.terminals.build and t.terminals.build.buf ~= main.buf, "second terminal must be distinct")
assert(vim.api.nvim_buf_is_valid(main.buf), "jobs must not interfere")

-- lists both, picker selection does not error
assert(vim.inspect(t.list()) == '{ "build", "main" }', "list bad: " .. vim.inspect(t.list()))

print("ALL LIFECYCLE TESTS PASSED, list=" .. table.concat(t.list(), ","))
