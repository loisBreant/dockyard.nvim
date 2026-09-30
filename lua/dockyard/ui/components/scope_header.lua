-- The `Project:` and `Filter:` lines above the table of a view, and the filter's match test.

local M = {}

---Case-insensitive substring match of `needle` in any of `fields` (literal text, not a pattern).
---@param fields string[]
---@param needle string|nil
---@return boolean
function M.matches(fields, needle)
	if not needle or needle == "" then
		return true
	end
	needle = needle:lower()
	for _, field in ipairs(fields) do
		if tostring(field):lower():find(needle, 1, true) then
			return true
		end
	end
	return false
end

---First key bound to `action`, for the hints.
---@param action string
---@param fallback string
---@return string
function M.key_label(action, fallback)
	local key = require("dockyard.core.keymaps").key(action) or fallback
	return type(key) == "table" and (key[1] or fallback) or key
end

---@class DockyardScopeHeaderOpts
---@field scope_on boolean
---@field root string
---@field scoped integer rows the scope lets through
---@field total integer rows before the scope
---@field filter string|nil
---@field shown integer rows left after the filter
---@field scope_key string
---@field clear_key string

---@param opts DockyardScopeHeaderOpts
---@return { lines: string[], highlights: table[] }
function M.block(opts)
	local lines, highlights = {}, {}
	local function add(text)
		table.insert(lines, text)
		table.insert(highlights, { line = #lines - 1, start_col = 0, end_col = #text, hl_group = "DockyardMuted" })
	end
	local has_filter = opts.filter ~= nil and opts.filter ~= ""

	if opts.scope_on then
		add((" Project: %s  (%d/%d)  [press %s to show all]"):format(vim.fn.fnamemodify(opts.root, ":~"), opts.scoped, opts.total, opts.scope_key))
		if not has_filter then
			table.insert(lines, "")
		end
	end
	if has_filter then
		add((" Filter: %s  (%d/%d)  [press %s to clear]"):format(opts.filter, opts.shown, opts.scoped, opts.clear_key))
		table.insert(lines, "")
	end
	return { lines = lines, highlights = highlights }
end

return M
