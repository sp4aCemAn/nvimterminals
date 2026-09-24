local config = require("nvimterminals.config")

local M = {}

-- name -> { buf, job_id }
M.terminals = {}
M.current = nil

local function tab_wins(tabpage)
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_tabpage(win) == tabpage
  end, vim.api.nvim_list_wins())
end

local function anchor_win()
  local cur = vim.api.nvim_get_current_win()
  if vim.bo[vim.api.nvim_win_get_buf(cur)].buftype ~= "terminal" then
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= cur and vim.bo[vim.api.nvim_win_get_buf(win)].buftype ~= "terminal" then
      vim.api.nvim_set_current_win(win)
      return
    end
  end
end

-- find a window in the current tab displaying one of our terminals
function M.find_open_win()
  local tabpage = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_tabpage(win) == tabpage then
      local buf = vim.api.nvim_win_get_buf(win)
      for _, state in pairs(M.terminals) do
        if state.buf == buf then
          return win
        end
      end
    end
  end
  return nil
end

-- display a terminal buffer: reuse the open term pane if there is one,
-- otherwise open a new split anchored to an editor window
local function show_buffer(bufnr)
  local existing = M.find_open_win()
  if existing then
    vim.api.nvim_win_set_buf(existing, bufnr)
    vim.api.nvim_set_current_win(existing)
    return
  end
  anchor_win()
  local position = config.get("position")
  local size = config.get("size")
  local cmds = {
    right = string.format("rightbelow %dvsplit", math.floor(vim.o.columns * size)),
    left = string.format("leftabove %dvsplit", math.floor(vim.o.columns * size)),
    top = string.format("leftabove %dsplit", math.floor(vim.o.lines * size)),
    bottom = string.format("rightbelow %dsplit", math.floor(vim.o.lines * size)),
  }
  vim.cmd(cmds[position] or cmds.right)
  vim.api.nvim_win_set_buf(0, bufnr)
end

local function job_running(state)
  return state ~= nil
    and vim.api.nvim_buf_is_valid(state.buf)
    and vim.fn.jobwait({ state.job_id }, 0)[1] == -1
end

function M.toggle(name)
  name = name or M.current or "main"
  local state = M.terminals[name]

  if job_running(state) then
    local tabpage = vim.api.nvim_get_current_tabpage()
    for _, win in ipairs(vim.fn.win_findbuf(state.buf)) do
      if vim.api.nvim_win_get_tabpage(win) == tabpage then
        if #tab_wins(tabpage) == 1 then
          vim.notify("nvimterminals: terminal is the only window in this tab", vim.log.levels.WARN)
        else
          vim.api.nvim_win_close(win, false)
        end
        M.current = name
        return
      end
    end
    show_buffer(state.buf)
    M.current = name
    return
  end

  -- spawn fresh: reuses the open term pane if one exists, else new split
  local bufnr = vim.api.nvim_create_buf(false, false)
  show_buffer(bufnr)
  local job_id = vim.fn.termopen(config.get("terminal_cmd"), {
    on_exit = function()
      M.terminals[name] = nil
      if M.current == name then
        M.current = nil
      end
    end,
  })
  pcall(vim.api.nvim_buf_set_name, bufnr, "term://" .. name)
  M.terminals[name] = { buf = bufnr, job_id = job_id }
  M.current = name
end

function M.list()
  local names = {}
  for name, state in pairs(M.terminals) do
    if vim.api.nvim_buf_is_valid(state.buf) then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

function M.select()
  local names = M.list()
  if #names == 0 then
    M.toggle()
    return
  end
  vim.ui.select(names, {
    prompt = "Select terminal: ",
    format_item = function(name)
      local state = M.terminals[name]
      local visible = #vim.fn.win_findbuf(state.buf) > 0
      return string.format("%s %s", visible and "[open]  " or "[hidden]", name)
    end,
  }, function(choice)
    if choice then
      M.toggle(choice)
    end
  end)
end

function M.get_current()
  return M.current
end

return M
