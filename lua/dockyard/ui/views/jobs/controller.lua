local M = {}

local renderer = require("dockyard.ui.views.jobs.renderer")
local runner = require("dockyard.commands.runner")
local ui_state = require("dockyard.ui.state")
local navigation = require("dockyard.ui.navigation")
local view_state = require("dockyard.ui.views.jobs.state")

---@param opts { focus_first?: boolean }|nil
function M.render(opts)
	if ui_state.current_view ~= "jobs" then
		return
	end
	if ui_state.win_id ~= nil and vim.api.nvim_win_is_valid(ui_state.win_id) then
		renderer.render()
		-- only when the previous selection is gone (first open, view switch)
		if opts and opts.focus_first == true and not navigation.restored then
			navigation.first()
		end
	end
end

---Re-render soon, once for a burst of changes. While a job runs, keep its duration ticking.
---@param delay? integer milliseconds
function M.schedule_render(delay)
	if view_state.pending then
		return
	end
	view_state.pending = true
	vim.defer_fn(function()
		view_state.pending = false
		M.render()
		local running = vim.tbl_filter(function(job)
			return job.status == "running"
		end, runner.list())
		if #running > 0 and ui_state.current_view == "jobs" then
			M.schedule_render(1000)
		end
	end, delay or 100)
end

---@param node { kind: string, item: DockyardJob }|nil
function M.open_output(node)
	if node and node.kind == "job" then
		require("dockyard.ui.views.jobs.output").open(node.item.id)
	end
end

return M
