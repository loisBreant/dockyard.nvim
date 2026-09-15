local icons = require("dockyard.ui.icons")
local resolver = require("dockyard.core.keymaps")

local function display_key(action_id, fallback)
	local k = resolver.key(action_id)
	if k == nil then
		return fallback
	end
	if type(k) == "table" then
		-- Show first mapping, join multiples with "/"
		return table.concat(k, "/")
	end
	return tostring(k)
end

local M = {}

---@param container_name string
---@param opts { follow: boolean, raw: boolean, filter: string|nil, sources?: LogSource[], active_source_idx?: number }|nil
---@return string
function M.render(container_name, opts)
	opts = opts or { follow = true, raw = false, filter = nil }

	local follow_hl = opts.follow and "DockyardTabActive" or "DockyardTabInactive"
	local raw_hl = opts.raw and "DockyardTabActive" or "DockyardTabInactive"
	local filter_active = type(opts.filter) == "string" and opts.filter ~= ""
	local filter_hl = filter_active and "DockyardTabActive" or "DockyardTabInactive"

	local sources = opts.sources or {}
	local active_source_idx = opts.active_source_idx or 0

	local parts = {
		"%#DockyardHeader#  " .. icons.icon("docker") .. "  ",
		container_name or "unknown",
		"  %#Normal#",
	}

	if #sources > 1 then
		local all_hl = active_source_idx == 0 and "DockyardTabActive" or "DockyardTabInactive"
		table.insert(parts, string.format("%%#%s# All (1) %%#Normal#", all_hl))
		for i, src in ipairs(sources) do
			local label = src.name or src.path or ((not src.path) and "docker" or ("src " .. i))
			local hl = active_source_idx == i and "DockyardTabActive" or "DockyardTabInactive"
			table.insert(parts, string.format("%%#%s# %s (%d) %%#Normal#", hl, label, i + 1))
		end
	end

	table.insert(parts, "%=")
	local details_key = display_key("loglens.open_detail", "K")
	table.insert(parts, string.format("%%#DockyardTabInactive# %s Details %%#Normal#", details_key))
	table.insert(parts, string.format("%%#%s# %s Raw %%#Normal#", raw_hl, display_key("loglens.toggle_raw", "r")))
	table.insert(parts, string.format("%%#%s# %s Follow %%#Normal#", follow_hl, display_key("loglens.toggle_follow", "f")))
	table.insert(parts, string.format("%%#%s# %s Filter %%#Normal#", filter_hl, display_key("loglens.filter", "/")))
	table.insert(parts, string.format("%%#DockyardTabInactive# %s Close %%#Normal#", display_key("loglens.close", "q")))

	if filter_active then
		table.insert(parts, string.format("%%#DockyardTabActive# %s Clear (" .. tostring(opts.filter) .. ") %%#Normal#", display_key("loglens.clear_filter", "c")))
	end

	return table.concat(parts, " ")
end

return M
