-- Runs a command and shows it in a notice. The job itself lives in commands/runner.

local M = {}

local runner = require("dockyard.commands.runner")

---@param args string[] Command and arguments
---@param opts { cwd?: string, title?: string, project?: string, on_exit?: fun(ok: boolean) }|nil
---@return DockyardJob|nil
function M.run(args, opts)
	opts = opts or {}
	if not args or #args == 0 then
		vim.notify("Dockyard: no command to run", vim.log.levels.WARN)
		return nil
	end

	local job = runner.start({
		argv = args,
		cwd = opts.cwd,
		title = opts.title,
		project = opts.project,
		on_exit = function(finished)
			if opts.on_exit then
				opts.on_exit(finished.status == "ok")
			end
		end,
	})
	require("dockyard.ui.popups.job_notice").show(job)
	return job
end

return M
