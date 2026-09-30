describe("plugin/dockyard.lua", function()
	it("registers the commands without setup()", function()
		vim.cmd.runtime("plugin/dockyard.lua")
		for _, cmd in ipairs({ "Dockyard", "DockyardFloat", "DockyardRun", "DockyardService", "DockyardPick", "DockyardFiles", "DockyardLogs" }) do
			eq(2, vim.fn.exists(":" .. cmd), cmd)
		end
	end)

	it("defines the <Plug> mappings", function()
		for _, name in ipairs({
			"dockyard-open",
			"dockyard-pick",
			"dockyard-service-run",
			"dockyard-service-open",
			"dockyard-jobs",
			"dockyard-job-last",
			"dockyard-compose",
		}) do
			truthy(vim.fn.maparg("<Plug>(" .. name .. ")", "n") ~= "", name)
		end
	end)

	it("does not load the plugin modules at startup", function()
		-- a fresh Neovim: this test process has already required modules
		local root = vim.fn.fnamemodify(vim.api.nvim_get_runtime_file("plugin/dockyard.lua", false)[1], ":h:h")
		local script = ("set rtp^=%s | runtime plugin/dockyard.lua | lua io.stdout:write(vim.inspect(vim.tbl_filter("
			.. "function(n) return n:match('^dockyard') ~= nil end, vim.tbl_keys(package.loaded))))"):format(root)
		local res = vim.system({ vim.v.progpath, "--clean", "--headless", "-c", script, "-c", "qa!" }, { text = true }):wait()
		eq("{}", vim.trim(res.stdout .. res.stderr))
	end)
end)

describe(":Dockyard completion", function()
	local cli = require("dockyard.commands.cli")

	it("offers subcommands and strategies", function()
		local items = cli.complete("", "Dockyard ")
		truthy(vim.tbl_contains(items, "pick"))
		truthy(vim.tbl_contains(items, "float"))
		eq({ "service" }, cli.complete("se", "Dockyard se"))
	end)

	it("completes service actions", function()
		eq({ "run", "restart" }, cli.complete("r", "Dockyard service r"))
	end)
end)

describe("config", function()
	local config = require("dockyard.config")

	it("accepts the defaults", function()
		eq({}, config.validate(config.defaults))
	end)

	it("reports wrong types", function()
		local opts = vim.tbl_deep_extend("force", vim.deepcopy(config.defaults), {
			display = { project_scope = "yes" },
			compose_lens = { enabled = "no" },
			keymaps = { containers = { filter = 3 } },
		})
		local errors = table.concat(config.validate(opts), "\n")
		truthy(errors:find("display.project_scope"), errors)
		truthy(errors:find("compose_lens.enabled"), errors)
		truthy(errors:find("keymaps.containers.filter"), errors)
	end)

	it("reports wrong jobs and compose options", function()
		local opts = vim.tbl_deep_extend("force", vim.deepcopy(config.defaults), {
			jobs = { history = "many", notice = { close_after = "soon" } },
			compose = { defaults = { build = "yes", pull = "sometimes" } },
		})
		local errors = table.concat(config.validate(opts), "\n")
		truthy(errors:find("jobs.history"), errors)
		truthy(errors:find("jobs.notice.close_after"), errors)
		truthy(errors:find("compose.defaults.build"), errors)
		truthy(errors:find("compose.defaults.pull"), errors)
	end)

	it("accepts a pull policy and knows the new options", function()
		local opts = vim.tbl_deep_extend("force", vim.deepcopy(config.defaults), { compose = { defaults = { pull = "always" } } })
		eq({}, config.validate(opts))
		eq({}, config.unknown_keys({ jobs = { history = 10 }, compose = { defaults = { build = true } }, keymaps = { jobs = { rerun = "R" } } }))
	end)

	it("has the Jobs view in the default views", function()
		truthy(vim.tbl_contains(config.defaults.display.views, "jobs"))
	end)

	it("finds unknown options but not container log configs", function()
		eq({ "compose_lense", "display.view" }, config.unknown_keys({
			display = { view = {} },
			compose_lense = {},
			loglens = { containers = { api = { anything = true } }, default_highlights = {} },
		}))
	end)
end)

describe("modules", function()
	it("every dockyard module loads", function()
		local root = vim.api.nvim_get_runtime_file("lua/dockyard/init.lua", false)[1]:gsub("/init%.lua$", "")
		for _, file in ipairs(vim.fn.globpath(root, "**/*.lua", false, true)) do
			local mod = file:gsub("^.*/lua/", ""):gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", ".")
			local ok, err = pcall(require, mod)
			truthy(ok, mod .. ": " .. tostring(err))
		end
	end)

	it("setup() merges options without registering anything itself", function()
		require("dockyard").setup({ display = { open_strategy = "float" } })
		eq("float", require("dockyard.config").options.display.open_strategy)
		eq("auto", require("dockyard.config").options.display.project_scope)
	end)
end)

describe("keymaps", function()
	it("the defaults of the Jobs view do not clash with each other or the general keys", function()
		eq({}, require("dockyard.core.keymaps").validate().jobs)
	end)

	it("every view has a filter, a clear and a scope key; Images prune moved to X", function()
		local keymaps = require("dockyard.config").defaults.keymaps
		for _, view in ipairs({ "images", "networks", "volumes", "jobs" }) do
			eq({ "F", "C", "P" }, { keymaps[view].filter, keymaps[view].clear_filter, keymaps[view].toggle_project_scope }, view)
		end
		eq("X", keymaps.images.prune)
	end)

	it("none of the views has clashing keys", function()
		local conflicts = require("dockyard.core.keymaps").validate()
		for _, view in ipairs({ "images", "networks", "volumes", "jobs", "containers" }) do
			eq({}, conflicts[view], view)
		end
	end)
end)
