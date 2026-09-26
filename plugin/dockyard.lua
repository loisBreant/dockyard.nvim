if vim.g.loaded_dockyard then
	return
end
vim.g.loaded_dockyard = true

-- Keep this file cheap: modules are only required when something is used.

local function cli()
	return require("dockyard.commands.cli")
end

local function complete_as(prefix)
	return function(lead, cmdline)
		return cli().complete(lead, (cmdline:gsub("^%S+", prefix)))
	end
end

vim.api.nvim_create_user_command("Dockyard", function(opts)
	cli().dispatch(opts)
end, { nargs = "*", range = true, complete = complete_as("Dockyard") })

-- older standalone commands
local aliases = {
	DockyardFloat = "open float",
	DockyardFull = "open tab",
	DockyardPick = "pick",
	DockyardBuild = "build",
	DockyardRun = "run",
	DockyardService = "service",
	DockyardFiles = "files",
	DockyardLogs = "logs",
}
for name, sub in pairs(aliases) do
	vim.api.nvim_create_user_command(name, function(opts)
		opts.fargs = vim.list_extend(vim.split(sub, " "), opts.fargs)
		cli().dispatch(opts)
	end, { nargs = "*", range = true, complete = complete_as("Dockyard " .. sub) })
end

local plugs = {
	open = "open",
	float = "open float",
	pick = "pick",
	build = "build",
	run = "run",
}
for _, action in ipairs({ "run", "stop", "restart", "build", "logs", "shell", "open" }) do
	plugs["service-" .. action] = "service " .. action
end
for name, sub in pairs(plugs) do
	vim.keymap.set("n", "<Plug>(dockyard-" .. name .. ")", function()
		cli().dispatch({ fargs = vim.split(sub, " "), range = 0 })
	end, { desc = "Dockyard " .. sub })
end

local group = vim.api.nvim_create_augroup("Dockyard", {})

local compose_files = {
	"docker-compose.yml",
	"docker-compose.yaml",
	"compose.yml",
	"compose.yaml",
	"docker-compose.*.yml",
	"docker-compose.*.yaml",
	"compose.*.yml",
	"compose.*.yaml",
}
local dockerfiles = { "Dockerfile", "Dockerfile.*", "*.Dockerfile", "*.dockerfile" }

local function on_open(patterns, module)
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufFilePost" }, {
		group = group,
		pattern = patterns,
		callback = function(args)
			require(module).maybe_attach(args.buf)
		end,
	})
end
on_open(compose_files, "dockyard.compose_lens")
on_open(dockerfiles, "dockyard.dockerfile_lens")

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

vim.api.nvim_create_autocmd("ColorScheme", {
	group = group,
	callback = function()
		if package.loaded["dockyard.ui.highlights"] then
			require("dockyard.ui.highlights").setup()
		end
	end,
})

-- buffers already open when a plugin manager loads us late
local function matches(name, patterns)
	for _, pattern in ipairs(patterns) do
		if vim.fn.match(name, vim.fn.glob2regpat(pattern)) == 0 then
			return true
		end
	end
	return false
end
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
	local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
	if vim.api.nvim_buf_is_loaded(buf) and name ~= "" then
		if matches(name, compose_files) then
			require("dockyard.compose_lens").maybe_attach(buf)
		elseif matches(name, dockerfiles) then
			require("dockyard.dockerfile_lens").maybe_attach(buf)
		end
	end
end
