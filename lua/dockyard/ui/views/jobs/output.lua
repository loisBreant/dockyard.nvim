-- The whole output of a job in a buffer, updated while the job runs.

local M = {}

local runner = require("dockyard.commands.runner")
local resolver = require("dockyard.core.keymaps")

local ns = vim.api.nvim_create_namespace("dockyard.job_output")

---@type table<integer, integer> job id -> buffer
local buffers = {}

local FOOTER = {
	running = { "⟳ running", "DockyardPending" },
	ok = { "✔ ok", "DockyardRunning" },
	failed = { "✖ failed", "DockyardStopped" },
	cancelled = { "⊘ cancelled", "DockyardMuted" },
}

---@param job DockyardJob
---@return string[] lines, table[] spans {line, start_col, end_col, hl_group}
function M.build(job)
	local lines = { "$ " .. runner.format_cmd(job.argv) }
	local spans = { { line = 0, start_col = 0, end_col = #lines[1], hl_group = "DockyardTitle" } }
	if job.cwd then
		table.insert(lines, "# in " .. vim.fn.fnamemodify(job.cwd, ":~"))
		table.insert(spans, { line = 1, start_col = 0, end_col = #lines[2], hl_group = "DockyardMuted" })
	end
	table.insert(lines, "")
	vim.list_extend(lines, runner.output(job))
	table.insert(lines, "")
	local footer = FOOTER[job.status] or FOOTER.failed
	local text = footer[1]
	if job.status == "ok" or job.status == "failed" then
		text = text .. " · exit " .. tostring(job.code)
	end
	text = text .. " · " .. runner.format_duration(runner.duration(job))
	table.insert(lines, text)
	table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #text, hl_group = footer[2] })
	return lines, spans
end

local function render(buf, job)
	-- keep following the output only when the cursor is on the last line
	local following = {}
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		following[win] = vim.api.nvim_win_get_cursor(win)[1] >= vim.api.nvim_buf_line_count(buf)
	end
	local lines, spans = M.build(job)
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
	for win, follow in pairs(following) do
		if follow and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_cursor(win, { #lines, 0 })
		end
	end
end

local function map(buf, action_id, fn)
	for _, key in ipairs(resolver.resolve(action_id) or {}) do
		vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true })
	end
end

local function create(job)
	local buf = vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, buf, "dockyard-job://" .. job.id)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "dockyardjob", { buf = buf })
	render(buf, job)

	local pending = false
	local off = runner.subscribe(function(changed)
		if changed ~= job or pending then
			return
		end
		pending = true
		vim.defer_fn(function()
			pending = false
			if vim.api.nvim_buf_is_valid(buf) then
				render(buf, job)
			end
		end, 50)
	end)
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			off()
			buffers[job.id] = nil
		end,
	})

	map(buf, "ui.close", function()
		pcall(vim.api.nvim_win_close, 0, true)
	end)
	map(buf, "jobs.rerun", function()
		local again = runner.rerun(job.id)
		if again then
			M.open(again.id)
		end
	end)
	map(buf, "jobs.cancel", function()
		runner.cancel(job.id)
	end)
	return buf
end

local function open_window(buf)
	if vim.api.nvim_win_get_config(0).relative ~= "" then
		-- from a floating dashboard: splitting a float is awkward, open another one
		local width = math.floor(vim.o.columns * 0.85)
		local height = math.floor(vim.o.lines * 0.7)
		return vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = width,
			height = height,
			row = math.floor((vim.o.lines - height) / 2),
			col = math.floor((vim.o.columns - width) / 2),
			style = "minimal",
			border = "rounded",
			zindex = 270,
		})
	end
	vim.cmd("botright 18split")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	return win
end

---@param id integer job id
function M.open(id)
	local job = runner.get(id)
	if not job then
		vim.notify("Dockyard: no job " .. tostring(id), vim.log.levels.WARN)
		return
	end
	local buf = buffers[id]
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		buf = create(job)
		buffers[id] = buf
	end
	local win = vim.fn.bufwinid(buf)
	if win ~= -1 then
		vim.api.nvim_set_current_win(win)
	else
		win = open_window(buf)
	end
	vim.api.nvim_set_option_value("wrap", false, { win = win })
	vim.api.nvim_set_option_value("number", false, { win = win })
	vim.api.nvim_set_option_value("signcolumn", "no", { win = win })
	vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
end

return M
