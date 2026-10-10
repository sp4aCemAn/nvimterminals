local terminals = require("nvimterminals.terminals")

local M = {}

local function complete_names(arglead)
  return vim.tbl_filter(function(name)
    return name:find(arglead, 1, true) ~= nil
  end, terminals.list())
end

function M.setup(opts)
  local config = require("nvimterminals.config")
  config.setup(opts)

  vim.api.nvim_create_user_command("TermToggle", function(e)
    terminals.toggle(e.args)
  end, {
    nargs = "?",
    desc = "Toggle a named persistent terminal",
    complete = complete_names,
  })

  vim.api.nvim_create_user_command("Terms", function()
    terminals.select()
  end, { desc = "List and pick a terminal" })

  vim.api.nvim_create_user_command("TermAgent", function(e)
    local name = vim.trim(e.args)
    local enabled, result = terminals.agent_toggle(name ~= "" and name or nil)
    if enabled == nil then
      vim.notify("nvimterminals: no such terminal: " .. tostring(result), vim.log.levels.ERROR)
    else
      vim.notify("nvimterminals: agent control " .. (enabled and "ENABLED" or "disabled") .. " for '" .. result .. "'")
    end
  end, {
    nargs = "?",
    desc = "Toggle agent control for a terminal",
    complete = complete_names,
  })

  vim.api.nvim_create_user_command("TermPolicy", function(e)
    local name = vim.trim(e.args)
    name = name ~= "" and name or terminals.get_current()
    if not name then
      vim.notify("nvimterminals: no terminal (pass a name or open one first)", vim.log.levels.ERROR)
      return
    end
    local _, bufnr = terminals.policy_buffer(name, true)
    local win = bufnr and vim.fn.win_findbuf(bufnr)[1]
    if win then
      vim.api.nvim_set_current_win(win)
    elseif bufnr then
      vim.cmd("botright 20vsplit")
      vim.api.nvim_win_set_buf(0, bufnr)
    end
  end, {
    nargs = "?",
    desc = "Edit the agent command whitelist for a terminal",
    complete = complete_names,
  })

  if vim.g.nvimterminals_keymaps == nil then
    vim.g.nvimterminals_keymaps = true
    local keymaps = config.options.keymaps
    if keymaps and keymaps.toggle_last then
      vim.keymap.set({ "n", "t" }, keymaps.toggle_last, function()
        terminals.toggle()
      end, { silent = true, desc = "Toggle last terminal" })
    end
    if keymaps and keymaps.menu then
      vim.keymap.set("n", keymaps.menu, function()
        terminals.select()
      end, { silent = true, desc = "Terminal list" })
    end
  end
end

return M
