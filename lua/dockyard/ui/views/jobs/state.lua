---@class DockyardJobsViewState
---@field off fun()|nil unsubscribe from the runner
---@field pending boolean a re-render is already scheduled

---@type DockyardJobsViewState
local M = {
	off = nil,
	pending = false,
}

return M
