local terminals = require("nvimterminals.terminals")

local M = {}

function M.setup(opts)
  local config = require("nvimterminals.config")
  config.setup(opts)

  vim.api.nvim_create_user_command("TermToggle", function(e)
    terminals.toggle(e.args)
  end, {
    nargs = "?",
    desc = "Toggle a named persistent terminal",
    complete = function(arglead)
      return vim.tbl_filter(function(name)
        return name:find(arglead, 1, true) ~= nil
      end, terminals.list())
    end,
  })

  vim.api.nvim_create_user_command("Terms", function()
    terminals.select()
  end, { desc = "List and pick a terminal" })

  if vim.g.nvimterminals_keymaps == nil then
    vim.g.nvimterminals_keymaps = true
    local keymaps = config.options.keymaps
    if keymaps and keymaps.toggle_last then
      vim.keymap.set({ "n", "t" }, keymaps.toggle_last, function()
        terminals.toggle()
      end, { silent = true, desc = "Toggle last terminal" })
    end
  end
end

return M
