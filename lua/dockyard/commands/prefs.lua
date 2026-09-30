-- Per-project compose preferences, kept in stdpath("data")/dockyard/projects.json.

local M = {}

local VERSION = 1

-- flags worth remembering; -v, --rmi and -V are deliberately left out: they destroy data
local FLAGS = { "build", "pull", "force_recreate", "no_deps", "wait", "remove_orphans" }

---@return string
function M.path()
	return vim.fn.stdpath("data") .. "/dockyard/projects.json"
end

---@type { version: integer, projects: table<string, table> }|nil
local data

---Forget what was read (tests, or after the file changed on disk).
function M.reset()
	data = nil
end

local function warn(msg)
	vim.notify("Dockyard: " .. msg, vim.log.levels.WARN)
end

local function load()
	if data then
		return data
	end
	data = { version = VERSION, projects = {} }
	local path = M.path()
	local fd = io.open(path, "r")
	if not fd then
		return data
	end
	local text = fd:read("*a")
	fd:close()
	local ok, decoded = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
	if ok and type(decoded) == "table" and decoded.version == VERSION and type(decoded.projects) == "table" then
		data = decoded
	else
		vim.uv.fs_rename(path, path .. ".bak")
		warn("could not read " .. path .. "; it was moved to projects.json.bak")
	end
	return data
end

---Read-only check of the file, for :checkhealth.
---@return boolean ok, string|nil problem
function M.check()
	local fd = io.open(M.path(), "r")
	if not fd then
		return true
	end
	local text = fd:read("*a")
	fd:close()
	local ok, decoded = pcall(vim.json.decode, text)
	if ok and type(decoded) == "table" and decoded.version == VERSION then
		return true
	end
	return false, "not valid JSON, or written by another version"
end

---@param file string compose file
---@return string
function M.key(file)
	return vim.uv.fs_realpath(file) or vim.fs.normalize(file)
end

---The defaults of a project that has no preferences yet.
---@return table
function M.defaults()
	local defaults = require("dockyard.config").options.compose.defaults
	return vim.tbl_extend("force", { profiles = {}, all_profiles = false }, vim.deepcopy(defaults))
end

---Saved preferences over the defaults.
---@param file string compose file
---@return table
function M.get(file)
	local saved = load().projects[M.key(file)] or {}
	local prefs = M.defaults()
	for _, name in ipairs(FLAGS) do
		if saved[name] ~= nil then
			prefs[name] = saved[name]
		end
	end
	if type(saved.profiles) == "table" then
		prefs.profiles = vim.deepcopy(saved.profiles)
	end
	if saved.all_profiles ~= nil then
		prefs.all_profiles = saved.all_profiles
	end
	return prefs
end

---Remember the persistent part of `prefs` for the project of `file`.
---@param file string compose file
---@param prefs table
---@return boolean ok
function M.set(file, prefs)
	local entry = { profiles = vim.deepcopy(prefs.profiles or {}), all_profiles = prefs.all_profiles == true }
	for _, name in ipairs(FLAGS) do
		entry[name] = prefs[name]
	end
	local current = load()
	current.projects[M.key(file)] = entry

	local path = M.path()
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	local tmp = path .. "." .. vim.uv.os_getpid() .. ".tmp"
	local fd, err = io.open(tmp, "w")
	if not fd then
		warn("could not save preferences: " .. tostring(err))
		return false
	end
	fd:write(vim.json.encode(current))
	fd:close()
	local renamed, rename_err = vim.uv.fs_rename(tmp, path)
	if not renamed then
		warn("could not save preferences: " .. tostring(rename_err))
		return false
	end
	return true
end

return M
