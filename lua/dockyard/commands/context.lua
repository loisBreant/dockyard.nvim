local M = {}

local COMPOSE_FILENAMES = {
	"docker-compose.yml",
	"docker-compose.yaml",
	"compose.yml",
	"compose.yaml",
}

---@return string|nil
function M.current_file()
	local buf = vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(buf)
	if name == "" then
		return nil
	end
	return name
end

---@return string|nil
function M.current_dir()
	local file = M.current_file()
	if file then
		return vim.fn.fnamemodify(file, ":h")
	end
	return vim.fn.getcwd()
end

---@param file string
---@return boolean
function M.is_dockerfile(file)
	local basename = vim.fn.fnamemodify(file, ":t")
	if basename == "Dockerfile" then
		return true
	end
	if basename:match("^Dockerfile%.") then
		return true
	end
	-- api.Dockerfile, worker.dockerfile
	return basename:lower():match("%.dockerfile$") ~= nil
end

---@param file string
---@return boolean
function M.is_compose_file(file)
	local basename = vim.fn.fnamemodify(file, ":t")
	for _, name in ipairs(COMPOSE_FILENAMES) do
		if basename == name then
			return true
		end
	end
	-- variants such as docker-compose.dev.yml or compose.override.yaml
	return basename:match("^docker%-compose%..+%.ya?ml$") ~= nil or basename:match("^compose%..+%.ya?ml$") ~= nil
end

---@class DockyardComposeService
---@field name string
---@field lnum integer 1-based line of the service key
---@field has_build boolean the service defines a `build:` section
---@field profiles string[] its `profiles:`

---Locate the `services:` block and each service key in a compose buffer.
---Service keys are the first indentation level under `services:`, whatever its width.
---@param buf? integer defaults to the current buffer
---@return { lnum: integer|nil, end_lnum: integer|nil, services: DockyardComposeService[] }
function M.compose_services(buf)
	local lines = vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
	local result = { lnum = nil, services = {} }
	local indent = nil
	local child_indent = nil

	for i, line in ipairs(lines) do
		if result.lnum == nil then
			if line:match("^services:%s*$") or line:match("^services:%s+#") then
				result.lnum = i
			end
		elseif not line:match("^%s*$") and not line:match("^%s*#") then
			if line:match("^%S") then
				-- next top-level key closes the block
				result.end_lnum = i - 1
				break
			end
			local lead, name = line:match("^(%s+)([%w_.%-]+):%s*")
			if lead and (indent == nil or #lead == indent) then
				indent = indent or #lead
				child_indent = nil
				table.insert(result.services, { name = name, lnum = i, has_build = false, profiles = {} })
			elseif lead and #lead > indent and #result.services > 0 then
				-- keys of the service itself sit at its first child indentation
				child_indent = child_indent or #lead
				if #lead == child_indent and name == "build" then
					result.services[#result.services].has_build = true
				elseif #lead == child_indent and name == "profiles" then
					result.services[#result.services].profiles = require("dockyard.commands.profiles").parse_at(lines, i)
				end
			end
		end
	end

	if result.lnum and not result.end_lnum then
		result.end_lnum = #lines
	end
	return result
end

---Find a compose file in the given directory only.
---TODO: Might wanna search the git directory of the Project instead of just the current dir, but this is a start.
---@param dir string
---@return string|nil
function M.find_compose_file(dir)
	for _, name in ipairs(COMPOSE_FILENAMES) do
		local path = dir .. "/" .. name
		if vim.loop.fs_stat(path) then
			return path
		end
	end
	return nil
end

---Try to detect the compose service name under the cursor.
---Only works when the current buffer is a compose file.
---@return string|nil
function M.service_at_cursor()
	local file = M.current_file()
	if not file or not M.is_compose_file(file) then
		return nil
	end

	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
	local block = M.compose_services(0)
	if not block.end_lnum or cursor_line > block.end_lnum then
		return nil
	end
	local last_service = nil
	for _, service in ipairs(block.services) do
		if service.lnum > cursor_line then
			break
		end
		last_service = service.name
	end
	return last_service
end

---Extract service names that appear within the given line range of the current buffer.
---@param line1 integer 1-based start line
---@param line2 integer 1-based end line
---@return string[]
function M.services_in_range(line1, line2)
	local file = M.current_file()
	if not file or not M.is_compose_file(file) then
		return {}
	end

	local services = {}
	for _, service in ipairs(M.compose_services(0).services) do
		if service.lnum >= line1 and service.lnum <= line2 then
			table.insert(services, service.name)
		end
	end
	return services
end

---@class DockyardContext
---@field type "dockerfile"|"compose"|"project"|nil
---@field file string|nil
---@field dir string
---@field service string|nil

---Detect the docker context for the current buffer.
---@return DockyardContext
function M.detect()
	local file = M.current_file()
	local dir = M.current_dir() or vim.fn.getcwd()

	if file and M.is_dockerfile(file) then
		return { type = "dockerfile", file = file, dir = vim.fn.fnamemodify(file, ":h") }
	end

	if file and M.is_compose_file(file) then
		return {
			type = "compose",
			file = file,
			dir = vim.fn.fnamemodify(file, ":h"),
			service = M.service_at_cursor(),
		}
	end

	-- Not in a docker file, try to find a compose file nearby
	local compose = M.find_compose_file(dir)
	if compose then
		return {
			type = "project",
			file = compose,
			dir = vim.fn.fnamemodify(compose, ":h"),
		}
	end

	return { type = nil, file = nil, dir = dir }
end

return M
