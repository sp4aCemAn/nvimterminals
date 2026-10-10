package.path = "./lua/?.lua;" .. package.path
local t = require("nvimterminals.terminals")
local c = require("nvimterminals.config")
c.setup({ terminal_cmd = "/bin/cat", size = 0.4 })

-- editor window
vim.cmd("edit /tmp/opencode_file_a.txt")
local buf_a = vim.api.nvim_get_current_buf()
local win_a = vim.api.nvim_get_current_win()
assert(vim.api.nvim_get_current_win() == win_a)

-- spawn main -> NEW split
t.toggle("main")
local main = t.terminals.main
assert(#vim.fn.win_findbuf(main.buf) == 1, "main should be in one window")
local n_win = #vim.api.nvim_list_wins()

-- toggle main -> hide, job alive
t.toggle("main")
assert(#vim.fn.win_findbuf(main.buf) == 0, "main should be hidden")
assert(vim.fn.jobwait({ main.job_id }, 0)[1] == -1, "job must keep running")
assert(vim.api.nvim_win_get_buf(win_a) == buf_a, "editor overridden on hide")

-- spawn build while no term pane open -> NEW split again
t.toggle("build")
local build = t.terminals.build
assert(#vim.fn.win_findbuf(build.buf) == 1, "build should get a window")
assert(vim.api.nvim_win_get_buf(win_a) == buf_a, "editor overridden on spawn")
local n_win_reopened = #vim.api.nvim_list_wins()
assert(n_win_reopened == n_win, "window count should be stable")

-- toggle main (hidden -> visible) while build pane open -> SWITCHES the pane, no new split
t.toggle("main")
assert(#vim.fn.win_findbuf(main.buf) == 1, "main should take over the pane")
assert(#vim.fn.win_findbuf(build.buf) == 0, "build should be hidden behind main")
assert(vim.fn.jobwait({ build.job_id }, 0)[1] == -1, "build job must keep running")
assert(#vim.api.nvim_list_wins() == n_win_reopened, "pane reuse must not create a split")
assert(vim.api.nvim_win_get_buf(win_a) == buf_a, "editor overridden on switch")

-- fresh spawn while a term pane is open -> also switches in place
t.toggle("repl")
local repl = t.terminals.repl
assert(#vim.fn.win_findbuf(repl.buf) == 1, "repl should be visible")
assert(#vim.fn.win_findbuf(main.buf) == 0, "main hidden behind repl")
assert(vim.fn.jobwait({ main.job_id }, 0)[1] == -1, "main job alive")
assert(#vim.api.nvim_list_wins() == n_win_reopened, "fresh spawn reused pane -> no new split")

-- toggle back to build: switch again
t.toggle("build")
assert(#vim.fn.win_findbuf(build.buf) == 1, "build should switch back in")
assert(#vim.api.nvim_list_wins() == n_win_reopened)

assert(vim.inspect(t.list()) == '{ "build", "main", "repl" }', vim.inspect(t.list()))

-- multi-tab: one global term pane; find_open_win must reuse across tabpages
vim.cmd("tabnew /tmp/opencode_file_c.txt")
local tab2 = vim.api.nvim_get_current_tabpage()
-- build is visible in tab1's pane; toggling from tab2 HIDES it (cross-tab close)
local wins_before = #vim.api.nvim_list_wins()
t.toggle("build")
assert(#vim.fn.win_findbuf(build.buf) == 0, "build must hide from another tab")
assert(#vim.api.nvim_list_wins() == wins_before - 1, "exactly one window closed")
assert(vim.api.nvim_get_current_tabpage() == tab2, "hide stays in the current tab")
-- reopen build: no pane exists anywhere -> split in tab2
t.toggle("build")
assert(#vim.fn.win_findbuf(build.buf) == 1, "build reopens in tab2")
assert(vim.api.nvim_get_current_tabpage() == tab2)
-- pane now lives in tab2: from tab1, toggle main -> reuse THAT pane (jump), never a 2nd window
vim.cmd("tabfirst")
local wins_tabbed = #vim.api.nvim_list_wins()
t.toggle("main")
assert(vim.api.nvim_get_current_tabpage() == tab2, "pane reuse jumps to the pane's tab")
assert(#vim.fn.win_findbuf(t.terminals.main.buf) == 1, "main in exactly one window")
assert(#vim.fn.win_findbuf(build.buf) == 0, "build swapped out of the pane")
assert(#vim.api.nvim_list_wins() == wins_tabbed, "cross-tab reopen must not add a split")

print("ALL PANE-SWITCH TESTS PASSED, list=" .. table.concat(t.list(), ","))
