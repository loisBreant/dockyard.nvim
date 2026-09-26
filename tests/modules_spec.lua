describe("plugin/dockyard.lua", function()
	it("registers the commands without setup()", function()
		vim.cmd.runtime("plugin/dockyard.lua")
		for _, cmd in ipairs({ "Dockyard", "DockyardFloat", "DockyardRun", "DockyardService", "DockyardPick", "DockyardFiles", "DockyardLogs" }) do
			eq(2, vim.fn.exists(":" .. cmd), cmd)
		end
	end)

	it("defines the <Plug> mappings", function()
		for _, name in ipairs({ "dockyard-open", "dockyard-pick", "dockyard-service-run", "dockyard-service-open" }) do
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
