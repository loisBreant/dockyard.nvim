local core = require("dockyard.files.core")
local icons = require("dockyard.ui.icons")
local table_view = require("dockyard.ui.components.table")
local ui_utils = require("dockyard.ui.utils")

local M = {}

---@class DockyardBrowserState
---@field buf integer|nil
---@field container string
---@field path string
---@field entries DockyardFileEntry[]|nil
---@field show_hidden boolean
---@field origin_buf integer|nil
---@field line_map table<integer, table>|nil

---@type DockyardBrowserState
local state = {
	buf = nil,
	container = "",
	path = "/",
	entries = nil,
	show_hidden = false,
	origin_buf = nil,
	line_map = nil,
}

local function notify(msg, level)
	vim.notify("[dockyard] " .. msg, level or vim.log.levels.INFO)
end

local function format_size(n)
	n = tonumber(n) or 0
	local units = { "B", "K", "M", "G", "T" }
	local i = 1
	while n >= 1024 and i < #units do
		n = n / 1024
		i = i + 1
	end
	return ("%6.1f%s"):format(n, units[i])
end

local function row_hl(row, col)
	if col.key == "name" then
		if row.type == "directory" then
			return "DockyardName"
		end
		if row.type == "link" then
			return "DockyardImage"
		end
	elseif col.key == "size" or col.key == "mtime" then
		return "DockyardMuted"
	end
end

local function build_rows()
	local rows = {}
	if state.path ~= "/" then
		table.insert(rows, {
			icon = icons.icon("directory"),
			name = "..",
			size = "",
			mtime = "",
			type = "directory",
			_item = { name = "..", type = "directory", _parent = true },
		})
	end
	for _, e in ipairs(state.entries or {}) do
		if state.show_hidden or e.name:sub(1, 1) ~= "." then
			local marker = e.type == "directory" and "/" or ""
			local name = e.name .. marker
			if e.target then
				name = name .. " -> " .. e.target
			end
			table.insert(rows, {
				icon = icons.icon(e.type),
				name = name,
				size = e.type == "directory" and "" or format_size(e.size),
				mtime = e.mtime or "",
				type = e.type,
				_item = e,
			})
		end
	end
	return rows
end

local function render()
	if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
		return
	end

	local width = vim.api.nvim_win_get_width(0)
	local header_lines = { ("# %s : %s   (g? help)"):format(state.container, state.path), "" }

	local body_lines, line_map, body_spans = table_view.render({
		width = width,
		margin = 1,
		columns = {
			{ key = "icon", name = "", width = 2 },
			{ key = "name", name = "Name", min_width = 30 },
			{ key = "size", name = "Size", width = 8 },
			{ key = "mtime", name = "Modified", min_width = 16, grow_last = true },
		},
		rows = build_rows(),
		cell_hl = row_hl,
	})

	for _, sp in ipairs(body_spans) do
		sp.line = sp.line + #header_lines
	end
	table.insert(body_spans, 1, { line = 0, start_col = 0, end_col = #header_lines[1], hl_group = "DockyardMuted" })

	local lines = {}
	for _, l in ipairs(header_lines) do
		table.insert(lines, l)
	end
	for _, l in ipairs(body_lines) do
		table.insert(lines, l)
	end

	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.bo[state.buf].modifiable = false
	vim.bo[state.buf].modified = false

	ui_utils.apply_spans(state.buf, body_spans)

	local shifted = {}
	for lnum, row in pairs(line_map) do
		shifted[lnum + #header_lines] = row
	end
	state.line_map = shifted
end

local function current_entry()
	if not state.line_map then
		return nil
	end
	local row = vim.api.nvim_win_get_cursor(0)[1]
	return state.line_map[row]
end

function M.refresh()
	core.list(state.container, state.path, function(res)
		if not res.ok then
			notify(res.error or "list failed", vim.log.levels.ERROR)
			state.entries = {}
		else
			state.entries = res.entries
		end
		render()
	end)
end

local function navigate(new_path)
	state.path = core.normalize(new_path)
	M.refresh()
end

local function abs_path_of(name)
	if state.path == "/" then
		return "/" .. name
	end
	return state.path .. "/" .. name
end

local function go_up()
	if state.path == "/" then
		return
	end
	navigate(core.dirname(state.path))
end

local function activate()
	local entry = current_entry()
	if not entry then
		return
	end
	if entry._parent then
		return go_up()
	end
	local target = abs_path_of(entry.name)
	if entry.type == "directory" then
		navigate(target)
		return
	end
	if entry.kind ~= "f" and entry.kind ~= "l" then
		notify("Not a regular file: " .. entry.name, vim.log.levels.WARN)
		return
	end
	M.open_file(state.container, target)
end

---@return string
function M.uri(container, path)
	return ("dockyard://%s%s"):format(container, core.normalize(path))
end

function M.open_file(container, path)
	vim.cmd("vsplit " .. vim.fn.fnameescape(M.uri(container, path)))
end

local function toggle_hidden()
	state.show_hidden = not state.show_hidden
	render()
end

local function yank_path()
	local entry = current_entry()
	if not entry then
		return
	end
	local p = entry._parent and core.dirname(state.path) or abs_path_of(entry.name)
	vim.fn.setreg("+", p)
	vim.fn.setreg('"', p)
	notify("Yanked " .. p)
end

local function confirm(prompt, cb)
	vim.ui.input({ prompt = prompt .. " [y/N]: " }, function(input)
		local answer = input and vim.trim(input):lower() or ""
		cb(answer == "y" or answer == "yes")
	end)
end

local function delete()
	local entry = current_entry()
	if not entry or entry._parent then
		return
	end
	local target = abs_path_of(entry.name)
	local kind = entry.type == "directory" and "directory" or "file"
	confirm(("Delete %s %s ?"):format(kind, target), function(ok)
		if not ok then
			return
		end
		core.rm(state.container, target, function(res)
			if not res.ok then
				return notify(res.error or "rm failed", vim.log.levels.ERROR)
			end
			notify("Deleted " .. target)
			M.refresh()
		end)
	end)
end

local function rename()
	local entry = current_entry()
	if not entry or entry._parent then
		return
	end
	vim.ui.input({ prompt = "Rename to: ", default = entry.name }, function(new_name)
		if not new_name or new_name == "" or new_name == entry.name then
			return
		end
		core.mv(state.container, abs_path_of(entry.name), abs_path_of(new_name), function(res)
			if not res.ok then
				return notify(res.error or "mv failed", vim.log.levels.ERROR)
			end
			notify(("Renamed %s -> %s"):format(entry.name, new_name))
			M.refresh()
		end)
	end)
end

local function create()
	vim.ui.input({ prompt = "Create (suffix / for dir): " }, function(name)
		if not name or name == "" then
			return
		end
		local is_dir = name:sub(-1) == "/"
		local clean = is_dir and name:sub(1, -2) or name
		local target = abs_path_of(clean)
		local fn = is_dir and core.mkdir or function(c, p, cb)
			core.write(c, p, {}, cb)
		end
		fn(state.container, target, function(res)
			if not res.ok then
				return notify(res.error or "create failed", vim.log.levels.ERROR)
			end
			notify("Created " .. target)
			M.refresh()
		end)
	end)
end

local function search()
	vim.ui.input({ prompt = "Find files named (glob or text): " }, function(pattern)
		if not pattern or pattern == "" then
			return
		end
		core.find(state.container, state.path, pattern, function(res)
			if not res.ok then
				notify(res.error or "find failed", vim.log.levels.ERROR)
				return
			end
			if #(res.paths or {}) == 0 then
				notify("No file matching " .. pattern .. " under " .. state.path, vim.log.levels.WARN)
				return
			end
			local qf = {}
			for _, p in ipairs(res.paths) do
				table.insert(qf, { filename = M.uri(state.container, p), lnum = 1, text = p })
			end
			vim.fn.setqflist({}, " ", { title = "dockyard find " .. pattern, items = qf })
			vim.cmd("botright copen")
		end)
	end)
end

local function grep()
	vim.ui.input({ prompt = "Search file contents for: " }, function(pattern)
		if not pattern or pattern == "" then
			return
		end
		core.grep(state.container, state.path, pattern, function(res)
			if not res.ok then
				notify(res.error or "grep failed", vim.log.levels.ERROR)
				return
			end
			if #(res.hits or {}) == 0 then
				notify("No match for " .. pattern .. " under " .. state.path, vim.log.levels.WARN)
				return
			end
			local qf = {}
			for _, hit in ipairs(res.hits) do
				table.insert(qf, { filename = M.uri(state.container, hit.path), lnum = hit.lnum, text = hit.text })
			end
			vim.fn.setqflist({}, " ", { title = "dockyard grep " .. pattern, items = qf })
			vim.cmd("botright copen")
		end)
	end)
end

-- copy / cut buffer, shared across directories (and containers: paste checks)
---@type { container: string, path: string, name: string, move: boolean }|nil
local clipboard = nil

local function mark(move)
	local entry = current_entry()
	if not entry or entry._parent then
		return
	end
	clipboard = { container = state.container, path = abs_path_of(entry.name), name = entry.name, move = move }
	notify(("%s %s — press p in the target directory"):format(move and "Cut" or "Copied", clipboard.path))
end

local function paste()
	if not clipboard then
		return notify("Nothing to paste: mark an entry with c (copy) or x (cut) first", vim.log.levels.WARN)
	end
	if clipboard.container ~= state.container then
		return notify("Can only paste inside the container it was copied from", vim.log.levels.WARN)
	end
	local src, move = clipboard.path, clipboard.move
	local dst = abs_path_of(clipboard.name)
	if dst == src then
		if move then
			return notify("Source and destination are the same", vim.log.levels.WARN)
		end
		-- copying next to itself: pick a free name
		dst = dst .. ".copy"
	end
	local fn = move and core.mv or core.cp
	fn(state.container, src, dst, function(res)
		if not res.ok then
			return notify(res.error or "paste failed", vim.log.levels.ERROR)
		end
		notify(("%s %s -> %s"):format(move and "Moved" or "Copied", src, dst))
		if move then
			clipboard = nil
		end
		M.refresh()
	end)
end

local function download()
	local entry = current_entry()
	if not entry or entry._parent then
		return
	end
	local src = abs_path_of(entry.name)
	local default = vim.fn.getcwd() .. "/" .. entry.name
	vim.ui.input({ prompt = "Download to (host): ", default = default, completion = "file" }, function(dst)
		if not dst or dst == "" then
			return
		end
		dst = vim.fn.expand(dst)
		core.download(state.container, src, dst, function(res)
			if not res.ok then
				return notify(res.error or "download failed", vim.log.levels.ERROR)
			end
			notify(("Downloaded %s -> %s"):format(src, dst))
		end)
	end)
end

local function upload()
	vim.ui.input({ prompt = "Upload from (host): ", default = vim.fn.getcwd() .. "/", completion = "file" }, function(src)
		if not src or src == "" then
			return
		end
		src = vim.fn.expand(src):gsub("/+$", "")
		if not vim.uv.fs_stat(src) then
			return notify("No such host path: " .. src, vim.log.levels.ERROR)
		end
		local dst = abs_path_of(vim.fn.fnamemodify(src, ":t"))
		core.upload(state.container, src, dst, function(res)
			if not res.ok then
				return notify(res.error or "upload failed", vim.log.levels.ERROR)
			end
			notify(("Uploaded %s -> %s"):format(src, dst))
			M.refresh()
		end)
	end)
end

local function close()
	local win = vim.api.nvim_get_current_win()
	if state.origin_buf and vim.api.nvim_buf_is_valid(state.origin_buf) then
		vim.api.nvim_win_set_buf(win, state.origin_buf)
	end
	local buf = state.buf
	state.buf = nil
	state.line_map = nil
	state.entries = nil
	state.origin_buf = nil
	if buf then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
end

local keymaps = {
	{ { "<CR>", "l" }, function()
		activate()
	end, "Open file / enter directory" },
	{ { "-", "h" }, function()
		go_up()
	end, "Parent directory" },
	{ "R", function()
		M.refresh()
	end, "Refresh" },
	{ "gh", toggle_hidden, "Toggle hidden files" },
	{ "s", search, "Find files by name (quickfix)" },
	{ "S", grep, "Search file contents (quickfix)" },
	{ "y", yank_path, "Yank path" },
	{ "a", create, "Create file (end with / for a directory)" },
	{ "r", rename, "Rename" },
	{ "d", delete, "Delete" },
	{ "c", function()
		mark(false)
	end, "Copy (then p to paste)" },
	{ "x", function()
		mark(true)
	end, "Cut (then p to paste)" },
	{ "p", paste, "Paste into this directory" },
	{ "D", download, "Download to host" },
	{ "U", upload, "Upload from host" },
	{ "q", close, "Close" },
}

local function show_help()
	local lines = {}
	for _, km in ipairs(keymaps) do
		local keys = type(km[1]) == "table" and table.concat(km[1], " ") or km[1]
		table.insert(lines, ("  %-10s %s"):format(keys, km[3]))
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	local width = 0
	for _, l in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
	end
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = #lines,
		row = math.floor((vim.o.lines - #lines) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " Dockyard files ",
		title_pos = "center",
	})
	for _, key in ipairs({ "q", "<Esc>", "g?" }) do
		vim.keymap.set("n", key, function()
			pcall(vim.api.nvim_win_close, win, true)
		end, { buffer = buf, nowait = true, silent = true })
	end
end

local function attach_keymaps(buf)
	local opts = { buffer = buf, silent = true, nowait = true }
	for _, km in ipairs(keymaps) do
		for _, key in ipairs(type(km[1]) == "table" and km[1] or { km[1] }) do
			vim.keymap.set("n", key, km[2], vim.tbl_extend("force", opts, { desc = km[3] }))
		end
	end
	vim.keymap.set("n", "g?", show_help, vim.tbl_extend("force", opts, { desc = "Help" }))
end

---@param container string
---@param path string
---@param opts? { win?: integer }
function M.open(container, path, opts)
	opts = opts or {}
	path = core.normalize(path)

	local name = ("dockyard://%s"):format(container)
	-- exact lookup: bufnr() would also match dockyard://<container>/some/file
	local buf = -1
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(b) == name then
			buf = b
			break
		end
	end
	if buf == -1 then
		buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, name)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].swapfile = false
		vim.bo[buf].filetype = "dockyard-files"
		attach_keymaps(buf)
	end

	state.buf = buf
	state.container = container
	state.path = path

	local target_win = opts.win or vim.api.nvim_get_current_win()
	local cur_buf = vim.api.nvim_win_get_buf(target_win)
	if cur_buf ~= buf then
		if vim.api.nvim_buf_is_valid(cur_buf) then
			state.origin_buf = cur_buf
		end
		vim.api.nvim_win_set_buf(target_win, buf)
	end

	vim.api.nvim_set_option_value("number", false, { win = target_win })
	vim.api.nvim_set_option_value("relativenumber", false, { win = target_win })
	vim.api.nvim_set_option_value("signcolumn", "no", { win = target_win })
	vim.api.nvim_set_option_value("statuscolumn", "", { win = target_win })
	vim.api.nvim_set_option_value("foldcolumn", "0", { win = target_win })
	vim.api.nvim_set_option_value("wrap", false, { win = target_win })
	vim.api.nvim_set_option_value("cursorline", false, { win = target_win })
	vim.b[buf].snacks_indent = false
	vim.b[buf].snacks_scope = false
	vim.b[buf].miniindentscope_disable = true

	M.refresh()
	return buf
end

return M
