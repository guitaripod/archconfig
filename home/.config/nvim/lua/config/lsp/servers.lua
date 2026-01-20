local lspconfig = require("lspconfig")
local config = require("config.lsp")

-- Ensure mason-lspconfig is loaded
require("mason").setup()
require("mason-lspconfig").setup({
  ensure_installed = {
    "gopls",
    "ts_ls",
    "pyright",
    "rust_analyzer",
  },
  automatic_installation = true,
})

-- Go
lspconfig.gopls.setup({
  on_attach = config.on_attach,
  capabilities = config.capabilities,
  cmd = {"gopls"},
  filetypes = { "go", "gomod", "gowork", "gotmpl" },
  settings = {
    gopls = {
      analyses = {
        unusedparams = true,
      },
      staticcheck = true,
      gofumpt = true,
    },
  },
})

-- TypeScript/JavaScript
lspconfig.ts_ls.setup({
  on_attach = config.on_attach,
  capabilities = config.capabilities,
  init_options = {
    preferences = {
      disableSuggestions = true,
    },
  },
})

-- Python
lspconfig.pyright.setup({
  on_attach = config.on_attach,
  capabilities = config.capabilities,
  settings = {
    python = {
      analysis = {
        typeCheckingMode = "basic",
        autoSearchPaths = true,
        useLibraryCodeForTypes = true,
      },
    },
  },
})

-- Swift (using system installed sourcekit-lsp)
lspconfig.sourcekit.setup({
  on_attach = config.on_attach,
  capabilities = config.capabilities,
})

-- Rust
lspconfig.rust_analyzer.setup({
  on_attach = config.on_attach,
  capabilities = config.capabilities,
  settings = {
    ["rust-analyzer"] = {
      checkOnSave = {
        command = "clippy",
      },
      cargo = {
        allFeatures = true,
      },
    },
  },
})
