# nvimterminals

Persistent per-name terminal windows for Neovim — keeps terminals out of your
buffer list so your buffers and tabs stay organized.

## Features

- `TermToggle [name]` — open/hide a named terminal (`TermToggle build`, `TermToggle repl`...).
- Hidden terminals keep running; reopen with the same command.
- Terminal buffers are unlisted: they stay out of `:ls`, bufferline, and tab pickers.
- `<C-\>` toggles the last used terminal (normal + terminal mode).

## Install

With lazy.nvim:

```lua
{
  dir = "~/vsc/nvimterminals", -- or your repo URL once published
  config = function()
    require("nvimterminals").setup({
      position = "right", -- "left" | "top" | "bottom"
      size = 0.35,
      -- keymaps = { toggle_last = "<C-\\>" },
    })
  end,
}
```

## Usage

- `:TermToggle` — toggle `main` terminal
- `:TermToggle build` — toggle a terminal named `build`
- `<C-\>` — toggle last used terminal
