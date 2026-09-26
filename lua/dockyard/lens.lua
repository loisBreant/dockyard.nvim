-- Clickable buttons drawn as virtual text at the end of lines.

local M = {}

local ns = vim.api.nvim_create_namespace("dockyard.lens")
local SEP = "  "

---@class DockyardLensButton
---@field first integer start column, relative to the lens
---@field last integer end column (exclusive)
---@field data table passed to the click handler

---@type table<integer, table<integer, DockyardLensButton[]>> buf -> lnum -> buttons
local buttons = {}

---@class DockyardLensLine
---@field chunks table
---@field buttons DockyardLensButton[]
---@field width integer
local Line = {}
Line.__index = Line

---@return DockyardLensLine
function M.line()
	return setmetatable({ chunks = {}, buttons = {}, width = 0 }, Line)
end

---A label, clickable when `data` is given.
---@return DockyardLensLine
function Line:add(label, hl, data)
	table.insert(self.chunks, { SEP, "DockyardLensMuted" })
	table.insert(self.chunks, { label, hl })
	self.width = self.width + #SEP
	local width = vim.fn.strdisplaywidth(label)
	if data then
		table.insert(self.buttons, { first = self.width, last = self.width + width, data = data })
	end
	self.width = self.width + width
	return self
end

---@param lines table<integer, DockyardLensLine> lnum -> line
function M.render(buf, lines)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	buttons[buf] = {}
	local count = vim.api.nvim_buf_line_count(buf)
	for lnum, line in pairs(lines) do
		if lnum <= count and #line.chunks > 0 then
			buttons[buf][lnum] = line.buttons
			vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
				virt_text = line.chunks,
				virt_text_pos = "eol",
				hl_mode = "combine",
			})
		end
	end
end

local function button_under_mouse(buf)
	local pos = vim.fn.getmousepos()
	if pos.winid == 0 or vim.api.nvim_win_get_buf(pos.winid) ~= buf then
		return nil
	end
	local list = buttons[buf] and buttons[buf][pos.line]
	if not list then
		return nil
	end
	local textoff = vim.fn.getwininfo(pos.winid)[1].textoff
	local leftcol = vim.api.nvim_win_call(pos.winid, function()
		return vim.fn.winsaveview().leftcol
	end)
	local text = vim.api.nvim_buf_get_lines(buf, pos.line - 1, pos.line, false)[1] or ""
	-- eol virtual text starts one cell after the text
	local col = pos.wincol - textoff + leftcol - 2 - vim.fn.strdisplaywidth(text)
	for _, b in ipairs(list) do
		if col >= b.first and col < b.last then
			return b
		end
	end
end

---Send clicks on the buffer's buttons to `on_click`; other clicks work as usual.
---@param on_click fun(data: table)
function M.attach(buf, on_click)
	require("dockyard.ui.highlights").setup()
	vim.keymap.set("n", "<LeftMouse>", function()
		local b = button_under_mouse(buf)
		if not b then
			return "<LeftMouse>"
		end
		vim.schedule(function()
			on_click(b.data)
		end)
		return ""
	end, { buffer = buf, expr = true })

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			buttons[buf] = nil
		end,
	})
end

return M
