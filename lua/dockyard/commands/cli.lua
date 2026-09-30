-- :Dockyard [strategy] | pick | files | logs | build | run | service | compose | jobs | job | rerun

local M = {}

local STRATEGIES = { "current", "split", "vsplit", "tab", "float" }
local SERVICE_ACTIONS = { "run", "stop", "restart", "build", "logs", "shell", "open" }
local COMPOSE_ACTIONS = { "up", "down", "build", "pull", "stop", "restart" }
local ALIASES = { edit = "current", vertical = "vsplit", horizontal = "split", panel = "float" }

local function notify(msg, level)
	vim.notify("Dockyard: " .. msg, level or vim.log.levels.INFO)
end

local function starting_with(lead, items)
	return vim.tbl_filter(function(item)
		return vim.startswith(item, lead)
	end, items)
end

local function strategy_from_mods(mods)
	mods = mods or ""
	if mods:find("tab") then
		return "tab"
	elseif mods:find("vertical") then
		return "vsplit"
	elseif mods:find("horizontal") or mods:find("botright") or mods:find("topleft") then
		return "split"
	end
end

function M.open(strategy, mods)
	strategy = strategy and (ALIASES[strategy] or strategy)
	if strategy and not vim.tbl_contains(STRATEGIES, strategy) then
		notify("unknown strategy '" .. strategy .. "'", vim.log.levels.WARN)
		strategy = nil
	end
	strategy = strategy or strategy_from_mods(mods) or require("dockyard.config").options.display.open_strategy
	require("dockyard.ui").open_with_strategy(strategy, mods)
end

local function container_names(lead, all)
	local cmd = { "docker", "ps", "--format", "{{.Names}}" }
	if all then
		table.insert(cmd, "-a")
	end
	local res = vim.system(cmd, { text = true }):wait(2000)
	return starting_with(lead, vim.split(res.stdout or "", "\n", { trimempty = true }))
end

local function logs(name)
	require("dockyard.core.docker").list_containers(function(res)
		for _, c in ipairs(res.data or {}) do
			if c.name == name then
				return require("dockyard.ui.loglens").open(c, { mode = "split" })
			end
		end
		notify("no container named '" .. name .. "'", vim.log.levels.ERROR)
	end)
end

local function service(action)
	if not vim.tbl_contains(SERVICE_ACTIONS, action) then
		return notify("unknown service action '" .. action .. "'", vim.log.levels.ERROR)
	end
	local name = require("dockyard.commands.context").service_at_cursor()
	if not name then
		return notify("the cursor is not on a compose service", vim.log.levels.WARN)
	end
	require("dockyard.compose_lens").run_action(vim.api.nvim_get_current_buf(), action, name)
end

local function compose_file()
	local context = require("dockyard.commands.context")
	local file = context.current_file()
	if file and context.is_compose_file(file) then
		return file
	end
	return context.find_compose_file(vim.fn.getcwd())
end

local function job_ids(lead)
	local ids = vim.tbl_map(function(job)
		return tostring(job.id)
	end, require("dockyard.commands.runner").list())
	table.insert(ids, 1, "last")
	return starting_with(lead, ids)
end

-- "last" or nil is the most recent job
local function find_job(arg)
	local runner = require("dockyard.commands.runner")
	local job = (arg == nil or arg == "last") and runner.last() or runner.get(tonumber(arg))
	if not job then
		notify(arg and ("no job '" .. arg .. "'") or "no job yet", vim.log.levels.WARN)
	end
	return job
end

---@type table<string, { run: fun(args: string[], opts: table), complete?: fun(lead: string, args: string[]): string[] }>
M.subcommands = {
	open = {
		run = function(args, opts)
			M.open(args[1], opts.mods)
		end,
		complete = function(lead)
			return starting_with(lead, STRATEGIES)
		end,
	},
	pick = {
		run = function()
			require("dockyard.picker").pick()
		end,
	},
	files = {
		run = function(args)
			if not args[1] then
				return notify("usage: :Dockyard files {container} [path]", vim.log.levels.ERROR)
			end
			require("dockyard.files").open(args[1], args[2] or "/")
		end,
		complete = function(lead, args)
			return #args == 0 and container_names(lead, false) or {}
		end,
	},
	logs = {
		run = function(args)
			if not args[1] then
				return notify("usage: :Dockyard logs {container}", vim.log.levels.ERROR)
			end
			logs(args[1])
		end,
		complete = function(lead, args)
			return #args == 0 and container_names(lead, true) or {}
		end,
	},
	build = {
		run = function()
			require("dockyard.commands").build()
		end,
	},
	run = {
		run = function(_, opts)
			if opts.range == 2 then
				require("dockyard.commands").run_visual(opts.line1, opts.line2)
			else
				require("dockyard.commands").run_all()
			end
		end,
	},
	service = {
		run = function(args)
			service(args[1] or "run")
		end,
		complete = function(lead)
			return starting_with(lead, SERVICE_ACTIONS)
		end,
	},
	compose = {
		run = function(args)
			local action = args[1] or "up"
			if not vim.tbl_contains(COMPOSE_ACTIONS, action) then
				return notify("unknown compose action '" .. action .. "'", vim.log.levels.ERROR)
			end
			local file = compose_file()
			if not file then
				return notify("no compose file found", vim.log.levels.WARN)
			end
			require("dockyard.ui.popups.compose_menu").open(file, { action = action })
		end,
		complete = function(lead)
			return starting_with(lead, COMPOSE_ACTIONS)
		end,
	},
	jobs = {
		run = function()
			require("dockyard.ui").open_view("jobs")
		end,
	},
	job = {
		run = function(args)
			local job = find_job(args[1])
			if job then
				require("dockyard.ui.views.jobs.output").open(job.id)
			end
		end,
		complete = function(lead, args)
			return #args == 0 and job_ids(lead) or {}
		end,
	},
	rerun = {
		run = function(args)
			local job = find_job(args[1])
			if job then
				require("dockyard.commands.runner").rerun(job.id)
			end
		end,
		complete = function(lead, args)
			return #args == 0 and job_ids(lead) or {}
		end,
	},
}

function M.dispatch(opts)
	local args = vim.deepcopy(opts.fargs)
	local name = table.remove(args, 1)
	local sub = M.subcommands[name]
	if sub then
		sub.run(args, opts)
	elseif not name or vim.tbl_contains(STRATEGIES, ALIASES[name] or name) then
		M.open(name, opts.mods)
	else
		notify("unknown subcommand '" .. name .. "'", vim.log.levels.ERROR)
	end
end

function M.complete(lead, cmdline)
	local words = vim.split(cmdline, "%s+", { trimempty = true })
	table.remove(words, 1)
	if lead ~= "" then
		table.remove(words)
	end
	if #words == 0 then
		local names = vim.list_extend(vim.tbl_keys(M.subcommands), STRATEGIES)
		table.sort(names)
		return starting_with(lead, names)
	end
	local sub = M.subcommands[words[1]]
	return sub and sub.complete and sub.complete(lead, vim.list_slice(words, 2)) or {}
end

return M
