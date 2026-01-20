return {
  -- Rose Pine (matching ghostty dark theme)
  {
    "rose-pine/neovim",
    name = "rose-pine",
    priority = 1000,
    opts = {
      variant = "auto", -- auto, main, moon, or dawn
      dark_variant = "main", -- main, moon, or dawn
      enable = {
        terminal = true,
        legacy_highlights = true,
        migrations = true,
      },
      styles = {
        transparency = false,
      },
    },
  },
  
  -- Solarized (matching ghostty light theme)
  {
    "maxmx03/solarized.nvim",
    lazy = false,
    priority = 1000,
    config = function()
      require('solarized').setup({
        transparent = {
          enabled = false,
        },
        palette = "solarized", -- or selenized
        styles = {
          functions = { italic = true },
          keywords = { italic = true },
        },
      })
    end,
  },
  
  -- Auto-detect system theme and apply appropriate colorscheme
  {
    "f-person/auto-dark-mode.nvim",
    priority = 1000,
    config = function()
      local auto_dark_mode = require('auto-dark-mode')
      
      auto_dark_mode.setup({
        update_interval = 1000,
        set_dark_mode = function()
          vim.api.nvim_set_option_value("background", "dark", {})
          vim.cmd("colorscheme rose-pine")
        end,
        set_light_mode = function()
          vim.api.nvim_set_option_value("background", "light", {})
          vim.cmd("colorscheme solarized")
        end,
      })
    end,
  },
}