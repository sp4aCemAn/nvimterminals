local M = {}

M.defaults = {
  position = "right",
  size = 0.35,
  terminal_cmd = vim.o.shell,
  keymaps = {
    toggle_last = "<C-\\>",
  },
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
  return M.options
end

function M.get(key)
  return M.options[key]
end

return M
