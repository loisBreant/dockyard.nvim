local M = {}

local data_state = require("dockyard.state")
local renderer = require("dockyard.ui.views.volumes.renderer")
local ui_state = require("dockyard.ui.state")
local navigation = require("dockyard.ui.navigation")

---@param opts { focus_first?: boolean }|nil
local function render(opts)
	if ui_state.current_view ~= "volumes" then
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

---@param on_done fun()|nil
---@param opts { force_update?: boolean }|nil
local function update_now(on_done, opts)
	local items = data_state.volumes.get_items()
	local has_data = type(items) == "table" and #items > 0
	if (opts and opts.force_update) or not has_data then
		data_state.volumes.refresh({
			silent = false,
			on_success = function()
				render({ focus_first = true })
				if on_done then
					on_done()
				end
			end,
			on_error = function()
				render({ focus_first = true })
				if on_done then
					on_done()
				end
			end,
		})
		return
	end

	render()
	if on_done then
		on_done()
	end
end

---@param on_done fun()|nil
---@param opts { force_update?: boolean }|nil
function M.update(on_done, opts)
	-- the scope needs the containers to know the project's names
	require("dockyard.scope").ensure_containers(function()
		update_now(on_done, opts)
	end)
end

M.filter = require("dockyard.ui.components.view_filter").controller({
	view = "volumes",
	label = "volumes",
	state = require("dockyard.ui.views.volumes.state"),
	render = function()
		renderer.render()
	end,
})

---@param node { kind: string, item: Volume }|nil
function M.open_details(node)
	if not node or node.kind ~= "volume" then
		return
	end
	require("dockyard.ui.popups.hover").open(node)
end

return M
