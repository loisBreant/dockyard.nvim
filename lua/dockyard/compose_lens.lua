-- Run / Stop / Logs / ... buttons next to the services of compose files.

local context = require("dockyard.commands.context")
local builder = require("dockyard.commands.builder")
local executor = require("dockyard.commands.executor")
local lens = require("dockyard.lens")

local M = {}

local group = vim.api.nvim_create_augroup("DockyardComposeLens", { clear = true })

---@class DockyardServiceStatus
---@field state string running|exited|created|...
---@field name string container name
---@field health string healthy|unhealthy|starting|""
---@field ports integer[] published tcp ports

---@type table<integer, table<string, DockyardServiceStatus>> buf -> service -> status
local statuses = {}

local function compose_base()
	if vim.fn.executable("docker") == 1 then
		return { "docker", "compose" }
	end
	return { "docker-compose" }
end

local function compose_cmd(file, ...)
	local args = vim.list_extend(compose_base(), { "-f", file })
	return vim.list_extend(args, { ... })
end

local function is_up(status)
	return status ~= nil and (status.state == "running" or status.state == "restarting")
end

local STATE_HL = {
	healthy = "DockyardRunning",
	running = "DockyardRunning",
	starting = "DockyardPending",
	restarting = "DockyardRestarting",
	unhealthy = "DockyardStopped",
}

-- one JSON object per line, or a single array with older compose versions
function M.parse_ps(output)
	local out = {}
	local function add(obj)
		if type(obj) == "table" and obj.Service then
			local ports, seen = {}, {}
			for _, pub in ipairs(type(obj.Publishers) == "table" and obj.Publishers or {}) do
				local port = tonumber(pub.PublishedPort)
				if port and port > 0 and not seen[port] and (pub.Protocol or "tcp") == "tcp" then
					seen[port] = true
					table.insert(ports, port)
				end
			end
			table.sort(ports)
			out[obj.Service] = {
				state = (obj.State or ""):lower(),
				name = obj.Name or "",
				health = (obj.Health or ""):lower(),
				ports = ports,
			}
		end
	end
	local ok, decoded = pcall(vim.json.decode, output)
	if ok and type(decoded) == "table" and decoded[1] ~= nil then
		for _, obj in ipairs(decoded) do
			add(obj)
		end
		return out
	end
	for line in output:gmatch("[^\r\n]+") do
		local ok_line, obj = pcall(vim.json.decode, line)
		if ok_line then
			add(obj)
		end
	end
	return out
end

---@param buf integer
---@param status table<string, DockyardServiceStatus>
---@return table<integer, DockyardLensLine>
function M.build_lines(buf, status)
	local lines = {}
	local block = context.compose_services(buf)
	if not block.lnum or #block.services == 0 then
		return lines
	end

	local any_up, any_created, any_build = false, false, false
	for _, service in ipairs(block.services) do
		local s = status[service.name]
		local line = lens.line()
		local name = service.name
		if s and s.state ~= "" then
			any_created = true
		end
		any_build = any_build or service.has_build

		if is_up(s) then
			any_up = true
			local state = s.health ~= "" and s.health or s.state
			line:add("● " .. state, STATE_HL[state] or "DockyardRunning")
			line:add("↻ Restart", "DockyardLensAction", { action = "restart", service = name })
			line:add("■ Stop", "DockyardLensStop", { action = "stop", service = name })
			line:add("≡ Logs", "DockyardLensAction", { action = "logs", service = name })
			line:add(" Shell", "DockyardLensAction", { action = "shell", service = name })
			for _, port in ipairs(s.ports or {}) do
				line:add("↗ :" .. port, "DockyardPorts", { action = "open", service = name, port = port })
			end
		else
			if s and s.state ~= "" then
				line:add("○ " .. s.state, "DockyardStopped")
			end
			line:add("▶ Run", "DockyardLensRun", { action = "run", service = name })
		end
		if service.has_build then
			line:add("⟳ Build", "DockyardLensAction", { action = "build", service = name })
		end
		lines[service.lnum] = line
	end

	local top = lens.line()
	top:add("▶▶ Run all", "DockyardLensRun", { action = "run" })
	if any_up then
		top:add("■ Stop all", "DockyardLensStop", { action = "stop" })
	end
	if any_build then
		top:add("⟳ Build all", "DockyardLensAction", { action = "build" })
	end
	if any_created then
		top:add("▼ Down", "DockyardLensStop", { action = "down" })
	end
	lines[block.lnum] = top
	return lines
end

local function render(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		lens.render(buf, M.build_lines(buf, statuses[buf] or {}))
	end
end

local refresh

function refresh(buf)
	local file = vim.api.nvim_buf_get_name(buf)
	render(buf)
	if file == "" or vim.fn.filereadable(file) == 0 then
		return
	end
	local cmd = compose_cmd(file, "ps", "-a", "--format", "json")
	pcall(vim.system, cmd, { text = true, cwd = vim.fn.fnamemodify(file, ":h") }, function(res)
		vim.schedule(function()
			statuses[buf] = res.code == 0 and M.parse_ps(res.stdout or "") or {}
			render(buf)
			-- poll while a service is starting and the file is visible
			for _, st in pairs(statuses[buf]) do
				if st.health == "starting" or st.state == "restarting" then
					vim.defer_fn(function()
						if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0 then
							refresh(buf)
						end
					end, 3000)
					break
				end
			end
		end)
	end)
end

---@param buf integer
---@param action string run|stop|restart|build|down|logs|shell|open
---@param service string|nil nil means every service
---@param port integer|nil for "open"; defaults to the first published port
function M.run_action(buf, action, service, port)
	local file = vim.api.nvim_buf_get_name(buf)
	local dir = vim.fn.fnamemodify(file, ":h")
	if vim.bo[buf].modified then
		vim.api.nvim_buf_call(buf, function()
			vim.cmd("silent! write")
		end)
	end

	local on_exit = function()
		refresh(buf)
	end
	local label = service or "all services"
	local function compose(verb)
		executor.run(compose_cmd(file, verb, service), { cwd = dir, title = "compose " .. verb .. " " .. label, on_exit = on_exit })
	end

	if action == "run" then
		local args, err = builder.run_cmd({ type = "compose", file = file, dir = dir }, service)
		if not args then
			vim.notify("Dockyard: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		executor.run(args, { cwd = dir, title = "compose up " .. label, on_exit = on_exit })
	elseif action == "stop" or action == "restart" or action == "build" then
		compose(action)
	elseif action == "down" then
		executor.run(compose_cmd(file, "down"), { cwd = dir, title = "compose down", on_exit = on_exit })
	elseif action == "open" then
		local s = (statuses[buf] or {})[service]
		port = port or (s and s.ports and s.ports[1])
		if not port then
			vim.notify("Dockyard: " .. tostring(service) .. " publishes no port", vim.log.levels.WARN)
			return
		end
		vim.ui.open("http://localhost:" .. port)
	elseif action == "logs" or action == "shell" then
		local s = (statuses[buf] or {})[service]
		if not is_up(s) or s.name == "" then
			vim.notify("Dockyard: " .. tostring(service) .. " is not running", vim.log.levels.WARN)
			return
		end
		if action == "logs" then
			vim.cmd.DockyardLogs(s.name)
		else
			require("dockyard.ui.views.terminal").open(s.name, "sh", { mode = "split" })
		end
	end
end

local function attach(buf)
	if vim.b[buf].dockyard_lens then
		refresh(buf)
		return
	end
	vim.b[buf].dockyard_lens = true

	lens.attach(buf, function(data)
		M.run_action(buf, data.action, data.service, data.port)
	end)

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		buffer = buf,
		callback = function()
			render(buf)
		end,
	})
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "FocusGained" }, {
		group = group,
		buffer = buf,
		callback = function()
			refresh(buf)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = buf,
		callback = function()
			statuses[buf] = nil
		end,
	})

	refresh(buf)
end

---@param buf integer
function M.maybe_attach(buf)
	if not require("dockyard.config").options.compose_lens.enabled then
		return
	end
	local name = vim.api.nvim_buf_get_name(buf)
	if name ~= "" and vim.bo[buf].buftype == "" and context.is_compose_file(name) then
		attach(buf)
	end
end

return M
