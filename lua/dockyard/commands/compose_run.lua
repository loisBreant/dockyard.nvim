-- Runs a compose action for a file with the project's saved preferences.

local compose = require("dockyard.commands.compose")
local prefs = require("dockyard.commands.prefs")
local executor = require("dockyard.commands.executor")

local M = {}

---@param file string compose file
---@param action "up"|"down"|"stop"|"restart"|"build"|"pull"
---@param extra? DockyardComposeOpts overrides the saved preferences (services, one-shot flags)
---@param run_opts? { on_exit?: fun(ok: boolean) }
---@return DockyardJob|nil
function M.run(file, action, extra, run_opts)
	local project = compose.project(file)
	local opts = vim.tbl_extend("force", prefs.get(file), extra or {})
	local argv, err = compose.build(project, action, opts)
	if not argv then
		vim.notify("Dockyard: " .. tostring(err), vim.log.levels.ERROR)
		return nil
	end
	local services = opts.services or {}
	local label = #services > 0 and table.concat(services, ", ") or "all services"
	return executor.run(argv, {
		cwd = project.dir,
		title = "compose " .. action .. " " .. label,
		project = prefs.key(file),
		on_exit = run_opts and run_opts.on_exit,
	})
end

return M
