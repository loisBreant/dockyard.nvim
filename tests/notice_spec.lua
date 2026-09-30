local config = require("dockyard.config")
local notice = require("dockyard.ui.popups.job_notice")

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

describe("job notice", function()
	it("shows the command, the last five lines and a failure hint", function()
		local lines = {}
		for i = 1, 8 do
			table.insert(lines, "line " .. i)
		end
		local got = notice.build_lines(fake({ lines = lines, status = "failed", code = 2 }))
		eq(" $ docker compose up -d api", got[1])
		eq(" line 4", got[2])
		eq(" line 8", got[6])
		eq(" ✖ Failed (exit 2) · :Dockyard job last · q close", got[7])
	end)

	it("stays open for a failure and closes after a success", function()
		config.options.jobs.notice.close_after = 100
		local executor = require("dockyard.commands.executor")
		local function count_floats()
			return #vim.tbl_filter(function(w)
				return vim.api.nvim_win_get_config(w).relative ~= ""
			end, vim.api.nvim_list_wins())
		end

		local bad = executor.run({ "sh", "-c", "echo boom >&2; exit 2" }, { title = "bad" })
		wait_done(bad)
		vim.wait(400)
		eq(1, count_floats())
		notice.close()
		eq(0, count_floats())

		local good = executor.run({ "sh", "-c", "echo fine" }, { title = "good" })
		wait_done(good)
		eq(true, vim.wait(2000, function()
			return count_floats() == 0
		end, 20))
		config.options.jobs.notice.close_after = 3000
	end)

	it("calls on_exit with a boolean, as before", function()
		local executor = require("dockyard.commands.executor")
		local seen = {}
		local ok = executor.run({ "sh", "-c", "exit 0" }, { on_exit = function(v) seen.ok = v end })
		local ko = executor.run({ "sh", "-c", "exit 1" }, { on_exit = function(v) seen.ko = v end })
		wait_done(ok)
		wait_done(ko)
		vim.wait(1000, function()
			return seen.ok ~= nil and seen.ko ~= nil
		end)
		eq({ ok = true, ko = false }, seen)
		notice.close()
	end)
end)

