-- Project scope, shared by every view: what belongs to the project Neovim is working on.
--
-- The project is the git root of Neovim's working directory (or the directory itself). A container belongs
-- to it when its compose project was started from inside it (or from a parent). Networks, volumes and
-- images are tied to it through the `com.docker.compose.project` label, which holds the project *name*.

local M = {}

local PROJECT_LABEL = "com.docker.compose.project"

---@type boolean|nil nil = follow display.project_scope
local override = nil

---@return string
function M.root()
	-- global cwd, the Dockyard tab may have a local one
	local cwd = vim.fn.getcwd(-1)
	return vim.fs.normalize(vim.fs.root(cwd, ".git") or cwd)
end

---@return boolean
function M.enabled()
	if override ~= nil then
		return override
	end
	local option = require("dockyard.config").options.display.project_scope
	if option == "auto" then
		return require("dockyard.commands.context").find_compose_file(M.root()) ~= nil
	end
	return option == true
end

---Flip the scope for every view.
---@return boolean now
function M.toggle()
	override = not M.enabled()
	return override
end

---Forget the toggles and follow the configuration again.
function M.reset()
	override = nil
end

local function contains(parent, child)
	return child == parent or vim.startswith(child, parent == "/" and "/" or parent .. "/")
end

---@param dir string|nil
---@param root string
---@return boolean
function M.dir_matches(dir, root)
	if type(dir) ~= "string" or dir == "" then
		return false
	end
	dir = vim.fs.normalize(dir)
	if contains(root, dir) then
		return true
	end
	-- a project in / or ~ would match everything
	return dir ~= "/" and dir ~= vim.fs.normalize("~") and contains(dir, root)
end

---@param c { compose_dir?: string }
---@param root string
---@return boolean
function M.matches(c, root)
	return M.dir_matches(c.compose_dir, root)
end

---How Docker compose names a project: lowercase, only [a-z0-9_-], starting with a letter or a digit.
---@param name string|nil
---@return string
function M.normalize_project_name(name)
	local out = tostring(name or ""):lower():gsub("[^a-z0-9_%-]", ""):gsub("^[^a-z0-9]+", "")
	return out
end

---Name of the compose project at `root`: its `name:` key, else the directory name.
---@param root string
---@return string|nil
function M.project_name(root)
	local file = require("dockyard.commands.context").find_compose_file(root)
	if not file then
		return nil
	end
	local ok, lines = pcall(vim.fn.readfile, file, "", 200)
	for _, line in ipairs(ok and lines or {}) do
		local name = line:match("^name:%s*(.-)%s*$")
		if name then
			name = name:gsub("%s+#.*$", ""):gsub("^[\"']", ""):gsub("[\"']$", "")
			name = M.normalize_project_name(name)
			if name ~= "" then
				return name
			end
		end
	end
	local base = M.normalize_project_name(vim.fs.basename(root))
	return base ~= "" and base or nil
end

---Compose project names of the scope: the ones of the containers started from the root, plus the compose
---project of the root itself (so a project without containers still shows its networks and volumes).
---@param containers Container[]|nil
---@return table<string, true>
function M.project_names(containers)
	local root = M.root()
	local names = {}
	for _, c in ipairs(containers or {}) do
		if c.compose_project and c.compose_project ~= "" and M.matches(c, root) then
			names[c.compose_project] = true
		end
	end
	local own = M.project_name(root)
	if own then
		names[own] = true
	end
	return names
end

---One label of the `k=v,k2=v2` string Docker prints for labels.
---@param labels string|nil
---@param key string
---@return string|nil
function M.label(labels, key)
	if type(labels) ~= "string" or labels == "" then
		return nil
	end
	for pair in labels:gmatch("([^,]+)") do
		local k, v = pair:match("^([^=]+)=(.*)$")
		if k == key then
			return v
		end
	end
	return nil
end

---@param items Container[]
---@return Container[]
function M.apply_containers(items)
	if not M.enabled() then
		return items
	end
	local root = M.root()
	return vim.tbl_filter(function(c)
		return M.matches(c, root)
	end, items)
end
M.apply = M.apply_containers

local function by_project_label(items, containers)
	local names = M.project_names(containers)
	return vim.tbl_filter(function(item)
		return names[M.label(item.labels, PROJECT_LABEL) or ""] == true
	end, items)
end

---@param items Network[]
---@param containers Container[]
---@return Network[]
function M.apply_networks(items, containers)
	if not M.enabled() then
		return items
	end
	return by_project_label(items, containers)
end

---@param items Volume[]
---@param containers Container[]
---@return Volume[]
function M.apply_volumes(items, containers)
	if not M.enabled() then
		return items
	end
	return by_project_label(items, containers)
end

-- a container refers to its image by `repo:tag`, by `repo` (latest) or by the image id
local function uses_image(container, image)
	local ref = tostring(image.repository or "<none>") .. ":" .. tostring(image.tag or "<none>")
	local used = tostring(container.image or "")
	if used == "" then
		return false
	end
	if not used:match(":[^/]*$") then
		used = used .. ":latest"
	end
	local id = tostring(image.id or "")
	return used == ref or (id ~= "" and (used == id or vim.startswith(id, used)))
end

---Images built for the project, and the ones its containers use.
---@param images Image[]
---@param containers Container[]
---@return Image[]
function M.apply_images(images, containers)
	if not M.enabled() then
		return images
	end
	local root = M.root()
	local names = M.project_names(containers)
	local in_scope = vim.tbl_filter(function(c)
		return M.matches(c, root)
	end, containers or {})
	return vim.tbl_filter(function(image)
		if names[image.compose_project or ""] then
			return true
		end
		for _, c in ipairs(in_scope) do
			if uses_image(c, image) then
				return true
			end
		end
		return false
	end, images)
end

---Jobs run inside the project; a job without a directory is not in it.
---@param jobs DockyardJob[]
---@return DockyardJob[]
function M.apply_jobs(jobs)
	if not M.enabled() then
		return jobs
	end
	local root = M.root()
	return vim.tbl_filter(function(job)
		return M.dir_matches(job.cwd, root)
	end, jobs)
end

---Networks, volumes and images are tied to the project through its containers: have them before drawing.
---@param cb fun()
function M.ensure_containers(cb)
	local containers = require("dockyard.state").containers
	if not M.enabled() or #containers.get_items() > 0 then
		return cb()
	end
	containers.refresh({
		silent = true,
		on_success = function()
			cb()
		end,
		on_error = function()
			cb()
		end,
	})
end

return M
