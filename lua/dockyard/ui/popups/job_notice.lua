-- Small floating notice for the job that was just started: the command, the tail of its output and
-- how it ended. A failed job stays until `q`; <CR> opens its whole output.

local M = {}

local runner = require("dockyard.commands.runner")
local statusline = require("dockyard.ui.statusline")

local WIN_WIDTH = 60
local RIGHT_PADDING = 4
local OUTPUT_LINES = 5
local MAX_HEIGHT = 10

local ns = vim.api.nvim_create_namespace("dockyard.job_notice")

---@type { job: DockyardJob, win: integer, buf: integer, off: fun(), spinner: SpinnerInstance, timer: uv.uv_timer_t|nil }|nil
local current

---@param job DockyardJob
---@return string[]
function M.build_lines(job)
	local lines = { " $ " .. runner.format_cmd(job.argv) }
	local tail = {}
	local output = runner.output(job)
	for i = #output, 1, -1 do
		if output[i]:match("%S") then
			table.insert(tail, 1, " " .. output[i])
			if #tail == OUTPUT_LINES then
				break
			end
		end
	end
	vim.list_extend(lines, tail)
	if job.status == "ok" then
		table.insert(lines, (" ✔ Done in %s"):format(runner.format_duration(runner.duration(job))))
	elseif job.status == "failed" then
		table.insert(lines, (" ✖ Failed (exit %s) · <CR> full output · q close"):format(tostring(job.code)))
	elseif job.status == "cancelled" then
		table.insert(lines, " ⊘ Cancelled")
	end
	return lines
end

---@param lines string[]
---@param width integer
---@return integer
local function wrapped_height(lines, width)
	local height = 0
	for _, line in ipairs(lines) do
		height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
	end
	return height
end

function M.close()
	local c = current
	if not c then
		return
	end
	current = nil
	c.off()
	c.spinner:stop()
	if c.timer and not c.timer:is_closing() then
		c.timer:stop()
		c.timer:close()
	end
	if vim.api.nvim_win_is_valid(c.win) then
		pcall(vim.api.nvim_win_close, c.win, true)
	end
end

local function set_title(c, prefix)
	if vim.api.nvim_win_is_valid(c.win) then
		pcall(vim.api.nvim_win_set_config, c.win, { title = " " .. prefix .. " " .. c.job.title .. " ", title_pos = "center" })
	end
end

local function render(c)
	if not vim.api.nvim_buf_is_valid(c.buf) or not vim.api.nvim_win_is_valid(c.win) then
		return M.close()
	end
	local lines = M.build_lines(c.job)
	vim.api.nvim_set_option_value("modifiable", true, { buf = c.buf })
	vim.api.nvim_buf_set_lines(c.buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = c.buf })
	vim.api.nvim_buf_clear_namespace(c.buf, ns, 0, -1)
	vim.api.nvim_buf_set_extmark(c.buf, ns, 0, 0, { end_row = 0, end_col = #lines[1], hl_group = "DockyardMuted" })
	local status = c.job.status
	if status ~= "running" then
		local last = #lines - 1
		local hl = status == "ok" and "DiagnosticOk" or status == "failed" and "DiagnosticError" or "DiagnosticWarn"
		vim.api.nvim_buf_set_extmark(c.buf, ns, last, 0, { end_row = last, end_col = #lines[#lines], hl_group = hl, hl_eol = true })
	end
	local width = vim.api.nvim_win_get_width(c.win)
	pcall(vim.api.nvim_win_set_height, c.win, math.min(MAX_HEIGHT, wrapped_height(lines, width)))
	pcall(vim.api.nvim_win_set_cursor, c.win, { #lines, 0 })
end

local function on_finished(c)
	c.spinner:stop()
	local icons = { ok = "✔", failed = "✖", cancelled = "⊘" }
	set_title(c, icons[c.job.status] or "")
	local delay = require("dockyard.config").options.jobs.notice.close_after
	if c.job.status ~= "failed" and delay > 0 then
		c.timer = vim.defer_fn(function()
			if current == c then
				M.close()
			end
		end, delay)
	end
end

---@param job DockyardJob
function M.show(job)
	M.close()
	local source_win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	local width = math.max(20, math.min(WIN_WIDTH, vim.o.columns - 2))
	local win = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		width = width,
		height = 1,
		row = 1,
		col = math.max(0, vim.o.columns - width - RIGHT_PADDING),
		style = "minimal",
		border = "rounded",
		title = " " .. job.title .. " ",
		title_pos = "center",
		zindex = 260,
		focusable = true,
	})
	vim.api.nvim_set_option_value("wrap", true, { win = win })
	vim.api.nvim_set_option_value("cursorline", false, { win = win })
	statusline.inherit(win, source_win)

	local c = { job = job, win = win, buf = buf }
	current = c
	c.spinner = require("dockyard.ui.components.spinner").create({
		on_tick = function(frame)
			set_title(c, frame)
		end,
	})
	c.spinner:start()

	local finished = false
	local function refresh()
		if current ~= c then
			return
		end
		render(c)
		if job.status ~= "running" and not finished then
			finished = true
			on_finished(c)
		end
	end
	c.off = runner.subscribe(function(changed)
		if changed == job then
			refresh()
		end
	end)

	vim.keymap.set("n", "q", M.close, { buffer = buf, silent = true, nowait = true })
	vim.keymap.set("n", "<CR>", function()
		M.close()
		require("dockyard.ui.views.jobs.output").open(job.id)
	end, { buffer = buf, silent = true, nowait = true })

	refresh()
end

vim.api.nvim_create_autocmd("VimLeavePre", {
	group = vim.api.nvim_create_augroup("DockyardJobNotice", { clear = true }),
	callback = M.close,
})

return M
