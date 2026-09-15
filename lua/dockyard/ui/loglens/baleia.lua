local M = {}

local instance = nil

local function get_instance()
	if instance then
		return instance
	end
	local ok, mod = pcall(require, "baleia")
	if not ok or type(mod) ~= "table" then
		return nil
	end
	-- mod.setup returns the baleia object with :once / :automatically
	-- If user already did `vim.g.baleia = require("baleia").setup(...)` reuse it
	if vim.g.baleia and type(vim.g.baleia) == "table" and vim.g.baleia.once then
		instance = vim.g.baleia
		return instance
	end
	local ok2, inst = pcall(mod.setup, {})
	if ok2 and inst and type(inst) == "table" and inst.once then
		instance = inst
		return instance
	end
	return nil
end

--- Strip ANSI escape sequences from a buffer (fallback when baleia is absent).
--- Matches ESC[<numbers>;<numbers>m, literal "\27" as shown by vim.inspect,
--- and the caret notation ^[ used by nvim's display. Also strips \r.
local function strip_ansi_fallback(buf)
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local changed = false
	for i, l in ipairs(lines) do
		-- ESC is \27 (0x1b), nvim shows it as ^[ in display but buffer contains \27
		-- vim.inspect shows it as the 4-char sequence "\27" (backslash, 2, 7)
		-- Also handle the literal "^[" two-char sequence that may appear in some logs
		local stripped = l:gsub("\27%[[%d;:]*m", ""):gsub("\\27%[[%d;:]*m", ""):gsub("%^%[[%d;:]*m", ""):gsub("\27", ""):gsub("\\27", ""):gsub("\r", "")
		-- Also handle the literal "\r" as shown by vim.inspect
		stripped = stripped:gsub("\\r", "")
		if stripped ~= l then
			lines[i] = stripped
			changed = true
		end
	end
	if changed then
		vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	end
end

--- Colorize ANSI escape sequences in a buffer if baleia is available.
--- Falls back to stripping codes when baleia is not installed so logs
--- never show raw `^[[0;32m` sequences. Always strips the `vim.inspect`
--- form `\\27` and `\r` which baleia does not handle.
--- @param buf number Buffer id
function M.colorize(buf)
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local b = get_instance()
	if b and type(b.once) == "function" then
		-- baleia.once is async when setup async=true (default). pcall to avoid errors
		-- if buffer is wiped during render.
		pcall(b.once, b, buf)
	end
	-- Always run fallback to handle `vim.inspect`'s `\\27`/`\\r` form and
	-- to guarantee stripping when baleia is absent. Safe to run after baleia.
	strip_ansi_fallback(buf)
end

return M
