local compose = require("dockyard.commands.compose")

-- do not depend on the docker binary of the machine running the tests
local real_base = compose.base_cmd
compose.base_cmd = function()
	return { "docker", "compose" }
end

local project = { files = { "/p/docker-compose.yml" }, dir = "/p" }

describe("compose.build", function()
	it("defaults to up -d", function()
		eq({ "docker", "compose", "-f", "/p/docker-compose.yml", "up", "-d" }, compose.build(project, "up"))
	end)

	it("puts global options before the verb and verb flags after it", function()
		local argv = compose.build(
			{ files = { "/p/a.yml", "/p/b.yml" }, dir = "/p", name = "demo", env_file = "/p/.env.dev" },
			"up",
			{ profiles = { "debug", "e2e" }, build = true, force_recreate = true, services = { "api", "db" } }
		)
		eq({
			"docker", "compose",
			"-f", "/p/a.yml", "-f", "/p/b.yml",
			"-p", "demo",
			"--env-file", "/p/.env.dev",
			"--profile", "debug", "--profile", "e2e",
			"up", "-d", "--build", "--force-recreate",
			"api", "db",
		}, argv)
	end)

	it("supports every up flag", function()
		local argv = compose.build(project, "up", {
			build = true,
			pull = "always",
			force_recreate = true,
			no_deps = true,
			wait = true,
			remove_orphans = true,
			renew_anon_volumes = true,
		})
		eq({
			"docker", "compose", "-f", "/p/docker-compose.yml",
			"up", "-d", "--build", "--pull", "always", "--force-recreate", "--no-deps", "--wait",
			"--remove-orphans", "-V",
		}, argv)
	end)

	it("treats pull = false as absent", function()
		eq({ "docker", "compose", "-f", "/p/docker-compose.yml", "up", "-d" }, compose.build(project, "up", { pull = false }))
	end)

	it("passes the active profiles to down, stop and restart too", function()
		for _, verb in ipairs({ "down", "stop", "restart" }) do
			eq(
				{ "docker", "compose", "-f", "/p/docker-compose.yml", "--profile", "debug", verb },
				compose.build(project, verb, { profiles = { "debug" } }),
				verb
			)
		end
	end)

	it("builds down -v --rmi --remove-orphans", function()
		eq(
			{ "docker", "compose", "-f", "/p/docker-compose.yml", "down", "-v", "--rmi", "local", "--remove-orphans" },
			compose.build(project, "down", { volumes = true, rmi = "local", remove_orphans = true })
		)
	end)

	it("uses --profile '*' for all profiles, ignoring the list", function()
		eq(
			{ "docker", "compose", "-f", "/p/docker-compose.yml", "--profile", "*", "up", "-d" },
			compose.build(project, "up", { all_profiles = true, profiles = { "debug" } })
		)
	end)

	it("ignores flags that do not belong to the action", function()
		eq(
			{ "docker", "compose", "-f", "/p/docker-compose.yml", "stop", "api" },
			compose.build(project, "stop", { build = true, volumes = true, services = { "api" } })
		)
	end)

	it("builds and pulls the given services", function()
		eq({ "docker", "compose", "-f", "/p/docker-compose.yml", "build", "api" }, compose.build(project, "build", { services = { "api" } }))
		eq({ "docker", "compose", "-f", "/p/docker-compose.yml", "pull" }, compose.build(project, "pull"))
	end)

	it("lists profiles without any profile flag", function()
		eq(
			{ "docker", "compose", "-f", "/p/docker-compose.yml", "config", "--profiles" },
			compose.build(project, "profiles", { profiles = { "debug" }, services = { "api" } })
		)
	end)

	it("keeps a path with spaces as a single argument", function()
		local argv = compose.build({ files = { "/my projects/app one/compose.yml" }, dir = "/my projects/app one" }, "up")
		eq("/my projects/app one/compose.yml", argv[4])
		eq(6, #argv)
	end)

	it("does not modify the options it is given", function()
		local opts = { profiles = { "debug" }, services = { "api" } }
		compose.build(project, "up", opts)
		eq({ profiles = { "debug" }, services = { "api" } }, opts)
	end)

	it("reports a missing file and an unknown action", function()
		local argv, err = compose.build({ files = {}, dir = "/p" }, "up")
		eq(nil, argv)
		eq("No compose file found", err)
		argv, err = compose.build(project, "explode")
		eq(nil, argv)
		eq("Unknown compose action: explode", err)
	end)
end)

describe("compose.base_cmd", function()
	it("prefers `docker compose`, falls back to docker-compose", function()
		compose.base_cmd = real_base
		local expected = vim.fn.executable("docker") == 1 and { "docker", "compose" } or { "docker-compose" }
		eq(expected, compose.base_cmd())
		compose.base_cmd = function()
			return { "docker", "compose" }
		end
	end)
end)
