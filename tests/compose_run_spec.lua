local prefs = require("dockyard.commands.prefs")
local compose = require("dockyard.commands.compose")
local executor = require("dockyard.commands.executor")
local compose_run = require("dockyard.commands.compose_run")

compose.base_cmd = function()
	return { "docker", "compose" }
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
prefs.path = function()
	return dir .. "/data/projects.json"
end
local file = dir .. "/compose.yml"
vim.fn.writefile({ "services: {}" }, file)

-- capture what would be run
local calls = {}
local real_run = executor.run
executor.run = function(argv, opts)
	table.insert(calls, { argv = argv, opts = opts })
	return { id = 0 }
end

describe("compose_run.run", function()
	it("runs up with the defaults of a project that has no preferences", function()
		prefs.reset()
		calls = {}
		compose_run.run(file, "up")
		eq({ "docker", "compose", "-f", file, "up", "-d", "--force-recreate" }, calls[1].argv)
		eq(dir, calls[1].opts.cwd)
		eq("compose up all services", calls[1].opts.title)
		eq(prefs.key(file), calls[1].opts.project)
	end)

	it("uses the saved profiles and flags, and the given services", function()
		prefs.reset()
		local saved = prefs.get(file)
		saved.profiles = { "debug" }
		saved.build = true
		prefs.set(file, saved)
		calls = {}
		compose_run.run(file, "up", { services = { "api", "db" } })
		eq({ "docker", "compose", "-f", file, "--profile", "debug", "up", "-d", "--build", "--force-recreate", "api", "db" }, calls[1].argv)
		eq("compose up api, db", calls[1].opts.title)
	end)

	it("lets one-shot flags through without saving them", function()
		prefs.reset()
		calls = {}
		compose_run.run(file, "down", { volumes = true })
		eq({ "docker", "compose", "-f", file, "--profile", "debug", "down", "-v" }, calls[1].argv)
		prefs.reset()
		eq(nil, prefs.get(file).volumes)
	end)

	it("hands on_exit to the executor", function()
		calls = {}
		local function cb() end
		compose_run.run(file, "stop", nil, { on_exit = cb })
		eq(cb, calls[1].opts.on_exit)
	end)

	it("reports an unknown action instead of running", function()
		calls = {}
		local orig = vim.notify
		local msg
		vim.notify = function(m)
			msg = m
		end
		compose_run.run(file, "explode")
		vim.notify = orig
		eq(0, #calls)
		truthy(msg and msg:find("Unknown compose action"), tostring(msg))
	end)
end)

executor.run = real_run
