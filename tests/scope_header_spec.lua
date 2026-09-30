local scope_header = require("dockyard.ui.components.scope_header")
local view_filter = require("dockyard.ui.components.view_filter")
local scope = require("dockyard.scope")
local config = require("dockyard.config")

describe("scope_header.matches", function()
	it("matches anything without a filter", function()
		eq(true, scope_header.matches({ "a" }, nil))
		eq(true, scope_header.matches({ "a" }, ""))
	end)

	it("looks for a substring, ignoring case, in any field", function()
		eq(true, scope_header.matches({ "Postgres", "16", "abc" }, "GRES"))
		eq(true, scope_header.matches({ "x", "y", "deadbeef" }, "beef"))
		eq(false, scope_header.matches({ "x", "y" }, "z"))
	end)

	it("takes the filter literally, not as a pattern", function()
		eq(true, scope_header.matches({ "a.b" }, "a.b"))
		eq(false, scope_header.matches({ "axb" }, "a.b"))
		eq(true, scope_header.matches({ "50%" }, "%"))
	end)
end)

describe("scope_header.block", function()
	local base = { scope_on = true, root = "/p/app", scoped = 3, total = 12, shown = 3, scope_key = "P", clear_key = "C" }

	it("shows the project line and a blank line", function()
		local block = scope_header.block(base)
		eq({ " Project: /p/app  (3/12)  [press P to show all]", "" }, block.lines)
		eq("DockyardMuted", block.highlights[1].hl_group)
		eq(0, block.highlights[1].line)
	end)

	it("adds the filter line, counted against what the scope lets through", function()
		local block = scope_header.block(vim.tbl_extend("force", base, { filter = "api", shown = 0 }))
		eq({
			" Project: /p/app  (3/12)  [press P to show all]",
			" Filter: api  (0/3)  [press C to clear]",
			"",
		}, block.lines)
		eq(1, block.highlights[2].line)
	end)

	it("shows only the filter when the scope is off, and nothing when neither applies", function()
		local off = scope_header.block(vim.tbl_extend("force", base, { scope_on = false, filter = "x", shown = 1 }))
		eq({ " Filter: x  (1/3)  [press C to clear]", "" }, off.lines)
		eq({ lines = {}, highlights = {} }, scope_header.block(vim.tbl_extend("force", base, { scope_on = false })))
	end)
end)

describe("scope_header.key_label", function()
	it("gives the first key of the action, or the fallback", function()
		eq("F", scope_header.key_label("images.filter", "?"))
		eq("?", scope_header.key_label("images.nope", "?"))
	end)
end)

describe("view_filter.controller", function()
	local function new()
		local state, renders = {}, { n = 0 }
		local ctl = view_filter.controller({
			view = "images",
			label = "images",
			state = state,
			render = function()
				renders.n = renders.n + 1
			end,
		})
		return ctl, state, renders
	end

	it("sets and clears the filter of its own view and redraws", function()
		local ctl, state, renders = new()
		ctl.set_filter("api")
		eq("api", state.filter)
		ctl.set_filter("")
		eq(nil, state.filter)
		ctl.set_filter("x")
		ctl.clear_filter()
		eq(nil, state.filter)
		eq(4, renders.n)
	end)

	it("toggles the scope shared by every view, then redraws", function()
		local ctl, _, renders = new()
		config.options.display.project_scope = true
		scope.reset()
		ctl.toggle_project_scope()
		eq(false, scope.enabled())
		eq(1, renders.n)
		scope.reset()
		config.options.display.project_scope = config.defaults.display.project_scope
	end)
end)

describe("view_filter keys", function()
	it("adds filter, clear and scope keys to a view, and takes them away again", function()
		local ctl = { prompt_filter = function() end, clear_filter = function() end, toggle_project_scope = function() end }
		local items = {}
		view_filter.push_items(items, "networks", ctl, 20)
		eq({ "F", "C", "P" }, vim.tbl_map(function(i)
			return i.key
		end, items))
		eq({ 20, 21, 22 }, vim.tbl_map(function(i)
			return i.index
		end, items))
		local removals = {}
		view_filter.push_removals(removals, "networks")
		eq({ "F", "C", "P" }, vim.tbl_map(function(i)
			return i.key
		end, removals))
	end)
end)
