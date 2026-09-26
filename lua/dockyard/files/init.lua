local M = {}

M.core = require("dockyard.files.core")
M.browser = require("dockyard.files.browser")

---@param container string
---@param path string|nil  defaults to "/"
function M.open(container, path)
	return M.browser.open(container, path or "/")
end

local function notify(msg, level)
	vim.notify("[dockyard] " .. msg, level or vim.log.levels.INFO)
end

-- dockyard://<container>/<path> buffers read from and write to the container,
-- so container files open from :edit, the quickfix list or the browser alike.
-- plugin/dockyard.lua routes BufReadCmd / BufWriteCmd here.

---@param args table autocmd callback argument
function M.read_cmd(args)
	local container, path = args.match:match("^dockyard://([^/]+)(/.*)$")
	if not container then
		-- the browser's own buffer (dockyard://<container>) is managed by the browser
		return
	end
	local buf = args.buf
	local lines, err = M.core.read_sync(container, path)
	if not lines then
		local stat = vim.system({ "docker", "exec", container, "test", "-d", path }):wait()
		if stat.code == 0 then
			-- the placeholder buffer goes away once the browser replaces it
			vim.bo[buf].bufhidden = "wipe"
			vim.bo[buf].buflisted = false
			vim.schedule(function()
				M.browser.open(container, path)
			end)
			return
		end
		notify(err or "read failed", vim.log.levels.ERROR)
		lines = {}
	end

	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].swapfile = false
	-- lockmarks: filling the buffer must not shift the line numbers of
	-- quickfix entries already pointing into it
	local function fill()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	end
	if vim._with then
		vim._with({ lockmarks = true }, fill)
	else
		fill()
	end
	vim.bo[buf].modified = false
	local ft = vim.filetype.match({ filename = path, buf = buf })
	if ft then
		vim.bo[buf].filetype = ft
	end
end

---@param args table autocmd callback argument
function M.write_cmd(args)
	local container, path = args.match:match("^dockyard://([^/]+)(/.*)$")
	if not container then
		return
	end
	local buf = args.buf
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	M.core.write(container, path, lines, function(res)
		if not res.ok then
			notify(res.error or "write failed", vim.log.levels.ERROR)
			return
		end
		if vim.api.nvim_buf_is_valid(buf) then
			vim.bo[buf].modified = false
		end
		notify("Saved " .. container .. ":" .. path)
	end)
end

return M
