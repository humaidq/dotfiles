vim.cmd [[packadd packer.nvim]]

return require('packer').startup(function()
	-- usually we let packer manage itself, but in this system this is managed
	-- by nix in the common/user/nvim.nix file.
	use {
		'wbthomason/packer.nvim',
		lock = true,
	}
	
	 -- Language Server Protocol implementation
    use {
		'neovim/nvim-lspconfig',
		config = function()
			require'lspconfig'.gopls.setup{}
			require'lspconfig'.rust_analyzer.setup{}
			require'lspconfig'.pyright.setup{}
			require'lspconfig'.cmake.setup{}
			require'lspconfig'.sumneko_lua.setup{}
		end
	}

	--use 'hrsh7th/nvim-compe' -- Code completion
	use 'nvim-treesitter/nvim-treesitter' -- Requirement for some plugins
	use 'tpope/vim-repeat' -- Repeat support for more stuff
	use 'tpope/vim-fugitive' -- Git wrapper for vim
	use 'ap/vim-css-color' -- Shows hex colours in CSS files
	use 'nvim-lua/plenary.nvim' -- Bundle of useful Lua functions
	use 'LnL7/vim-nix' -- Syntax highlighting, etc for Nix files
    use 'lervag/vimtex' -- LaTeX support
	use {
		'nvim-neorg/neorg',
		config = function()
			require('neorg').setup {}
		end,
		requires = "nvim-lua/plenary.nvim"
	}

end)

--vim.o.completeopt = "menuone,noselect"
--require('compe').setup({
--    enabled = true,
--    autocomplete = true,
--    debug = false,
--    min_length = 1,
--    preselect = 'enable',
--    throttle_time = 80,
--    source_timeout = 200,
--    incomplete_delay = 400,
--    max_abbr_width = 100,
--    max_kind_width = 100,
--    max_menu_width = 100,
--    documentation = true,
--
--    source = {
--        path = true,
--        buffer = true,
--        calc = true,
--        vsnip = true,
--        nvim_lsp = true,
--        nvim_lua = true,
--        spell = true,
--        tags = true,
--        snippets_nvim = true,
--        treesitter = true,
--    },
--})

