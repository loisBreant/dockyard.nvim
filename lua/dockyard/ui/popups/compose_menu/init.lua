-- Compose options menu: profiles and flags as check boxes, and the command they produce.

local M = {}

local model = require("dockyard.ui.popups.compose_menu.model")
local prefs = require("dockyard.commands.prefs")
local profiles = require("dockyard.commands.profiles")
local compose_run = require("dockyard.commands.compose_run")

local ns = vim.api.nvim_create_namespace("dockyard.compose_menu")
local WIDTH = 78

local ACTIONS = { d = "down", b = "build", p = "pull", s = "stop", r = "restart", u = "up" }

---@param state DockyardComposeMenuState
---@param run_opts { on_exit?: fun(ok: boolean) }
local function open_window(state, run_opts)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "dockyardmenu", { buf = buf })

	local item_lines = {}
	local win

	local function item_line_list()
		local list = vim.tbl_keys(item_lines)
		table.sort(list)
		return list
	end

	local function draw()
		local lines, spans
		lines, item_lines, spans = model.render(state)
		vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		for _, span in ipairs(spans) do
			vim.api.nvim_buf_set_extmark(buf, ns, span.line, span.start_col, {
				end_row = span.line,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_set_height, win, #lines)
		end
	end

	local width = math.min(WIDTH, vim.o.columns - 4)
	win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = 10,
		row = 2,
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " Compose options ",
		title_pos = "center",
		zindex = 280,
	})
	vim.api.nvim_set_option_value("cursorline", true, { win = win })
	vim.api.nvim_set_option_value("winhighlight", "CursorLine:DockyardCursorLine", { win = win })
	draw()

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end

	local function move(step)
		local list = item_line_list()
		local row = vim.api.nvim_win_get_cursor(win)[1]
		local target
		if step > 0 then
			for _, l in ipairs(list) do
				if l > row then
					target = l
					break
				end
			end
		else
			for i = #list, 1, -1 do
				if list[i] < row then
					target = list[i]
					break
				end
			end
		end
		if target then
			vim.api.nvim_win_set_cursor(win, { target, 0 })
		end
	end

	local function toggle()
		local row = vim.api.nvim_win_get_cursor(win)[1]
		local id = item_lines[row]
		if not id then
			return
		end
		if model.toggle(state, id) then
			prefs.set(state.file, state.prefs)
		end
		draw()
		pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
	end

	local function run(action)
		local opts = model.opts(state)
		local function go()
			close()
			compose_run.run(state.file, action, {
				volumes = state.once.volumes,
				rmi = state.once.rmi,
				renew_anon_volumes = state.once.renew_anon_volumes,
			}, run_opts)
		end
		if action == "down" and (opts.volumes or opts.rmi) then
			local what = opts.volumes and "the volumes" or "the images"
			vim.ui.select({ "No", "Yes" }, {
				prompt = ("Remove %s of %s?"):format(what, vim.fn.fnamemodify(state.project.dir, ":~")),
			}, function(choice)
				if choice == "Yes" then
					go()
				end
			end)
		else
			go()
		end
	end

	local function map(keys, fn)
		for _, key in ipairs(type(keys) == "table" and keys or { keys }) do
			vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true })
		end
	end
	map({ "j", "<Down>" }, function()
		move(1)
	end)
	map({ "k", "<Up>" }, function()
		move(-1)
	end)
	map({ "<Space>", "x" }, toggle)
	map({ "q", "<Esc>" }, close)
	map("<CR>", function()
		run(state.action)
	end)
	for key, action in pairs(ACTIONS) do
		map(key, function()
			run(action)
		end)
	end

	local first = item_line_list()[1]
	if first then
		vim.api.nvim_win_set_cursor(win, { first, 0 })
	end
end

---@param file string compose file
---@param opts? { action?: string, on_exit?: fun(ok: boolean) }
function M.open(file, opts)
	opts = opts or {}
	require("dockyard.ui.highlights").setup()
	profiles.detect(file, function(available, source, err)
		if source == "scan" and err and err ~= "" then
			vim.notify("Dockyard: could not ask docker for the profiles, read them from the file instead:\n" .. err, vim.log.levels.INFO)
		end
		open_window(model.new(file, available, prefs.get(file), opts.action), { on_exit = opts.on_exit })
	end)
end

return M
