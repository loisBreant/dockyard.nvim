-- Builds `docker compose` command lines. Pure: no I/O besides the docker/docker-compose lookup.

local M = {}

---@class DockyardComposeProject
---@field files string[] compose files, in `-f` order
---@field dir string working directory
---@field name? string project name (`-p`)
---@field env_file? string `--env-file`

---@class DockyardComposeOpts
---@field profiles? string[]
---@field all_profiles? boolean `--profile '*'`
---@field services? string[]
---@field build? boolean up: `--build`
---@field pull? false|"always"|"missing"|"never" up: `--pull`
---@field force_recreate? boolean up
---@field no_deps? boolean up
---@field wait? boolean up
---@field remove_orphans? boolean up, down
---@field renew_anon_volumes? boolean up: `-V`
---@field volumes? boolean down: `-v`
---@field rmi? false|"local"|"all" down

---@return string[] base command parts
function M.base_cmd()
	if vim.fn.executable("docker") == 1 then
		return { "docker", "compose" }
	end
	return { "docker-compose" }
end

---The project of a compose file: the file alone, run from its directory.
---@param file string
---@return DockyardComposeProject
function M.project(file)
	return { files = { file }, dir = vim.fs.dirname(file) }
end

local function push(list, ...)
	for _, value in ipairs({ ... }) do
		table.insert(list, value)
	end
end

-- verb + its flags; `o` is the options table
local VERBS = {
	up = function(o)
		local a = { "up", "-d" }
		if o.build then
			push(a, "--build")
		end
		if o.pull then
			push(a, "--pull", o.pull == true and "always" or o.pull)
		end
		if o.force_recreate then
			push(a, "--force-recreate")
		end
		if o.no_deps then
			push(a, "--no-deps")
		end
		if o.wait then
			push(a, "--wait")
		end
		if o.remove_orphans then
			push(a, "--remove-orphans")
		end
		if o.renew_anon_volumes then
			push(a, "-V")
		end
		return a
	end,
	down = function(o)
		local a = { "down" }
		if o.volumes then
			push(a, "-v")
		end
		if o.rmi then
			push(a, "--rmi", o.rmi == true and "local" or o.rmi)
		end
		if o.remove_orphans then
			push(a, "--remove-orphans")
		end
		return a
	end,
	stop = function()
		return { "stop" }
	end,
	restart = function()
		return { "restart" }
	end,
	build = function()
		return { "build" }
	end,
	pull = function()
		return { "pull" }
	end,
	-- names of the profiles of a file; profile flags would be meaningless here
	profiles = function()
		return { "config", "--profiles" }
	end,
}

---@param project DockyardComposeProject
---@param action "up"|"down"|"stop"|"restart"|"build"|"pull"|"profiles"
---@param opts? DockyardComposeOpts
---@return string[]|nil argv, string|nil err
function M.build(project, action, opts)
	opts = opts or {}
	if not project or not project.files or #project.files == 0 then
		return nil, "No compose file found"
	end
	local verb = VERBS[action]
	if not verb then
		return nil, "Unknown compose action: " .. tostring(action)
	end

	local argv = M.base_cmd()
	for _, file in ipairs(project.files) do
		push(argv, "-f", file)
	end
	if project.name and project.name ~= "" then
		push(argv, "-p", project.name)
	end
	if project.env_file and project.env_file ~= "" then
		push(argv, "--env-file", project.env_file)
	end
	if action ~= "profiles" then
		if opts.all_profiles then
			push(argv, "--profile", "*")
		else
			for _, profile in ipairs(opts.profiles or {}) do
				push(argv, "--profile", profile)
			end
		end
	end
	for _, part in ipairs(verb(opts)) do
		table.insert(argv, part)
	end
	if action ~= "profiles" then
		for _, service in ipairs(opts.services or {}) do
			table.insert(argv, service)
		end
	end
	return argv
end

return M
