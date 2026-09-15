---@class DockyardContainersViewState
---@field last_rendered_at integer|nil
---@field spinner_frame string|nil
---@field poll_spinner SpinnerInstance|nil
---@field expanded table<string, boolean>
---@field filter string|nil Filter text (case-insensitive substring match)

---@class DockyardContainersViewState
local M = {
	last_rendered_at = nil,
	spinner_frame = nil,
	poll_spinner = nil,
	expanded = {},
	filter = nil,
}

function M.toggle(key)
	local current = M.expanded[key]
	if current == nil then
		current = true
	end
	M.expanded[key] = not current
end

function M.reset()
	M.expanded = {}
	M.filter = nil
end

return M
