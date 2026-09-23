local terminals = require("nvimterminals.terminals")

local M = {}

function M.setup(opts)
  require("nvimterminals.config").setup(opts)

  vim.api.nvim_create_user_command("TermToggle", function(e)
    terminals.toggle(e.args)
  end, { nargs = "?" })

  if vim.g.nvimterminals_keymaps == nil then
    vim.g.nvimterminals_keymaps = true
    local keymaps = require("nvimterminals.config").options.keymaps
    if keymaps and keymaps.toggle_last then
      vim.keymap.set({ "n", "t" }, keymaps.toggle_last, function()
        terminals.toggle()
      end, { silent = true, desc = "Toggle last terminal" })
    end
  end
end

return M
