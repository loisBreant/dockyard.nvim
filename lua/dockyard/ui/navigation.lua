local M = {}

local ui_state = require("dockyard.ui.state")

---@return integer[]
local function sorted_row_lines()
	---@type integer[]
	local lines = {}
	for lnum, _ in pairs(ui_state.line_map or {}) do
		if type(lnum) == "number" then
			table.insert(lines, lnum)
		end
	end
	table.sort(lines)
	return lines
end

---@param lines integer[]
---@param current_line integer
---@return integer?
local function nearest_row_index(lines, current_line)
	if #lines == 0 then
		return nil
	end

	for i, l in ipairs(lines) do
		if l == current_line then
			return i
		end

		if current_line < lines[1] then
			return 1
		end

		if current_line > lines[#lines] then
			return #lines
		end

		for j = 1, #lines - 1 do
			local a = lines[j]
			local b = lines[j + 1]
			if current_line > a and current_line < b then
				if (current_line - a) <= (b - current_line) then
					return j
				end
				return j + 1
			end
		end
	end

	return #lines
end

---@param step integer
local function move(step)
	local lines = sorted_row_lines()
	if #lines == 0 then
		return
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	local idx = nearest_row_index(lines, cursor[1])
	if idx == nil then
		return
	end

	local target_idx = idx + step
	if target_idx < 1 then
		target_idx = 1
	elseif target_idx > #lines then
		target_idx = #lines
	end

	vim.api.nvim_win_set_cursor(0, { lines[target_idx], 0 })
end

function M.down()
	move(1)
end

function M.up()
	move(-1)
end

function M.first()
	local lines = sorted_row_lines()
	if #lines == 0 then
		return
	end
	local count = vim.v.count
	if count ~= 0 then
		local idx = math.min(count, #lines)
		-- v:count is 1-based row index when used with gg (e.g. 3gg -> 3rd row)
		idx = math.max(1, idx)
		vim.api.nvim_win_set_cursor(0, { lines[idx], 0 })
	else
		vim.api.nvim_win_set_cursor(0, { lines[1], 0 })
	end
end

function M.last()
	local lines = sorted_row_lines()
	if #lines == 0 then
		return
	end
	local count = vim.v.count
	if count ~= 0 then
		local idx = math.min(count, #lines)
		idx = math.max(1, idx)
		vim.api.nvim_win_set_cursor(0, { lines[idx], 0 })
	else
		vim.api.nvim_win_set_cursor(0, { lines[#lines], 0 })
	end
end

-- Keep the cursor on the same item across re-renders.

local function node_key(node)
	if type(node) ~= "table" then
		return nil
	end
	local item = node.item or node
	return tostring(node.kind) .. ":" .. tostring(item.id or item.name)
end

local function dashboard_win()
	local win = ui_state.win_id
	return win and vim.api.nvim_win_is_valid(win) and win or nil
end

---True when the last keep_selection() put the cursor back on its item.
M.restored = false

---@param draw fun()
function M.keep_selection(draw)
	local win = dashboard_win()
	local key = win and node_key(ui_state.line_map[vim.api.nvim_win_get_cursor(win)[1]])
	draw()
	M.restored = false
	win = dashboard_win()
	if not (win and key) then
		return
	end
	for lnum, node in pairs(ui_state.line_map or {}) do
		if node_key(node) == key then
			vim.api.nvim_win_set_cursor(win, { lnum, 0 })
			M.restored = true
			return
		end
	end
end

return M
