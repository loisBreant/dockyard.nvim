---@class DockyardJobsViewState
---@field off fun()|nil unsubscribe from the runner
---@field pending boolean a re-render is already scheduled
---@field filter string|nil text filter (case-insensitive substring)

---@type DockyardJobsViewState
local M = {
	off = nil,
	pending = false,
	filter = nil,
}

return M
