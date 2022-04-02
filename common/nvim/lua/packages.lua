require "paq" {
    "savq/paq-nvim";                  -- Let Paq manage itself

    "neovim/nvim-lspconfig";          -- Mind the semi-colons
    "hrsh7th/nvim-compe";
	"nvim-treesitter/nvim-treesitter";
	"tpope/vim-repeat";
	"tpope/vim-fugitive";
	"ap/vim-css-color";
	"nvim-lua/plenary.nvim";
	"LnL7/vim-nix";
	"nvim-neorg/neorg";

    "lervag/vimtex";      -- Use braces when passing options
}

require('neorg').setup {}

require'lspconfig'.gopls.setup{}
require'lspconfig'.rust_analyzer.setup{}
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

