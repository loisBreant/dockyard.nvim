# Portée projet et filtre dans toutes les vues — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Les vues Images, Networks, Volumes et Jobs se limitent au projet courant par défaut (`P` pour tout voir, un seul état partagé) et se filtrent (`F` / `C`), comme Containers.

**Architecture:** un module partagé `dockyard/scope.lua` (état, racine, noms de projet, règles d'appartenance pures) ; deux composants UI partagés (`scope_header` : lignes `Project:`/`Filter:` et correspondance ; `view_filter` : contrôleur et touches `F`/`C`/`P` réutilisés par chaque vue) ; chaque vue expose une fonction pure `select(...)` appliquée avant de dessiner. `core/docker.lua` ajoute les labels des réseaux et des images.

**Tech Stack:** Lua (LuaJIT, API 5.1), Neovim ≥ 0.10, Docker CLI. Tests : mini-runner du dépôt (`make test`).

**Spec:** `docs/superpowers/specs/2026-09-30-project-scope-and-filter-all-views-design.md`. Un écart assumé : les contrôleurs et les touches communs vivent dans `ui/components/view_filter.lua` (la spec ne listait que `scope_header`), pour ne pas copier la même logique quatre fois.

**Répertoire de travail de toutes les commandes :** `/home/lois/dotfiles/.config/nvim/dockyard.nvim`, branche `main` (l'utilisateur autorise à travailler directement dessus, sans push). Un test seul : `nvim --headless --clean -l tests/run.lua tests/<nom>_spec.lua` ; tous : `make test`.

## Global Constraints

- Neovim `>= 0.10` ; Lua 5.1/LuaJIT ; tabulations dans `*.lua`, 2 espaces dans `*.md`/`*.json`.
- Aucune nouvelle dépendance ; tests avec `describe`/`it`/`eq`/`truthy`/`buffer` de `tests/run.lua`.
- `plugin/dockyard.lua` reste léger (aucun module `dockyard.*` chargé au démarrage) ; pas de mapping global.
- Aucun raccourci existant ne change, sauf `keymaps.images.prune` : `"P"` → `"X"`.
- `ui/views/containers/scope.lua` reste importable (alias de `dockyard.scope`) : le picker et les tests existants ne changent pas.
- Hors d'un dossier avec compose (`display.project_scope = "auto"`), aucune vue ne change de comportement.
- Toute touche nouvelle est configurable (`false` la désactive) et couverte par `core.keymaps.validate()` (aucun conflit dans aucune vue).
- Tous les modules se chargent sans effet de bord (`tests/modules_spec.lua` les `require` tous).
- Commits : messages conventionnels terminés par `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` (second `-m`). Pas de `git push`.
- `make typecheck`, `selene`, `stylua` ne sont pas installés : le dire dans le compte rendu final, ne pas prétendre qu'ils ont passé.
- `rm` est aliasé en interactif dans ce shell : `command rm -f`.

## Review Focus

Conditions que la spec sous-entend sans les décrire, les plus probables d'abord :

1. **Projet sans conteneur** (arrêté, jamais lancé) : ses réseaux et volumes restent visibles grâce au nom du compose à la racine — Task 1 (`project_names`), Task 5/6 (`select`).
2. **Images ouverte avant Containers** (liste des conteneurs vide) : la portée charge les conteneurs avant de dessiner — Task 1 (`ensure_containers`).
3. **Image référencée sans tag** (`postgres` utilisé, `postgres:latest` listée) : elle compte comme utilisée — Task 1 (`apply_images`).
4. **Nom de projet** écrit avec `name: "My_App"  # commentaire` ou dossier `My App.git` : normalisé comme Docker — Task 1 (`project_name`).
5. **`docker image inspect` qui échoue ou aucune image** : pas d'erreur, images sans label — Task 2.
6. **Filtre sans résultat** : tableau vide et ligne `Filter: … (0/N)` — Task 3 (`scope_header`), Task 4 (`select`).

---

### Task 1: Module de portée partagé

**Files:**
- Create: `lua/dockyard/scope.lua`
- Modify: `lua/dockyard/ui/views/containers/scope.lua` (alias), `lua/dockyard/ui/views/containers/controller.lua`, `lua/dockyard/ui/views/containers/renderer.lua`, `lua/dockyard/ui/views/containers/state.lua`, `lua/dockyard/picker.lua`
- Test: `tests/scope_spec.lua`

**Interfaces:**
- Consumes: `dockyard.commands.context.find_compose_file`, `dockyard.state` (`containers.get_items`, `containers.refresh`), `dockyard.config.options.display.project_scope`.
- Produces (`require("dockyard.scope")`) :
  - `enabled(): boolean`, `toggle(): boolean` (état partagé), `reset()` (tests)
  - `root(): string`, `dir_matches(dir, root): boolean`, `matches(container, root): boolean`
  - `normalize_project_name(name): string`, `project_name(root): string|nil`, `project_names(containers): table<string, true>`
  - `label(labels: string|nil, key: string): string|nil`
  - `apply_containers(items)` (alias `apply`), `apply_networks(items, containers)`, `apply_volumes(items, containers)`, `apply_images(images, containers)`, `apply_jobs(jobs)`
  - `ensure_containers(cb: fun())`

- [ ] **Step 1: Write the failing test**

Créer `tests/scope_spec.lua` :

```lua
local scope = require("dockyard.scope")
local config = require("dockyard.config")

-- a project directory with a compose file, as root
local function project(compose_lines, name)
	local base = vim.fn.tempname()
	local dir = base .. "/" .. (name or "My App")
	vim.fn.mkdir(dir, "p")
	if compose_lines then
		vim.fn.writefile(compose_lines, dir .. "/compose.yml")
	end
	return vim.fs.normalize(dir)
end

local real_root = scope.root
local function use_root(dir)
	scope.root = function()
		return dir
	end
end

local function enable(on)
	config.options.display.project_scope = on
	scope.reset()
end

local function names(list, key)
	return vim.tbl_map(function(item)
		return item[key]
	end, list)
end

describe("scope.normalize_project_name", function()
	it("lowercases, drops characters Docker refuses and leading separators", function()
		eq("myapp", scope.normalize_project_name("My App!"))
		eq("x-y", scope.normalize_project_name("_x-Y"))
		eq("dockyardnvim", scope.normalize_project_name("Dockyard.NVIM"))
		eq("", scope.normalize_project_name(""))
		eq("", scope.normalize_project_name(nil))
	end)
end)

describe("scope.project_name", function()
	it("uses the normalised directory name without a name: key", function()
		eq("myapp", scope.project_name(project({ "services: {}" })))
	end)

	it("reads name:, with quotes and a trailing comment", function()
		eq("custom_name", scope.project_name(project({ 'name: "Custom_Name"  # the project', "services: {}" })))
	end)

	it("is nil without a compose file", function()
		eq(nil, scope.project_name(project(nil)))
	end)
end)

describe("scope.label", function()
	local networks = "com.docker.compose.config-hash=e0d23ec7,com.docker.compose.network=net,com.docker.compose.project=filow-docs,com.docker.compose.version=5.5.1"

	it("reads one label of the comma separated list Docker prints", function()
		eq("filow-docs", scope.label(networks, "com.docker.compose.project"))
		eq("net", scope.label(networks, "com.docker.compose.network"))
	end)

	it("returns nil for a missing label, empty labels and nil", function()
		eq(nil, scope.label(networks, "nope"))
		eq(nil, scope.label("", "com.docker.compose.project"))
		eq(nil, scope.label(nil, "com.docker.compose.project"))
		eq("", scope.label("com.docker.volume.anonymous=", "com.docker.volume.anonymous"))
	end)
end)

describe("scope.enabled / toggle", function()
	it("follows display.project_scope until toggled, for every view at once", function()
		enable(true)
		eq(true, scope.enabled())
		eq(false, scope.toggle())
		eq(false, scope.enabled())
		eq(true, scope.toggle())
		scope.reset()
		enable(false)
		eq(false, scope.enabled())
	end)

	it("is on in 'auto' mode only when the root has a compose file", function()
		enable("auto")
		use_root(project({ "services: {}" }))
		eq(true, scope.enabled())
		use_root(project(nil))
		eq(false, scope.enabled())
	end)
end)

describe("scope.project_names", function()
	it("collects the projects of the containers started from the root, plus the compose project of the root", function()
		local root = project({ "services: {}" }, "Shop")
		use_root(root)
		local set = scope.project_names({
			{ compose_project = "shop-custom", compose_dir = root },
			{ compose_project = "shop-custom", compose_dir = root .. "/services/api" },
			{ compose_project = "other", compose_dir = "/somewhere/else" },
			{ name = "plain-docker-run" },
		})
		eq({ ["shop-custom"] = true, shop = true }, set)
	end)

	it("keeps the compose project of the root when there is no container at all", function()
		use_root(project({ "services: {}" }, "Fresh"))
		eq({ fresh = true }, scope.project_names({}))
	end)
end)

describe("scope.apply_*", function()
	local root
	local containers

	local function setup()
		root = project({ "services: {}" }, "App")
		use_root(root)
		enable(true)
		containers = {
			{ name = "app-api-1", image = "app-api", compose_project = "app", compose_dir = root },
			{ name = "app-cache-1", image = "redis:7", compose_project = "app", compose_dir = root },
			{ name = "app-db-1", image = "postgres", compose_project = "app", compose_dir = root },
			{ name = "other-db-1", image = "mysql:8", compose_project = "other", compose_dir = "/q/other" },
		}
	end

	it("keeps the networks and volumes labelled with a project of the scope", function()
		setup()
		local networks = {
			{ name = "app_default", labels = "com.docker.compose.project=app,com.docker.compose.network=default" },
			{ name = "other_net", labels = "com.docker.compose.project=other" },
			{ name = "bridge", labels = "" },
		}
		eq({ "app_default" }, names(scope.apply_networks(networks, containers), "name"))
		local volumes = {
			{ name = "app_data", labels = "com.docker.compose.project=app,com.docker.compose.volume=data" },
			{ name = "0f35a03b", labels = "com.docker.volume.anonymous=" },
			{ name = "other_data", labels = "com.docker.compose.project=other" },
		}
		eq({ "app_data" }, names(scope.apply_volumes(volumes, containers), "name"))
	end)

	it("shows the networks of a project that has no container yet", function()
		setup()
		local networks = { { name = "app_default", labels = "com.docker.compose.project=app" } }
		eq({ "app_default" }, names(scope.apply_networks(networks, {}), "name"))
	end)

	it("keeps the images built for the project and the ones its containers use, tag or not", function()
		setup()
		local images = {
			{ id = "a1", repository = "app-api", tag = "latest", compose_project = "app" },
			{ id = "b2", repository = "redis", tag = "7" },
			{ id = "c3", repository = "postgres", tag = "latest" },
			{ id = "d4", repository = "mysql", tag = "8" },
			{ id = "e5", repository = "unrelated", tag = "1" },
		}
		eq({ "app-api", "redis", "postgres" }, names(scope.apply_images(images, containers), "repository"))
	end)

	it("keeps the jobs run inside the project, and none without a directory", function()
		setup()
		local jobs = {
			{ id = 1, cwd = root },
			{ id = 2, cwd = root .. "/services/api" },
			{ id = 3, cwd = "/elsewhere" },
			{ id = 4 },
		}
		eq({ 1, 2 }, names(scope.apply_jobs(jobs), "id"))
	end)

	it("changes nothing when the scope is off", function()
		setup()
		enable(false)
		local list = { { name = "x", labels = "" }, { id = 1 } }
		eq(list, scope.apply_networks(list, containers))
		eq(list, scope.apply_volumes(list, containers))
		eq(list, scope.apply_images(list, containers))
		eq(list, scope.apply_jobs(list))
		eq(containers, scope.apply_containers(containers))
	end)

	it("filters the containers like before", function()
		setup()
		eq({ "app-api-1", "app-cache-1", "app-db-1" }, names(scope.apply(containers), "name"))
	end)
end)

describe("scope.ensure_containers", function()
	local state = require("dockyard.state")

	it("calls back at once when the scope is off or containers are known", function()
		local real_refresh = state.containers.refresh
		local refreshed = 0
		state.containers.refresh = function()
			refreshed = refreshed + 1
		end
		local calls = 0
		enable(false)
		scope.ensure_containers(function()
			calls = calls + 1
		end)
		eq(1, calls)
		eq(0, refreshed)
		state.containers.refresh = real_refresh
	end)

	it("loads the containers first when the scope is on and none are known", function()
		local real_refresh, real_items = state.containers.refresh, state.containers.get_items
		state.containers.get_items = function()
			return {}
		end
		state.containers.refresh = function(opts)
			opts.on_success({})
		end
		enable(true)
		local calls = 0
		scope.ensure_containers(function()
			calls = calls + 1
		end)
		state.containers.refresh, state.containers.get_items = real_refresh, real_items
		eq(1, calls)
	end)

	it("calls back even when loading the containers fails", function()
		local real_refresh, real_items = state.containers.refresh, state.containers.get_items
		state.containers.get_items = function()
			return {}
		end
		state.containers.refresh = function(opts)
			opts.on_error("boom")
		end
		enable(true)
		local calls = 0
		scope.ensure_containers(function()
			calls = calls + 1
		end)
		state.containers.refresh, state.containers.get_items = real_refresh, real_items
		eq(1, calls)
	end)
end)

scope.root = real_root
config.options.display.project_scope = config.defaults.display.project_scope
scope.reset()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim --headless --clean -l tests/run.lua tests/scope_spec.lua`
Expected: FAIL `could not load: … module 'dockyard.scope' not found`.

- [ ] **Step 3: Write the implementation**

Créer `lua/dockyard/scope.lua` :

```lua
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
```

Remplacer **tout** le contenu de `lua/dockyard/ui/views/containers/scope.lua` par :

```lua
-- The project scope is shared by every view: see dockyard/scope.lua.
return require("dockyard.scope")
```

Dans `lua/dockyard/ui/views/containers/controller.lua`, remplacer

```lua
function M.toggle_project_scope()
	view_state.project_scope = not require("dockyard.ui.views.containers.scope").enabled()
```

par

```lua
function M.toggle_project_scope()
	require("dockyard.scope").toggle()
```

Dans `lua/dockyard/ui/views/containers/renderer.lua`, remplacer `local scope = require("dockyard.ui.views.containers.scope")` par `local scope = require("dockyard.scope")`.

Dans `lua/dockyard/ui/views/containers/state.lua`, supprimer la ligne `---@field project_scope boolean|nil Only show containers of the current project; nil = use config default`.

Dans `lua/dockyard/picker.lua`, remplacer `require("dockyard.ui.views.containers.scope").apply(res.data or {})` par `require("dockyard.scope").apply_containers(res.data or {})`.

- [ ] **Step 4: Run it to verify it passes**

Run: `nvim --headless --clean -l tests/run.lua tests/scope_spec.lua && make test`
Expected: `0 failed` (les tests `project scope` de `tests/misc_spec.lua` passent par l'alias).

- [ ] **Step 5: Commit**

```bash
git add lua/dockyard tests/scope_spec.lua
git commit -m "feat: project scope shared by every view" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Labels des réseaux et des images

**Files:**
- Modify: `lua/dockyard/core/docker.lua`
- Test: `tests/docker_labels_spec.lua`

**Interfaces:**
- Consumes: rien.
- Produces:
  - `Network.labels: string` (`k=v,k2=v2`, `""` sans label) renvoyé par `docker.list_networks`
  - `Image.compose_project: string|nil` renvoyé par `docker.list_images`
  - `docker.attach_image_labels(images: Image[], stdout: string)` (pure).

- [ ] **Step 1: Write the failing test**

Créer `tests/docker_labels_spec.lua` :

```lua
local docker = require("dockyard.core.docker")

describe("docker.attach_image_labels", function()
	local stdout = table.concat({
		'{"id":"sha256:c1d2e3f4a5b6deadbeef","labels":{"com.docker.compose.project":"filow-docs","x":"y"}}',
		'{"id":"sha256:0123456789abcdef","labels":null}',
		"not json",
		'{"id":"sha256:aaaaaaaaaaaa1111","labels":{"org.opencontainers.image.source":"x"}}',
	}, "\n")

	it("tells which compose project built each image, by the start of its id", function()
		local images = {
			{ id = "c1d2e3f4a5b6", repository = "filow-docs-docs" },
			{ id = "0123456789ab", repository = "postgres" },
			{ id = "aaaaaaaaaaaa", repository = "other" },
			{ id = "ffffffffffff", repository = "not-inspected" },
		}
		docker.attach_image_labels(images, stdout)
		eq("filow-docs", images[1].compose_project)
		eq(nil, images[2].compose_project)
		eq(nil, images[3].compose_project)
		eq(nil, images[4].compose_project)
	end)

	it("copes with nothing to read", function()
		local images = { { id = "c1d2e3f4a5b6" } }
		docker.attach_image_labels(images, "")
		docker.attach_image_labels(images, nil)
		docker.attach_image_labels({}, stdout)
		eq(nil, images[1].compose_project)
	end)
end)

describe("docker.list_networks", function()
	it("reports the labels of every network as a string", function()
		if vim.fn.executable("docker") == 0 then
			return
		end
		local result
		docker.list_networks(function(res)
			result = res
		end)
		vim.wait(15000, function()
			return result ~= nil
		end, 50)
		truthy(result, "docker never answered")
		if not result.ok then
			return -- no daemon on this machine
		end
		for _, network in ipairs(result.data) do
			eq("string", type(network.labels), network.name)
		end
	end)
end)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim --headless --clean -l tests/run.lua tests/docker_labels_spec.lua`
Expected: FAIL (`attempt to call a nil value (field 'attach_image_labels')`, et `string expected, got nil` si un démon Docker tourne).

- [ ] **Step 3: Write the implementation**

Dans `lua/dockyard/core/docker.lua` :

(a) Remplacer

```lua
--- @field size string

--- @param callback fun(result: {ok: boolean, data: Image[], error?: string})
M.list_images = function(callback)
```

par

```lua
--- @field size string
--- @field compose_project string|nil compose project that built the image (label), when known

---Tell which compose project built each image. `stdout` holds one `{"id": …, "labels": …}` JSON per line, as
---printed by `docker image inspect`; ids are matched by prefix (the list shows the short id).
---@param images Image[]
---@param stdout string|nil
function M.attach_image_labels(images, stdout)
	local projects = {}
	for line in (stdout or ""):gmatch("[^\r\n]+") do
		local ok, parsed = pcall(vim.json.decode, line)
		if ok and type(parsed) == "table" and type(parsed.id) == "string" and type(parsed.labels) == "table" then
			local project = parsed.labels["com.docker.compose.project"]
			if project then
				projects[(parsed.id:gsub("^sha256:", ""))] = project
			end
		end
	end
	for _, image in ipairs(images) do
		local short = tostring(image.id or ""):gsub("^sha256:", "")
		if short ~= "" then
			for full, project in pairs(projects) do
				if vim.startswith(full, short) then
					image.compose_project = project
					break
				end
			end
		end
	end
end

--- @param callback fun(result: {ok: boolean, data: Image[], error?: string})
M.list_images = function(callback)
```

(b) Dans `M.list_images`, remplacer

```lua
		callback({ ok = true, data = images })
	end)
end

--- @class Network
```

par

```lua
		-- labels are not part of `docker images`: one inspect for all of them
		local ids, seen = {}, {}
		for _, image in ipairs(images) do
			if image.id and image.id ~= "" and not seen[image.id] then
				seen[image.id] = true
				table.insert(ids, image.id)
			end
		end
		if #ids == 0 then
			callback({ ok = true, data = images })
			return
		end
		local args = { "image", "inspect", "--format", '{"id":{{json .Id}},"labels":{{json .Config.Labels}}}' }
		vim.list_extend(args, ids)
		M.run(args, function(inspected)
			if inspected.ok then
				M.attach_image_labels(images, inspected.data)
			end
			callback({ ok = true, data = images })
		end)
	end)
end

--- @class Network
```

(c) Dans la classe `Network`, remplacer

```lua
--- @field created string

--- @param callback fun(result: {ok: boolean, data: Network[], error?: string})
```

par

```lua
--- @field created string
--- @field labels string `k=v,k2=v2`, empty without labels

--- @param callback fun(result: {ok: boolean, data: Network[], error?: string})
```

et, dans le format de `M.list_networks`, remplacer

```lua
		'  "scope": {{json .Scope}},',
		'  "created": {{json .CreatedAt}}',
		"}",
	}, "")

	M.run({ "network", "ls", "--format", format }
```

par

```lua
		'  "scope": {{json .Scope}},',
		'  "created": {{json .CreatedAt}},',
		'  "labels": {{json .Labels}}',
		"}",
	}, "")

	M.run({ "network", "ls", "--format", format }
```

- [ ] **Step 4: Run it to verify it passes**

Run: `nvim --headless --clean -l tests/run.lua tests/docker_labels_spec.lua && make test`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lua/dockyard/core/docker.lua tests/docker_labels_spec.lua
git commit -m "feat: labels of networks and compose project of images" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: En-tête, contrôleur de filtre partagé et touches

**Files:**
- Create: `lua/dockyard/ui/components/scope_header.lua`, `lua/dockyard/ui/components/view_filter.lua`
- Modify: `lua/dockyard/config.lua` (touches), `lua/dockyard/core/keymaps.lua` (types, ids, conflits)
- Test: `tests/scope_header_spec.lua`, `tests/modules_spec.lua`

**Interfaces:**
- Consumes: `dockyard.scope` (Task 1), `dockyard.core.keymaps` (`resolver`), `dockyard.ui.navigation`, `dockyard.ui.state`.
- Produces:
  - `scope_header.matches(fields: string[], needle: string|nil): boolean`
  - `scope_header.key_label(action: string, fallback: string): string`
  - `scope_header.block(opts): { lines: string[], highlights: table[] }` avec `opts = { scope_on, root, scoped, total, filter, shown, scope_key, clear_key }`
  - `view_filter.controller({ view, label, state, render }) -> { set_filter, clear_filter, toggle_project_scope, prompt_filter }`
  - `view_filter.push_items(items, group, ctl, index)` (ajoute `<group>.filter`, `<group>.clear_filter`, `<group>.toggle_project_scope`) et `view_filter.push_removals(items, group)`
  - `config.options.keymaps.<images|networks|volumes|jobs>.{filter = "F", clear_filter = "C", toggle_project_scope = "P"}` et `keymaps.images.prune = "X"`.

- [ ] **Step 1: Write the failing tests**

Créer `tests/scope_header_spec.lua` :

```lua
local scope_header = require("dockyard.ui.components.scope_header")
local view_filter = require("dockyard.ui.components.view_filter")
local scope = require("dockyard.scope")
local config = require("dockyard.config")

describe("scope_header.matches", function()
	it("matches anything without a filter", function()
		eq(true, scope_header.matches({ "a" }, nil))
		eq(true, scope_header.matches({ "a" }, ""))
	end)

	it("looks for a substring, ignoring case, in any field", function()
		eq(true, scope_header.matches({ "Postgres", "16", "abc" }, "GRES"))
		eq(true, scope_header.matches({ "x", "y", "deadbeef" }, "beef"))
		eq(false, scope_header.matches({ "x", "y" }, "z"))
	end)

	it("takes the filter literally, not as a pattern", function()
		eq(true, scope_header.matches({ "a.b" }, "a.b"))
		eq(false, scope_header.matches({ "axb" }, "a.b"))
		eq(true, scope_header.matches({ "50%" }, "%"))
	end)
end)

describe("scope_header.block", function()
	local base = { scope_on = true, root = "/p/app", scoped = 3, total = 12, shown = 3, scope_key = "P", clear_key = "C" }

	it("shows the project line and a blank line", function()
		local block = scope_header.block(base)
		eq({ " Project: /p/app  (3/12)  [press P to show all]", "" }, block.lines)
		eq("DockyardMuted", block.highlights[1].hl_group)
		eq(0, block.highlights[1].line)
	end)

	it("adds the filter line, counted against what the scope lets through", function()
		local block = scope_header.block(vim.tbl_extend("force", base, { filter = "api", shown = 0 }))
		eq({
			" Project: /p/app  (3/12)  [press P to show all]",
			" Filter: api  (0/3)  [press C to clear]",
			"",
		}, block.lines)
		eq(1, block.highlights[2].line)
	end)

	it("shows only the filter when the scope is off, and nothing when neither applies", function()
		local off = scope_header.block(vim.tbl_extend("force", base, { scope_on = false, filter = "x", shown = 1 }))
		eq({ " Filter: x  (1/3)  [press C to clear]", "" }, off.lines)
		eq({ lines = {}, highlights = {} }, scope_header.block(vim.tbl_extend("force", base, { scope_on = false })))
	end)
end)

describe("scope_header.key_label", function()
	it("gives the first key of the action, or the fallback", function()
		eq("F", scope_header.key_label("images.filter", "?"))
		eq("?", scope_header.key_label("images.nope", "?"))
	end)
end)

describe("view_filter.controller", function()
	local function new()
		local state, renders = {}, { n = 0 }
		local ctl = view_filter.controller({
			view = "images",
			label = "images",
			state = state,
			render = function()
				renders.n = renders.n + 1
			end,
		})
		return ctl, state, renders
	end

	it("sets and clears the filter of its own view and redraws", function()
		local ctl, state, renders = new()
		ctl.set_filter("api")
		eq("api", state.filter)
		ctl.set_filter("")
		eq(nil, state.filter)
		ctl.set_filter("x")
		ctl.clear_filter()
		eq(nil, state.filter)
		eq(4, renders.n)
	end)

	it("toggles the scope shared by every view, then redraws", function()
		local ctl, _, renders = new()
		config.options.display.project_scope = true
		scope.reset()
		ctl.toggle_project_scope()
		eq(false, scope.enabled())
		eq(1, renders.n)
		scope.reset()
		config.options.display.project_scope = config.defaults.display.project_scope
	end)
end)

describe("view_filter keys", function()
	it("adds filter, clear and scope keys to a view, and takes them away again", function()
		local ctl = { prompt_filter = function() end, clear_filter = function() end, toggle_project_scope = function() end }
		local items = {}
		view_filter.push_items(items, "networks", ctl, 20)
		eq({ "F", "C", "P" }, vim.tbl_map(function(i)
			return i.key
		end, items))
		eq({ 20, 21, 22 }, vim.tbl_map(function(i)
			return i.index
		end, items))
		local removals = {}
		view_filter.push_removals(removals, "networks")
		eq({ "F", "C", "P" }, vim.tbl_map(function(i)
			return i.key
		end, removals))
	end)
end)
```

Dans `tests/modules_spec.lua`, dans `describe("keymaps", …)` (en fin de fichier), ajouter ces tests :

```lua
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `nvim --headless --clean -l tests/run.lua tests/scope_header_spec.lua tests/modules_spec.lua`
Expected: FAIL (`module 'dockyard.ui.components.scope_header' not found` ; `images.prune` vaut `"P"`).

- [ ] **Step 3: Write the implementation**

Créer `lua/dockyard/ui/components/scope_header.lua` :

```lua
-- The `Project:` and `Filter:` lines above the table of a view, and the filter's match test.

local M = {}

---Case-insensitive substring match of `needle` in any of `fields` (literal text, not a pattern).
---@param fields string[]
---@param needle string|nil
---@return boolean
function M.matches(fields, needle)
	if not needle or needle == "" then
		return true
	end
	needle = needle:lower()
	for _, field in ipairs(fields) do
		if tostring(field):lower():find(needle, 1, true) then
			return true
		end
	end
	return false
end

---First key bound to `action`, for the hints.
---@param action string
---@param fallback string
---@return string
function M.key_label(action, fallback)
	local key = require("dockyard.core.keymaps").key(action) or fallback
	return type(key) == "table" and (key[1] or fallback) or key
end

---@class DockyardScopeHeaderOpts
---@field scope_on boolean
---@field root string
---@field scoped integer rows the scope lets through
---@field total integer rows before the scope
---@field filter string|nil
---@field shown integer rows left after the filter
---@field scope_key string
---@field clear_key string

---@param opts DockyardScopeHeaderOpts
---@return { lines: string[], highlights: table[] }
function M.block(opts)
	local lines, highlights = {}, {}
	local function add(text)
		table.insert(lines, text)
		table.insert(highlights, { line = #lines - 1, start_col = 0, end_col = #text, hl_group = "DockyardMuted" })
	end
	local has_filter = opts.filter ~= nil and opts.filter ~= ""

	if opts.scope_on then
		add((" Project: %s  (%d/%d)  [press %s to show all]"):format(vim.fn.fnamemodify(opts.root, ":~"), opts.scoped, opts.total, opts.scope_key))
		if not has_filter then
			table.insert(lines, "")
		end
	end
	if has_filter then
		add((" Filter: %s  (%d/%d)  [press %s to clear]"):format(opts.filter, opts.shown, opts.scoped, opts.clear_key))
		table.insert(lines, "")
	end
	return { lines = lines, highlights = highlights }
end

return M
```

Créer `lua/dockyard/ui/components/view_filter.lua` :

```lua
-- Filter and project-scope handlers and keys shared by the Images, Networks, Volumes and Jobs views.

local M = {}

local resolver = require("dockyard.core.keymaps")
local ui_state = require("dockyard.ui.state")
local navigation = require("dockyard.ui.navigation")

---@param opts { view: string, label: string, state: { filter: string|nil }, render: fun() }
---@return { set_filter: fun(text: string|nil), clear_filter: fun(), toggle_project_scope: fun(), prompt_filter: fun() }
function M.controller(opts)
	local C = {}

	local function active()
		return ui_state.current_view == opts.view
	end

	function C.set_filter(text)
		opts.state.filter = (text ~= nil and text ~= "") and text or nil
		opts.render()
		if active() and opts.state.filter then
			navigation.first()
		end
	end

	function C.clear_filter()
		opts.state.filter = nil
		opts.render()
	end

	function C.toggle_project_scope()
		local scope = require("dockyard.scope")
		scope.toggle()
		scope.ensure_containers(function()
			opts.render()
			if active() then
				navigation.first()
			end
		end)
	end

	function C.prompt_filter()
		vim.ui.input({ prompt = "Filter " .. opts.label .. ": ", default = opts.state.filter or "" }, function(input)
			if input ~= nil then
				C.set_filter(input)
			end
		end)
	end

	return C
end

---@param items table list given to help.register
---@param group string keymaps group: "images", "networks", "volumes" or "jobs"
---@param ctl table result of M.controller
---@param index integer help order of the first key
function M.push_items(items, group, ctl, index)
	resolver.push(
		items,
		resolver.item(group .. ".filter", {
			desc = "Filter " .. group,
			callback = function()
				ctl.prompt_filter()
			end,
			index = index,
		})
	)
	resolver.push(
		items,
		resolver.item(group .. ".clear_filter", {
			desc = "Clear filter",
			callback = function()
				ctl.clear_filter()
			end,
			index = index + 1,
		})
	)
	resolver.push(
		items,
		resolver.item(group .. ".toggle_project_scope", {
			desc = "Only this project's " .. group .. " / all",
			callback = function()
				ctl.toggle_project_scope()
			end,
			index = index + 2,
		})
	)
end

---@param items table list given to help.remove
---@param group string
function M.push_removals(items, group)
	for _, action in ipairs({ "filter", "clear_filter", "toggle_project_scope" }) do
		resolver.push(items, resolver.removal(group .. "." .. action))
	end
end

return M
```

Dans `lua/dockyard/config.lua`, dans `M.options.keymaps` :

(a) Remplacer

```lua
		images = {
			remove = "d",
			prune = "P",
		},
		networks = {
			remove = "d",
		},
		volumes = {
			remove = "d",
		},
		jobs = {
			open_output = "<CR>",
			rerun = "r",
			cancel = "x",
			clear = "D",
			copy_command = "y",
		},
```

par

```lua
		images = {
			remove = "d",
			prune = "X",
			filter = "F",
			clear_filter = "C",
			toggle_project_scope = "P",
		},
		networks = {
			remove = "d",
			filter = "F",
			clear_filter = "C",
			toggle_project_scope = "P",
		},
		volumes = {
			remove = "d",
			filter = "F",
			clear_filter = "C",
			toggle_project_scope = "P",
		},
		jobs = {
			open_output = "<CR>",
			rerun = "r",
			cancel = "x",
			clear = "D",
			copy_command = "y",
			filter = "F",
			clear_filter = "C",
			toggle_project_scope = "P",
		},
```

Dans `lua/dockyard/core/keymaps.lua` :

(a) Dans les classes de types, ajouter `---@field filter? DockyardKeymapValue`, `---@field clear_filter? DockyardKeymapValue` et `---@field toggle_project_scope? DockyardKeymapValue` à `DockyardImagesKeymaps`, `DockyardNetworksKeymaps`, `DockyardVolumesKeymaps` et `DockyardJobsKeymaps` (après leur dernier `@field`).

(b) Remplacer

```lua
local IMAGES_IDS = {
	"images.remove",
	"images.prune",
}

local NETWORKS_IDS = {
	"networks.remove",
}

local VOLUMES_IDS = {
	"volumes.remove",
}
```

par

```lua
local IMAGES_IDS = {
	"images.remove",
	"images.prune",
	"images.filter",
	"images.clear_filter",
	"images.toggle_project_scope",
}

local NETWORKS_IDS = {
	"networks.remove",
	"networks.filter",
	"networks.clear_filter",
	"networks.toggle_project_scope",
}

local VOLUMES_IDS = {
	"volumes.remove",
	"volumes.filter",
	"volumes.clear_filter",
	"volumes.toggle_project_scope",
}
```

(c) Dans `JOBS_IDS`, remplacer `"jobs.copy_command",` par

```lua
	"jobs.copy_command",
	"jobs.filter",
	"jobs.clear_filter",
	"jobs.toggle_project_scope",
```

- [ ] **Step 4: Run them to verify they pass**

Run: `make test`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lua/dockyard tests
git commit -m "feat: shared scope header, filter controller and keys for the other views" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Vue Images

**Files:**
- Modify: `lua/dockyard/ui/views/images/{state,renderer,controller,keymaps}.lua`
- Test: `tests/project_views_spec.lua`

**Interfaces:**
- Consumes: `scope.apply_images`, `scope_header.matches/block/key_label`, `view_filter.controller/push_items/push_removals` (Tasks 1 et 3).
- Produces: `require("dockyard.ui.views.images.renderer").select(images, containers, filter): shown, scoped` ; `images.controller.filter` (contrôleur de filtre) ; touches `F`/`C`/`P` (prune sur `X`).

- [ ] **Step 1: Write the failing test**

Créer `tests/project_views_spec.lua` :

```lua
local scope = require("dockyard.scope")
local config = require("dockyard.config")

local root = vim.fs.normalize(vim.fn.tempname() .. "/app")
vim.fn.mkdir(root, "p")
vim.fn.writefile({ "services: {}" }, root .. "/compose.yml")
scope.root = function()
	return root
end

local function scope_on(on)
	config.options.display.project_scope = on
	scope.reset()
end

local containers = {
	{ name = "app-api-1", image = "app-api", compose_project = "app", compose_dir = root },
	{ name = "app-cache-1", image = "redis:7", compose_project = "app", compose_dir = root },
	{ name = "other-db-1", image = "postgres:16", compose_project = "other", compose_dir = "/q/other" },
}

local function names(list, key)
	return vim.tbl_map(function(item)
		return item[key]
	end, list)
end

describe("images view selection", function()
	local renderer = require("dockyard.ui.views.images.renderer")
	local images = {
		{ id = "a1", repository = "app-api", tag = "latest", compose_project = "app" },
		{ id = "b2", repository = "redis", tag = "7" },
		{ id = "c3", repository = "postgres", tag = "16" },
		{ id = "d4", repository = "unrelated", tag = "1" },
	}

	it("shows the images of the project: built for it, or used by its containers", function()
		scope_on(true)
		local shown, scoped = renderer.select(images, containers, nil)
		eq({ "app-api", "redis" }, names(shown, "repository"))
		eq(2, #scoped)
	end)

	it("filters by repository, tag or id on top of the scope, counted against the scope", function()
		scope_on(true)
		local shown, scoped = renderer.select(images, containers, "REDIS")
		eq({ "redis" }, names(shown, "repository"))
		eq(2, #scoped)
		eq({ "app-api" }, names((renderer.select(images, containers, "a1")), "repository"))
		eq({ "redis" }, names((renderer.select(images, containers, "7")), "repository"))
	end)

	it("shows everything when the scope is off, and nothing for a filter that matches nothing", function()
		scope_on(false)
		eq(4, #renderer.select(images, containers, nil))
		eq({}, renderer.select(images, containers, "zzz"))
	end)
end)

describe("images view keys", function()
	it("has a filter controller and prune moved off P", function()
		local controller = require("dockyard.ui.views.images.controller")
		eq("function", type(controller.filter.prompt_filter))
		eq("X", require("dockyard.core.keymaps").key("images.prune"))
		eq("P", require("dockyard.core.keymaps").key("images.toggle_project_scope"))
	end)
end)

scope_on(config.defaults.display.project_scope)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim --headless --clean -l tests/run.lua tests/project_views_spec.lua`
Expected: FAIL (`attempt to call a nil value (field 'select')`, `controller.filter` nil).

- [ ] **Step 3: Write the implementation**

`lua/dockyard/ui/views/images/state.lua` : remplacer

```lua
---@field expanded table<string, boolean>
---@field spinner_frame string|nil
---@field poll_spinner SpinnerInstance|nil

---@class DockyardImagesViewState
local M = {
	expanded = {},
	spinner_frame = nil,
	poll_spinner = nil,
}
```

par

```lua
---@field expanded table<string, boolean>
---@field spinner_frame string|nil
---@field poll_spinner SpinnerInstance|nil
---@field filter string|nil text filter (case-insensitive substring)

---@class DockyardImagesViewState
local M = {
	expanded = {},
	spinner_frame = nil,
	poll_spinner = nil,
	filter = nil,
}
```

et, dans `M.reset`, remplacer `M.expanded = {}` par `M.expanded = {}\n\tM.filter = nil`.

`lua/dockyard/ui/views/images/renderer.lua` :

(a) Après `local icons = require("dockyard.ui.icons")`, ajouter :

```lua
local scope = require("dockyard.scope")
local scope_header = require("dockyard.ui.components.scope_header")
```

(b) Juste avant `local function draw()`, ajouter :

```lua
---The images to show: the ones of the project (when the scope is on), then the ones matching the filter.
---@param images Image[]
---@param containers Container[]
---@param filter string|nil
---@return Image[] shown, Image[] scoped
function M.select(images, containers, filter)
	local scoped = scope.apply_images(images, containers)
	local shown = vim.tbl_filter(function(image)
		return scope_header.matches({ image.repository or "", image.tag or "", image.id or "" }, filter)
	end, scoped)
	return shown, scoped
end

```

(c) Dans `draw`, remplacer

```lua
	local image = data_state.images.get_items()
	local container = data_state.containers.get_items()
```

par

```lua
	local all_images = data_state.images.get_items()
	local container = data_state.containers.get_items()
	local image, scoped = M.select(all_images, container, view_state.filter)
```

et, juste après

```lua
	table.insert(lines, "")

	local ok, body_lines, body_line_map, body_spans = pcall(build_body, width, image, container)
```

insérer entre les deux (donc après `table.insert(lines, "")`) :

```lua
	ui_utils.append_block(
		lines,
		spans,
		scope_header.block({
			scope_on = scope.enabled(),
			root = scope.root(),
			scoped = #scoped,
			total = #all_images,
			filter = view_state.filter,
			shown = #image,
			scope_key = scope_header.key_label("images.toggle_project_scope", "P"),
			clear_key = scope_header.key_label("images.clear_filter", "C"),
		})
	)

```

`lua/dockyard/ui/views/images/controller.lua` :

(a) Remplacer `function M.update(on_done, opts)` par `local function update_now(on_done, opts)` et, juste avant `function M.toggle(node)`, ajouter :

```lua
---@param on_done fun()|nil
---@param opts { force_update?: boolean }|nil
function M.update(on_done, opts)
	-- the scope needs the containers to tell which images are the project's
	require("dockyard.scope").ensure_containers(function()
		update_now(on_done, opts)
	end)
end

M.filter = require("dockyard.ui.components.view_filter").controller({
	view = "images",
	label = "images",
	state = view_state,
	render = function()
		renderer.render()
	end,
})

```

`lua/dockyard/ui/views/images/keymaps.lua` : ajouter `local view_filter = require("dockyard.ui.components.view_filter")` après `local resolver = …`, puis remplacer

```lua
	help.register(GROUP, items, { buffer = buf, index = INDEX })
end
```

par

```lua
	view_filter.push_items(items, "images", controller.filter, 20)

	help.register(GROUP, items, { buffer = buf, index = INDEX })
end
```

et, dans `M.teardown`, remplacer `help.remove(GROUP, items, { buffer = buf })` par

```lua
	view_filter.push_removals(items, "images")
	help.remove(GROUP, items, { buffer = buf })
```

- [ ] **Step 4: Run it to verify it passes**

Run: `make test`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lua/dockyard/ui/views/images tests/project_views_spec.lua
git commit -m "feat: project scope and filter in the Images view" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Vue Networks

**Files:**
- Modify: `lua/dockyard/ui/views/networks/{state,renderer,controller,keymaps}.lua`
- Test: `tests/project_views_spec.lua`

**Interfaces:**
- Consumes: `scope.apply_networks`, composants de la Task 3.
- Produces: `networks.renderer.select(networks, containers, filter): shown, scoped` ; `networks.controller.filter`.

- [ ] **Step 1: Write the failing test**

Dans `tests/project_views_spec.lua`, avant la dernière ligne (`scope_on(config.defaults…)`), ajouter :

```lua
describe("networks view selection", function()
	local renderer = require("dockyard.ui.views.networks.renderer")
	local networks = {
		{ id = "n1", name = "app_default", driver = "bridge", labels = "com.docker.compose.project=app,com.docker.compose.network=default" },
		{ id = "n2", name = "bridge", driver = "bridge", labels = "" },
		{ id = "n3", name = "other_net", driver = "overlay", labels = "com.docker.compose.project=other" },
	}

	it("shows the networks of the project, and keeps them when it has no container", function()
		scope_on(true)
		eq({ "app_default" }, names((renderer.select(networks, containers, nil)), "name"))
		eq({ "app_default" }, names((renderer.select(networks, {}, nil)), "name"))
	end)

	it("filters by name, driver or id", function()
		scope_on(false)
		eq({ "other_net" }, names((renderer.select(networks, containers, "overlay")), "name"))
		eq({ "bridge" }, names((renderer.select(networks, containers, "n2")), "name"))
		eq({ "app_default", "bridge", "other_net" }, names((renderer.select(networks, containers, "")), "name"))
		scope_on(true)
		local shown, scoped = renderer.select(networks, containers, "zzz")
		eq(0, #shown)
		eq(1, #scoped)
	end)

	it("has a filter controller", function()
		eq("function", type(require("dockyard.ui.views.networks.controller").filter.prompt_filter))
	end)
end)

```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim --headless --clean -l tests/run.lua tests/project_views_spec.lua`
Expected: FAIL (`attempt to call a nil value (field 'select')`).

- [ ] **Step 3: Write the implementation**

`lua/dockyard/ui/views/networks/state.lua` : ajouter `---@field filter string|nil text filter (case-insensitive substring)` après le dernier `@field` de la classe, `filter = nil,` dans la table `M`, et `M.filter = nil` dans `M.reset` (même forme que pour Images).

`lua/dockyard/ui/views/networks/renderer.lua` :

(a) Après la dernière ligne `local … = require(…)` du début du fichier, ajouter :

```lua
local scope = require("dockyard.scope")
local scope_header = require("dockyard.ui.components.scope_header")
```

(b) Juste avant `local function draw()`, ajouter :

```lua
---The networks to show: the ones of the project (when the scope is on), then the ones matching the filter.
---@param networks Network[]
---@param containers Container[]
---@param filter string|nil
---@return Network[] shown, Network[] scoped
function M.select(networks, containers, filter)
	local scoped = scope.apply_networks(networks, containers)
	local shown = vim.tbl_filter(function(network)
		return scope_header.matches({ network.name or "", network.driver or "", network.id or "" }, filter)
	end, scoped)
	return shown, scoped
end

```

(c) Dans `draw`, remplacer

```lua
	local networks = data_state.networks.get_items()
	local containers = data_state.containers.get_items()
```

par

```lua
	local all_networks = data_state.networks.get_items()
	local containers = data_state.containers.get_items()
	local networks, scoped = M.select(all_networks, containers, view_state.filter)
```

et insérer, entre `table.insert(lines, "")` et `local ok, body_lines, body_line_map, body_spans = pcall(build_body, width, networks, containers)`, le même bloc `ui_utils.append_block(lines, spans, scope_header.block({ … }))` que pour Images, avec `total = #all_networks`, `scoped = #scoped`, `shown = #networks`, `view_state.filter`, et les actions `"networks.toggle_project_scope"` / `"networks.clear_filter"`.

`lua/dockyard/ui/views/networks/controller.lua` : même modification que pour Images — `function M.update(on_done, opts)` devient `local function update_now(on_done, opts)`, et juste avant `function M.toggle(node)` on ajoute le nouveau `M.update` (qui passe par `require("dockyard.scope").ensure_containers`) et `M.filter = require("dockyard.ui.components.view_filter").controller({ view = "networks", label = "networks", state = view_state, render = function() renderer.render() end })`. (Vérifier les noms locaux `view_state`/`state` et `renderer` déjà présents dans ce fichier et utiliser ceux-là.)

`lua/dockyard/ui/views/networks/keymaps.lua` : comme Images — `local view_filter = require("dockyard.ui.components.view_filter")`, `view_filter.push_items(items, "networks", controller.filter, 20)` avant `help.register(...)`, et `view_filter.push_removals(items, "networks")` dans `M.teardown` avant `help.remove(...)`.

- [ ] **Step 4: Run it to verify it passes**

Run: `make test`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lua/dockyard/ui/views/networks tests/project_views_spec.lua
git commit -m "feat: project scope and filter in the Networks view" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Vue Volumes

**Files:**
- Modify: `lua/dockyard/ui/views/volumes/{state,renderer,controller,keymaps}.lua`
- Test: `tests/project_views_spec.lua`

**Interfaces:**
- Consumes: `scope.apply_volumes`, composants de la Task 3.
- Produces: `volumes.renderer.select(volumes, containers, filter): shown, scoped` ; `volumes.controller.filter`.

- [ ] **Step 1: Write the failing test**

Dans `tests/project_views_spec.lua`, avant la dernière ligne, ajouter :

```lua
describe("volumes view selection", function()
	local renderer = require("dockyard.ui.views.volumes.renderer")
	local volumes = {
		{ name = "app_data", driver = "local", labels = "com.docker.compose.project=app,com.docker.compose.volume=data" },
		{ name = "0f35a03bff05", driver = "local", labels = "com.docker.volume.anonymous=" },
		{ name = "other_data", driver = "local", labels = "com.docker.compose.project=other" },
	}

	it("shows the named volumes of the project and hides the anonymous ones", function()
		scope_on(true)
		eq({ "app_data" }, names((renderer.select(volumes, containers, nil)), "name"))
	end)

	it("filters by name or driver, and shows everything when the scope is off", function()
		scope_on(false)
		eq(3, #renderer.select(volumes, containers, nil))
		eq({ "other_data" }, names((renderer.select(volumes, containers, "OTHER")), "name"))
		eq(3, #renderer.select(volumes, containers, "local"))
	end)

	it("has a filter controller", function()
		eq("function", type(require("dockyard.ui.views.volumes.controller").filter.prompt_filter))
	end)
end)

```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim --headless --clean -l tests/run.lua tests/project_views_spec.lua`
Expected: FAIL (`attempt to call a nil value (field 'select')`).

- [ ] **Step 3: Write the implementation**

`lua/dockyard/ui/views/volumes/state.lua` : remplacer tout le contenu par

```lua
---@class DockyardVolumesViewState
---@field last_rendered_at integer|nil
---@field filter string|nil text filter (case-insensitive substring)

---@class DockyardVolumesViewState
local M = {
	last_rendered_at = nil,
	filter = nil,
}

return M
```

`lua/dockyard/ui/views/volumes/renderer.lua` :

(a) Après la ligne `local icons = require("dockyard.ui.icons")`, ajouter :

```lua
local scope = require("dockyard.scope")
local scope_header = require("dockyard.ui.components.scope_header")
```

(b) Juste avant `local function draw()`, ajouter :

```lua
---The volumes to show: the ones of the project (when the scope is on), then the ones matching the filter.
---@param volumes Volume[]
---@param containers Container[]
---@param filter string|nil
---@return Volume[] shown, Volume[] scoped
function M.select(volumes, containers, filter)
	local scoped = scope.apply_volumes(volumes, containers)
	local shown = vim.tbl_filter(function(volume)
		return scope_header.matches({ volume.name or "", volume.driver or "" }, filter)
	end, scoped)
	return shown, scoped
end

```

(c) Dans `draw`, remplacer `local volumes = data_state.volumes.get_items()` par

```lua
	local all_volumes = data_state.volumes.get_items()
	local volumes, scoped = M.select(all_volumes, data_state.containers.get_items(), view_state.filter)
```

et insérer, entre `table.insert(lines, "")` et `local ok, body_lines, body_line_map, body_spans = pcall(build_body, width, volumes)`, le bloc `ui_utils.append_block(lines, spans, scope_header.block({ … }))` (mêmes champs que pour Images, avec `total = #all_volumes`, `scoped = #scoped`, `shown = #volumes`, actions `"volumes.toggle_project_scope"` / `"volumes.clear_filter"`).

`lua/dockyard/ui/views/volumes/controller.lua` : `function M.update(on_done, opts)` devient `local function update_now(on_done, opts)` ; avant `---@param node { kind: string, item: Volume }|nil` (juste avant `function M.open_details`), ajouter

```lua
---@param on_done fun()|nil
---@param opts { force_update?: boolean }|nil
function M.update(on_done, opts)
	-- the scope needs the containers to know the project's names
	require("dockyard.scope").ensure_containers(function()
		update_now(on_done, opts)
	end)
end

M.filter = require("dockyard.ui.components.view_filter").controller({
	view = "volumes",
	label = "volumes",
	state = require("dockyard.ui.views.volumes.state"),
	render = function()
		renderer.render()
	end,
})

```

`lua/dockyard/ui/views/volumes/keymaps.lua` : `local view_filter = require("dockyard.ui.components.view_filter")` ; `view_filter.push_items(items, "volumes", controller.filter, 20)` avant `help.register(...)` ; `view_filter.push_removals(items, "volumes")` dans `M.teardown` avant `help.remove(...)`.

- [ ] **Step 4: Run it to verify it passes**

Run: `make test`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lua/dockyard/ui/views/volumes tests/project_views_spec.lua
git commit -m "feat: project scope and filter in the Volumes view" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Vue Jobs

**Files:**
- Modify: `lua/dockyard/ui/views/jobs/{state,renderer,controller,keymaps}.lua`
- Test: `tests/project_views_spec.lua`

**Interfaces:**
- Consumes: `scope.apply_jobs`, composants de la Task 3, `runner.format_cmd`.
- Produces: `jobs.renderer.select(jobs, filter): shown, scoped` ; `jobs.controller.filter`.

- [ ] **Step 1: Write the failing test**

Dans `tests/project_views_spec.lua`, avant la dernière ligne, ajouter :

```lua
describe("jobs view selection", function()
	local renderer = require("dockyard.ui.views.jobs.renderer")
	local jobs = {
		{ id = 1, title = "compose up all services", argv = { "docker", "compose", "up" }, cwd = root, status = "ok" },
		{ id = 2, title = "docker build web", argv = { "docker", "build", "." }, cwd = root .. "/web", status = "failed" },
		{ id = 3, title = "compose up other", argv = { "docker", "compose", "up" }, cwd = "/q/other", status = "ok" },
	}

	it("shows the jobs run inside the project", function()
		scope_on(true)
		eq({ 1, 2 }, names((renderer.select(jobs, nil)), "id"))
	end)

	it("filters by title, status, directory or command line", function()
		scope_on(false)
		eq({ 2 }, names((renderer.select(jobs, "BUILD")), "id"))
		eq({ 2 }, names((renderer.select(jobs, "failed")), "id"))
		eq({ 3 }, names((renderer.select(jobs, "/q/other")), "id"))
		eq({ 1, 2, 3 }, names((renderer.select(jobs, "docker")), "id"))
		scope_on(true)
		local shown, scoped = renderer.select(jobs, "nothing")
		eq(0, #shown)
		eq(2, #scoped)
	end)

	it("has a filter controller", function()
		eq("function", type(require("dockyard.ui.views.jobs.controller").filter.prompt_filter))
	end)
end)

```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim --headless --clean -l tests/run.lua tests/project_views_spec.lua`
Expected: FAIL (`attempt to call a nil value (field 'select')`).

- [ ] **Step 3: Write the implementation**

`lua/dockyard/ui/views/jobs/state.lua` : remplacer tout le contenu par

```lua
---@class DockyardJobsViewState
---@field off fun()|nil unsubscribe from the runner
---@field pending boolean a re-render is already scheduled
---@field filter string|nil text filter (case-insensitive substring)

---@type DockyardJobsViewState
local M = {
	off = nil,
	pending = false,
	filter = nil,
}

return M
```

`lua/dockyard/ui/views/jobs/renderer.lua` :

(a) Après `local ui_utils = require("dockyard.ui.utils")`, ajouter :

```lua
local scope = require("dockyard.scope")
local scope_header = require("dockyard.ui.components.scope_header")
local view_state = require("dockyard.ui.views.jobs.state")
```

(b) Juste avant `---@param jobs DockyardJob[]\nlocal function set_statusline_items(jobs)`, ajouter :

```lua
---The jobs to show: the ones run inside the project (when the scope is on), then the ones matching the filter.
---@param jobs DockyardJob[]
---@param filter string|nil
---@return DockyardJob[] shown, DockyardJob[] scoped
function M.select(jobs, filter)
	local scoped = scope.apply_jobs(jobs)
	local shown = vim.tbl_filter(function(job)
		return scope_header.matches({ job.title or "", job.status or "", job.cwd or "", runner.format_cmd(job.argv or {}) }, filter)
	end, scoped)
	return shown, scoped
end

```

(c) Dans `draw`, remplacer `local jobs = runner.list()` par

```lua
	local all_jobs = runner.list()
	local jobs, scoped = M.select(all_jobs, view_state.filter)
```

et insérer, entre `table.insert(lines, "")` et `local body_lines, body_line_map, body_spans = build_body(width, jobs)`, le bloc `ui_utils.append_block(lines, spans, scope_header.block({ … }))` (mêmes champs que pour Images, avec `total = #all_jobs`, `scoped = #scoped`, `shown = #jobs`, actions `"jobs.toggle_project_scope"` / `"jobs.clear_filter"`).

`lua/dockyard/ui/views/jobs/controller.lua` : avant `---@param node { kind: string, item: DockyardJob }|nil`, ajouter

```lua
M.filter = require("dockyard.ui.components.view_filter").controller({
	view = "jobs",
	label = "jobs",
	state = view_state,
	render = function()
		renderer.render()
	end,
})

```

`lua/dockyard/ui/views/jobs/keymaps.lua` : `local view_filter = require("dockyard.ui.components.view_filter")` et `local controller = require("dockyard.ui.views.jobs.controller")` en tête ; `view_filter.push_items(items, "jobs", controller.filter, 10)` avant `help.register(...)` ; `view_filter.push_removals(items, "jobs")` dans `M.teardown` avant `help.remove(...)`.

- [ ] **Step 4: Run it to verify it passes**

Run: `make test`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lua/dockyard/ui/views/jobs tests/project_views_spec.lua
git commit -m "feat: project scope and filter in the Jobs view" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Documentation et vérification réelle

**Files:**
- Modify: `README.md`, `doc/dockyard.txt`, `CHANGELOG.md`

**Interfaces:**
- Consumes: tout ce qui précède.
- Produces: documentation à jour.

- [ ] **Step 1: CHANGELOG**

Dans `CHANGELOG.md`, sous `## Unreleased`, ajouter à `### Added` :

```markdown
- Images, Networks, Volumes and Jobs show only the project Neovim works on, like Containers, when it has a compose file
  (`display.project_scope`); `P` shows everything again, in every view at once. Networks and volumes are matched through
  the compose project label, images when built for the project or used by one of its containers, jobs by the directory
  they ran in
- `F` filters and `C` clears the filter in those four views (`keymaps.<view>.filter`, `clear_filter`,
  `toggle_project_scope`)
```

et à `### Changed` :

```markdown
- Images: `prune` moved from `P` to `X` (`keymaps.images.prune`), `P` is the project scope as in the other views
```

- [ ] **Step 2: README**

Dans `README.md`, dans le bloc `> [!NOTE]` du fork, remplacer la puce `**Project scope** (\`P\`): only the containers of the project Neovim is working on, on by default in compose projects` par `**Project scope** (\`P\`): only the containers, images, networks, volumes and jobs of the project Neovim is working on, on by default in compose projects`, et la puce `**Container filter** (\`F\` / \`C\`)` par `**Filter** (\`F\` / \`C\`) in every view`. Dans la liste `## Features`, remplacer `- [x] Show only the containers of the current project` par `- [x] Show only the containers, images, networks, volumes and jobs of the current project`.

- [ ] **Step 3: Vimdoc**

Dans `doc/dockyard.txt` :

(a) Section 5, remplacer la ligne `Images view: \`d\` remove, \`P\` prune. Networks and volumes views: \`d\` remove.` par :

```
Images view: `d` remove, `X` prune. Networks and volumes views: `d` remove.
Images, networks, volumes and jobs views also have `F` filter, `C` clear the
filter and `P` project scope on / off, as the containers view
(|dockyard-scope|).
```

(b) Section 6 (`PROJECT SCOPE AND FILTER`), remplacer le paragraphe qui commence par ``P` shows only the containers of the project`` (jusqu'à la ligne `Containers started with a plain `docker run` have no project.`) par :

```
`P` shows only what belongs to the project Neovim works on, in every view at
once. The project is the git root of Neovim's working directory, or the
directory itself.

  Containers  started by a Docker Compose project from inside it, or from a
              parent directory (Neovim opened in a subdirectory)
  Networks    labelled with a compose project of the scope
  Volumes     same; anonymous volumes have no project and are hidden
  Images      built for a compose project of the scope, or used by one of its
              containers
  Jobs        run in a directory inside the project

The compose projects of the scope are the ones of those containers plus the
one of the compose file in the project root (its `name:`, else the directory
name), so the networks and volumes of a project without containers show up.
Containers started with a plain `docker run` have no project.
```

(c) Section 6, après `*dockyard-filter*`, remplacer `` `F` asks for a text and keeps the containers whose name, image, status, ports or compose project contain it, ignoring case. `C` clears it. `` par :

```
`F` asks for a text and keeps the rows that contain it, ignoring case, in the
current view: containers (name, image, status, ports, compose project), images
(repository, tag, id), networks (name, driver, id), volumes (name, driver),
jobs (title, status, directory, command). `C` clears it. The keys are
`keymaps.<view>.filter`, `clear_filter` and `toggle_project_scope`.
```

(d) Section 12 (configuration), dans `images = { remove = "d", prune = "P" },` remplacer par `images = { remove = "d", prune = "X" },` et ajouter, après les lignes `networks = …`, `volumes = …` et `jobs = {…}`, une phrase sous le bloc : `The images, networks, volumes and jobs groups also take filter = "F", clear_filter = "C" and toggle_project_scope = "P".` (à placer dans le paragraphe qui suit le bloc, avant `A keymap set to false is disabled`).

- [ ] **Step 4: Verify the docs**

Run: `nvim --headless --clean --cmd "set rtp^=." -c "helptags doc" -c "qa" 2>&1 | grep -c E154; git status --short`
Expected: `0` ; `doc/tags` n'apparaît pas (ignoré).

- [ ] **Step 5: Final verification**

Run: `make test`
Expected: `0 failed`.

Run: `nvim --headless --clean -c "set rtp^=." -c "checkhealth dockyard" -c "w! /tmp/dockyard-health.txt" -c "qa!"; grep -e ERROR /tmp/dockyard-health.txt`
Expected: aucune ligne ; le groupe `jobs`, `images`, `networks`, `volumes` : `no conflicting mapped keys`.

Vérification réelle avec Docker, dans la config de l'utilisateur (le plugin est chargé depuis ce clone) : un dossier temporaire avec un `compose.yml` (image locale, `pull_policy: never`) ; lancer le projet ; pour chacun des onglets Images, Networks, Volumes et Jobs vérifier que seules les ressources du projet sont listées, que `P` montre tout puis re-masque, que `F` restreint et `C` efface, et qu'un projet sans conteneur montre son réseau. Nettoyer avec `docker compose down -v`.

- [ ] **Step 6: Commit**

```bash
git add README.md doc/dockyard.txt CHANGELOG.md
git commit -m "docs: project scope and filter in every view" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

## Self-Review (rempli avant exécution)

**Couverture de la spec :** état partagé et règles d'appartenance (T1) ; labels des réseaux et des images via `docker image inspect` (T2) ; lignes `Project:`/`Filter:`, correspondance du filtre, touches `F`/`C`/`P` configurables et `prune` → `X`, conflits validés (T3) ; Images, Networks, Volumes, Jobs : sélection pure, en-tête, contrôleur, touches, chargement des conteneurs avant dessin (T4 à T7) ; documentation et vérification réelle (T8). Alias `containers/scope.lua` et picker (T1).

**Types et noms :** `scope.apply_*`, `scope.ensure_containers`, `scope.project_names/project_name/label/dir_matches`, `scope_header.matches/block/key_label`, `view_filter.controller/push_items/push_removals`, `renderer.select(...)` (Images/Networks/Volumes : `(items, containers, filter)` ; Jobs : `(jobs, filter)`) et `controller.filter` sont définis une fois et utilisés avec la même signature.

**Ordre de dépendance :** T2 n'a pas besoin de T1 ; T3 utilise `scope` (T1) ; T4 à T7 utilisent T1 et T3 ; T7 n'utilise pas les conteneurs.
