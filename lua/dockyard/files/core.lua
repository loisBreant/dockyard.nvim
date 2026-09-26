local docker = require("dockyard.core.docker")

local M = {}

---@class DockyardFileEntry
---@field name string
---@field type "file"|"directory"|"link"
---@field kind string  Raw single-char type: f|d|l|o (other = device/socket/fifo)
---@field size integer
---@field mtime string|nil
---@field target string|nil  -- for symlinks

local function split_lines(s)
	if not s or s == "" then
		return {}
	end
	local lines = {}
	for line in (s .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

---@param container string
---@param argv string[]
---@param cb fun(res: { ok: boolean, stdout: string[], error?: string })
local function exec(container, argv, cb)
	local args = { "exec", container }
	vim.list_extend(args, argv)
	docker.run(args, function(res)
		cb({
			ok = res.ok,
			stdout = res.ok and split_lines(res.data) or {},
			error = res.error,
		})
	end)
end

-- kind: f (file) | d (dir) | l (link) | o (other: char/block/socket/fifo)
local LIST_SCRIPT = [[
cd "$1" 2>/dev/null || exit 0
for f in .[!.]* ..?* *; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  case "$f" in .|..) continue ;; esac
  if [ -L "$f" ]; then
    kind=l; target=$(readlink -- "$f" 2>/dev/null)
  elif [ -d "$f" ]; then
    kind=d; target=
  elif [ -f "$f" ]; then
    kind=f; target=
  else
    kind=o; target=
  fi
  size=$(stat -c %s -- "$f" 2>/dev/null) || size=0
  mtime=$(stat -c %y -- "$f" 2>/dev/null); mtime=${mtime%%.*}
  printf '%s|%s|%s|%s|%s\n' "$kind" "$size" "$mtime" "$target" "$f"
done
]]

---@param container string
---@param path string
---@param cb fun(res: { ok: boolean, entries?: DockyardFileEntry[], error?: string })
function M.list(container, path, cb)
	docker.run({ "exec", container, "sh", "-c", LIST_SCRIPT, "sh", path }, function(res)
		if not res.ok then
			return cb({ ok = false, error = res.error })
		end
		local entries = {}
		for line in (res.data or ""):gmatch("[^\n]+") do
			local kind, size, mtime, target, name = line:match("^([fdlo])|([^|]*)|([^|]*)|([^|]*)|(.+)$")
			if kind and name then
				table.insert(entries, {
					name = name,
					kind = kind,
					type = kind == "d" and "directory" or kind == "l" and "link" or "file",
					size = tonumber(size) or 0,
					mtime = mtime ~= "" and mtime or nil,
					target = target ~= "" and target or nil,
				})
			end
		end
		table.sort(entries, function(a, b)
			if a.type ~= b.type then
				return a.type == "directory"
			end
			return a.name:lower() < b.name:lower()
		end)
		cb({ ok = true, entries = entries })
	end)
end

---@param cb fun(res: { ok: boolean, lines?: string[], error?: string })
function M.read(container, path, cb)
	exec(container, { "cat", "--", path }, function(res)
		if not res.ok then
			return cb({ ok = false, error = res.error })
		end
		cb({ ok = true, lines = res.stdout })
	end)
end

---Written with `cat >` rather than `docker cp` to keep owner and permissions.
---@param cb fun(res: { ok: boolean, error?: string })
function M.write(container, path, lines, cb)
	local data = table.concat(lines, "\n")
	if #lines > 0 then
		data = data .. "\n"
	end
	local cmd = { "docker", "exec", "-i", container, "sh", "-c", 'cat > "$1"', "sh", path }
	local ok, err = pcall(vim.system, cmd, { stdin = data, text = true }, function(res)
		vim.schedule(function()
			if res.code == 0 then
				cb({ ok = true })
			else
				local stderr = vim.trim(res.stderr or "")
				cb({ ok = false, error = stderr ~= "" and stderr or "write failed" })
			end
		end)
	end)
	if not ok then
		cb({ ok = false, error = tostring(err) })
	end
end

function M.mkdir(container, path, cb)
	exec(container, { "mkdir", "-p", "--", path }, function(res)
		cb({ ok = res.ok, error = (not res.ok) and res.error or nil })
	end)
end

function M.rm(container, path, cb)
	exec(container, { "rm", "-rf", "--", path }, function(res)
		cb({ ok = res.ok, error = (not res.ok) and res.error or nil })
	end)
end

function M.mv(container, src, dst, cb)
	exec(container, { "mv", "--", src, dst }, function(res)
		cb({ ok = res.ok, error = (not res.ok) and res.error or nil })
	end)
end

function M.cp(container, src, dst, cb)
	exec(container, { "cp", "-a", "--", src, dst }, function(res)
		cb({ ok = res.ok, error = (not res.ok) and res.error or nil })
	end)
end

---Copy a container path to the host.
function M.download(container, src, host_dst, cb)
	docker.run({ "cp", container .. ":" .. src, host_dst }, function(res)
		cb({ ok = res.ok, error = (not res.ok) and res.error or nil })
	end)
end

---Copy a host path into the container.
function M.upload(container, host_src, dst, cb)
	docker.run({ "cp", host_src, container .. ":" .. dst }, function(res)
		cb({ ok = res.ok, error = (not res.ok) and res.error or nil })
	end)
end

---Synchronous read, for BufReadCmd.
---@return string[]|nil lines, string|nil error
function M.read_sync(container, path)
	local res = vim.system({ "docker", "exec", container, "cat", "--", path }, { text = true }):wait()
	if res.code ~= 0 then
		return nil, vim.trim(res.stderr or "") ~= "" and vim.trim(res.stderr) or "read failed"
	end
	return split_lines(res.stdout), nil
end

---@param cb fun(res: { ok: boolean, hits?: { path: string, lnum: integer, text: string }[], error?: string })
function M.grep(container, path, pattern, cb)
	-- grep exits 1 when nothing matches
	docker.run({ "exec", container, "sh", "-c", 'grep -rnI -- "$1" "$2"; [ $? -le 1 ]', "sh", pattern, path }, function(res)
		if not res.ok then
			return cb({ ok = false, error = res.error })
		end
		local hits = {}
		for _, line in ipairs(split_lines(res.data)) do
			local file, lnum, text = line:match("^(.-):(%d+):(.*)$")
			if file then
				table.insert(hits, { path = file, lnum = tonumber(lnum), text = text })
			end
		end
		cb({ ok = true, hits = hits })
	end)
end

---A pattern without wildcards matches as a substring.
---@param cb fun(res: { ok: boolean, paths?: string[], error?: string })
function M.find(container, path, pattern, cb)
	if not pattern:find("[%*%?%[]") then
		pattern = "*" .. pattern .. "*"
	end
	-- find fails on unreadable dirs (/proc...), keep what it found
	docker.run({ "exec", container, "sh", "-c", 'find "$1" -name "$2" 2>/dev/null; true', "sh", path, pattern }, function(res)
		if not res.ok then
			return cb({ ok = false, error = res.error })
		end
		cb({ ok = true, paths = split_lines(res.data) })
	end)
end

---@param path string
function M.normalize(path)
	if path == nil or path == "" then
		return "/"
	end
	if path:sub(1, 1) ~= "/" then
		path = "/" .. path
	end
	local parts = {}
	for part in path:gmatch("[^/]+") do
		if part == ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	if #parts == 0 then
		return "/"
	end
	return "/" .. table.concat(parts, "/")
end

---@return string parent
function M.dirname(path)
	path = M.normalize(path)
	if path == "/" then
		return "/"
	end
	local parent = path:gsub("/[^/]+$", "")
	if parent == "" then
		return "/"
	end
	return parent
end

return M
