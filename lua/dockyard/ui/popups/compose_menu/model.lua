-- State and text of the compose options menu. No windows here, so it can be tested.

local compose = require("dockyard.commands.compose")
local prefs = require("dockyard.commands.prefs")
local runner = require("dockyard.commands.runner")

local M = {}

-- saved for the project; `on` is the value a checked box stands for when it is not `true`
local FLAG_ROWS = {
	{ key = "force_recreate", label = "--force-recreate" },
	{ key = "build", label = "--build" },
	{ key = "pull", label = "--pull", on = "always" },
	{ key = "no_deps", label = "--no-deps" },
	{ key = "wait", label = "--wait" },
	{ key = "remove_orphans", label = "--remove-orphans" },
}

-- never saved: they destroy data, or are only useful once
local ONCE_ROWS = {
	{ key = "volumes", label = "-v  remove volumes (down)" },
	{ key = "rmi", label = "--rmi", on = "local", suffix = "  remove images (down)" },
	{ key = "renew_anon_volumes", label = "-V  renew anonymous volumes (up)" },
}

local ACTION_KEYS = "<CR> %s · d down · b build · p pull · s stop · r restart"

---@class DockyardComposeMenuState
---@field file string
---@field project DockyardComposeProject
---@field action string action run by <CR>
---@field profiles string[] every profile to offer
---@field prefs table saved part
---@field once table this run only

---@param file string
---@param available string[] profiles found in the file
---@param saved table preferences of the project
---@param action? string
---@return DockyardComposeMenuState
function M.new(file, available, saved, action)
	local profiles = vim.deepcopy(available)
	for _, name in ipairs(saved.profiles or {}) do
		if not vim.tbl_contains(profiles, name) then
			table.insert(profiles, name)
		end
	end
	table.sort(profiles)
	return {
		file = file,
		project = compose.project(file),
		action = action or "up",
		profiles = profiles,
		prefs = vim.deepcopy(saved),
		once = { volumes = false, rmi = false, renew_anon_volumes = false },
	}
end

local function is_on(value)
	return value ~= nil and value ~= false
end

---@class DockyardComposeMenuItem
---@field id string
---@field section string
---@field label string
---@field checked boolean

---@param state DockyardComposeMenuState
---@return DockyardComposeMenuItem[]
function M.items(state)
	local items = {}
	local function add(section, id, label, checked)
		table.insert(items, { id = id, section = section, label = label, checked = checked })
	end
	if #state.profiles > 0 then
		for _, name in ipairs(state.profiles) do
			add("Profiles", "profile:" .. name, name, vim.tbl_contains(state.prefs.profiles, name))
		end
		add("Profiles", "all_profiles", "all profiles (*)", state.prefs.all_profiles == true)
	end
	for _, row in ipairs(FLAG_ROWS) do
		local value = state.prefs[row.key]
		local label = row.on and (row.label .. " " .. tostring(is_on(value) and value or row.on)) or row.label
		add("Saved for this project", "flag:" .. row.key, label, is_on(value))
	end
	for _, row in ipairs(ONCE_ROWS) do
		local value = state.once[row.key]
		local label = row.on and (row.label .. " " .. tostring(is_on(value) and value or row.on) .. (row.suffix or "")) or row.label
		add("This run only", "once:" .. row.key, label, is_on(value))
	end
	return items
end

---Flip a box.
---@param state DockyardComposeMenuState
---@param id string
---@return boolean saved whether the change belongs in the project preferences
function M.toggle(state, id)
	local function flip(tbl, key, on)
		tbl[key] = not is_on(tbl[key]) and (on or true) or false
	end
	local kind, name = id:match("^(%w+):(.+)$")
	if kind == "profile" then
		local list = state.prefs.profiles
		local at = vim.fn.index(list, name)
		if at >= 0 then
			table.remove(list, at + 1)
		else
			table.insert(list, name)
			table.sort(list)
		end
		return true
	elseif id == "all_profiles" then
		state.prefs.all_profiles = not state.prefs.all_profiles
		return true
	elseif kind == "flag" then
		for _, row in ipairs(FLAG_ROWS) do
			if row.key == name then
				flip(state.prefs, name, row.on)
			end
		end
		return true
	elseif kind == "once" then
		for _, row in ipairs(ONCE_ROWS) do
			if row.key == name then
				flip(state.once, name, row.on)
			end
		end
		return false
	end
	return false
end

---Options for compose.build: the saved preferences and the one-shot flags.
---@param state DockyardComposeMenuState
---@return DockyardComposeOpts
function M.opts(state)
	return vim.tbl_extend("force", state.prefs, state.once)
end

---The command a key would run.
---@param state DockyardComposeMenuState
---@param action string
---@return string
function M.command(state, action)
	local argv, err = compose.build(state.project, action, M.opts(state))
	return argv and runner.format_cmd(argv) or tostring(err)
end

---@param state DockyardComposeMenuState
---@return string[] lines, table<integer, string> item_lines line -> item id, table[] spans
function M.render(state)
	local lines, item_lines, spans = {}, {}, {}
	local function add(text, hl)
		table.insert(lines, text)
		if hl then
			table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #text, hl_group = hl })
		end
	end

	add(" Compose · " .. vim.fn.fnamemodify(state.file, ":t"), "DockyardTitle")
	local section
	for _, item in ipairs(M.items(state)) do
		if item.section ~= section then
			section = item.section
			add("")
			add(" " .. section, "DockyardColumnHeader")
		end
		add(("   [%s] %s"):format(item.checked and "x" or " ", item.label))
		item_lines[#lines] = item.id
	end
	add("")
	add(" $ " .. M.command(state, state.action), "DockyardMuted")
	add(" " .. ACTION_KEYS:format(state.action) .. " · <Space> toggle · q close", "DockyardMuted")
	return lines, item_lines, spans
end

---Short text for the lens: what differs from the defaults ("debug +build").
---@param saved table
---@return string
function M.summary(saved)
	local defaults = prefs.defaults()
	local parts = {}
	if saved.all_profiles then
		table.insert(parts, "*")
	elseif #(saved.profiles or {}) > 0 then
		table.insert(parts, table.concat(saved.profiles, ","))
	end
	for _, row in ipairs(FLAG_ROWS) do
		local now, was = is_on(saved[row.key]), is_on(defaults[row.key])
		if now ~= was then
			table.insert(parts, (now and "+" or "-") .. row.label:gsub("^%-%-", ""))
		end
	end
	return table.concat(parts, " ")
end

return M
