-- Clickable actions in compose files, like VSCode's "Run Service" code lenses.
-- `services:` gets "Run all", every service gets its state plus the actions
-- that make sense for it (Run when down; Restart / Stop / Logs / Shell when up).

local context = require("dockyard.commands.context")
local builder = require("dockyard.commands.builder")
local executor = require("dockyard.commands.executor")

local M = {}

local ns = vim.api.nvim_create_namespace("dockyard.compose_lens")
local group = vim.api.nvim_create_augroup("DockyardComposeLens", { clear = true })

---@class DockyardLensButton
---@field first integer display column where the label starts, 0-based from the lens start
---@field last integer display column after the label
---@field action string
---@field service string|nil

---@type table<integer, table<integer, DockyardLensButton[]>> buf -> 1-based lnum -> buttons
local buttons = {}

---@type table<integer, table<string, { state: string, name: string, health: string }>> buf -> service -> status
local statuses = {}

local SEP = "  "

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

-- `docker compose ps --format json` prints one object per line on recent
-- versions and a single array on older ones
local function parse_ps(output)
	local out = {}
	local function add(obj)
		if type(obj) == "table" and obj.Service then
			out[obj.Service] = {
				state = (obj.State or ""):lower(),
				name = obj.Name or "",
				health = (obj.Health or ""):lower(),
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

---@param chunks table virt_text being built
---@param list DockyardLensButton[]
---@param width integer current display width of the lens
---@return integer width
local function push(chunks, list, width, label, hl, action, service)
	table.insert(chunks, { SEP, "DockyardLensMuted" })
	width = width + #SEP
	local w = vim.fn.strdisplaywidth(label)
	table.insert(chunks, { label, hl })
	if action then
		table.insert(list, { first = width, last = width + w, action = action, service = service })
	end
	return width + w
end

local function render(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	buttons[buf] = {}

	local block = context.compose_services(buf)
	if not block.lnum then
		return
	end
	local status = statuses[buf] or {}

	local function place(lnum, chunks, list)
		buttons[buf][lnum] = list
		vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
			virt_text = chunks,
			virt_text_pos = "eol",
			hl_mode = "combine",
		})
	end

	local any_up = false
	for _, service in ipairs(block.services) do
		local s = status[service.name]
		local chunks, list, width = {}, {}, 0
		if is_up(s) then
			any_up = true
			local state = s.health ~= "" and s.health or s.state
			width = push(chunks, list, width, "● " .. state, "DockyardRunning")
			width = push(chunks, list, width, "↻ Restart", "DockyardLensAction", "restart", service.name)
			width = push(chunks, list, width, "■ Stop", "DockyardLensStop", "stop", service.name)
			width = push(chunks, list, width, "≡ Logs", "DockyardLensAction", "logs", service.name)
			push(chunks, list, width, " Shell", "DockyardLensAction", "shell", service.name)
		else
			if s and s.state ~= "" then
				width = push(chunks, list, width, "○ " .. s.state, "DockyardStopped")
			end
			push(chunks, list, width, "▶ Run", "DockyardLensRun", "run", service.name)
		end
		place(service.lnum, chunks, list)
	end

	if #block.services > 0 then
		local chunks, list = {}, {}
		local width = push(chunks, list, 0, "▶▶ Run all", "DockyardLensRun", "run")
		if any_up then
			push(chunks, list, width, "■ Stop all", "DockyardLensStop", "stop")
		end
		place(block.lnum, chunks, list)
	end
end

local function refresh(buf)
	local file = vim.api.nvim_buf_get_name(buf)
	render(buf)
	if file == "" or vim.fn.filereadable(file) == 0 then
		return
	end
	local cmd = compose_cmd(file, "ps", "-a", "--format", "json")
	pcall(vim.system, cmd, { text = true, cwd = vim.fn.fnamemodify(file, ":h") }, function(res)
		vim.schedule(function()
			statuses[buf] = res.code == 0 and parse_ps(res.stdout or "") or {}
			render(buf)
		end)
	end)
end

---@param buf integer
---@param action string run|stop|restart|logs|shell
---@param service string|nil nil means every service
function M.run_action(buf, action, service)
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

	if action == "run" then
		local args = builder.run_cmd({ type = "compose", file = file, dir = dir }, service)
		executor.run(args, { cwd = dir, title = "compose up " .. label, on_exit = on_exit })
	elseif action == "stop" then
		local args = compose_cmd(file, "stop")
		if service then
			table.insert(args, service)
		end
		executor.run(args, { cwd = dir, title = "compose stop " .. label, on_exit = on_exit })
	elseif action == "restart" then
		executor.run(compose_cmd(file, "restart", service), { cwd = dir, title = "compose restart " .. label, on_exit = on_exit })
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

-- the button under the mouse, if the click landed on a lens
local function button_at_mouse(buf)
	local pos = vim.fn.getmousepos()
	if pos.winid == 0 or vim.api.nvim_win_get_buf(pos.winid) ~= buf then
		return nil
	end
	local list = (buttons[buf] or {})[pos.line]
	if not list or #list == 0 then
		return nil
	end
	local info = vim.fn.getwininfo(pos.winid)[1]
	local leftcol = vim.api.nvim_win_call(pos.winid, function()
		return vim.fn.winsaveview().leftcol
	end)
	local text = vim.api.nvim_buf_get_lines(buf, pos.line - 1, pos.line, false)[1] or ""
	-- eol virtual text starts one cell after the end of the line
	local offset = pos.wincol - info.textoff + leftcol - 1 - (vim.fn.strdisplaywidth(text) + 1)
	for _, b in ipairs(list) do
		if offset >= b.first and offset < b.last then
			return b
		end
	end
	return nil
end

local function attach(buf)
	if vim.b[buf].dockyard_lens then
		refresh(buf)
		return
	end
	vim.b[buf].dockyard_lens = true

	vim.keymap.set("n", "<LeftMouse>", function()
		local b = button_at_mouse(buf)
		if not b then
			return "<LeftMouse>"
		end
		vim.schedule(function()
			M.run_action(buf, b.action, b.service)
		end)
		return ""
	end, { buffer = buf, expr = true, desc = "Dockyard: compose lens click" })

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
			buttons[buf] = nil
			statuses[buf] = nil
		end,
	})

	refresh(buf)
end

local function maybe_attach(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	if name ~= "" and vim.bo[buf].buftype == "" and context.is_compose_file(name) then
		attach(buf)
	end
end

function M.setup()
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufFilePost" }, {
		group = group,
		callback = function(args)
			maybe_attach(args.buf)
		end,
	})
	-- buffers opened before the plugin loaded (lazy loading on the compose file itself)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			maybe_attach(buf)
		end
	end
end

return M
