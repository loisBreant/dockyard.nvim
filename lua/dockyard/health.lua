local M = {}

function M.check()
	--- Requirements
	vim.health.start("Requirements")
	if vim.fn.has("nvim-0.10") == 0 then
		vim.health.error("Neovim >= 0.10 required")
	else
		vim.health.ok("Neovim version compatible")
	end

	if type(vim.system) == "function" then
		vim.health.ok("vim.system available")
	else
		vim.health.error("vim.system unavailable; Neovim >= 0.10 required")
	end

	local has_toggleterm, _ = pcall(require, "toggleterm.terminal")
	if has_toggleterm then
		vim.health.ok("toggleterm.nvim found")
	else
		vim.health.ok("toggleterm.nvim not found — using native terminal fallback for T")
	end

	local has_baleia, _ = pcall(require, "baleia")
	if has_baleia then
		vim.health.ok("baleia.nvim found — ANSI colors in logs enabled")
	else
		vim.health.ok("baleia.nvim not found — logs will show raw ANSI codes (install m00qek/baleia.nvim for colors)")
	end

	--- Docker
	vim.health.start("Docker")
	if vim.fn.executable("docker") == 1 then
		vim.health.ok("Docker CLI found")

		local version = vim.fn.system("docker --version 2>/dev/null"):gsub("\n", "")
		if vim.v.shell_error == 0 then
			vim.health.ok(version)
		end

		vim.fn.system("docker info 2>/dev/null")
		if vim.v.shell_error == 0 then
			vim.health.ok("Docker daemon running")
		else
			vim.health.error("Docker daemon not running")
		end
	else
		vim.health.error("Docker CLI not found")
	end

	--- Plugin
	vim.health.start("Plugin")
	if vim.fn.exists(":Dockyard") == 2 then
		vim.health.ok(":Dockyard command registered")
	else
		vim.health.error(":Dockyard command not found: is plugin/dockyard.lua on the runtimepath?")
	end

	local has_telescope = pcall(require, "telescope")
	if has_telescope then
		vim.health.ok("telescope.nvim found — :Telescope dockyard available")
	else
		vim.health.ok("telescope.nvim not found — :Dockyard pick uses vim.ui.select")
	end

	local compose = vim.fn.executable("docker") == 1 and vim.system({ "docker", "compose", "version" }):wait().code == 0
	if compose then
		vim.health.ok("docker compose available — compose actions enabled")
	elseif vim.fn.executable("docker-compose") == 1 then
		vim.health.ok("docker-compose available — compose actions enabled")
	else
		vim.health.warn("neither `docker compose` nor `docker-compose` found — compose actions will fail")
	end

	local prefs_ok, prefs_problem = require("dockyard.commands.prefs").check()
	if prefs_ok then
		vim.health.ok("compose preferences file is readable")
	else
		vim.health.warn("compose preferences file (" .. require("dockyard.commands.prefs").path() .. "): " .. prefs_problem)
	end

	--- Configuration
	vim.health.start("Configuration")
	local config = require("dockyard.config")
	local errors = config.validate(config.options)
	for _, err in ipairs(errors) do
		vim.health.error(err)
	end
	local unknown = config.unknown_keys(config.user or {})
	for _, key in ipairs(unknown) do
		vim.health.warn("unknown option: " .. key .. " (typo, or an option this version does not have)")
	end
	if #errors == 0 and #unknown == 0 then
		vim.health.ok("options are valid")
	end

	--- Keymaps
	vim.health.start("Keymaps")
	local by_context = require("dockyard.core.keymaps").validate()
	local context_names = vim.tbl_keys(by_context)
	table.sort(context_names)

	local has_conflicts = false
	for _, ctx in ipairs(context_names) do
		local conflicts = by_context[ctx] or {}
		local keys = vim.tbl_keys(conflicts)
		table.sort(keys)
		if #keys == 0 then
			vim.health.ok(string.format("%s: no conflicting mapped keys", ctx))
		else
			has_conflicts = true
			vim.health.warn(string.format("%s: %d conflicting key(s)", ctx, #keys))
			for _, key in ipairs(keys) do
				vim.health.warn(string.format("  %s -> %s", key, table.concat(conflicts[key], ", ")))
			end
		end
	end
	if not has_conflicts and #context_names == 0 then
		vim.health.ok("No conflicting mapped keys")
	end
end

return M
