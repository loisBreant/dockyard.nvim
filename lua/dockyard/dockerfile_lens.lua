-- Build / Build & Run buttons on the last FROM line of Dockerfiles.

local context = require("dockyard.commands.context")
local builder = require("dockyard.commands.builder")
local executor = require("dockyard.commands.executor")
local lens = require("dockyard.lens")

local M = {}

local group = vim.api.nvim_create_augroup("DockyardDockerfileLens", { clear = true })

---@param buf integer
---@return integer|nil
function M.final_from(buf)
	local found = nil
	for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:match("^%s*[Ff][Rr][Oo][Mm]%s") then
			found = i
		end
	end
	return found
end

local function render(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local lines = {}
	local lnum = M.final_from(buf)
	if lnum then
		local file = vim.api.nvim_buf_get_name(buf)
		local tag = builder.image_tag(vim.fn.fnamemodify(file, ":h"))
		lines[lnum] = lens.line()
			:add("⟳ Build " .. tag, "DockyardLensAction", { action = "build" })
			:add("▶ Build & Run", "DockyardLensRun", { action = "build_run" })
	end
	lens.render(buf, lines)
end

local function run_image(tag)
	vim.cmd("botright 15split")
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(0, buf)
	local cmd = { "docker", "run", "--rm", "-it", "-P", tag }
	if vim.fn.has("nvim-0.11") == 1 then
		vim.fn.jobstart(cmd, { term = true })
	else
		---@diagnostic disable-next-line: deprecated -- Neovim 0.10 fallback
		vim.fn.termopen(cmd)
	end
	vim.cmd.startinsert()
end

---@param buf integer
---@param action "build"|"build_run"
function M.run_action(buf, action)
	if vim.bo[buf].modified then
		vim.api.nvim_buf_call(buf, function()
			vim.cmd("silent! write")
		end)
	end
	local file = vim.api.nvim_buf_get_name(buf)
	local dir = vim.fn.fnamemodify(file, ":h")
	local args, err = builder.build_cmd({ type = "dockerfile", file = file, dir = dir })
	if not args then
		vim.notify("Dockyard: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	local tag = builder.image_tag(dir)
	executor.run(args, {
		cwd = dir,
		title = "docker build " .. tag,
		on_exit = function(ok)
			if ok and action == "build_run" then
				run_image(tag)
			end
		end,
	})
end

local function attach(buf)
	if vim.b[buf].dockyard_lens then
		return
	end
	vim.b[buf].dockyard_lens = true

	lens.attach(buf, function(data)
		M.run_action(buf, data.action)
	end)
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter" }, {
		group = group,
		buffer = buf,
		callback = function()
			render(buf)
		end,
	})
	render(buf)
end

---@param buf integer
function M.maybe_attach(buf)
	if not require("dockyard.config").options.compose_lens.enabled then
		return
	end
	local name = vim.api.nvim_buf_get_name(buf)
	if name ~= "" and vim.bo[buf].buftype == "" and context.is_dockerfile(name) then
		attach(buf)
	end
end

return M
