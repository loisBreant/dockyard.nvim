local prefs = require("dockyard.commands.prefs")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local store = dir .. "/data/projects.json"
prefs.path = function()
	return store
end

local project = dir .. "/compose.yml"
vim.fn.writefile({ "services: {}" }, project)

local function fresh()
	prefs.reset()
	vim.fn.delete(dir .. "/data", "rf")
	vim.fn.delete(store .. ".bak")
end

describe("prefs.get", function()
	it("returns the configured defaults for an unknown project", function()
		fresh()
		eq({
			profiles = {},
			all_profiles = false,
			force_recreate = true,
			build = false,
			pull = false,
			no_deps = false,
			wait = false,
			remove_orphans = false,
		}, prefs.get(project))
	end)
end)

describe("prefs.set", function()
	it("round-trips through the file", function()
		fresh()
		local p = prefs.get(project)
		p.profiles = { "debug" }
		p.build = true
		p.pull = "always"
		truthy(prefs.set(project, p))
		prefs.reset() -- read it back from disk
		local back = prefs.get(project)
		eq({ "debug" }, back.profiles)
		eq(true, back.build)
		eq("always", back.pull)
		eq(true, back.force_recreate)
	end)

	it("never stores destructive flags", function()
		fresh()
		local p = prefs.get(project)
		p.volumes = true
		p.rmi = "all"
		p.renew_anon_volumes = true
		prefs.set(project, p)
		local text = table.concat(vim.fn.readfile(store), "\n")
		eq(nil, text:find("volumes\":true", 1, true))
		eq(nil, text:find("rmi", 1, true))
		eq(nil, text:find("renew_anon_volumes", 1, true))
		prefs.reset()
		local back = prefs.get(project)
		eq(nil, back.volumes)
		eq(nil, back.rmi)
	end)

	it("keeps projects apart", function()
		fresh()
		local other = dir .. "/other.yml"
		vim.fn.writefile({ "services: {}" }, other)
		prefs.set(project, vim.tbl_extend("force", prefs.get(project), { profiles = { "a" } }))
		eq({}, prefs.get(other).profiles)
		eq({ "a" }, prefs.get(project).profiles)
	end)
end)

describe("prefs shared between Neovim instances", function()
	it("keeps what another instance saved in the meantime", function()
		fresh()
		local other = dir .. "/other.yml"
		vim.fn.writefile({ "services: {}" }, other)
		prefs.get(project) -- this instance has read the file (there was none)
		-- another instance saves preferences for `other`
		vim.fn.mkdir(dir .. "/data", "p")
		vim.fn.writefile({ vim.json.encode({ version = 1, projects = { [prefs.key(other)] = { profiles = { "x" } } } }) }, store)
		local mine = prefs.get(project)
		mine.build = true
		truthy(prefs.set(project, mine))
		prefs.reset()
		eq({ "x" }, prefs.get(other).profiles)
		eq(true, prefs.get(project).build)
	end)
end)

describe("prefs with a broken file", function()
	it("moves it aside and starts from the defaults", function()
		fresh()
		vim.fn.mkdir(dir .. "/data", "p")
		vim.fn.writefile({ "{ not json" }, store)
		local warned
		local orig = vim.notify
		vim.notify = function(msg)
			warned = msg
		end
		local got = prefs.get(project)
		vim.notify = orig
		eq(true, got.force_recreate)
		truthy(warned and warned:find("projects.json.bak", 1, true), tostring(warned))
		eq(1, vim.fn.filereadable(store .. ".bak"))
		eq(0, vim.fn.filereadable(store))
	end)

	it("ignores a file from another version", function()
		fresh()
		vim.fn.mkdir(dir .. "/data", "p")
		vim.fn.writefile({ '{"version":99,"projects":{}}' }, store)
		local orig = vim.notify
		vim.notify = function() end
		local got = prefs.get(project)
		vim.notify = orig
		eq(true, got.force_recreate)
		eq(1, vim.fn.filereadable(store .. ".bak"))
	end)
end)
