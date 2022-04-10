require "paq" {
    --"savq/paq-nvim"; -- Paq is managed by Nix now

    "neovim/nvim-lspconfig"; -- Language Server Protocol implementation
    "hrsh7th/nvim-compe"; -- Code completion
	"nvim-treesitter/nvim-treesitter"; -- Requirement for some plugins
	"tpope/vim-repeat"; -- Repeat support for more stuff
	"tpope/vim-fugitive"; -- Git wrapper for vim
	"ap/vim-css-color"; -- Shows hex colours in CSS files
	"nvim-lua/plenary.nvim"; -- Bundle of useful Lua functions
	"LnL7/vim-nix"; -- Syntax highlighting, etc for Nix files
    "lervag/vimtex"; -- LaTeX support
}

require'lspconfig'.gopls.setup{}
require'lspconfig'.rust_analyzer.setup{}
require'lspconfig'.pyright.setup{}
require'lspconfig'.cmake.setup{}
require'lspconfig'.sumneko_lua.setup{}
vim.o.completeopt = "menuone,noselect"
require('compe').setup({
    enabled = true,
    autocomplete = true,
    debug = false,
    min_length = 1,
    preselect = 'enable',
    throttle_time = 80,
    source_timeout = 200,
    incomplete_delay = 400,
    max_abbr_width = 100,
    max_kind_width = 100,
    max_menu_width = 100,
    documentation = true,

    source = {
        path = true,
        buffer = true,
        calc = true,
        vsnip = true,
        nvim_lsp = true,
        nvim_lua = true,
        spell = true,
        tags = true,
        snippets_nvim = true,
        treesitter = true,
    },
})

