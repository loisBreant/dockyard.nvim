local context = require("dockyard.commands.context")

describe("is_compose_file", function()
	it("accepts the standard names and their variants", function()
		for _, name in ipairs({
			"docker-compose.yml",
			"docker-compose.yaml",
			"compose.yml",
			"compose.yaml",
			"docker-compose.dev.yml",
			"compose.override.yaml",
			"/some/dir/compose.prod.yml",
		}) do
			truthy(context.is_compose_file(name), name)
		end
	end)

	it("rejects other yaml files", function()
		for _, name in ipairs({ "config.yml", "my-compose.yml", "compose.json", "docker-compose.yml.bak" }) do
			eq(false, context.is_compose_file(name), name)
		end
	end)
end)

describe("is_dockerfile", function()
	it("accepts Dockerfile, Dockerfile.* and *.Dockerfile", function()
		for _, name in ipairs({ "Dockerfile", "Dockerfile.dev", "api.Dockerfile", "worker.dockerfile" }) do
			truthy(context.is_dockerfile(name), name)
		end
	end)

	it("rejects lookalikes", function()
		for _, name in ipairs({ "Dockerfile-notes.md", "dockerfile.go", ".dockerignore" }) do
			eq(false, context.is_dockerfile(name), name)
		end
	end)
end)

describe("compose_services profiles", function()
	it("reads inline and block profiles of each service", function()
		local block = context.compose_services(buffer({
			"services:",
			"  api:",
			"    image: x",
			"  adminer:",
			"    profiles: [debug]",
			"  seed:",
			"    profiles:",
			"      - tools",
			"      - debug",
		}))
		eq({}, block.services[1].profiles)
		eq({ "debug" }, block.services[2].profiles)
		eq({ "tools", "debug" }, block.services[3].profiles)
	end)
end)

describe("compose_services", function()
	local lines = {
		"name: demo", -- 1
		"services:", -- 2
		"    # the api", -- 3
		"    api:", -- 4
		"        build: .", -- 5
		"        environment:", -- 6
		"            build: not-a-key-of-the-service", -- 7
		"", -- 8
		"    db:", -- 9
		"        image: postgres", -- 10
		"volumes:", -- 11
		"    data:", -- 12
	}

	it("finds services at the file's own indentation", function()
		local block = context.compose_services(buffer(lines))
		eq(2, block.lnum)
		eq(10, block.end_lnum)
		eq({ "api", "db" }, vim.tbl_map(function(s)
			return s.name
		end, block.services))
		eq({ 4, 9 }, vim.tbl_map(function(s)
			return s.lnum
		end, block.services))
	end)

	it("only counts build: at the service's own key level", function()
		local block = context.compose_services(buffer(lines))
		eq(true, block.services[1].has_build)
		eq(false, block.services[2].has_build)
	end)

	it("handles two-space indentation and names with dots and dashes", function()
		local block = context.compose_services(buffer({ "services:", "  web-1:", "    image: x", "  api.v2:", "    image: y" }))
		eq({ "web-1", "api.v2" }, vim.tbl_map(function(s)
			return s.name
		end, block.services))
	end)

	it("returns nothing without a services block", function()
		local block = context.compose_services(buffer({ "version: '3'", "volumes:", "  data:" }))
		eq(nil, block.lnum)
		eq({}, block.services)
	end)
end)

describe("service_at_cursor / services_in_range", function()
	local lines = {
		"services:",
		"  api:",
		"    image: api",
		"  db:",
		"    image: db",
		"volumes:",
		"  data:",
	}

	local function with_cursor(lnum, fn)
		local buf = buffer(lines, vim.fn.tempname() .. "/docker-compose.yml")
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_win_set_cursor(0, { lnum, 0 })
		fn()
		vim.api.nvim_buf_delete(buf, { force = true })
	end

	it("finds the service the cursor is in", function()
		with_cursor(3, function()
			eq("api", context.service_at_cursor())
		end)
		with_cursor(4, function()
			eq("db", context.service_at_cursor())
		end)
	end)

	it("returns nil outside the services block", function()
		with_cursor(1, function()
			eq(nil, context.service_at_cursor())
		end)
		with_cursor(7, function()
			eq(nil, context.service_at_cursor())
		end)
	end)

	it("lists the services whose key is in the range", function()
		with_cursor(1, function()
			eq({ "api", "db" }, context.services_in_range(1, 5))
			eq({ "db" }, context.services_in_range(3, 5))
		end)
	end)
end)
