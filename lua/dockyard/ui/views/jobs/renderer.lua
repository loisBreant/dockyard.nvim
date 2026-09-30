local navigation = require("dockyard.ui.navigation")
local M = {}

local runner = require("dockyard.commands.runner")
local ui_state = require("dockyard.ui.state")
local config = require("dockyard.config")
local table_view = require("dockyard.ui.components.table")
local header = require("dockyard.ui.components.header")
local navbar = require("dockyard.ui.components.navbar")
local statusline = require("dockyard.ui.statusline")
local ui_utils = require("dockyard.ui.utils")
local scope = require("dockyard.scope")
local scope_header = require("dockyard.ui.components.scope_header")
local view_state = require("dockyard.ui.views.jobs.state")

local STATUS = {
	running = { icon = "⟳", hl = "DockyardPending" },
	ok = { icon = "✔", hl = "DockyardRunning" },
	failed = { icon = "✖", hl = "DockyardStopped" },
	cancelled = { icon = "⊘", hl = "DockyardMuted" },
}

local function current_width()
	if ui_state.win_id ~= nil and vim.api.nvim_win_is_valid(ui_state.win_id) then
		return vim.api.nvim_win_get_width(ui_state.win_id)
	end
	return vim.o.columns
end

---@param jobs DockyardJob[]
---@return table[] rows
function M.build_rows(jobs)
	local rows = {}
	for _, job in ipairs(jobs) do
		local status = STATUS[job.status] or STATUS.failed
		table.insert(rows, {
			status = status.icon .. " " .. job.status,
			started = os.date("%H:%M:%S", job.started_time),
			duration = runner.format_duration(runner.duration(job)),
			title = job.title,
			dir = job.cwd and vim.fn.fnamemodify(job.cwd, ":~") or "-",
			_hl = status.hl,
			_item = { kind = "job", item = job },
		})
	end
	return rows
end

local function cell_hl(row, col)
	if col.key == "status" then
		return row._hl
	elseif col.key == "title" then
		return "DockyardName"
	end
	return "DockyardMuted"
end

---The jobs to show: the ones run inside the project (when the scope is on), then the ones matching the filter.
---@param jobs DockyardJob[]
---@param filter string|nil
---@return DockyardJob[] shown, DockyardJob[] scoped
function M.select(jobs, filter)
	local scoped = scope.apply_jobs(jobs)
	local shown = vim.tbl_filter(function(job)
		return scope_header.matches({ job.title or "", job.status or "", job.cwd or "", runner.format_cmd(job.argv or {}) }, filter)
	end, scoped)
	return shown, scoped
end

---@param jobs DockyardJob[]
local function set_statusline_items(jobs)
	local running = #vim.tbl_filter(function(job)
		return job.status == "running"
	end, jobs)
	local items = { { text = ("%d jobs"):format(#jobs), hl_group = "DockyardFooterAccent" } }
	if running > 0 then
		table.insert(items, { text = ("⟳ %d running"):format(running), hl_group = "DockyardFooterPending" })
	end
	statusline.set_items(items)
end

---@param width number
---@param jobs DockyardJob[]
local function build_body(width, jobs)
	local lines, line_map, spans = table_view.render({
		width = width,
		margin = 1,
		columns = {
			{ key = "status", name = "Status", min_width = 12 },
			{ key = "started", name = "Started", min_width = 8 },
			{ key = "duration", name = "Duration", min_width = 8 },
			{ key = "title", name = "Command", min_width = 30 },
			{ key = "dir", name = "Directory", min_width = 20 },
		},
		rows = M.build_rows(jobs),
		cell_hl = cell_hl,
	})
	if #jobs == 0 then
		local hint = " No jobs yet. Commands started from Dockyard show up here."
		table.insert(lines, hint)
		table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #hint, hl_group = "DockyardMuted" })
	end
	return lines, line_map, spans
end

local function draw()
	local buf = ui_state.buf_id
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local lines = {}
	local spans = {}
	local width = current_width()
	local all_jobs = runner.list()
	local jobs, scoped = M.select(all_jobs, view_state.filter)

	ui_utils.append_block(lines, spans, header.render(ui_state.mode, width))
	ui_utils.append_block(
		lines,
		spans,
		navbar.render({
			width = width,
			current_view = ui_state.current_view,
			views = config.options.display.views,
		})
	)
	table.insert(lines, "")

	ui_utils.append_block(
		lines,
		spans,
		scope_header.block({
			scope_on = scope.enabled(),
			root = scope.root(),
			scoped = #scoped,
			total = #all_jobs,
			filter = view_state.filter,
			shown = #jobs,
			scope_key = scope_header.key_label("jobs.toggle_project_scope", "P"),
			clear_key = scope_header.key_label("jobs.clear_filter", "C"),
		})
	)

	local body_lines, body_line_map, body_spans = build_body(width, jobs)
	local body_start = ui_utils.append_body(lines, spans, body_lines, body_spans)
	ui_state.line_map = {}
	for lnum, item in pairs(body_line_map or {}) do
		ui_state.line_map[body_start + lnum] = item
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	ui_utils.apply_spans(buf, spans)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	set_statusline_items(jobs)
end

function M.render()
	navigation.keep_selection(draw)
end

return M
