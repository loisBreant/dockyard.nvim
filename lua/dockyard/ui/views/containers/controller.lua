local M = {}

local docker = require("dockyard.core.docker")
local data_state = require("dockyard.state")
local renderer = require("dockyard.ui.views.containers.renderer")
local ui_state = require("dockyard.ui.state")
local navigation = require("dockyard.ui.navigation")
local spinner = require("dockyard.ui.components.spinner")
local view_state = require("dockyard.ui.views.containers.state")

local POLL_INTERVAL_MS = 100

---@return boolean
local function is_containers_view_active()
	if ui_state.current_view ~= "containers" and ui_state.current_view ~= "compose" then
		return false
	end
	if ui_state.win_id == nil then
		return false
	end
	return vim.api.nvim_win_is_valid(ui_state.win_id)
end

local function stop_polling()
	if view_state.poll_spinner == nil then
		return
	end
	view_state.poll_spinner:stop()
	view_state.poll_spinner = nil
	view_state.spinner_frame = nil
end

local function start_polling()
	if view_state.poll_spinner ~= nil then
		return
	end

	view_state.poll_spinner = spinner.create({
		interval_ms = POLL_INTERVAL_MS,
		on_tick = function(frame)
			view_state.spinner_frame = frame
			if not is_containers_view_active() then
				stop_polling()
				return
			end

			data_state.containers.refresh({
				silent = true,
				on_success = function(items)
					renderer.render()
					if not docker.has_transitional_status(items) then
						stop_polling()
					end
				end,
				on_error = function()
					renderer.render()
				end,
			})
		end,
	})

	view_state.spinner_frame = view_state.poll_spinner:current_frame()
	view_state.poll_spinner:start()
end

---@param opts { focus_first?: boolean }|nil
local function render(opts)
	if ui_state.current_view ~= "containers" and ui_state.current_view ~= "compose" then
		return
	end
	if ui_state.win_id ~= nil and vim.api.nvim_win_is_valid(ui_state.win_id) then
		renderer.render()

		-- only when the previous selection is gone (first open, view switch)
		if opts and opts.focus_first == true and not navigation.restored then
			navigation.first()
		end
	end
end

---@param on_done fun()|nil
---@param opts { force_update?: boolean }|nil
function M.update(on_done, opts)
	local items = data_state.containers.get_items()
	local has_data = type(items) == "table" and #items > 0
	if (opts and opts.force_update) or not has_data then
		data_state.containers.refresh({
			silent = false,
			on_success = function(refreshed_items)
				render({ focus_first = true })
				if docker.has_transitional_status(refreshed_items) then
					start_polling()
				else
					stop_polling()
				end
				if on_done then
					on_done()
				end
			end,
			on_error = function()
				render({ focus_first = true })
				if on_done then
					on_done()
				end
			end,
		})
		return
	end

	render()
	if docker.has_transitional_status(items) then
		start_polling()
	else
		stop_polling()
	end
	if on_done then
		on_done()
	end
end

---@param item Container
function M.open_terminal(item)
	require("dockyard.ui.views.terminal").open(item.id, "sh", {
		mode = ui_state.mode,
		win = ui_state.win_id,
	})
end

---Host ports published by a container, from its formatted ports ("8080→80, 3000").
---@param item { ports?: string }
---@return integer[]
function M.published_ports(item)
	local ports = {}
	for host in tostring(item.ports or ""):gmatch("(%d+)%-?%d*→") do
		table.insert(ports, tonumber(host))
	end
	return ports
end

---@param item Container
function M.open_port(item)
	local ports = M.published_ports(item or {})
	if #ports == 0 then
		vim.notify("Dockyard: no published port", vim.log.levels.WARN)
		return
	end
	local function open(port)
		if port then
			require("dockyard.ui.utils").open_url("http://localhost:" .. port)
		end
	end
	if #ports == 1 then
		return open(ports[1])
	end
	vim.ui.select(ports, { prompt = "Open port" }, open)
end

---@param item Container
function M.open_logs(item)
	require("dockyard.ui.loglens").open(item)
end

---@param item Container
function M.open_details(item)
	require("dockyard.ui.popups.hover").open({ kind = "container", item = item })
end

function M.toggle(node)
	view_state.toggle(node.key)
end

function M.set_filter(filter)
	if filter == nil or filter == "" then
		view_state.filter = nil
	else
		view_state.filter = filter
	end
	renderer.render()
	if is_containers_view_active() then
		-- Move cursor to first matching container after filter
		navigation.first()
	end
end

function M.clear_filter()
	view_state.filter = nil
	renderer.render()
end

function M.toggle_project_scope()
	require("dockyard.scope").toggle()
	renderer.render()
	if is_containers_view_active() then
		navigation.first()
	end
end

function M.prompt_filter()
	vim.ui.input({ prompt = "Filter containers: ", default = view_state.filter or "" }, function(input)
		if input == nil then
			return
		end
		if input == "" then
			M.clear_filter()
		else
			M.set_filter(input)
		end
	end)
end

function M.on_teardown()
	stop_polling()
end

return M
