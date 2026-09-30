local model = require("dockyard.ui.popups.compose_menu.model")
local compose = require("dockyard.commands.compose")

compose.base_cmd = function()
	return { "docker", "compose" }
end

local defaults = {
	profiles = {},
	all_profiles = false,
	force_recreate = true,
	build = false,
	pull = false,
	no_deps = false,
	wait = false,
	remove_orphans = false,
}

local function state(available, saved, action)
	return model.new("/p/compose.yml", available, vim.tbl_extend("force", vim.deepcopy(defaults), saved or {}), action)
end

local function checked(st)
	local out = {}
	for _, item in ipairs(model.items(st)) do
		if item.checked then
			table.insert(out, item.id)
		end
	end
	return out
end

describe("compose menu model", function()
	it("offers the profiles of the file and the ones already saved", function()
		local st = state({ "tools", "debug" }, { profiles = { "old" } })
		local ids = vim.tbl_map(function(i)
			return i.id
		end, model.items(st))
		eq({ "profile:debug", "profile:old", "profile:tools", "all_profiles" }, vim.list_slice(ids, 1, 4))
	end)

	it("hides the profile section when there is no profile", function()
		local st = state({})
		eq("flag:force_recreate", model.items(st)[1].id)
	end)

	it("checks what is saved", function()
		eq({ "flag:force_recreate" }, checked(state({})))
		eq({ "profile:debug", "flag:force_recreate", "flag:build" }, checked(state({ "debug" }, { profiles = { "debug" }, build = true })))
	end)

	it("toggles a profile and reports that it must be saved", function()
		local st = state({ "debug", "e2e" })
		eq(true, model.toggle(st, "profile:e2e"))
		eq(true, model.toggle(st, "profile:debug"))
		eq({ "debug", "e2e" }, st.prefs.profiles)
		eq(true, model.toggle(st, "profile:debug"))
		eq({ "e2e" }, st.prefs.profiles)
	end)

	it("toggles flags, with pull standing for --pull always", function()
		local st = state({})
		model.toggle(st, "flag:build")
		model.toggle(st, "flag:pull")
		model.toggle(st, "flag:force_recreate")
		eq(true, st.prefs.build)
		eq("always", st.prefs.pull)
		eq(false, st.prefs.force_recreate)
		model.toggle(st, "flag:pull")
		eq(false, st.prefs.pull)
	end)

	it("keeps destructive flags out of the saved part", function()
		local st = state({})
		eq(false, model.toggle(st, "once:volumes"))
		eq(false, model.toggle(st, "once:rmi"))
		eq(true, st.once.volumes)
		eq("local", st.once.rmi)
		eq(nil, st.prefs.volumes)
		eq(true, model.opts(st).volumes)
	end)

	it("previews the command of an action", function()
		local st = state({ "debug" }, { profiles = { "debug" }, build = true })
		eq("docker compose -f /p/compose.yml --profile debug up -d --build --force-recreate", model.command(st, "up"))
		model.toggle(st, "once:volumes")
		eq("docker compose -f /p/compose.yml --profile debug down -v", model.command(st, "down"))
	end)

	it("renders the boxes, the command and the keys", function()
		local st = state({ "debug" }, { profiles = { "debug" } })
		local lines, item_lines = model.render(st)
		eq(" Compose · compose.yml", lines[1])
		local text = table.concat(lines, "\n")
		truthy(text:find("[x] debug", 1, true), text)
		truthy(text:find("[ ] all profiles (*)", 1, true), text)
		truthy(text:find("[x] --force-recreate", 1, true), text)
		truthy(text:find("$ docker compose -f /p/compose.yml --profile debug up -d --force-recreate", 1, true), text)
		truthy(text:find("<CR> up", 1, true), text)
		eq("profile:debug", item_lines[4])
	end)

	it("summarises what differs from the defaults", function()
		eq("", model.summary(defaults))
		eq("debug +build", model.summary(vim.tbl_extend("force", defaults, { profiles = { "debug" }, build = true })))
		eq("*", model.summary(vim.tbl_extend("force", defaults, { all_profiles = true })))
		eq("-force-recreate +pull", model.summary(vim.tbl_extend("force", defaults, { force_recreate = false, pull = "always" })))
	end)
end)

describe(":Dockyard compose completion", function()
	local cli = require("dockyard.commands.cli")

	it("completes the compose actions and is a subcommand", function()
		eq({ "down" }, cli.complete("d", "Dockyard compose d"))
		truthy(vim.tbl_contains(cli.complete("", "Dockyard "), "compose"))
	end)
end)

describe("compose menu window", function()
	local prefs = require("dockyard.commands.prefs")
	local menu = require("dockyard.ui.popups.compose_menu")
	local compose_run = require("dockyard.commands.compose_run")

	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	prefs.path = function()
		return dir .. "/data/projects.json"
	end
	local file = dir .. "/compose.yml"
	vim.fn.writefile({ "services:", "  api:", "    image: alpine", "    profiles: [debug]" }, file)

	local function open_menu(action)
		prefs.reset()
		menu.open(file, { action = action })
		vim.wait(10000, function()
			return vim.bo.filetype == "dockyardmenu"
		end, 20)
		eq("dockyardmenu", vim.bo.filetype)
		return vim.api.nvim_get_current_buf()
	end

	local function goto_line(buf, needle)
		for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
			if line:find(needle, 1, true) then
				vim.api.nvim_win_set_cursor(0, { i, 0 })
				return
			end
		end
		error("no line with " .. needle)
	end

	it("saves the boxes of the project and keeps the one-shot ones out of the file", function()
		local buf = open_menu()
		goto_line(buf, "--build")
		vim.cmd("normal x")
		goto_line(buf, "debug")
		vim.cmd("normal x")
		goto_line(buf, "-v  remove volumes")
		vim.cmd("normal x")
		prefs.reset()
		local saved = prefs.get(file)
		eq(true, saved.build)
		eq({ "debug" }, saved.profiles)
		eq(nil, saved.volumes)
		vim.cmd("normal q")
	end)

	it("runs the action of the key with the saved options", function()
		local calls = {}
		local real = compose_run.run
		compose_run.run = function(f, action, extra)
			table.insert(calls, { f, action, extra })
		end
		open_menu()
		vim.cmd("normal b")
		compose_run.run = real
		eq(1, #calls)
		eq({ file, "build" }, { calls[1][1], calls[1][2] })
	end)

	it("does not run down -v when the confirmation is declined", function()
		local calls = {}
		local real_run, real_select = compose_run.run, vim.ui.select
		compose_run.run = function(f, action)
			table.insert(calls, action)
		end
		local asked
		vim.ui.select = function(items, opts, on_choice)
			asked = { items = items, prompt = opts.prompt }
			on_choice("No")
		end
		local buf = open_menu()
		goto_line(buf, "-v  remove volumes")
		vim.cmd("normal x")
		vim.cmd("normal d")
		eq({ "No", "Yes" }, asked.items)
		truthy(asked.prompt:find("volumes", 1, true), asked.prompt)
		eq({}, calls)

		vim.ui.select = function(_, _, on_choice)
			on_choice("Yes")
		end
		buf = open_menu()
		goto_line(buf, "-v  remove volumes")
		vim.cmd("normal x")
		vim.cmd("normal d")
		compose_run.run, vim.ui.select = real_run, real_select
		eq({ "down" }, calls)
	end)

	it("saves a modified compose buffer before it runs", function()
		vim.cmd("edit " .. vim.fn.fnameescape(file))
		local cbuf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(cbuf, -1, -1, false, { "# edited" })
		eq(true, vim.bo[cbuf].modified)
		local modified_when_run
		local real = compose_run.run
		compose_run.run = function()
			modified_when_run = vim.bo[cbuf].modified
		end
		open_menu()
		vim.cmd("normal b")
		compose_run.run = real
		eq(false, modified_when_run)
		truthy(vim.tbl_contains(vim.fn.readfile(file), "# edited"))
	end)

	it("closes the menu before asking, so the prompt cannot end up under it", function()
		local real_run, real_select = compose_run.run, vim.ui.select
		compose_run.run = function() end
		local menus_open
		vim.ui.select = function(_, _, on_choice)
			menus_open = #vim.tbl_filter(function(w)
				return vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "dockyardmenu"
			end, vim.api.nvim_list_wins())
			on_choice("No")
		end
		local buf = open_menu()
		goto_line(buf, "-v  remove volumes")
		vim.cmd("normal x")
		vim.cmd("normal d")
		compose_run.run, vim.ui.select = real_run, real_select
		eq(0, menus_open)
	end)

	it("runs down without asking when nothing destructive is ticked", function()
		local calls = {}
		local real_run, real_select = compose_run.run, vim.ui.select
		compose_run.run = function(_, action)
			table.insert(calls, action)
		end
		vim.ui.select = function()
			error("must not ask")
		end
		open_menu()
		vim.cmd("normal d")
		compose_run.run, vim.ui.select = real_run, real_select
		eq({ "down" }, calls)
	end)
end)
