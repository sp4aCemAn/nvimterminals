# nvimterminals

Persistent per-name terminal windows for Neovim — keeps terminals out of your
buffer list so your buffers and tabs stay organized.

## Features

- `:TermToggle [name]` — open/hide a named terminal (`TermToggle build`, `TermToggle repl`...).
  Each new name spawns a fresh persistent terminal.
- Hidden terminals keep running; reopen with the same command.
- Opening a terminal always takes a brand-new split/buffer — your current
  buffer is never replaced or renamed.
- Splitting anchors to your editor window even when you spawn from inside a
  terminal window, so terminals don't cascade nested.
- Terminal buffers are unlisted: they stay out of `:ls`, bufferline, and tab pickers.
- `<C-\>` toggles the last used terminal (normal + terminal mode).
- `<leader>tt` opens the terminal picker — all terminals listed with `[open]` /
  `[hidden]`, like VS Code's terminal panel.

## Install

With lazy.nvim:

```lua
{
  "sp4aCemAn/nvimterminals",
  config = function()
    require("nvimterminals").setup({
      position = "right", -- "left" | "top" | "bottom"
      size = 0.35,
      -- keymaps = {
      --   toggle_last = "<C-\\>",  -- nvim-terminals: last terminal
      --   menu = "<leader>tt",     -- set to false to disable
      -- },
    })
  end,
}
```

## Usage

- `:TermToggle` — toggle `main` terminal
- `:TermToggle build` — toggle a terminal named `build` (name completion available)
- `:Terms` — list terminals and pick one
- `<C-\>` — toggle last used terminal
- `<leader>tt` — open terminal picker

## Tests

```sh
cd .../nvimterminals
nvim --headless -u NONE +'set shell=/bin/sh noswapfile' -l tests/lifecycle.lua +qa
nvim --headless -u NONE +'set shell=/bin/sh noswapfile' -l tests/split_override.lua +qa
```

Each script prints `... PASSED` on success or a failing assertion.
