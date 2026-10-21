local M = {}

M.defaults = {
  position = "right",
  size = 0.35,
  -- resolved lazily (on use) so setup() at startup sees the real 'shell',
  -- not whatever vim.o.shell was when this file was first required
  terminal_cmd = function()
    return vim.o.shell
  end,
  keymaps = {
    toggle_last = "<C-\\>",
    menu = "<leader>tt",
  },
  -- how :TermPolicy presents the policy scratch buffer: "float" (centered
  -- window; the buffer is storage, closing the window changes nothing) or
  -- "split" (legacy: botright 20vsplit).
  policy_window = "float",
  agent = {
    enabled = false,
    allow = {},
  },
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
  return M.options
end

function M.get(key)
  local v = M.options[key]
  if v == nil then
    v = M.defaults[key]
  end
  if type(v) == "function" then
    return v()
  end
  return v
end

return M
