local scope = require("dockyard.scope")
local config = require("dockyard.config")

-- a project directory with a compose file, as root
local function project(compose_lines, name)
	local base = vim.fn.tempname()
	local dir = base .. "/" .. (name or "My App")
	vim.fn.mkdir(dir, "p")
	if compose_lines then
		vim.fn.writefile(compose_lines, dir .. "/compose.yml")
	end
	return vim.fs.normalize(dir)
end

local real_root = scope.root
local function use_root(dir)
	scope.root = function()
		return dir
	end
end

local function enable(on)
	config.options.display.project_scope = on
	scope.reset()
end

local function names(list, key)
	return vim.tbl_map(function(item)
		return item[key]
	end, list)
end

describe("scope.normalize_project_name", function()
	it("lowercases, drops characters Docker refuses and leading separators", function()
		eq("myapp", scope.normalize_project_name("My App!"))
		eq("x-y", scope.normalize_project_name("_x-Y"))
		eq("dockyardnvim", scope.normalize_project_name("Dockyard.NVIM"))
		eq("", scope.normalize_project_name(""))
		eq("", scope.normalize_project_name(nil))
	end)
end)

describe("scope.project_name", function()
	it("uses the normalised directory name without a name: key", function()
		eq("myapp", scope.project_name(project({ "services: {}" })))
	end)

	it("reads name:, with quotes and a trailing comment", function()
		eq("custom_name", scope.project_name(project({ 'name: "Custom_Name"  # the project', "services: {}" })))
	end)

	it("is nil without a compose file", function()
		eq(nil, scope.project_name(project(nil)))
	end)
end)

describe("scope.label", function()
	local networks = "com.docker.compose.config-hash=e0d23ec7,com.docker.compose.network=net,com.docker.compose.project=filow-docs,com.docker.compose.version=5.5.1"

	it("reads one label of the comma separated list Docker prints", function()
		eq("filow-docs", scope.label(networks, "com.docker.compose.project"))
		eq("net", scope.label(networks, "com.docker.compose.network"))
	end)

	it("returns nil for a missing label, empty labels and nil", function()
		eq(nil, scope.label(networks, "nope"))
		eq(nil, scope.label("", "com.docker.compose.project"))
		eq(nil, scope.label(nil, "com.docker.compose.project"))
		eq("", scope.label("com.docker.volume.anonymous=", "com.docker.volume.anonymous"))
	end)
end)

describe("scope.enabled / toggle", function()
	it("follows display.project_scope until toggled, for every view at once", function()
		enable(true)
		eq(true, scope.enabled())
		eq(false, scope.toggle())
		eq(false, scope.enabled())
		eq(true, scope.toggle())
		scope.reset()
		enable(false)
		eq(false, scope.enabled())
	end)

	it("is on in 'auto' mode only when the root has a compose file", function()
		enable("auto")
		use_root(project({ "services: {}" }))
		eq(true, scope.enabled())
		use_root(project(nil))
		eq(false, scope.enabled())
	end)
end)

describe("scope.project_names", function()
	it("collects the projects of the containers started from the root, plus the compose project of the root", function()
		local root = project({ "services: {}" }, "Shop")
		use_root(root)
		local set = scope.project_names({
			{ compose_project = "shop-custom", compose_dir = root },
			{ compose_project = "shop-custom", compose_dir = root .. "/services/api" },
			{ compose_project = "other", compose_dir = "/somewhere/else" },
			{ name = "plain-docker-run" },
		})
		eq({ ["shop-custom"] = true, shop = true }, set)
	end)

	it("keeps the compose project of the root when there is no container at all", function()
		use_root(project({ "services: {}" }, "Fresh"))
		eq({ fresh = true }, scope.project_names({}))
	end)
end)

describe("scope.apply_*", function()
	local root
	local containers

	local function setup()
		root = project({ "services: {}" }, "App")
		use_root(root)
		enable(true)
		containers = {
			{ name = "app-api-1", image = "app-api", compose_project = "app", compose_dir = root },
			{ name = "app-cache-1", image = "redis:7", compose_project = "app", compose_dir = root },
			{ name = "app-db-1", image = "postgres", compose_project = "app", compose_dir = root },
			{ name = "other-db-1", image = "mysql:8", compose_project = "other", compose_dir = "/q/other" },
		}
	end

	it("keeps the networks and volumes labelled with a project of the scope", function()
		setup()
		local networks = {
			{ name = "app_default", labels = "com.docker.compose.project=app,com.docker.compose.network=default" },
			{ name = "other_net", labels = "com.docker.compose.project=other" },
			{ name = "bridge", labels = "" },
		}
		eq({ "app_default" }, names(scope.apply_networks(networks, containers), "name"))
		local volumes = {
			{ name = "app_data", labels = "com.docker.compose.project=app,com.docker.compose.volume=data" },
			{ name = "0f35a03b", labels = "com.docker.volume.anonymous=" },
			{ name = "other_data", labels = "com.docker.compose.project=other" },
		}
		eq({ "app_data" }, names(scope.apply_volumes(volumes, containers), "name"))
	end)

	it("shows the networks of a project that has no container yet", function()
		setup()
		local networks = { { name = "app_default", labels = "com.docker.compose.project=app" } }
		eq({ "app_default" }, names(scope.apply_networks(networks, {}), "name"))
	end)

	it("keeps the images built for the project and the ones its containers use, tag or not", function()
		setup()
		local images = {
			{ id = "a1", repository = "app-api", tag = "latest", compose_project = "app" },
			{ id = "b2", repository = "redis", tag = "7" },
			{ id = "c3", repository = "postgres", tag = "latest" },
			{ id = "d4", repository = "mysql", tag = "8" },
			{ id = "e5", repository = "unrelated", tag = "1" },
		}
		eq({ "app-api", "redis", "postgres" }, names(scope.apply_images(images, containers), "repository"))
	end)

	it("keeps the jobs run inside the project, and none without a directory", function()
		setup()
		local jobs = {
			{ id = 1, cwd = root },
			{ id = 2, cwd = root .. "/services/api" },
			{ id = 3, cwd = "/elsewhere" },
			{ id = 4 },
		}
		eq({ 1, 2 }, names(scope.apply_jobs(jobs), "id"))
	end)

	it("changes nothing when the scope is off", function()
		setup()
		enable(false)
		local list = { { name = "x", labels = "" }, { id = 1 } }
		eq(list, scope.apply_networks(list, containers))
		eq(list, scope.apply_volumes(list, containers))
		eq(list, scope.apply_images(list, containers))
		eq(list, scope.apply_jobs(list))
		eq(containers, scope.apply_containers(containers))
	end)

	it("filters the containers like before", function()
		setup()
		eq({ "app-api-1", "app-cache-1", "app-db-1" }, names(scope.apply(containers), "name"))
	end)
end)

describe("scope.ensure_containers", function()
	local state = require("dockyard.state")

	it("calls back at once when the scope is off or containers are known", function()
		local real_refresh = state.containers.refresh
		local refreshed = 0
		state.containers.refresh = function()
			refreshed = refreshed + 1
		end
		local calls = 0
		enable(false)
		scope.ensure_containers(function()
			calls = calls + 1
		end)
		eq(1, calls)
		eq(0, refreshed)
		state.containers.refresh = real_refresh
	end)

	it("loads the containers first when the scope is on and none are known", function()
		local real_refresh, real_items = state.containers.refresh, state.containers.get_items
		state.containers.get_items = function()
			return {}
		end
		state.containers.refresh = function(opts)
			opts.on_success({})
		end
		enable(true)
		local calls = 0
		scope.ensure_containers(function()
			calls = calls + 1
		end)
		state.containers.refresh, state.containers.get_items = real_refresh, real_items
		eq(1, calls)
	end)

	it("reloads the containers even when some are known, when asked to (the R key)", function()
		local real_refresh, real_items = state.containers.refresh, state.containers.get_items
		state.containers.get_items = function()
			return { { name = "known" } }
		end
		local refreshed = 0
		state.containers.refresh = function(opts)
			refreshed = refreshed + 1
			opts.on_success({})
		end
		enable(true)
		local calls = 0
		local function cb()
			calls = calls + 1
		end
		scope.ensure_containers(cb)
		eq({ 1, 0 }, { calls, refreshed })
		scope.ensure_containers(cb, { force = true })
		eq({ 2, 1 }, { calls, refreshed })
		enable(false)
		scope.ensure_containers(cb, { force = true })
		state.containers.refresh, state.containers.get_items = real_refresh, real_items
		eq({ 3, 1 }, { calls, refreshed })
	end)

	it("calls back even when loading the containers fails", function()
		local real_refresh, real_items = state.containers.refresh, state.containers.get_items
		state.containers.get_items = function()
			return {}
		end
		state.containers.refresh = function(opts)
			opts.on_error("boom")
		end
		enable(true)
		local calls = 0
		scope.ensure_containers(function()
			calls = calls + 1
		end)
		state.containers.refresh, state.containers.get_items = real_refresh, real_items
		eq(1, calls)
	end)
end)

scope.root = real_root
config.options.display.project_scope = config.defaults.display.project_scope
scope.reset()
