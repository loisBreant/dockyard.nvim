local M = {}

local runner = require("dockyard.commands.runner")
local ui_state = require("dockyard.ui.state")
local help = require("dockyard.ui.popups.help")
local resolver = require("dockyard.core.keymaps")
local view_filter = require("dockyard.ui.components.view_filter")
local controller = require("dockyard.ui.views.jobs.controller")

local GROUP = "Jobs"
local INDEX = 50

local function job_at_cursor()
	local node = ui_state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
	if node and node.kind == "job" then
		return node
	end
end

---@param buf number
---@param notify fun(msg:string,level?:"success"|"warn"|"error"|"info"|"loading")
function M.setup(buf, notify)
	local items = {}
	local function on_job(fn)
		return function()
			local node = job_at_cursor()
			if node then
				fn(node.item)
			end
		end
	end

	resolver.push(
		items,
		resolver.item("jobs.open_output", {
			desc = "Open the full output",
			callback = on_job(function(job)
				require("dockyard.ui.views.jobs.output").open(job.id)
			end),
			index = 1,
		})
	)
	resolver.push(
		items,
		resolver.item("ui.open_details", {
			desc = "Open the full output",
			callback = on_job(function(job)
				require("dockyard.ui.views.jobs.output").open(job.id)
			end),
			index = 2,
			hidden = true,
		})
	)
	resolver.push(
		items,
		resolver.item("jobs.rerun", {
			desc = "Run the command again",
			callback = on_job(function(job)
				if runner.rerun(job.id) then
					notify("Started again: " .. job.title, "info")
				end
			end),
			index = 3,
		})
	)
	resolver.push(
		items,
		resolver.item("jobs.cancel", {
			desc = "Cancel the running command",
			callback = on_job(function(job)
				if not runner.cancel(job.id) then
					notify("Not running", "warn")
				end
			end),
			index = 4,
		})
	)
	resolver.push(
		items,
		resolver.item("jobs.clear", {
			desc = "Forget the finished jobs",
			callback = function()
				runner.clear_finished()
			end,
			index = 5,
		})
	)
	resolver.push(
		items,
		resolver.item("jobs.copy_command", {
			desc = "Copy the command line",
			callback = on_job(function(job)
				local cmd = runner.format_cmd(job.argv)
				vim.fn.setreg("+", cmd)
				vim.fn.setreg('"', cmd)
				notify("Copied: " .. cmd, "success")
			end),
			index = 6,
		})
	)

	view_filter.push_items(items, "jobs", controller.filter, 10)

	help.register(GROUP, items, { buffer = buf, index = INDEX })
end

---@param buf number
function M.teardown(buf)
	local items = {}
	for _, id in ipairs({ "jobs.open_output", "ui.open_details", "jobs.rerun", "jobs.cancel", "jobs.clear", "jobs.copy_command" }) do
		resolver.push(items, resolver.removal(id))
	end
	view_filter.push_removals(items, "jobs")
	help.remove(GROUP, items, { buffer = buf })
end

return M
