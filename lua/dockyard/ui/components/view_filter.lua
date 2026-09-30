-- Filter and project-scope handlers and keys shared by the Images, Networks, Volumes and Jobs views.

local M = {}

local resolver = require("dockyard.core.keymaps")
local ui_state = require("dockyard.ui.state")
local navigation = require("dockyard.ui.navigation")

---@param opts { view: string, label: string, state: { filter: string|nil }, render: fun() }
---@return { set_filter: fun(text: string|nil), clear_filter: fun(), toggle_project_scope: fun(), prompt_filter: fun() }
function M.controller(opts)
	local C = {}

	local function active()
		return ui_state.current_view == opts.view
	end

	function C.set_filter(text)
		opts.state.filter = (text ~= nil and text ~= "") and text or nil
		opts.render()
		if active() and opts.state.filter then
			navigation.first()
		end
	end

	function C.clear_filter()
		opts.state.filter = nil
		opts.render()
	end

	function C.toggle_project_scope()
		local scope = require("dockyard.scope")
		scope.toggle()
		scope.ensure_containers(function()
			opts.render()
			if active() then
				navigation.first()
			end
		end)
	end

	function C.prompt_filter()
		vim.ui.input({ prompt = "Filter " .. opts.label .. ": ", default = opts.state.filter or "" }, function(input)
			if input ~= nil then
				C.set_filter(input)
			end
		end)
	end

	return C
end

---@param items table list given to help.register
---@param group string keymaps group: "images", "networks", "volumes" or "jobs"
---@param ctl table result of M.controller
---@param index integer help order of the first key
function M.push_items(items, group, ctl, index)
	resolver.push(
		items,
		resolver.item(group .. ".filter", {
			desc = "Filter " .. group,
			callback = function()
				ctl.prompt_filter()
			end,
			index = index,
		})
	)
	resolver.push(
		items,
		resolver.item(group .. ".clear_filter", {
			desc = "Clear filter",
			callback = function()
				ctl.clear_filter()
			end,
			index = index + 1,
		})
	)
	resolver.push(
		items,
		resolver.item(group .. ".toggle_project_scope", {
			desc = "Only this project's " .. group .. " / all",
			callback = function()
				ctl.toggle_project_scope()
			end,
			index = index + 2,
		})
	)
end

---@param items table list given to help.remove
---@param group string
function M.push_removals(items, group)
	for _, action in ipairs({ "filter", "clear_filter", "toggle_project_scope" }) do
		resolver.push(items, resolver.removal(group .. "." .. action))
	end
end

return M
