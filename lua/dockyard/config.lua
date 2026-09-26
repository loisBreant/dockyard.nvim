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
--- @field format? fun(entry: any, ctx: table): table<string, any>|nil Optional per-source formatter override (nil skips the entry)
--- @field highlights? LogHighlightRule[]     Optional per-source highlight override

--- @class ContainerLogConfig
--- @field sources? LogSource[]                   Log sources for this container
--- @field _order? string[]                       Default column order for all sources
--- @field max_lines? number                      Max rows kept in memory (default: 1000)
--- @field tails? number                          Default initial tail lines for each source (default: 100)
--- @field format? fun(entry: any, ctx: table): table<string, any>|nil Default formatter for all sources (nil skips the entry)
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

M.defaults = vim.deepcopy(M.options)

---@param options DockyardConfig
---@return string[] errors
function M.validate(options)
	local errors = {}
	-- vim.validate's signature changed in 0.11
	local function check(path, value, expected)
		if type(value) ~= expected then
			table.insert(errors, ("%s: expected %s, got %s"):format(path, expected, type(value)))
		end
	end
	local function check_keymap(path, value)
		local t = type(value)
		if value ~= nil and t ~= "string" and t ~= "table" and value ~= false then
			table.insert(errors, path .. ": expected string, list of strings or false, got " .. t)
		end
	end

	check("display", options.display, "table")
	check("compose_lens", options.compose_lens, "table")
	check("loglens", options.loglens, "table")
	check("keymaps", options.keymaps, "table")
	if type(options.display) == "table" then
		check("display.views", options.display.views, "table")
		check("display.open_strategy", options.display.open_strategy, "string")
		local scope = options.display.project_scope
		if scope ~= true and scope ~= false and scope ~= "auto" then
			table.insert(errors, 'display.project_scope: expected true, false or "auto", got ' .. vim.inspect(scope))
		end
	end
	if type(options.compose_lens) == "table" then
		check("compose_lens.enabled", options.compose_lens.enabled, "boolean")
	end
	if type(options.keymaps) == "table" then
		for context, maps in pairs(options.keymaps) do
			if type(maps) == "table" then
				for action, key in pairs(maps) do
					check_keymap(("keymaps.%s.%s"):format(context, action), key)
				end
			end
		end
	end
	return errors
end

-- options that exist but have no default value
local NO_DEFAULT = { ["loglens.default_highlights"] = true }

---Options Dockyard does not know (typos...). loglens.containers is free-form.
---@param options table
---@return string[]
function M.unknown_keys(options)
	local unknown = {}
	local function walk(user, defaults, path)
		for key, value in pairs(user) do
			local p = path == "" and tostring(key) or (path .. "." .. tostring(key))
			if defaults[key] == nil and not NO_DEFAULT[p] then
				table.insert(unknown, p)
			elseif type(value) == "table" and type(defaults[key]) == "table" and not vim.islist(defaults[key]) and p ~= "loglens.containers" then
				walk(value, defaults[key], p)
			end
		end
	end
	walk(options, M.defaults, "")
	table.sort(unknown)
	return unknown
end

---@type DockyardConfig
M.user = {}

---Optional: only merges options, plugin/dockyard.lua does the rest.
---@param opts? DockyardConfig
function M.setup(opts)
	M.user = opts or {}
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), M.user)
	local errors = M.validate(M.options)
	if #errors > 0 then
		vim.notify("dockyard: invalid options\n  " .. table.concat(errors, "\n  "), vim.log.levels.ERROR)
	end
end

return M
