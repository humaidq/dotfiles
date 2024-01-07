local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)
require('options')

-- minimal systems don't have packages file.
local f = io.open(vim.fn.stdpath("config") .. '/lua/packages.lua', 'r')
if f then
    f:close()
	require('packages')
end
