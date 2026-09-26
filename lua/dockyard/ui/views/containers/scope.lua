-- Project scope: containers whose compose project lives in (or above) the
-- git root of Neovim's cwd.

local view_state = require("dockyard.ui.views.containers.state")

local M = {}

function M.enabled()
	if view_state.project_scope ~= nil then
		return view_state.project_scope
	end
	local option = require("dockyard.config").options.display.project_scope
	if option == "auto" then
		return require("dockyard.commands.context").find_compose_file(M.root()) ~= nil
	end
	return option == true
end

---@return string
function M.root()
	-- global cwd, the Dockyard tab may have a local one
	local cwd = vim.fn.getcwd(-1)
	return vim.fs.normalize(vim.fs.root(cwd, ".git") or cwd)
end

local function contains(parent, child)
	return child == parent or vim.startswith(child, parent == "/" and "/" or parent .. "/")
end

---@param c { compose_dir?: string }
---@param root string
function M.matches(c, root)
	local dir = c.compose_dir
	if type(dir) ~= "string" or dir == "" then
		return false
	end
	dir = vim.fs.normalize(dir)
	if contains(root, dir) then
		return true
	end
	-- a project in / or ~ would match everything
	return dir ~= "/" and dir ~= vim.fs.normalize("~") and contains(dir, root)
end

---@param items Container[]
---@return Container[]
function M.apply(items)
	if not M.enabled() then
		return items
	end
	local root = M.root()
	return vim.tbl_filter(function(c)
		return M.matches(c, root)
	end, items)
end

return M
