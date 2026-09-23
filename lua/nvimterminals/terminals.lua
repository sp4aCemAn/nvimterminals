local config = require("nvimterminals.config")

local M = {}

-- name -> state
M.terminals = {}
M.current = nil

local function create_split(name)
  local position = config.get("position")
  local size = config.get("size")
  local width = math.floor(vim.o.columns * size)
  local height = math.floor(vim.o.lines * size)

  local cmds = {
    right = string.format("rightbelow %dvsplit", width),
    left = string.format("leftabove %dvsplit", width),
    top = string.format("leftabove %dsplit", height),
    bottom = string.format("rightbelow %dsplit", height),
  }

  vim.cmd(cmds[position] or cmds.right)
  vim.api.nvim_buf_set_name(0, "term://" .. name)
  vim.api.nvim_set_option_value("buflisted", false, { buf = 0 })
end

function M.toggle(name)
  name = name or M.current or "main"

  local state = M.terminals[name]
  local buf = state and state.buf

  -- buffer exists and job is running
  if buf and vim.api.nvim_buf_is_valid(buf) and vim.fn.jobwait({ state.job_id }, 0)[1] == -1 then
    local win = vim.fn.win_findbuf(buf)[1]
    if win then
      -- visible -> hide it (job keeps running)
      vim.api.nvim_win_close(win, false)
      M.current = name
      return
    end
    -- hidden -> reopen it in a split
    create_split(name)
    vim.cmd("buffer " .. buf)
    M.current = name
    return
  end

  -- no terminal yet (or job died) -> spawn fresh
  create_split(name)
  buf = vim.api.nvim_get_current_buf()
  local job_id = vim.fn.termopen(config.get("terminal_cmd"), {
    name = name,
    on_exit = function()
      M.terminals[name] = nil
      if M.current == name then
        M.current = nil
      end
    end,
  })
  M.terminals[name] = { buf = buf, job_id = job_id }
  M.current = name
end

function M.get_current()
  return M.current
end

return M
