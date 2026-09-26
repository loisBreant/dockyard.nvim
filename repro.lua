-- Minimal config to reproduce an issue, isolated from your own setup:
--   nvim -u repro.lua
-- Everything is installed under ./.repro; edit the plugin options below.

for _, name in ipairs({ "config", "data", "state", "cache" }) do
	vim.env[("XDG_%s_HOME"):format(name:upper())] = vim.fn.fnamemodify("./.repro/" .. name, ":p")
end

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
	vim.fn.system({ "git", "clone", "--filter=blob:none", "https://github.com/folke/lazy.nvim.git", "--branch=stable", lazypath })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
	{
		"loisBreant/dockyard.nvim",
		opts = {
			-- options needed to reproduce the issue
		},
	},
	-- other plugins needed to reproduce the issue, e.g. "nvim-telescope/telescope.nvim"
})
