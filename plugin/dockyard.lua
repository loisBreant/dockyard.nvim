-- Entry point: commands, <Plug> mappings and file triggers. Nothing is
-- required until one of them is used, so this costs nothing at startup and
-- the plugin works without setup() or plugin-manager lazy-loading rules.

if vim.g.loaded_dockyard then
	return
end
vim.g.loaded_dockyard = true

local function cli()
	return require("dockyard.commands.cli")
end

vim.api.nvim_create_user_command("Dockyard", function(opts)
	cli().dispatch(opts)
end, {
	desc = "Dockyard: dashboard, or pick | files | logs | build | run | service",
	nargs = "*",
	range = true,
	complete = function(lead, cmdline)
		return cli().complete(lead, cmdline)
	end,
})

-- Standalone commands from before the :Dockyard subcommands, kept working.
local legacy = {
	DockyardFloat = { "open float", "Open the Dockyard dashboard in a float" },
	DockyardFull = { "open tab", "Open the Dockyard dashboard in a tab" },
	DockyardPick = { "pick", "Pick a container and act on it" },
	DockyardBuild = { "build", "Build the image of the current Dockerfile" },
}
for name, spec in pairs(legacy) do
	vim.api.nvim_create_user_command(name, function(opts)
		cli().dispatch(vim.tbl_extend("force", opts, { fargs = vim.split(spec[1], " ") }))
	end, { desc = spec[2] })
end
vim.api.nvim_create_user_command("DockyardRun", function(opts)
	cli().run(opts)
end, { desc = "docker compose up (all services, or those in the range)", range = true })
vim.api.nvim_create_user_command("DockyardService", function(opts)
	cli().service(opts.fargs[1])
end, {
	desc = "Act on the compose service under the cursor",
	nargs = "?",
	complete = function(lead)
		return cli().subcommands.service.complete(lead, {})
	end,
})
vim.api.nvim_create_user_command("DockyardFiles", function(opts)
	cli().subcommands.files.impl(opts.fargs, opts)
end, {
	desc = "Browse a container's filesystem",
	nargs = "+",
	complete = function(lead, cmdline)
		return cli().complete(lead, (cmdline:gsub("^%S*DockyardFiles", "Dockyard files")))
	end,
})
vim.api.nvim_create_user_command("DockyardLogs", function(opts)
	cli().logs(opts.fargs[1])
end, {
	desc = "Open LogLens for a container",
	nargs = 1,
	complete = function(lead, cmdline)
		return cli().complete(lead, (cmdline:gsub("^%S*DockyardLogs", "Dockyard logs")))
	end,
})

-- <Plug> mappings, for users to bind: vim.keymap.set("n", "<leader>dp", "<Plug>(dockyard-pick)")
local plugs = {
	["dockyard-open"] = function()
		cli().open()
	end,
	["dockyard-float"] = function()
		cli().open("float")
	end,
	["dockyard-pick"] = function()
		require("dockyard.picker").pick()
	end,
	["dockyard-build"] = function()
		require("dockyard.commands").build()
	end,
	["dockyard-run"] = function()
		cli().run()
	end,
}
for _, action in ipairs({ "run", "stop", "restart", "build", "logs", "shell", "open" }) do
	plugs["dockyard-service-" .. action] = function()
		cli().service(action)
	end
end
for name, fn in pairs(plugs) do
	vim.keymap.set("n", "<Plug>(" .. name .. ")", fn, { desc = "Dockyard: " .. name:gsub("^dockyard%-", "") })
end

local group = vim.api.nvim_create_augroup("Dockyard", { clear = true })

-- clickable actions in compose files and Dockerfiles
local compose_patterns = {
	"docker-compose.yml",
	"docker-compose.yaml",
	"compose.yml",
	"compose.yaml",
	"docker-compose.*.yml",
	"docker-compose.*.yaml",
	"compose.*.yml",
	"compose.*.yaml",
}
local dockerfile_patterns = { "Dockerfile", "Dockerfile.*", "*.Dockerfile", "*.dockerfile" }

vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufFilePost" }, {
	group = group,
	pattern = compose_patterns,
	callback = function(args)
		require("dockyard.compose_lens").maybe_attach(args.buf)
	end,
})
vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufFilePost" }, {
	group = group,
	pattern = dockerfile_patterns,
	callback = function(args)
		require("dockyard.dockerfile_lens").maybe_attach(args.buf)
	end,
})

-- container files: :edit dockyard://<container>/<path>
vim.api.nvim_create_autocmd("BufReadCmd", {
	group = group,
	pattern = "dockyard://*",
	callback = function(args)
		require("dockyard.files").read_cmd(args)
	end,
})
vim.api.nvim_create_autocmd("BufWriteCmd", {
	group = group,
	pattern = "dockyard://*",
	callback = function(args)
		require("dockyard.files").write_cmd(args)
	end,
})

-- colour schemes clear highlight groups; restore ours once they are in use
vim.api.nvim_create_autocmd("ColorScheme", {
	group = group,
	callback = function()
		if package.loaded["dockyard.ui.highlights"] then
			require("dockyard.ui.highlights").setup()
		end
	end,
})

-- files already open when the plugin loads (e.g. lazy-loaded by a plugin manager)
local function matches_any(name, patterns)
	for _, pattern in ipairs(patterns) do
		if vim.fn.match(name, vim.fn.glob2regpat(pattern)) == 0 then
			return true
		end
	end
	return false
end
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
	local name = vim.api.nvim_buf_is_loaded(buf) and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t") or ""
	if name ~= "" and matches_any(name, compose_patterns) then
		require("dockyard.compose_lens").maybe_attach(buf)
	elseif name ~= "" and matches_any(name, dockerfile_patterns) then
		require("dockyard.dockerfile_lens").maybe_attach(buf)
	end
end
