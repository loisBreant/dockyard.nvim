local M = {}

---Image tag used by :DockyardBuild: the build directory's name.
---@param dir string
---@return string
function M.image_tag(dir)
	local tag = vim.fn.fnamemodify(dir, ":t"):lower():gsub("[^%w%-_]", "")
	if tag == "" then
		tag = "dockyard-build"
	end
	return tag
end

---@param ctx DockyardContext
---@return string[]|nil args, string|nil error
function M.build_cmd(ctx)
	if not ctx or not ctx.file then
		return nil, "No docker file found"
	end

	if ctx.type == "dockerfile" then
		local dir = ctx.dir
		local args = { "docker", "build", "-f", ctx.file, "-t", M.image_tag(dir), dir }
		return args, nil
	end

	return nil, "Cannot build command for context type: " .. tostring(ctx.type)
end

return M
