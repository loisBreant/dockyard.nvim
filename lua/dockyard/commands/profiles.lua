-- Compose profiles of a file: asked to `docker compose config --profiles`, with a text scan as fallback.

local M = {}

---@type table<string, { profiles: string[], source: "config"|"scan" }>
local cache = {}

local function unique_sorted(list)
	local seen, out = {}, {}
	for _, name in ipairs(list) do
		if name ~= "" and not seen[name] then
			seen[name] = true
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

local function clean(item)
	item = item:gsub("%s+#.*$", "")
	item = vim.trim(item)
	return (item:gsub("^[\"']", ""):gsub("[\"']$", ""))
end

---Profiles listed by the `profiles:` key at `lines[i]` (`[a, b]` or a `- a` list below it).
---@param lines string[]
---@param i integer
---@return string[]
function M.parse_at(lines, i)
	local line = lines[i] or ""
	local inline = line:match("profiles:%s*%[(.-)%]")
	if inline then
		return vim.tbl_map(clean, vim.split(inline, ",", { plain = true, trimempty = true }))
	end
	if not line:match("profiles:%s*$") and not line:match("profiles:%s+#") then
		return {}
	end
	local out = {}
	for j = i + 1, #lines do
		local item = lines[j]:match("^%s*%-%s*(.-)%s*$")
		if item then
			table.insert(out, clean(item))
		elseif not lines[j]:match("^%s*$") and not lines[j]:match("^%s*#") then
			break
		end
	end
	return out
end

---Every profile named in the file, found by text (a service's `profiles:` key).
---@param lines string[]
---@return string[]
function M.scan(lines)
	local out = {}
	for i, line in ipairs(lines) do
		if line:match("^%s+profiles:") then
			vim.list_extend(out, M.parse_at(lines, i))
		end
	end
	return unique_sorted(out)
end

---@param stdout string
---@return string[]
function M.parse_output(stdout)
	return unique_sorted(vim.tbl_map(vim.trim, vim.split(stdout or "", "\n", { plain = true })))
end

local function cache_key(file)
	local stat = vim.uv.fs_stat(file)
	return file .. ":" .. (stat and (stat.mtime.sec .. "." .. stat.mtime.nsec) or "missing")
end

function M.invalidate(file)
	for key in pairs(cache) do
		if vim.startswith(key, file .. ":") then
			cache[key] = nil
		end
	end
end

---@param file string
---@param on_done fun(profiles: string[], source: "config"|"scan", err: string|nil)
function M.detect(file, on_done)
	local key = cache_key(file)
	if cache[key] then
		return on_done(cache[key].profiles, cache[key].source, nil)
	end

	local function finish(profiles, source, err)
		cache[key] = { profiles = profiles, source = source }
		on_done(profiles, source, err)
	end
	local function fallback(err)
		local ok, lines = pcall(vim.fn.readfile, file)
		finish(M.scan(ok and lines or {}), "scan", err)
	end

	local argv = require("dockyard.commands.compose").build({ files = { file }, dir = vim.fs.dirname(file) }, "profiles")
	local ok, err = pcall(vim.system, argv, { text = true, cwd = vim.fs.dirname(file) }, function(res)
		vim.schedule(function()
			if res.code == 0 then
				finish(M.parse_output(res.stdout), "config", nil)
			else
				fallback(vim.trim(res.stderr or ""))
			end
		end)
	end)
	if not ok then
		vim.schedule(function()
			fallback(tostring(err))
		end)
	end
end

return M
