require("lazy").setup({
  "folke/which-key.nvim",
  { "folke/neoconf.nvim", cmd = "Neoconf" },
  "folke/neodev.nvim",
  "ap/vim-css-color",
  "LnL7/vim-nix",
  "tpope/vim-repeat",
  "tpope/vim-fugitive",
  "nvim-lua/plenary.nvim",
  "lervag/vimtex",
  "L3MON4D3/LuaSnip",
  'williamboman/mason.nvim',
  { 
    'VonHeikemen/lsp-zero.nvim',
    branch = 'v2.x',
    dependencies = {
        -- LSP Support
        { 'neovim/nvim-lspconfig' }, -- Required
        {
            -- Optional
            'williamboman/mason.nvim',
            build = function()
                pcall(vim.cmd, 'MasonUpdate')
            end,
        },
        { 'williamboman/mason-lspconfig.nvim' }, -- Optional

        -- Autocompletion
        { 'hrsh7th/nvim-cmp' },     -- Required
        { 'hrsh7th/cmp-nvim-lsp' }, -- Required
        { 'L3MON4D3/LuaSnip' },     -- Required
    }
  },
  'hrsh7th/cmp-path',
  'hrsh7th/cmp-buffer',
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    opts = {},
  },
})
vim.cmd[[colorscheme tokyonight-night]]
local lsp_zero = require('lsp-zero')

lsp_zero.on_attach(function(client, bufnr)
  lsp_zero.default_keymaps({buffer = bufnr})
end)
require('mason').setup()
require('mason-lspconfig').setup({
  handlers = {
    lsp_zero.default_setup,
  },
})

