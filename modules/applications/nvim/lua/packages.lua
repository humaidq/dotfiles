require("lazy").setup({
  -- Misc (functionality that should be in vim)
  "nvim-lua/plenary.nvim",
  "ap/vim-css-color",
  "tpope/vim-repeat",
  "tpope/vim-surround",
  "tpope/vim-fugitive",
  "tpope/vim-commentary",
  "nvim-telescope/telescope.nvim",

  -- Language support
  "lervag/vimtex",
  "LnL7/vim-nix",
   {
    "wuelnerdotexe/vim-astro",
    ft = "astro",
    init = function()
      -- Astro configuration variables.
      vim.g.astro_typescript = "enable"
      vim.g.astro_stylus     = "disable"
    end,
  },

  -- Auto Complete and LSP stuff
  "folke/neodev.nvim",
  "L3MON4D3/LuaSnip",
  "williamboman/mason.nvim",
  "WhoIsSethDaniel/mason-tool-installer.nvim",
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
  'github/copilot.vim',

  -- Theme
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
require("neodev").setup()
require('mason').setup()
require('mason-lspconfig').setup({
  handlers = {
    lsp_zero.default_setup,
  },
	ensure_installed = {"nil_ls"},
})
require("lspconfig").nil_ls.setup {}
require('mason-tool-installer').setup {
  ensure_installed = {
    'golangci-lint',
    'bash-language-server',
    'gopls',
    'shellcheck',
    'typescript-language-server',
    'lua-language-server',
	'dockerfile-language-server',
    'stylelint',
    'stylelint-lsp',
	'css-lsp',
    'eslint-lsp',
    'rust-analyzer',
    'pyright',
	'json-lsp',
	'taplo',
	'astro-language-server',
	'prettierd',
	'tailwindcss-language-server',
	'hadolint',
  },
}

local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>ff', builtin.find_files, {})
vim.keymap.set('n', '<leader>fg', builtin.live_grep, {})
vim.keymap.set('n', '<leader>fb', builtin.buffers, {})
vim.keymap.set('n', '<leader>fh', builtin.help_tags, {})

local cmp = require('cmp')
cmp.setup({
	snippet = {
	  -- REQUIRED - you must specify a snippet engine
	  expand = function(args)
		vim.fn["vsnip#anonymous"](args.body) -- For `vsnip` users.
	  end,
	},
	mapping = cmp.mapping.preset.insert({
	  ['<C-b>'] = cmp.mapping.scroll_docs(-4),
	  ['<C-f>'] = cmp.mapping.scroll_docs(4),
	  ['<C-Space>'] = cmp.mapping.complete(),
	  ['<C-e>'] = cmp.mapping.abort(),
	  ['<CR>'] = cmp.mapping.confirm({ select = true }), -- Accept currently selected item. Set `select` to `false` to only confirm explicitly selected items.
	}),
	sources = cmp.config.sources({
	  { name = 'nvim_lsp' },
	}, {
	  { name = 'buffer' },
	})
})

-- Use buffer source for `/` and `?` (if you enabled `native_menu`, this won't work anymore).
cmp.setup.cmdline({ '/', '?' }, {
	mapping = cmp.mapping.preset.cmdline(),
	sources = {
	  { name = 'buffer' }
	}
})

-- Use cmdline & path source for ':' (if you enabled `native_menu`, this won't work anymore).
cmp.setup.cmdline(':', {
	mapping = cmp.mapping.preset.cmdline(),
	sources = cmp.config.sources({
	  { name = 'path' }
	}, {
	  { name = 'cmdline' }
	})
})
