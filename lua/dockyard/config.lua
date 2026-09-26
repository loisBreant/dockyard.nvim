--- @alias LogParserType "json"|"text"
--- "json" = always parse as JSON
--- "text" = treat as plain text, no parsing

--- A single highlight rule. Matches a Lua pattern and applies a color.
--- Use EITHER 'group' (Neovim highlight group) OR 'color' (hex), not both.
---
--- @class LogHighlightRule
--- @field pattern string    Lua pattern to match (e.g., "%[ERROR%]", "%d+%.%d+%.%d+%.%d+")
--- @field group? string     Neovim highlight group (e.g., "DiagnosticError", "Comment")
--- @field color? string     Hex color (e.g., "#ff5555", "#50fa7b")
---
--- Examples:
---   { pattern = "%[ERROR%]", group = "DiagnosticError" }  -- Use built-in group
---   { pattern = "%[CRITICAL%]", color = "#ff0000" }       -- Use custom hex color
---   { pattern = "%d%d:%d%d:%d%d", group = "Comment" }     -- Timestamps gray

--- A log source defines where to get logs and how to display them.
--- A container can have multiple sources (docker output, various log files).
---
--- A log source defines where to get logs and how to display them.
--- A container can have multiple sources (docker output, various log files).
--- Omitting `path` streams docker stdout/stderr (equivalent to `docker logs -f`).
--- For path-less sources, `parser` and `format` default to plain-text if not set.
---
--- @class LogSource
--- @field name? string                       Display name (auto-generated if omitted)
--- @field path? string                       File path inside the container; omit to stream docker logs
--- @field parser? LogParserType              How to parse logs ("json" or "text"); defaults to "text" when path is absent
--- @field _order? string[]                   Optional per-source column key order override
--- @field max_lines? number                  Optional per-source max rows override
--- @field tails? number                      Number of lines to tail on initial load (default: 100)
--- @field format? fun(entry: any, ctx: table): table<string, any> Optional per-source formatter override
--- @field highlights? LogHighlightRule[]     Optional per-source highlight override

--- @class ContainerLogConfig
--- @field sources? LogSource[]                   Log sources for this container
--- @field _order? string[]                       Default column order for all sources
--- @field max_lines? number                      Max rows kept in memory (default: 1000)
--- @field tails? number                          Default initial tail lines for each source (default: 100)
--- @field format? fun(entry: any, ctx: table): table<string, any> Default formatter for all sources
--- @field highlights? LogHighlightRule[]         Default highlight rules for all sources

--- @class LogLensConfig
--- @field containers? table<string, ContainerLogConfig> Per-container configurations
--- @field default_highlights? LogHighlightRule[]        Fallback highlights for all containers (overrides built-in defaults)

--- @alias DockyardView "containers"|"compose"|"images"|"networks"|"volumes"

--- @alias DockyardOpenStrategy "current"|"split"|"vsplit"|"tab"|"float"
--- How :Dockyard opens when no explicit arg/modifier is given.
---  "current" = replace current window (like :edit)
---  "split"   = horizontal split (like :split)
---  "vsplit"  = vertical split (like :vsplit / :vertical split)
---  "tab"     = new tabpage (like :tabnew) — default, preserves old behavior
---  "float"   = centered floating window (like :DockyardFloat)

--- @class DisplayConfig
--- @field views? DockyardView[] Ordered list of views shown in the navbar
--- @field open_strategy? DockyardOpenStrategy Default open strategy for :Dockyard
--- @field project_scope? boolean|"auto" Start with only the current project's containers shown (toggle with P); "auto" = when the project has a compose file

--- @class ComposeLensConfig
--- @field enabled? boolean Clickable actions next to services in compose files and on a Dockerfile's FROM line

--- @class DockyardConfig
--- @field display? DisplayConfig Display settings
--- @field compose_lens? ComposeLensConfig Compose file actions
--- @field loglens? LogLensConfig LogLens settings
--- @field keymaps? DockyardKeymapsConfig Keybindings (see core/keymaps.lua for type)

local M = {}

---@type DockyardConfig
M.options = {
	display = {
		views = { "containers", "images", "networks", "volumes" },
		open_strategy = "tab",
		project_scope = "auto",
	},
	compose_lens = {
		enabled = true,
	},
	loglens = {
		containers = {},
	},
	keymaps = {
		ui = {
			help = "g?",
			close = "q",
			refresh = "R",
			next_view = { "<Tab>", "]" },
			prev_view = { "<S-Tab>", "[" },
			toggle_node = "<CR>",
			open_details = "K",
			open_panel = "p",
		},
		containers = {
			toggle_start_stop = "s",
			stop = "x",
			restart = "r",
			remove = "d",
			open_terminal = "T",
			open_logs = "L",
			open_files = "f",
			open_port = "o",
			filter = "F",
			clear_filter = "C",
			toggle_project_scope = "P",
		},
		images = {
			remove = "d",
			prune = "P",
		},
		networks = {
			remove = "d",
		},
		volumes = {
			remove = "d",
		},
		loglens = {
			close = "q",
			toggle_follow = "f",
			toggle_raw = "r",
			filter = "/",
			clear_filter = "c",
			next_source = "<Tab>",
			prev_source = "<S-Tab>",
			open_detail = { "<CR>", "K" },
			help = "g?",
		},
	},
}

local _dockyard_strategies = { "current", "edit", "split", "vsplit", "tab", "float" }

local function normalize_strategy(val)
	if not val or val == "" then
		return nil
	end
	val = vim.trim(tostring(val)):lower()
	if val == "edit" or val == "current" or val == "buffer" or val == "enew" then
		return "current"
	end
	if val == "split" or val == "horizontal" or val == "hsplit" or val == "h_split" then
		return "split"
	end
	if val == "vsplit" or val == "vertical" or val == "v_split" then
		return "vsplit"
	end
	if val == "tab" or val == "tabnew" or val == "tabe" then
		return "tab"
	end
	if val == "float" or val == "panel" or val == "floating" then
		return "float"
	end
	return val
end

-- Resolve final strategy honoring Vim's command modifiers (:vertical, :tab, :horizontal, :botright, etc.)
-- This mirrors oil.nvim's mods support and the standard Vim convention where
-- :vertical Dockyard => vsplit, :tab Dockyard => tab, :horizontal Dockyard => split.
local function resolve_strategy(arg, mods)
	local from_arg = normalize_strategy(arg)
	if from_arg and vim.tbl_contains(_dockyard_strategies, from_arg) then
		return from_arg
	end
	if from_arg ~= nil then
		vim.notify("Dockyard: unknown strategy '" .. tostring(arg) .. "' — falling back to default", vim.log.levels.WARN)
	end
	if mods and mods ~= "" then
		local m = mods:lower()
		if m:find("tab") then
			return "tab"
		end
		if m:find("vertical") then
			return "vsplit"
		end
		if m:find("horizontal") then
			return "split"
		end
		-- :botright / :leftabove / :aboveleft / :belowright / :topleft imply a split
		if m:find("botright") or m:find("leftabove") or m:find("aboveleft") or m:find("belowright") or m:find("topleft") then
			return "split"
		end
	end
	return M.options.display.open_strategy or "tab"
end

local function dockyard_complete(arg_lead, _cmd_line, _cursor_pos)
	local strategies = { "current", "edit", "split", "vsplit", "tab", "float" }
	if not arg_lead or arg_lead == "" then
		return strategies
	end
	local out = {}
	local lead = arg_lead:lower()
	for _, s in ipairs(strategies) do
		if vim.startswith(s, lead) then
			table.insert(out, s)
		end
	end
	return out
end

local function create_commands()
	pcall(vim.api.nvim_del_user_command, "Dockyard")
	pcall(vim.api.nvim_del_user_command, "DockyardFloat")
	pcall(vim.api.nvim_del_user_command, "DockyardFull")
	pcall(vim.api.nvim_del_user_command, "DockyardBuild")
	pcall(vim.api.nvim_del_user_command, "DockyardRun")
	pcall(vim.api.nvim_del_user_command, "DockyardFiles")
	pcall(vim.api.nvim_del_user_command, "DockyardLogs")
	pcall(vim.api.nvim_del_user_command, "DockyardService")

	vim.api.nvim_create_user_command("Dockyard", function(opts)
		local strategy = resolve_strategy(opts.args, opts.mods)
		require("dockyard.ui").open_with_strategy(strategy, opts.mods)
	end, {
		desc = "Open Dockyard UI (args: current|split|vsplit|tab|float; also honors :vertical/:tab/:horizontal modifiers)",
		nargs = "?",
		complete = dockyard_complete,
	})

	-- Kept for backwards compatibility — delegate to unified strategy.
	vim.api.nvim_create_user_command("DockyardFloat", function()
		require("dockyard.ui").open_with_strategy("float", nil)
	end, { desc = "Open Dockyard Floating UI (deprecated: use :Dockyard float)" })

	vim.api.nvim_create_user_command("DockyardFull", function()
		require("dockyard.ui").open_with_strategy("tab", nil)
	end, { desc = "Open Dockyard fullscreen UI (deprecated: use :Dockyard tab)" })

	vim.api.nvim_create_user_command("DockyardBuild", function()
		require("dockyard.commands").build()
	end, { desc = "Build Docker image from current Dockerfile" })

	vim.api.nvim_create_user_command("DockyardRun", function(cmd_opts)
		if cmd_opts.range == 2 then
			require("dockyard.commands").run_visual(cmd_opts.line1, cmd_opts.line2)
		else
			require("dockyard.commands").run_all()
		end
	end, { desc = "Run Docker Compose services", range = true })

	local service_actions = { "run", "stop", "restart", "build", "logs", "shell", "open" }
	vim.api.nvim_create_user_command("DockyardService", function(cmd_opts)
		local action = cmd_opts.fargs[1] or "run"
		if not vim.tbl_contains(service_actions, action) then
			vim.notify("DockyardService: unknown action '" .. action .. "'", vim.log.levels.ERROR)
			return
		end
		local service = require("dockyard.commands.context").service_at_cursor()
		if not service then
			vim.notify("DockyardService: cursor is not on a compose service", vim.log.levels.WARN)
			return
		end
		require("dockyard.compose_lens").run_action(vim.api.nvim_get_current_buf(), action, service)
	end, {
		desc = "Act on the compose service under the cursor (run|stop|restart|build|logs|shell|open)",
		nargs = "?",
		complete = function(arg_lead)
			return vim.tbl_filter(function(a)
				return vim.startswith(a, arg_lead)
			end, service_actions)
		end,
	})

	vim.api.nvim_create_user_command("DockyardLogs", function(cmd_opts)
		local name = cmd_opts.fargs[1]
		if not name or name == "" then
			vim.notify("DockyardLogs: container required", vim.log.levels.ERROR)
			return
		end
		require("dockyard.core.docker").list_containers(function(result)
			if not result.ok or type(result.data) ~= "table" then
				vim.schedule(function()
					vim.notify("DockyardLogs: failed to list containers", vim.log.levels.ERROR)
				end)
				return
			end
			local match
			for _, c in ipairs(result.data) do
				if c.name == name or (c.name and c.name:gsub("^/", "") == name) then
					match = c
					break
				end
			end
			vim.schedule(function()
				if not match then
					vim.notify("DockyardLogs: container '" .. name .. "' not found", vim.log.levels.ERROR)
					return
				end
				require("dockyard.ui.loglens").open(match, { mode = "split" })
			end)
		end)
	end, {
		desc = "Open LogLens for a container",
		nargs = 1,
		complete = function(arg_lead)
			local out = vim.fn.systemlist({ "docker", "ps", "--format", "{{.Names}}" })
			local matches = {}
			for _, n in ipairs(out) do
				if n:find(arg_lead, 1, true) == 1 then
					table.insert(matches, n)
				end
			end
			return matches
		end,
	})

	vim.api.nvim_create_user_command("DockyardFiles", function(cmd_opts)
		local container = cmd_opts.fargs[1]
		local path = cmd_opts.fargs[2] or "/"
		if not container or container == "" then
			vim.notify("DockyardFiles: container required", vim.log.levels.ERROR)
			return
		end
		require("dockyard.files").open(container, path)
	end, {
		desc = "Browse a container's filesystem",
		nargs = "+",
		complete = function(arg_lead)
			local out = vim.fn.systemlist({ "docker", "ps", "--format", "{{.Names}}" })
			local matches = {}
			for _, name in ipairs(out) do
				if name:find(arg_lead, 1, true) == 1 then
					table.insert(matches, name)
				end
			end
			return matches
		end,
	})
end

---@param opts? DockyardConfig
function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.options, opts or {})
	create_commands()
	require("dockyard.files").setup()
	if M.options.compose_lens.enabled then
		require("dockyard.compose_lens").setup()
		require("dockyard.dockerfile_lens").setup()
	end
end

return M
