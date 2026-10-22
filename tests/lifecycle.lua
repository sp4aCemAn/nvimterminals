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

-- ---------------------------------------------------------------------------
-- N1: adaptive narrow-pane fallback (owner-approved QoL). The headless screen
-- is a fixed 80x24, so the threshold lever is the explicit size:
-- floor(80*0.8)=64 clears narrow_min_width=60, floor(80*0.35)=28 does not.
-- Orientation pins: vsplit -> term and sibling editor share the full height,
-- widths differ; horizontal split -> share the full width, heights differ.
-- nvim_win_get_position rows pin top vs bottom. Only NEW splits are affected:
-- every pin below starts from "no pane visible anywhere" (hide first) so
-- show_buffer takes the split path, and F proves the reuse path is untouched.
-- ---------------------------------------------------------------------------
t.toggle("main") -- the multi-tab pane shows main: hide it first
assert(#vim.fn.win_findbuf(t.terminals.main.buf) == 0, "pane hidden before N1 pins")
vim.cmd("tabnew /tmp/opencode_file_d.txt")
local n1_ed = vim.api.nvim_get_current_win()

local function n1_term_win(name)
  local ws = vim.fn.win_findbuf(t.terminals[name].buf)
  assert(#ws == 1, "exactly one window for " .. name .. ": " .. vim.inspect(ws))
  return ws[1]
end

local function n1_is_vsplit(name)
  local w = n1_term_win(name)
  return vim.api.nvim_win_get_height(w) == vim.api.nvim_win_get_height(n1_ed)
    and vim.api.nvim_win_get_width(w) ~= vim.api.nvim_win_get_width(n1_ed)
end

local function n1_is_split(name)
  local w = n1_term_win(name)
  return vim.api.nvim_win_get_width(w) == vim.api.nvim_win_get_width(n1_ed)
    and vim.api.nvim_win_get_height(w) ~= vim.api.nvim_win_get_height(n1_ed)
end

-- nvim_win_get_position returns ONE {row, col} table from Lua (not two
-- return values): comparing it directly errors "attempt to compare two
-- table values"
local function n1_row(w)
  return vim.api.nvim_win_get_position(w)[1]
end

-- A: pane would be 64 cols (>= 60) -> primary right survives
c.setup({ terminal_cmd = "/bin/cat", size = 0.8, position = "right", narrow_min_width = 60 })
t.toggle("n1a")
assert(n1_is_vsplit("n1a"), "A: wide pane must stay a vsplit")
t.toggle("n1a") -- hide

-- B: pane would be 28 cols (< 60) -> bottom fallback, full width, LOWER row
c.setup({ terminal_cmd = "/bin/cat", size = 0.35, position = "right", narrow_min_width = 60 })
t.toggle("n1b")
assert(n1_is_split("n1b"), "B: narrow pane must fall back to a horizontal split")
local b_row = n1_row(n1_term_win("n1b"))
assert(b_row > n1_row(n1_ed), "B: fallback lands at the BOTTOM")
t.toggle("n1b") -- hide

-- C: narrow_min_width = 0 disables at the same narrow size
c.setup({ terminal_cmd = "/bin/cat", size = 0.35, position = "right", narrow_min_width = 0 })
t.toggle("n1c")
assert(n1_is_vsplit("n1c"), "C: narrow_min_width=0 disables the fallback")
t.toggle("n1c") -- hide

-- D: primary top is never converted (already horizontal; narrow_position
--    is only ever consulted for left/right primaries)
c.setup({ terminal_cmd = "/bin/cat", size = 0.35, position = "top", narrow_min_width = 60 })
t.toggle("n1d")
assert(n1_is_split("n1d"), "D: primary top stays a horizontal split")
assert(n1_row(n1_term_win("n1d")) < n1_row(n1_ed), "D: top stays TOP")
t.toggle("n1d") -- hide

-- E: bogus narrow_position keeps the primary despite narrowness
c.setup({ terminal_cmd = "/bin/cat", size = 0.35, position = "right", narrow_min_width = 60, narrow_position = "right" })
t.toggle("n1e")
assert(n1_is_vsplit("n1e"), "E: bogus narrow_position must NOT convert (primary kept)")
t.toggle("n1e") -- hide

-- F: the reuse path is untouched: a second name SWITCHES the fallback pane
--    (same window id, orientation belongs to the window, no new split)
c.setup({ terminal_cmd = "/bin/cat", size = 0.35, position = "right", narrow_min_width = 60 })
t.toggle("n1b")
local f_win = n1_term_win("n1b")
assert(n1_is_split("n1b"), "F: bottom fallback again")
local n1_wins = #vim.api.nvim_list_wins()
vim.api.nvim_set_current_win(n1_ed)
t.toggle("n1e")
assert(n1_term_win("n1e") == f_win, "F: reuse switches the SAME window")
assert(n1_is_split("n1e"), "F: orientation belongs to the window, not the name")
assert(#vim.api.nvim_list_wins() == n1_wins, "F: no new split on reuse")
t.toggle("n1e") -- hide

print("ALL PANE-SWITCH TESTS PASSED, list=" .. table.concat(t.list(), ","))
