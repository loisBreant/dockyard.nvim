-- :Dockyard and its subcommands. plugin/dockyard.lua only forwards to this
-- module, so nothing here loads until a command is used.
--
--   :Dockyard [current|split|vsplit|tab|float]   open the dashboard
--   :Dockyard pick                                 container picker
--   :Dockyard files {container} [path]             container file browser
--   :Dockyard logs {container}                     LogLens
--   :Dockyard build                                build the current Dockerfile
--   :[range]Dockyard run                           compose up (all, or services in range)
--   :Dockyard service {action}                     act on the compose service under the cursor

local M = {}

local STRATEGIES = { "current", "split", "vsplit", "tab", "float" }
M.SERVICE_ACTIONS = { "run", "stop", "restart", "build", "logs", "shell", "open" }

local ALIASES = {
	edit = "current",
	buffer = "current",
	enew = "current",
	horizontal = "split",
	hsplit = "split",
	vertical = "vsplit",
	tabnew = "tab",
	panel = "float",
	floating = "float",
}

local function notify(msg, level)
	vim.notify("Dockyard: " .. msg, level or vim.log.levels.INFO)
end

local function normalize_strategy(val)
	if not val or val == "" then
		return nil
	end
	val = vim.trim(tostring(val)):lower()
	return ALIASES[val] or val
end

-- honour :vertical / :tab / :horizontal / :botright ... like :split does
local function strategy_from_mods(mods)
	local m = (mods or ""):lower()
	if m:find("tab") then
		return "tab"
	end
	if m:find("vertical") then
		return "vsplit"
	end
	if m:find("horizontal") or m:find("botright") or m:find("topleft") or m:find("above") or m:find("below") then
		return "split"
	end
	return nil
end

---@param strategy string|nil
---@param mods string|nil
function M.open(strategy, mods)
	local resolved = normalize_strategy(strategy)
	if resolved and not vim.tbl_contains(STRATEGIES, resolved) then
		notify("unknown strategy '" .. tostring(strategy) .. "', using the default", vim.log.levels.WARN)
		resolved = nil
	end
	resolved = resolved or strategy_from_mods(mods) or require("dockyard.config").options.display.open_strategy or "tab"
	require("dockyard.ui").open_with_strategy(resolved, mods)
end

local function container_names(lead, running_only)
	local args = { "docker", "ps", "--format", "{{.Names}}" }
	if not running_only then
		table.insert(args, 3, "-a")
	end
	local ok, res = pcall(function()
		return vim.system(args, { text = true }):wait(2000)
	end)
	if not ok or not res or res.code ~= 0 then
		return {}
	end
	return vim.tbl_filter(function(name)
		return name ~= "" and vim.startswith(name, lead)
	end, vim.split(res.stdout or "", "\n", { plain = true }))
end

function M.logs(name)
	if not name or name == "" then
		return notify("a container name is required", vim.log.levels.ERROR)
	end
	require("dockyard.core.docker").list_containers(function(result)
		if not result.ok or type(result.data) ~= "table" then
			return notify("failed to list containers", vim.log.levels.ERROR)
		end
		for _, c in ipairs(result.data) do
			if c.name == name or (c.name and c.name:gsub("^/", "") == name) then
				return require("dockyard.ui.loglens").open(c, { mode = "split" })
			end
		end
		notify("container '" .. name .. "' not found", vim.log.levels.ERROR)
	end)
end

function M.service(action)
	action = action or "run"
	if not vim.tbl_contains(M.SERVICE_ACTIONS, action) then
		return notify("unknown service action '" .. action .. "'", vim.log.levels.ERROR)
	end
	local service = require("dockyard.commands.context").service_at_cursor()
	if not service then
		return notify("the cursor is not on a compose service", vim.log.levels.WARN)
	end
	require("dockyard.compose_lens").run_action(vim.api.nvim_get_current_buf(), action, service)
end

function M.run(opts)
	if opts and opts.range == 2 then
		require("dockyard.commands").run_visual(opts.line1, opts.line2)
	else
		require("dockyard.commands").run_all()
	end
end

---@class DockyardSubcommand
---@field impl fun(args: string[], opts: table)
---@field complete? fun(lead: string, args: string[]): string[]

---@type table<string, DockyardSubcommand>
M.subcommands = {
	open = {
		impl = function(args, opts)
			M.open(args[1], opts.mods)
		end,
		complete = function(lead)
			return vim.tbl_filter(function(s)
				return vim.startswith(s, lead)
			end, STRATEGIES)
		end,
	},
	pick = {
		impl = function()
			require("dockyard.picker").pick()
		end,
	},
	files = {
		impl = function(args)
			if not args[1] then
				return notify("usage: :Dockyard files {container} [path]", vim.log.levels.ERROR)
			end
			require("dockyard.files").open(args[1], args[2] or "/")
		end,
		complete = function(lead, args)
			return #args == 0 and container_names(lead, true) or {}
		end,
	},
	logs = {
		impl = function(args)
			M.logs(args[1])
		end,
		complete = function(lead, args)
			return #args == 0 and container_names(lead, false) or {}
		end,
	},
	build = {
		impl = function()
			require("dockyard.commands").build()
		end,
	},
	run = {
		impl = function(_, opts)
			M.run(opts)
		end,
	},
	service = {
		impl = function(args)
			M.service(args[1])
		end,
		complete = function(lead)
			return vim.tbl_filter(function(a)
				return vim.startswith(a, lead)
			end, M.SERVICE_ACTIONS)
		end,
	},
}

---Entry point of :Dockyard.
---@param opts table user command callback argument
function M.dispatch(opts)
	local args = vim.deepcopy(opts.fargs)
	local name = table.remove(args, 1)
	if not name then
		return M.open(nil, opts.mods)
	end
	local sub = M.subcommands[name]
	if sub then
		return sub.impl(args, opts)
	end
	-- :Dockyard float / :Dockyard vsplit ...
	if vim.tbl_contains(STRATEGIES, normalize_strategy(name) or "") then
		return M.open(name, opts.mods)
	end
	notify("unknown subcommand '" .. name .. "'", vim.log.levels.ERROR)
end

---Completion of :Dockyard.
function M.complete(lead, cmdline)
	local words = vim.split(cmdline:gsub("^%S*Dockyard%s*", ""), "%s+", { trimempty = true })
	if lead ~= "" then
		table.remove(words)
	end
	if #words == 0 then
		local names = vim.list_extend(vim.tbl_keys(M.subcommands), vim.deepcopy(STRATEGIES))
		table.sort(names)
		return vim.tbl_filter(function(n)
			return vim.startswith(n, lead)
		end, names)
	end
	local sub = M.subcommands[words[1]]
	if sub and sub.complete then
		return sub.complete(lead, vim.list_slice(words, 2))
	end
	return {}
end

return M
