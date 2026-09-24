package.path = "./lua/?.lua;" .. package.path
local t = require("nvimterminals.terminals")
local c = require("nvimterminals.config")
c.setup({ terminal_cmd = "/bin/cat", size = 0.4 })

-- editor window with a file-like buffer
vim.cmd("edit /tmp/opencode_file_b.txt")
vim.bo.filetype = "txt"
local buf_a = vim.api.nvim_get_current_buf()
local win_a = vim.api.nvim_get_current_win()

-- spawn main
t.toggle("main")
local main = t.terminals.main
assert(vim.api.nvim_get_current_win() ~= win_a, "focus should be in the term pane")
assert(vim.api.nvim_win_get_buf(win_a) == buf_a, "BUG1: win_a overridden")

-- from INSIDE the term pane, spawn a second name -> switches pane, no new split
local n_win = #vim.api.nvim_list_wins()
t.toggle("repl")
local repl = t.terminals.repl
assert(vim.api.nvim_win_get_buf(win_a) == buf_a, "BUG2: editor overridden")
assert(#vim.fn.win_findbuf(repl.buf) == 1, "repl visible")
assert(#vim.fn.win_findbuf(main.buf) == 0, "main hidden behind repl")
assert(#vim.api.nvim_list_wins() == n_win, "must reuse pane, not split")
assert(vim.fn.jobwait({ main.job_id }, 0)[1] == -1, "main job alive")

-- switch back to main from the editor window
vim.api.nvim_set_current_win(win_a)
t.toggle("main")
assert(vim.api.nvim_win_get_buf(win_a) == buf_a, "BUG3: editor overridden on switch back")
assert(#vim.fn.win_findbuf(main.buf) == 1, "main back")
assert(#vim.api.nvim_list_wins() == n_win, "no new split")

print("SPLIT-OVERRIDE GUARD TESTS PASSED, list=" .. table.concat(t.list(), ","))
