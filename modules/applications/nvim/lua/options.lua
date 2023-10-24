local cmd = vim.cmd
local opt = vim.opt

cmd('filetype plugin indent on')
cmd('syntax on')
--cmd('colorscheme ron')

-- Character encoding
opt.encoding = 'utf-8'
opt.fileencoding = 'utf-8'
opt.fileencodings = { 'utf-8' }

-- Show whitespace characters
opt.listchars = 'tab:▸\\ ,eol:¬,space:.'

-- Show line number
opt.number = true

opt.smartindent = true
opt.autoread = true
opt.history = 1000

-- Set line width
opt.colorcolumn = { 80 }
opt.textwidth = 79

-- Setup backup dir
opt.backupdir = vim.fn.stdpath('data') .. '/.cache'
opt.directory = vim.fn.stdpath('data') .. '/.cache'

-- Setup undo file
opt.undofile = true
opt.undodir = vim.fn.stdpath('data') .. '/.config/nvim/vimundo'
opt.undolevels = 10000
opt.undoreload = 10000

-- Tabs
opt.tabstop = 4
opt.shiftwidth = 4
opt.expandtab = false

-- File preferences
vim.api.nvim_command('autocmd FileType css setlocal et ts=2 sw=2')
vim.api.nvim_command('autocmd FileType javascript setlocal et ts=2 sw=2')
vim.api.nvim_command('autocmd FileType html setlocal et ts=2 sw=2')
vim.api.nvim_command('autocmd FileType yaml setlocal et ts=2 sw=2')
vim.api.nvim_command('autocmd FileType python setlocal et ts=4 sw=4')
vim.api.nvim_command('autocmd FileType javascript setlocal et ts=2 sw=2')

-- Disable splash screen
opt.shm:append("I")
