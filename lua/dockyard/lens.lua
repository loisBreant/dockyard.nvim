-- Clickable "code lenses": buttons drawn as virtual text at the end of a line.
-- Providers (compose files, Dockerfiles) describe the buttons of each line;
-- this module draws them and turns mouse clicks on them into callbacks.

local M = {}

local ns = vim.api.nvim_create_namespace("dockyard.lens")

local SEP = "  "

---@class DockyardLensButton
---@field first integer display column where the label starts, 0-based from the lens start
---@field last integer display column after the label
---@field data table what the provider's click handler receives

---@type table<integer, table<integer, DockyardLensButton[]>> buf -> 1-based lnum -> buttons
local buttons = {}

---@class DockyardLensLine
---@field chunks table virt_text
---@field buttons DockyardLensButton[]
---@field width integer
local Line = {}
Line.__index = Line

---@return DockyardLensLine
function M.line()
	return setmetatable({ chunks = {}, buttons = {}, width = 0 }, Line)
end

---Append a label; with `data` it becomes a clickable button.
---@param label string
---@param hl string
---@param data table|nil
---@return DockyardLensLine
function Line:add(label, hl, data)
	table.insert(self.chunks, { SEP, "DockyardLensMuted" })
	self.width = self.width + #SEP
	local w = vim.fn.strdisplaywidth(label)
	table.insert(self.chunks, { label, hl })
	if data then
		table.insert(self.buttons, { first = self.width, last = self.width + w, data = data })
	end
	self.width = self.width + w
	return self
end

---Replace every lens of the buffer.
---@param buf integer
---@param lines table<integer, DockyardLensLine> 1-based lnum -> line
function M.render(buf, lines)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	buttons[buf] = {}
	local count = vim.api.nvim_buf_line_count(buf)
	for lnum, line in pairs(lines) do
		if lnum >= 1 and lnum <= count and #line.chunks > 0 then
			buttons[buf][lnum] = line.buttons
			vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
				virt_text = line.chunks,
				virt_text_pos = "eol",
				hl_mode = "combine",
			})
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

---Route clicks on the buffer's buttons to `on_click`; other clicks behave as usual.
---@param buf integer
---@param on_click fun(data: table)
function M.attach(buf, on_click)
	vim.keymap.set("n", "<LeftMouse>", function()
		local b = button_at_mouse(buf)
		if not b then
			return "<LeftMouse>"
		end
		vim.schedule(function()
			on_click(b.data)
		end)
		return ""
	end, { buffer = buf, expr = true, desc = "Dockyard: lens click" })

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			buttons[buf] = nil
		end,
	})
end

return M
