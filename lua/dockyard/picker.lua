-- Pick a container from anywhere and act on it, without opening the dashboard.
-- Backs both :DockyardPick (vim.ui.select) and the :Telescope dockyard extension.

local docker = require("dockyard.core.docker")
local actions = require("dockyard.ui.actions.containers")

local M = {}

local function notify(msg, level)
	local levels = { error = vim.log.levels.ERROR, warn = vim.log.levels.WARN }
	vim.notify("[dockyard] " .. msg, levels[level] or vim.log.levels.INFO)
end

---@class DockyardPickAction
---@field key string
---@field label string
---@field run fun(c: Container)
---@field when? fun(c: Container): boolean

---@type DockyardPickAction[]
M.actions = {
	{
		key = "logs",
		label = "Logs",
		run = function(c)
			require("dockyard.ui.loglens").open(c, { mode = "split" })
		end,
	},
	{
		key = "shell",
		label = "Shell",
		when = function(c)
			return c.status == "running"
		end,
		run = function(c)
			require("dockyard.ui.views.terminal").open(c.name, "sh", { mode = "split" })
		end,
	},
	{
		key = "files",
		label = "Browse files",
		when = function(c)
			return c.status == "running"
		end,
		run = function(c)
			require("dockyard.files").open(c.name, "/")
		end,
	},
	{
		key = "open",
		label = "Open port in browser",
		when = function(c)
			return #require("dockyard.ui.views.containers.controller").published_ports(c) > 0
		end,
		run = function(c)
			require("dockyard.ui.views.containers.controller").open_port(c)
		end,
	},
	{
		key = "toggle",
		label = "Start / Stop",
		run = function(c)
			actions.toggle_start_stop(c, nil, notify)
		end,
	},
	{
		key = "restart",
		label = "Restart",
		run = function(c)
			actions.restart(c, nil, notify)
		end,
	},
}

---@param c Container
---@return DockyardPickAction[]
function M.available_actions(c)
	return vim.tbl_filter(function(a)
		return not a.when or a.when(c)
	end, M.actions)
end

-- run after the picker has closed and restored its mode, so an action that
-- enters insert mode (the shell) keeps it
local function later(a, c)
	vim.schedule(function()
		a.run(c)
	end)
end

---@param c Container
---@param key string
function M.run(c, key)
	for _, a in ipairs(M.actions) do
		if a.key == key then
			if a.when and not a.when(c) then
				return notify(a.label .. " is not available for " .. c.name, "warn")
			end
			return later(a, c)
		end
	end
end

---Ask which action to run on a container.
---@param c Container
function M.choose_action(c)
	vim.ui.select(M.available_actions(c), {
		prompt = c.name,
		format_item = function(a)
			return a.label
		end,
	}, function(a)
		if a then
			later(a, c)
		end
	end)
end

---@param c Container
---@return string
function M.format(c)
	local mark = c.status == "running" and "●" or "○"
	local ports = (c.ports and c.ports ~= "") and ("  " .. c.ports) or ""
	return ("%s %s  %s  %s%s"):format(mark, c.name, c.image, c.status_message or c.status, ports)
end

---Containers, running first, restricted to the current project when the
---dashboard's project scope applies.
---@param cb fun(items: Container[])
function M.list(cb)
	docker.list_containers(function(res)
		if not res.ok then
			return notify("could not list containers: " .. tostring(res.error), "error")
		end
		local items = require("dockyard.ui.views.containers.scope").apply(res.data or {})
		table.sort(items, function(a, b)
			if (a.status == "running") ~= (b.status == "running") then
				return a.status == "running"
			end
			return a.name < b.name
		end)
		cb(items)
	end)
end

---:DockyardPick — vim.ui.select, then the action menu.
function M.pick()
	M.list(function(items)
		if #items == 0 then
			return notify("no containers", "warn")
		end
		vim.ui.select(items, { prompt = "Containers", format_item = M.format }, function(c)
			if c then
				M.choose_action(c)
			end
		end)
	end)
end

return M
