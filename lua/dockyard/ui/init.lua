local M = {}
local state = require("dockyard.ui.state")
local statusline = require("dockyard.ui.statusline")
local keymaps = require("dockyard.ui.keymaps")
local ui_utils = require("dockyard.ui.utils")
local config = require("dockyard.config")
local containers_view = require("dockyard.ui.views.containers.init")
local view_modules = {
	containers = containers_view,
	compose = containers_view,
	images = require("dockyard.ui.views.images.init"),
	networks = require("dockyard.ui.views.networks.init"),
	volumes = require("dockyard.ui.views.volumes.init"),
}

local win_config_by_mode = ui_utils.win_config_by_mode

---@param on_done fun()|nil
---@param opts { force_update?: boolean }|nil
local function update_active_view(on_done, opts)
	local module = view_modules[state.current_view]
	if module and type(module.update) == "function" then
		module.update(on_done, opts)
	elseif on_done then
		on_done()
	end
end

local function teardown_active_view()
	if state.buf_id == nil then
		return
	end
	local module = view_modules[state.current_view]
	if module and type(module.teardown) == "function" then
		module.teardown(state.buf_id)
	end
end

local function setup_active_view()
	if state.buf_id == nil then
		return
	end
	local module = view_modules[state.current_view]
	if module and type(module.setup) == "function" then
		module.setup(state.buf_id, function(msg, level)
			if level == "error" then
				vim.notify(msg, vim.log.levels.ERROR)
			end

			if M.is_open() then
				statusline.notify(level or "info", msg)
			end
		end)
	end
end

local function open_with(mode, win_config_fn, mods)
	local views = config.options.display.views or { "containers", "images", "networks", "volumes" }
	if #views > 0 and not vim.tbl_contains(views, state.current_view) then
		state.current_view = views[1]
	end

	state.prev_win = vim.api.nvim_get_current_win()
	state.mode = mode
	statusline.reset()

	if state.buf_id == nil or not vim.api.nvim_buf_is_valid(state.buf_id) then
		state.buf_id = ui_utils.create_buf()
	end

	-- normalize mods prefix for split/vsplit
	local mods_prefix = ""
	if mods and mods ~= "" then
		mods_prefix = vim.trim(mods)
	end

	if mode == "full" or mode == "tab" then
		-- Honor :tab modifier: always open a new tab.
		vim.cmd("tabnew")
		state.tab_id = vim.api.nvim_get_current_tabpage()
		state.win_id = vim.api.nvim_get_current_win()
		local tab_buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_win_set_buf(state.win_id, state.buf_id)
		if tab_buf ~= state.buf_id and vim.api.nvim_buf_is_valid(tab_buf) then
			pcall(vim.api.nvim_buf_delete, tab_buf, { force = true })
		end
		state.prev_buf = nil
	elseif mode == "current" then
		state.prev_buf = vim.api.nvim_get_current_buf()
		state.win_id = vim.api.nvim_get_current_win()
		state.tab_id = nil
		vim.api.nvim_win_set_buf(state.win_id, state.buf_id)
	elseif mode == "split" or mode == "vsplit" then
		-- Use :new / :vnew (split with new empty buffer) to avoid reusing the
		-- current buffer in both windows; :split reuses the same buffer which
		-- would be deleted and take the original window with it.
		local cmd = mode == "split" and "new" or "vnew"
		if mods_prefix ~= "" then
			-- Strip redundant vertical/horizontal that duplicate the cmd
			local m = mods_prefix
			if mode == "split" then
				m = m:gsub("vertical", ""):gsub("horizontal", "")
			else
				m = m:gsub("horizontal", "")
			end
			m = vim.trim(m:gsub("%s+", " "))
			if m ~= "" then
				local ok = pcall(vim.cmd, m .. " " .. cmd)
				if not ok then
					vim.cmd(cmd)
				end
			else
				vim.cmd(cmd)
			end
		else
			vim.cmd(cmd)
		end
		state.win_id = vim.api.nvim_get_current_win()
		state.tab_id = nil
		state.prev_buf = nil
		local new_buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_win_set_buf(state.win_id, state.buf_id)
		if new_buf ~= state.buf_id and vim.api.nvim_buf_is_valid(new_buf) then
			pcall(vim.api.nvim_buf_delete, new_buf, { force = true })
		end
	else
		-- panel / float — floating window via nvim_open_win
		state.win_id = vim.api.nvim_open_win(state.buf_id, true, win_config_fn())
		state.tab_id = nil
		state.prev_buf = nil
	end
	ui_utils.apply_win_config(state.win_id, mode)
	statusline.attach(state.win_id)
	local attached_win = state.win_id
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(attached_win),
		once = true,
		callback = function()
			vim.schedule(function()
				if state.win_id == attached_win and not vim.api.nvim_win_is_valid(attached_win) then
					statusline.reset()
				end
			end)
		end,
	})
	keymaps.register_global(state.buf_id, {
		close = M.close,
		refresh = M.refresh,
		next_view = M.next_view,
		prev_view = M.prev_view,
		open_help = function()
			require("dockyard.ui.popups.help").toggle({ buffer = state.buf_id })
		end,
	})

	require("dockyard.ui.popups.help").register_command("Commands", {
		{ name = "Dockyard", desc = "Open Dockyard UI" },
		{ name = "DockyardFloat", desc = "Open Dockyard floating UI" },
		{ name = "DockyardBuild", desc = "Build Docker image from current Dockerfile" },
		{ name = "DockyardRun", desc = "Run Docker Compose services" },
		{ name = "DockyardFiles", desc = "Browse a container's filesystem" },
	}, { buffer = state.buf_id, index = 999 })

	return state.win_id
end

local function cycle_view(step)
	local views = config.options.display.views or { "containers", "images", "networks" }
	if #views == 0 then
		return
	end

	local idx = 1
	for i, view in ipairs(views) do
		if view == state.current_view then
			idx = i
			break
		end
	end

	local next_idx = ((idx - 1 + step) % #views) + 1
	teardown_active_view()
	state.current_view = views[next_idx]
	setup_active_view()
	update_active_view(nil)
end

M.resize = function()
	if not M.is_open() then
		return
	end

	if state.mode == "full" or state.mode == "tab" then
		update_active_view(nil)
		return
	end

	-- Only floating/panel modes support nvim_win_set_config resize
	if state.mode ~= "panel" and state.mode ~= "float" then
		update_active_view(nil)
		return
	end

	local config_fn = win_config_by_mode[state.mode] or ui_utils.panel_win_config
	vim.api.nvim_win_set_config(state.win_id, config_fn())
	update_active_view(nil)
end

M.is_open = function()
	return state.win_id ~= nil and vim.api.nvim_win_is_valid(state.win_id)
end

M.open = function()
	if M.is_open() then
		vim.api.nvim_set_current_win(state.win_id)
		update_active_view(nil)
		return state.win_id
	end

	local win_id = open_with("panel", ui_utils.panel_win_config)
	setup_active_view()
	update_active_view(nil, { force_update = true })
	return win_id
end

M.open_full = function()
	if M.is_open() then
		vim.api.nvim_set_current_win(state.win_id)
		update_active_view(nil)
		return state.win_id
	end

	local win_id = open_with("full", ui_utils.full_win_config)
	setup_active_view()
	update_active_view(nil, { force_update = true })
	return win_id
end

-- Additional open strategies — honor Vim's window modifiers convention
-- e.g. :vertical Dockyard, :tab Dockyard, :split | Dockyard

M.open_current = function(mods)
	if M.is_open() then
		vim.api.nvim_set_current_win(state.win_id)
		update_active_view(nil)
		return state.win_id
	end
	local win_id = open_with("current", ui_utils.panel_win_config, mods)
	setup_active_view()
	update_active_view(nil, { force_update = true })
	return win_id
end

M.open_split = function(mods)
	if M.is_open() then
		vim.api.nvim_set_current_win(state.win_id)
		update_active_view(nil)
		return state.win_id
	end
	local win_id = open_with("split", ui_utils.panel_win_config, mods)
	setup_active_view()
	update_active_view(nil, { force_update = true })
	return win_id
end

M.open_vsplit = function(mods)
	if M.is_open() then
		vim.api.nvim_set_current_win(state.win_id)
		update_active_view(nil)
		return state.win_id
	end
	local win_id = open_with("vsplit", ui_utils.panel_win_config, mods)
	setup_active_view()
	update_active_view(nil, { force_update = true })
	return win_id
end

M.open_tab = function(mods)
	if M.is_open() then
		vim.api.nvim_set_current_win(state.win_id)
		update_active_view(nil)
		return state.win_id
	end
	local win_id = open_with("tab", ui_utils.full_win_config, mods)
	setup_active_view()
	update_active_view(nil, { force_update = true })
	return win_id
end

M.open_float = M.open

--- Unified entry point for :Dockyard [strategy]. Mirrors oil.nvim / neo-tree
--- convention while also honoring Vim's command modifiers (:vertical, :tab, etc.)
--- @param strategy DockyardOpenStrategy|nil Explicit arg or nil to use config.mods
--- @param mods string|nil Vim command modifiers (opts.mods)
M.open_with_strategy = function(strategy, mods)
	require("dockyard.ui.highlights").setup()
	local s = strategy or config.options.display.open_strategy or "tab"
	-- Normalize
	s = tostring(s):lower()
	if s == "panel" or s == "floating" then
		s = "float"
	end
	if s == "edit" or s == "buffer" or s == "current" then
		s = "current"
	end
	if s == "horizontal" or s == "h_split" or s == "hsplit" then
		s = "split"
	end
	if s == "vertical" or s == "v_split" then
		s = "vsplit"
	end
	if s == "tabnew" or s == "tabe" then
		s = "tab"
	end

	if s == "float" then
		return M.open_float()
	elseif s == "current" then
		return M.open_current(mods)
	elseif s == "split" then
		return M.open_split(mods)
	elseif s == "vsplit" then
		return M.open_vsplit(mods)
	elseif s == "tab" or s == "full" then
		return M.open_tab(mods)
	else
		vim.notify("Dockyard: unknown open strategy '" .. s .. "'", vim.log.levels.WARN)
		return M.open_tab(mods)
	end
end

M.close = function()
	if not M.is_open() then
		statusline.reset()
		return
	end

	if state.mode == "full" or state.mode == "tab" then
		if state.tab_id ~= nil and vim.api.nvim_tabpage_is_valid(state.tab_id) then
			local current_tab = vim.api.nvim_get_current_tabpage()
			if current_tab ~= state.tab_id then
				vim.api.nvim_set_current_tabpage(state.tab_id)
			end
			vim.cmd("tabclose")
		end
		state.win_id = nil
	elseif state.mode == "current" then
		-- Replace Dockyard buffer with previous buffer; keep window alive.
		if state.prev_buf ~= nil and vim.api.nvim_buf_is_valid(state.prev_buf) then
			if vim.api.nvim_win_is_valid(state.win_id) then
				vim.api.nvim_win_set_buf(state.win_id, state.prev_buf)
			end
		else
			-- No valid previous buffer — try alternate buffer, else create listed empty buffer.
			if vim.api.nvim_win_is_valid(state.win_id) then
				local alt = vim.fn.bufnr("#")
				if alt ~= -1 and vim.api.nvim_buf_is_valid(alt) then
					vim.api.nvim_win_set_buf(state.win_id, alt)
				else
					local empty = vim.api.nvim_create_buf(true, false)
					vim.api.nvim_win_set_buf(state.win_id, empty)
				end
			end
		end
		state.win_id = nil
		state.prev_buf = nil
	else
		-- panel/float/split/vsplit — close the window
		vim.api.nvim_win_close(state.win_id, true)
		state.win_id = nil
	end
	state.win_id = nil
	statusline.reset()

	if state.mode ~= "current" then
		if state.prev_win ~= nil and vim.api.nvim_win_is_valid(state.prev_win) then
			-- For split/vsplit the prev_win is the window we split from; focus back
			-- only if current window was the Dockyard window.
			local cur = vim.api.nvim_get_current_win()
			if cur ~= state.prev_win then
				pcall(vim.api.nvim_set_current_win, state.prev_win)
			end
		end
	end

	state.prev_win = nil
	state.prev_buf = nil
	state.tab_id = nil
	teardown_active_view()
	if state.buf_id ~= nil then
		keymaps.unregister_global(state.buf_id)
	end
end

M.refresh = function()
	if not M.is_open() then
		return
	end

	update_active_view(nil, { force_update = true })
end

M.next_view = function()
	cycle_view(1)
end

M.prev_view = function()
	cycle_view(-1)
end

local resize_group = vim.api.nvim_create_augroup("DockyardUIResize", { clear = true })
vim.api.nvim_create_autocmd("VimResized", {
	group = resize_group,
	callback = function()
		M.resize()
	end,
})

return M
