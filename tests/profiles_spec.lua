local profiles = require("dockyard.commands.profiles")

describe("profiles.parse_at", function()
	it("reads an inline list", function()
		eq({ "debug", "e2e" }, profiles.parse_at({ "    profiles: [debug, 'e2e']" }, 1))
		eq({ "debug" }, profiles.parse_at({ '    profiles: ["debug"]  # dev only' }, 1))
	end)

	it("reads a block list, skipping comments and blank lines", function()
		local lines = {
			"    profiles:",
			"      - debug",
			"      # a comment",
			"",
			"      - \"tools\"",
			"    image: x",
		}
		eq({ "debug", "tools" }, profiles.parse_at(lines, 1))
	end)

	it("returns nothing for other keys", function()
		eq({}, profiles.parse_at({ "    image: x" }, 1))
	end)
end)

describe("profiles.scan", function()
	it("collects every profile of the file, sorted and unique", function()
		local lines = {
			"services:",
			"  api:",
			"    image: x",
			"  adminer:",
			"    profiles: [debug]",
			"  seed:",
			"    profiles:",
			"      - tools",
			"      - debug",
		}
		eq({ "debug", "tools" }, profiles.scan(lines))
	end)
end)

describe("profiles.parse_output", function()
	it("reads one profile per line", function()
		eq({ "debug", "tools" }, profiles.parse_output("tools\ndebug\n\n"))
		eq({}, profiles.parse_output(""))
	end)
end)

describe("profiles.detect", function()
	it("answers with no profile for a file that does not exist", function()
		local got
		profiles.detect("/definitely/not/here/compose.yml", function(list, source)
			got = { list, source }
		end)
		vim.wait(10000, function()
			return got ~= nil
		end)
		truthy(got, "detect never answered")
		eq({}, got[1])
		eq("scan", got[2])
	end)

	it("falls back to a text scan when docker cannot read the file", function()
		local dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
		local file = dir .. "/compose.yml"
		-- an unset required variable makes `docker compose config` fail
		vim.fn.writefile({
			"services:",
			"  api:",
			"    image: ${MISSING_VAR:?must be set}",
			"    profiles: [debug]",
		}, file)
		local got
		profiles.detect(file, function(list, source)
			got = { list, source }
		end)
		vim.wait(10000, function()
			return got ~= nil
		end)
		truthy(got, "detect never answered")
		eq({ "debug" }, got[1])
		-- without docker the answer is the scan as well
		truthy(got[2] == "scan" or got[2] == "config")
	end)
end)
