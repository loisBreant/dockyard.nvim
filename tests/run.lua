-- Tiny test runner: nvim --headless --clean -l tests/run.lua [specs...]

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

local results = { passed = 0, failed = 0 }
local stack = {}

function _G.describe(name, fn)
	table.insert(stack, name)
	fn()
	table.remove(stack)
end

function _G.it(name, fn)
	local full = table.concat(stack, " › ") .. " › " .. name
	local ok, err = xpcall(fn, debug.traceback)
	if ok then
		results.passed = results.passed + 1
		io.stdout:write("  ok    " .. full .. "\n")
	else
		results.failed = results.failed + 1
		io.stdout:write("  FAIL  " .. full .. "\n" .. tostring(err):gsub("\n", "\n        ") .. "\n")
	end
end

function _G.eq(expected, actual, msg)
	if not vim.deep_equal(expected, actual) then
		error(
			("%sexpected %s, got %s"):format(msg and (msg .. ": ") or "", vim.inspect(expected), vim.inspect(actual)),
			2
		)
	end
end

function _G.truthy(value, msg)
	if not value then
		error((msg or "expected a truthy value") .. ", got " .. vim.inspect(value), 2)
	end
end

---A scratch buffer holding `lines`, optionally named.
function _G.buffer(lines, name)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	if name then
		vim.api.nvim_buf_set_name(buf, name)
	end
	return buf
end

local files = _G.arg and #_G.arg > 0 and _G.arg or vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
for _, file in ipairs(files) do
	io.stdout:write(vim.fn.fnamemodify(file, ":t") .. "\n")
	local ok, err = xpcall(dofile, debug.traceback, file)
	if not ok then
		results.failed = results.failed + 1
		io.stdout:write("  FAIL  could not load: " .. tostring(err) .. "\n")
	end
end

io.stdout:write(("\n%d passed, %d failed\n"):format(results.passed, results.failed))
os.exit(results.failed == 0 and 0 or 1)
