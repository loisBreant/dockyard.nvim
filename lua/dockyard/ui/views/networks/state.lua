---@class DockyardNetworksViewState
---@field expanded table<string, boolean>
---@field spinner_frame string|nil
---@field poll_spinner SpinnerInstance|nil
---@field filter string|nil text filter (case-insensitive substring)

---@class DockyardNetworksViewState
local M = {
	expanded = {},
	spinner_frame = nil,
	poll_spinner = nil,
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
