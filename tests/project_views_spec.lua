local scope = require("dockyard.scope")
local config = require("dockyard.config")

local root = vim.fs.normalize(vim.fn.tempname() .. "/app")
vim.fn.mkdir(root, "p")
vim.fn.writefile({ "services: {}" }, root .. "/compose.yml")
local real_root = scope.root
scope.root = function()
	return root
end

local function scope_on(on)
	config.options.display.project_scope = on
	scope.reset()
end

local containers = {
	{ name = "app-api-1", image = "app-api", compose_project = "app", compose_dir = root },
	{ name = "app-cache-1", image = "redis:7", compose_project = "app", compose_dir = root },
	{ name = "other-db-1", image = "postgres:16", compose_project = "other", compose_dir = "/q/other" },
}

local function names(list, key)
	return vim.tbl_map(function(item)
		return item[key]
	end, list)
end

describe("images view selection", function()
	local renderer = require("dockyard.ui.views.images.renderer")
	local images = {
		{ id = "a1", repository = "app-api", tag = "latest", compose_project = "app" },
		{ id = "b2", repository = "redis", tag = "7" },
		{ id = "c3", repository = "postgres", tag = "16" },
		{ id = "d4", repository = "unrelated", tag = "1" },
	}

	it("shows the images of the project: built for it, or used by its containers", function()
		scope_on(true)
		local shown, scoped = renderer.select(images, containers, nil)
		eq({ "app-api", "redis" }, names(shown, "repository"))
		eq(2, #scoped)
	end)

	it("filters by repository, tag or id on top of the scope, counted against the scope", function()
		scope_on(true)
		local shown, scoped = renderer.select(images, containers, "REDIS")
		eq({ "redis" }, names(shown, "repository"))
		eq(2, #scoped)
		eq({ "app-api" }, names((renderer.select(images, containers, "a1")), "repository"))
		eq({ "redis" }, names((renderer.select(images, containers, "7")), "repository"))
	end)

	it("shows everything when the scope is off, and nothing for a filter that matches nothing", function()
		scope_on(false)
		eq(4, #renderer.select(images, containers, nil))
		eq({}, renderer.select(images, containers, "zzz"))
	end)
end)

describe("the R key reloads the containers the scope depends on", function()
	for _, view in ipairs({ "images", "networks", "volumes" }) do
		it("in the " .. view .. " view", function()
			local data_state = require("dockyard.state")
			local controller = require("dockyard.ui.views." .. view .. ".controller")
			local real_refresh, real_ensure = data_state[view].refresh, scope.ensure_containers
			data_state[view].refresh = function() end
			local asked = {}
			scope.ensure_containers = function(_, opts)
				table.insert(asked, opts or {})
			end
			controller.update(nil, { force_update = true })
			controller.update(nil, nil)
			data_state[view].refresh, scope.ensure_containers = real_refresh, real_ensure
			eq(2, #asked)
			eq(true, asked[1].force)
			eq(false, asked[2].force == true)
		end)
	end
end)

describe("images view keys", function()
	it("has a filter controller and prune moved off P", function()
		local controller = require("dockyard.ui.views.images.controller")
		eq("function", type(controller.filter.prompt_filter))
		eq("X", require("dockyard.core.keymaps").key("images.prune"))
		eq("P", require("dockyard.core.keymaps").key("images.toggle_project_scope"))
	end)
end)

describe("networks view selection", function()
	local renderer = require("dockyard.ui.views.networks.renderer")
	local networks = {
		{ id = "n1", name = "app_default", driver = "bridge", labels = "com.docker.compose.project=app,com.docker.compose.network=default" },
		{ id = "n2", name = "bridge", driver = "bridge", labels = "" },
		{ id = "n3", name = "other_net", driver = "overlay", labels = "com.docker.compose.project=other" },
	}

	it("shows the networks of the project, and keeps them when it has no container", function()
		scope_on(true)
		eq({ "app_default" }, names((renderer.select(networks, containers, nil)), "name"))
		eq({ "app_default" }, names((renderer.select(networks, {}, nil)), "name"))
	end)

	it("filters by name, driver or id", function()
		scope_on(false)
		eq({ "other_net" }, names((renderer.select(networks, containers, "overlay")), "name"))
		eq({ "bridge" }, names((renderer.select(networks, containers, "n2")), "name"))
		eq({ "app_default", "bridge", "other_net" }, names((renderer.select(networks, containers, "")), "name"))
		scope_on(true)
		local shown, scoped = renderer.select(networks, containers, "zzz")
		eq(0, #shown)
		eq(1, #scoped)
	end)

	it("has a filter controller", function()
		eq("function", type(require("dockyard.ui.views.networks.controller").filter.prompt_filter))
	end)
end)


describe("volumes view selection", function()
	local renderer = require("dockyard.ui.views.volumes.renderer")
	local volumes = {
		{ name = "app_data", driver = "local", labels = "com.docker.compose.project=app,com.docker.compose.volume=data" },
		{ name = "0f35a03bff05", driver = "local", labels = "com.docker.volume.anonymous=" },
		{ name = "other_data", driver = "local", labels = "com.docker.compose.project=other" },
	}

	it("shows the named volumes of the project and hides the anonymous ones", function()
		scope_on(true)
		eq({ "app_data" }, names((renderer.select(volumes, containers, nil)), "name"))
	end)

	it("filters by name or driver, and shows everything when the scope is off", function()
		scope_on(false)
		eq(3, #renderer.select(volumes, containers, nil))
		eq({ "other_data" }, names((renderer.select(volumes, containers, "OTHER")), "name"))
		eq(3, #renderer.select(volumes, containers, "local"))
	end)

	it("has a filter controller", function()
		eq("function", type(require("dockyard.ui.views.volumes.controller").filter.prompt_filter))
	end)
end)


describe("jobs view selection", function()
	local renderer = require("dockyard.ui.views.jobs.renderer")
	local jobs = {
		{ id = 1, title = "compose up all services", argv = { "docker", "compose", "up" }, cwd = root, status = "ok" },
		{ id = 2, title = "docker build web", argv = { "docker", "build", "." }, cwd = root .. "/web", status = "failed" },
		{ id = 3, title = "compose up other", argv = { "docker", "compose", "up" }, cwd = "/q/other", status = "ok" },
	}

	it("shows the jobs run inside the project", function()
		scope_on(true)
		eq({ 1, 2 }, names((renderer.select(jobs, nil)), "id"))
	end)

	it("filters by title, status, directory or command line", function()
		scope_on(false)
		eq({ 2 }, names((renderer.select(jobs, "BUILD")), "id"))
		eq({ 2 }, names((renderer.select(jobs, "failed")), "id"))
		eq({ 3 }, names((renderer.select(jobs, "/q/other")), "id"))
		eq({ 1, 2, 3 }, names((renderer.select(jobs, "docker")), "id"))
		scope_on(true)
		local shown, scoped = renderer.select(jobs, "nothing")
		eq(0, #shown)
		eq(2, #scoped)
	end)

	it("has a filter controller", function()
		eq("function", type(require("dockyard.ui.views.jobs.controller").filter.prompt_filter))
	end)
end)


scope.root = real_root
scope_on(config.defaults.display.project_scope)
