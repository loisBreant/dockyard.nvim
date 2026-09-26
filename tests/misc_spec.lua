describe("lens.line", function()
	local lens = require("dockyard.lens")

	it("records where each button sits, after the separators", function()
		local line = lens.line():add("● up", "X"):add("▶ Run", "Y", { action = "run" }):add("↗ :80", "Z", { action = "open" })
		-- "  ● up  ▶ Run  ↗ :80"
		eq({ first = 8, last = 13, data = { action = "run" } }, line.buttons[1])
		eq({ first = 15, last = 20, data = { action = "open" } }, line.buttons[2])
		eq(20, line.width)
	end)
end)

describe("dockerfile final_from", function()
	local dockerfile_lens = require("dockyard.dockerfile_lens")

	it("points at the last FROM", function()
		eq(3, dockerfile_lens.final_from(buffer({ "FROM node AS build", "RUN make", "from nginx", "COPY . ." })))
	end)

	it("returns nil without FROM", function()
		eq(nil, dockerfile_lens.final_from(buffer({ "# nothing", "RUN true" })))
	end)
end)

describe("project scope", function()
	local scope = require("dockyard.ui.views.containers.scope")
	local home = vim.fs.normalize("~")

	local function matches(root, compose_dir)
		return scope.matches({ compose_dir = compose_dir }, root)
	end

	it("matches the project, its subdirectories and its parent", function()
		eq(true, matches(home .. "/app", home .. "/app"))
		eq(true, matches(home .. "/app", home .. "/app/services/api"))
		eq(true, matches(home .. "/app/src", home .. "/app"))
	end)

	it("does not confuse sibling directories sharing a prefix", function()
		eq(false, matches(home .. "/app", home .. "/app2"))
	end)

	it("ignores containers without a compose project, or started from ~ or /", function()
		eq(false, matches(home .. "/app", ""))
		eq(false, matches(home .. "/app", nil))
		eq(false, matches(home .. "/app", home))
		eq(false, matches(home .. "/app", "/"))
	end)
end)

describe("published_ports", function()
	local controller = require("dockyard.ui.views.containers.controller")

	it("keeps host ports of mapped ports only", function()
		eq({ 8080, 3000 }, controller.published_ports({ ports = "8080→80, 3000→3000, 5432" }))
		eq({}, controller.published_ports({ ports = "" }))
		eq({}, controller.published_ports({}))
	end)
end)

describe("files core paths", function()
	local core = require("dockyard.files.core")

	it("normalizes paths", function()
		eq("/", core.normalize(""))
		eq("/etc", core.normalize("etc"))
		eq("/usr/lib", core.normalize("/usr/./bin/../lib/"))
		eq("/", core.normalize("/.."))
	end)

	it("computes parents", function()
		eq("/", core.dirname("/"))
		eq("/", core.dirname("/etc"))
		eq("/usr/local", core.dirname("/usr/local/bin"))
	end)
end)
