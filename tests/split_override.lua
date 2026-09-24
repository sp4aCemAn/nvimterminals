package.path = "./lua/?.lua;" .. package.path
local t = require("nvimterminals.terminals")
local c = require("nvimterminals.config")
c.setup({ terminal_cmd = "/bin/cat", size = 0.4 })

-- editor window with a file-like buffer
vim.cmd("edit /tmp/opencode_file_a.txt")
vim.bo.filetype = "txt"
local buf_a = vim.api.nvim_get_current_buf()
local win_a = vim.api.nvim_get_current_win()

-- spawn main
t.toggle("main")
local main = t.terminals.main

-- is win_a still showing buf_a? (did the split "override" it?)
assert(vim.api.nvim_win_get_buf(win_a) == buf_a, "BUG1: win_a buf overridden -> " .. vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win_a)))

-- jump back to editor, spawn a SECOND named terminal
vim.api.nvim_set_current_win(win_a)
t.toggle("repl")
local repl = t.terminals.repl
assert(vim.api.nvim_win_get_buf(win_a) == buf_a, "BUG2: editor overridden after 2nd term")

-- from INSIDE the term window, spawn a third
local mainwin = vim.fn.win_findbuf(main.buf)[1]
local main_col = vim.fn.win_screenpos(mainwin)[2]
vim.api.nvim_set_current_win(mainwin)
t.toggle("third")
assert(t.terminals.third, "BUG3: spawn from inside term failed")
assert(vim.api.nvim_win_get_buf(win_a) == buf_a, "BUG4: editor overridden spawning from term")
local anchored = vim.fn.win_findbuf(t.terminals.third.buf)[1]
assert(vim.fn.win_screenpos(anchored)[2] < main_col, "BUG6: new term split anchored to term window, not editor")

-- full inventory: every terminal buf has its own window
for name, s in pairs(t.terminals) do
  assert(#vim.fn.win_findbuf(s.buf) >= 1, name .. " has no window")
end

-- no buffer is displayed in a window that isn't its own terminal
local seen = {}
for name, s in pairs(t.terminals) do
  for _, w in ipairs(vim.fn.win_findbuf(s.buf)) do
    seen[w] = name
  end
end
assert(vim.api.nvim_win_get_buf(win_a) == buf_a, "BUG5: editor buf got swapped at some point")

print("REPO TEST PASSED - list=" .. table.concat(t.list(), ","))
