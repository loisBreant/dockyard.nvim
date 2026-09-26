local compose_lens = require("dockyard.compose_lens")

-- the visible text of a lens line, separators trimmed
local function text(line)
	local parts = {}
	for _, chunk in ipairs(line.chunks) do
		table.insert(parts, chunk[1])
	end
	return vim.trim(table.concat(parts))
end

local function actions(line)
	return vim.tbl_map(function(b)
		return b.data.action
	end, line.buttons)
end

describe("parse_ps", function()
	local api = '{"Service":"api","State":"running","Name":"demo-api-1","Health":"healthy",'
		.. '"Publishers":[{"URL":"0.0.0.0","TargetPort":80,"PublishedPort":8080,"Protocol":"tcp"},'
		.. '{"URL":"::","TargetPort":80,"PublishedPort":8080,"Protocol":"tcp"},'
		.. '{"URL":"","TargetPort":53,"PublishedPort":5353,"Protocol":"udp"},'
		.. '{"URL":"","TargetPort":9000,"PublishedPort":0,"Protocol":"tcp"}]}'
	local db = '{"Service":"db","State":"exited","Name":"demo-db-1","Health":"","Publishers":null}'

	it("reads one object per line", function()
		local out = compose_lens.parse_ps(api .. "\n" .. db .. "\n")
		eq({ state = "running", name = "demo-api-1", health = "healthy", ports = { 8080 } }, out.api)
		eq({ state = "exited", name = "demo-db-1", health = "", ports = {} }, out.db)
	end)

	it("reads a JSON array (older compose versions)", function()
		local out = compose_lens.parse_ps("[" .. api .. "," .. db .. "]")
		eq("running", out.api.state)
		eq("exited", out.db.state)
	end)

	it("ignores garbage", function()
		eq({}, compose_lens.parse_ps("not json\n"))
		eq({}, compose_lens.parse_ps(""))
	end)
end)

describe("build_lines", function()
	local buf = buffer({
		"services:",
		"  api:",
		"    build: .",
		"  db:",
		"    image: postgres",
		"  cache:",
		"    image: redis",
	})

	it("shows Run for services that are not up, Build where there is a build section", function()
		local lines = compose_lens.build_lines(buf, {})
		eq("▶ Run  ⟳ Build", text(lines[2]))
		eq({ "run", "build" }, actions(lines[2]))
		eq("▶ Run", text(lines[4]))
		eq("▶▶ Run all  ⟳ Build all", text(lines[1]))
	end)

	it("shows the state, actions and ports of running services", function()
		local lines = compose_lens.build_lines(buf, {
			db = { state = "running", name = "demo-db-1", health = "healthy", ports = { 5432 } },
			cache = { state = "exited", name = "demo-cache-1", health = "", ports = {} },
		})
		eq("● healthy  ↻ Restart  ■ Stop  ≡ Logs   Shell  ↗ :5432", text(lines[4]))
		eq({ "restart", "stop", "logs", "shell", "open" }, actions(lines[4]))
		eq(5432, lines[4].buttons[5].data.port)
		eq("○ exited  ▶ Run", text(lines[6]))
		eq("▶▶ Run all  ■ Stop all  ⟳ Build all  ▼ Down", text(lines[1]))
	end)

	it("colours the health state", function()
		local lines = compose_lens.build_lines(buf, {
			db = { state = "running", name = "x", health = "unhealthy", ports = {} },
		})
		eq({ "● unhealthy", "DockyardStopped" }, lines[4].chunks[2])
	end)

	it("has no lens without services", function()
		eq({}, compose_lens.build_lines(buffer({ "volumes:", "  data:" }), {}))
	end)
end)
