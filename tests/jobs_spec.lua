local runner = require("dockyard.commands.runner")
local output = require("dockyard.ui.views.jobs.output")
local renderer = require("dockyard.ui.views.jobs.renderer")

local function wait_done(job)
	vim.wait(10000, function()
		return job.status ~= "running"
	end, 10)
	truthy(job.status ~= "running", "job never finished")
end

local function fake(fields)
	return vim.tbl_extend("force", {
		id = 1,
		title = "compose up api",
		argv = { "docker", "compose", "up", "-d", "api" },
		cwd = "/p",
		status = "ok",
		code = 0,
		started_at = 0,
		started_time = 0,
		ended_at = 3.2e9,
		lines = {},
		omitted = 0,
	}, fields or {})
end

describe("jobs view rows", function()
	it("shows status, duration, command and directory", function()
		local rows = renderer.build_rows({ fake(), fake({ id = 2, status = "failed", code = 1 }) })
		eq("✔ ok", rows[1].status)
		eq("3.2s", rows[1].duration)
		eq("compose up api", rows[1].title)
		eq("✖ failed", rows[2].status)
		eq("DockyardStopped", rows[2]._hl)
		eq("job", rows[1]._item.kind)
		eq(1, rows[1]._item.item.id)
	end)
end)

describe("job output", function()
	it("has the command, the directory, the output and how it ended", function()
		local lines = output.build(fake({ lines = { "one", "two" }, status = "failed", code = 3 }))
		eq("$ docker compose up -d api", lines[1])
		eq("# in /p", lines[2])
		eq({ "one", "two" }, vim.list_slice(lines, 4, 5))
		eq("✖ failed · exit 3 · 3.2s", lines[#lines])
	end)

	it("says how many lines were dropped", function()
		local lines = output.build(fake({ lines = { "x" }, omitted = 12 }))
		eq("… 12 earlier lines omitted", lines[4])
	end)
end)

describe("job output buffer", function()
	it("opens on a job, follows its output and closes with q", function()
		local job = runner.start({ argv = { "sh", "-c", "printf 'a%s\\n' 1; sleep 0.2; printf 'b%s\\n' 2" } })
		output.open(job.id)
		local buf = vim.api.nvim_get_current_buf()
		eq("dockyardjob", vim.bo[buf].filetype)
		wait_done(job)
		vim.wait(500, function()
			return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("b2", 1, true) ~= nil
		end, 20)
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		truthy(text:find("a1", 1, true), text)
		truthy(text:find("b2", 1, true), text)
		truthy(text:find("✔ ok · exit 0", 1, true), text)
		vim.cmd("normal q")
		eq(false, vim.api.nvim_buf_is_valid(buf))
	end)
end)

describe("job output with odd bytes", function()
	it("opens without error when the output is not valid UTF-8", function()
		local job = runner.start({ argv = { "sh", "-c", "printf '\\377\\376 bytes\\n'" } })
		wait_done(job)
		output.open(job.id)
		local buf = vim.api.nvim_get_current_buf()
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		truthy(text:find(" bytes", 1, true), text)
		vim.cmd("normal q")
	end)
end)

describe("Jobs in the dashboard", function()
	it("refuses to open when the user left the view out of display.views", function()
		local config = require("dockyard.config")
		local state = require("dockyard.ui.state")
		local views = config.options.display.views
		config.options.display.views = { "containers", "images" }
		local msg
		local orig = vim.notify
		vim.notify = function(m)
			msg = m
		end
		require("dockyard.ui").open_view("jobs")
		vim.notify = orig
		config.options.display.views = views
		truthy(msg and msg:find("display.views", 1, true), tostring(msg))
		eq(nil, state.win_id)
	end)

	it("is a view of the dashboard, listing the jobs", function()
		local ui = require("dockyard.ui")
		local state = require("dockyard.ui.state")
		local job = runner.start({ argv = { "sh", "-c", "exit 0" }, title = "visible job" })
		wait_done(job)
		ui.open_view("jobs")
		vim.wait(500)
		eq("jobs", state.current_view)
		local text = table.concat(vim.api.nvim_buf_get_lines(state.buf_id, 0, -1, false), "\n")
		truthy(text:find("visible job", 1, true), text)
		truthy(text:find("Jobs", 1, true), text)
		ui.close()
	end)
end)

describe(":Dockyard job commands", function()
	local cli = require("dockyard.commands.cli")

	it("completes ids and last", function()
		local job = runner.start({ argv = { "sh", "-c", "exit 0" } })
		wait_done(job)
		local items = cli.complete("", "Dockyard job ")
		truthy(vim.tbl_contains(items, "last"))
		truthy(vim.tbl_contains(items, tostring(job.id)))
	end)

	it("lists the new subcommands", function()
		local items = cli.complete("", "Dockyard ")
		for _, name in ipairs({ "jobs", "job", "rerun" }) do
			truthy(vim.tbl_contains(items, name), name)
		end
	end)
end)
