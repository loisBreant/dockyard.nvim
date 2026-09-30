-- Runs commands and remembers them: command line, status, duration and the whole output.
-- No UI here; the notice, the Jobs view and the output buffer read from this registry.

local M = {}

---@class DockyardJob
---@field id integer
---@field title string
---@field argv string[]
---@field cwd string|nil
---@field status "running"|"ok"|"failed"|"cancelled"
---@field code integer|nil
---@field started_at integer vim.uv.hrtime()
---@field started_time integer os.time(), for display
---@field ended_at integer|nil
---@field lines string[] output, stdout and stderr interleaved
---@field omitted integer lines dropped from the start of `lines`
---@field project string|nil preferences key of the compose project

---@class DockyardJobSpec
---@field argv string[]
---@field cwd? string
---@field title? string
---@field project? string
---@field on_exit? fun(job: DockyardJob)

local MAX_LINES = 5000
local TRIM_STEP = 500

---@type table<integer, DockyardJob>
local jobs = {}
---@type integer[] oldest first
local order = {}
---@type table<integer, vim.SystemObj>
local procs = {}
---@type table<integer, DockyardJobSpec>
local specs = {}
---@type table<integer, table<"out"|"err", string>> unfinished last line of each stream
local partial = {}
local listeners = {}
local next_id = 1

---@param fn fun(job: DockyardJob|nil) called on every change; nil = the list changed
---@return fun() unsubscribe
function M.subscribe(fn)
	table.insert(listeners, fn)
	return function()
		for i, l in ipairs(listeners) do
			if l == fn then
				table.remove(listeners, i)
				return
			end
		end
	end
end

local function emit(job)
	for _, fn in ipairs(vim.list_slice(listeners)) do
		pcall(fn, job)
	end
	pcall(vim.api.nvim_exec_autocmds, "User", {
		pattern = "DockyardJobChanged",
		data = { id = job and job.id or nil },
		modeline = false,
	})
end

local function history_limit()
	local opts = require("dockyard.config").options.jobs
	return opts and opts.history or 50
end

local function evict()
	local limit = history_limit()
	local i = 1
	while #order > limit and i <= #order do
		local id = order[i]
		if jobs[id].status ~= "running" then
			table.remove(order, i)
			jobs[id], specs[id], partial[id] = nil, nil, nil
		else
			i = i + 1
		end
	end
end

local function clean(line)
	-- a carriage return redraws the line: keep what was written last
	line = line:match("([^\r]*)\r*$") or line
	return (line:gsub("\27%[[%d;?]*%a", ""))
end

local function add_line(job, line)
	table.insert(job.lines, line)
	if #job.lines > MAX_LINES + TRIM_STEP then
		for _ = 1, TRIM_STEP do
			table.remove(job.lines, 1)
		end
		job.omitted = job.omitted + TRIM_STEP
	end
end

local function ingest(job, stream, chunk)
	local text = (partial[job.id][stream] or "") .. chunk
	local parts = vim.split(text, "\n", { plain = true })
	partial[job.id][stream] = table.remove(parts)
	for _, line in ipairs(parts) do
		add_line(job, clean(line))
	end
	emit(job)
end

local function flush(job)
	for _, stream in ipairs({ "out", "err" }) do
		local rest = partial[job.id] and partial[job.id][stream]
		if rest and rest ~= "" then
			add_line(job, clean(rest))
		end
		if partial[job.id] then
			partial[job.id][stream] = ""
		end
	end
end

local function finish(job, code, signal)
	if not jobs[job.id] then
		return
	end
	flush(job)
	procs[job.id] = nil
	job.code = code
	job.ended_at = vim.uv.hrtime()
	if job.status == "running" then
		job.status = code == 0 and "ok" or "failed"
		if signal and signal ~= 0 then
			add_line(job, ("(killed by signal %d)"):format(signal))
		end
	end
	local spec = specs[job.id]
	emit(job)
	if spec and spec.on_exit then
		pcall(spec.on_exit, job)
	end
	evict()
end

---@param spec DockyardJobSpec
---@return DockyardJob
function M.start(spec)
	local job = {
		id = next_id,
		title = spec.title or table.concat(spec.argv, " "),
		argv = vim.deepcopy(spec.argv),
		cwd = spec.cwd,
		status = "running",
		started_at = vim.uv.hrtime(),
		started_time = os.time(),
		lines = {},
		omitted = 0,
		project = spec.project,
	}
	next_id = next_id + 1
	jobs[job.id] = job
	specs[job.id] = spec
	partial[job.id] = { out = "", err = "" }
	table.insert(order, job.id)

	local function reader(stream)
		return function(_, data)
			if data then
				vim.schedule(function()
					if jobs[job.id] then
						ingest(job, stream, data)
					end
				end)
			end
		end
	end

	local ok, proc = pcall(vim.system, spec.argv, {
		cwd = spec.cwd,
		text = true,
		stdout = reader("out"),
		stderr = reader("err"),
	}, function(result)
		vim.schedule(function()
			finish(job, result.code, result.signal)
		end)
	end)
	if ok then
		procs[job.id] = proc
	else
		add_line(job, tostring(proc))
		vim.schedule(function()
			finish(job, 127, nil)
		end)
	end
	emit(nil)
	emit(job)
	return job
end

---@param id integer
---@return DockyardJob|nil
function M.get(id)
	return jobs[id]
end

---@return DockyardJob|nil the most recent job
function M.last()
	return jobs[order[#order]]
end

---@return DockyardJob[] newest first
function M.list()
	local out = {}
	for i = #order, 1, -1 do
		table.insert(out, jobs[order[i]])
	end
	return out
end

---The output of a job, with a first line saying how much was dropped.
---@param job DockyardJob
---@return string[]
function M.output(job)
	if job.omitted == 0 then
		return vim.list_slice(job.lines)
	end
	local out = { ("… %d earlier lines omitted"):format(job.omitted) }
	vim.list_extend(out, job.lines)
	return out
end

---@param id integer
---@return boolean cancelled
function M.cancel(id)
	local job, proc = jobs[id], procs[id]
	if not job or job.status ~= "running" or not proc then
		return false
	end
	job.status = "cancelled"
	proc:kill(15)
	emit(job)
	return true
end

---@param id integer
---@return DockyardJob|nil the new job
function M.rerun(id)
	local spec = specs[id]
	if not spec then
		return nil
	end
	return M.start(spec)
end

---Forget the jobs that are over.
function M.clear_finished()
	local kept = {}
	for _, id in ipairs(order) do
		if jobs[id].status == "running" then
			table.insert(kept, id)
		else
			jobs[id], specs[id], partial[id] = nil, nil, nil
		end
	end
	order = kept
	emit(nil)
end

---@param job DockyardJob
---@return number seconds
function M.duration(job)
	return ((job.ended_at or vim.uv.hrtime()) - job.started_at) / 1e9
end

---@param seconds number
---@return string
function M.format_duration(seconds)
	if seconds < 1 then
		return ("%dms"):format(math.floor(seconds * 1000))
	elseif seconds < 60 then
		return ("%.1fs"):format(seconds)
	end
	return ("%dm %02ds"):format(math.floor(seconds / 60), math.floor(seconds % 60))
end

---The command as one line, quoting the arguments that need it.
---@param argv string[]
---@return string
function M.format_cmd(argv)
	local parts = {}
	for _, arg in ipairs(argv) do
		table.insert(parts, arg:match("^[%w_%-%./:=@%%+,]+$") and arg or vim.fn.shellescape(arg))
	end
	return table.concat(parts, " ")
end

vim.api.nvim_create_autocmd("VimLeavePre", {
	group = vim.api.nvim_create_augroup("DockyardRunnerCleanup", { clear = true }),
	callback = function()
		for _, proc in pairs(procs) do
			pcall(proc.kill, proc, 15)
		end
	end,
})

return M
