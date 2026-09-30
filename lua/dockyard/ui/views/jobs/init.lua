local M = {}

local runner = require("dockyard.commands.runner")
local keymaps = require("dockyard.ui.views.jobs.keymaps")
local controller = require("dockyard.ui.views.jobs.controller")
local view_state = require("dockyard.ui.views.jobs.state")

---@param buf number
---@param notify fun(msg:string,level?:"success"|"warn"|"error"|"info"|"loading")
function M.setup(buf, notify)
	keymaps.setup(buf, notify)
	if view_state.off then
		view_state.off()
	end
	view_state.off = runner.subscribe(function()
		controller.schedule_render()
	end)
end

---@param on_done fun()|nil
function M.update(on_done)
	controller.render({ focus_first = true })
	if on_done then
		on_done()
	end
end

---@param buf number
function M.teardown(buf)
	keymaps.teardown(buf)
	if view_state.off then
		view_state.off()
		view_state.off = nil
	end
end

return M
