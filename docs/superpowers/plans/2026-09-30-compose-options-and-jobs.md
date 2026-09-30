# Options compose et vue Jobs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Choisir profils et flags compose (menu, défauts mémorisés par projet) et garder chaque commande lancée — ligne exacte, statut, durée, sortie complète — dans une vue « Jobs » du dashboard.

**Architecture:** un constructeur de commandes pur (`commands/compose.lua`), des préférences par projet (`commands/prefs.lua`), un registre de jobs sans UI (`commands/runner.lua`) ; `commands/executor.lua` reste la façade et branche le flottant. L'UI (vue Jobs, buffer de sortie, menu, flottant) ne fait que lire ces trois modules.

**Tech Stack:** Lua (LuaJIT, API 5.1), Neovim ≥ 0.10 (`vim.system`, `vim.uv`), `docker compose`. Tests : le mini-runner du dépôt (`tests/run.lua`, `make test`).

**Spec:** `docs/superpowers/specs/2026-09-30-compose-options-and-jobs-design.md` (dans le même dépôt). Trois écarts assumés par rapport à la spec, déjà reportés dedans : le buffer de sortie s'appelle `dockyard-job://<id>` (pas `dockyard://job/<id>`, qui déclencherait les autocmds du navigateur de fichiers), le menu est une liste verticale de cases, et la section « Cible » du menu est retirée (YAGNI).

**Répertoire de travail de toutes les commandes :** `/home/lois/dotfiles/.config/nvim/dockyard.nvim` (dépôt git imbriqué, branche `main`). Un test seul : `nvim --headless --clean -l tests/run.lua tests/<nom>_spec.lua` ; tous : `make test`.

## Global Constraints

- Neovim `>= 0.10` (README) : pas d'API plus récente sans repli ; `vim.system`, `vim.uv` sont disponibles.
- Lua 5.1 / LuaJIT uniquement ; indentation par tabulations dans `*.lua` (`.editorconfig`, `indent_size = 4`), 2 espaces dans `*.md`/`*.json`.
- Aucune nouvelle dépendance : ni busted, ni plenary. Les tests utilisent `describe`/`it`/`eq`/`truthy`/`buffer` de `tests/run.lua`.
- `plugin/dockyard.lua` reste léger : aucun module `dockyard.*` n'est chargé au démarrage (le test `does not load the plugin modules at startup` doit rester vert) et aucun mapping global n'est créé (seulement des `<Plug>`).
- Chaque option utilisateur est validée dans `config.validate` ; les options inconnues sont signalées par `config.unknown_keys` (elle lit l'arbre des défauts).
- Compat ascendante : aucune option existante ne change de sens ; `:DockyardRun`, `:DockyardBuild`, `:DockyardService` continuent de marcher ; `up -d --force-recreate` reste le comportement par défaut de `▶ Run`.
- `-v`, `--rmi` et `-V` ne sont jamais enregistrés dans les préférences ; `down` avec `-v` ou `--rmi` demande confirmation (Non par défaut).
- Tous les modules doivent se charger sans effet de bord (`tests/modules_spec.lua` les `require` tous).
- Commits : messages conventionnels (`feat:`, `test:`, `docs:`…) terminés par la ligne `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` (passée en second `-m`). Pas de `git push`.
- `make typecheck` (lua-language-server) et `selene`/`stylua` ne sont pas installés sur cette machine : les lancer s'ils existent, sinon le signaler dans le compte rendu final ; ne pas prétendre qu'ils ont passé.
- Dans ce shell, `rm` est aliasé en mode interactif : utiliser `command rm -f`.

## Review Focus

Entrées ou conditions que la spec sous-entend sans les décrire, les plus probables d'abord. Chacune a son test dans la tâche indiquée.

1. **`down -v` refusé** : répondre « Non » à la confirmation ne doit rien lancer (perte de données) — Task 9, `compose menu window`.
2. **Chemin de projet avec des espaces** : le fichier compose reste un seul argument, jamais recoupé par un shell — Task 2, `compose.build`.
3. **Sortie qui n'est pas de l'UTF-8** (un binaire, un log corrompu) : le job la garde et le buffer de sortie s'ouvre sans erreur — Task 5 (`runner`) et Task 8 (`job output with odd bytes`).
4. **Fichier compose absent** au moment de détecter les profils (renommé, supprimé) : aucune erreur, liste vide — Task 3, `profiles.detect`.
5. **`display.views` de l'utilisateur sans `"jobs"`** : `:Dockyard jobs` prévient au lieu de casser le dashboard — Task 8, `Jobs in the dashboard`.

---

### Task 1: Options `jobs`, `compose` et touches `jobs`

**Files:**
- Modify: `lua/dockyard/config.lua` (types, défauts, validation)
- Modify: `lua/dockyard/core/keymaps.lua` (types, `JOBS_IDS`, `validate`)
- Test: `tests/modules_spec.lua`

**Interfaces:**
- Consumes: rien.
- Produces: `config.options.jobs.history: integer`, `config.options.jobs.notice.close_after: integer`, `config.options.compose.defaults` (`force_recreate, build, no_deps, wait, remove_orphans: boolean`, `pull: false|"always"|"missing"|"never"`), `config.options.keymaps.jobs` (`open_output, rerun, cancel, clear, copy_command`), `require("dockyard.core.keymaps").validate().jobs`.

- [ ] **Step 1: Write the failing tests**

Dans `tests/modules_spec.lua`, dans `describe("config", ...)`, juste avant le test `finds unknown options but not container log configs`, ajouter :

```lua
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
```

Et à la fin du fichier :

```lua

describe("keymaps", function()
	it("the defaults of the Jobs view do not clash with each other or the general keys", function()
		eq({}, require("dockyard.core.keymaps").validate().jobs)
	end)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `nvim --headless --clean -l tests/run.lua tests/modules_spec.lua`
Expected: FAIL sur `reports wrong jobs and compose options` (aucune erreur `jobs.history`), `accepts a pull policy…` (options inconnues `compose`, `jobs`) et `keymaps › …` (`attempt to index a nil value`).

- [ ] **Step 3: Implement the options**

Dans `lua/dockyard/config.lua` :

(a) Remplacer

```lua
--- @class DockyardConfig
--- @field display? DisplayConfig Display settings
--- @field compose_lens? ComposeLensConfig Compose file actions
```

par

```lua
--- @class JobsNoticeConfig
--- @field close_after? integer Milliseconds before the notice of a finished job closes (failed jobs stay until `q`); 0 keeps it

--- @class JobsConfig
--- @field history? integer Finished jobs kept in the Jobs view
--- @field notice? JobsNoticeConfig

--- @class ComposeDefaultsConfig
--- @field force_recreate? boolean `up --force-recreate`
--- @field build? boolean `up --build`
--- @field pull? false|"always"|"missing"|"never" `up --pull`
--- @field no_deps? boolean `up --no-deps`
--- @field wait? boolean `up --wait`
--- @field remove_orphans? boolean `up --remove-orphans`

--- @class ComposeConfig
--- @field defaults? ComposeDefaultsConfig Flags of projects that have no saved preferences

--- @class DockyardConfig
--- @field display? DisplayConfig Display settings
--- @field compose_lens? ComposeLensConfig Compose file actions
--- @field compose? ComposeConfig Compose options
--- @field jobs? JobsConfig Command history and notices
```

(b) Dans `M.options`, remplacer

```lua
	compose_lens = {
		enabled = true,
	},
	loglens = {
```

par

```lua
	compose_lens = {
		enabled = true,
	},
	compose = {
		defaults = {
			force_recreate = true,
			build = false,
			pull = false,
			no_deps = false,
			wait = false,
			remove_orphans = false,
		},
	},
	jobs = {
		history = 50,
		notice = { close_after = 3000 },
	},
	loglens = {
```

(c) Dans `keymaps`, remplacer

```lua
		volumes = {
			remove = "d",
		},
		loglens = {
```

par

```lua
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
		loglens = {
```

(d) Dans `M.validate`, remplacer

```lua
	check("compose_lens", options.compose_lens, "table")
	check("loglens", options.loglens, "table")
```

par

```lua
	check("compose_lens", options.compose_lens, "table")
	check("compose", options.compose, "table")
	check("jobs", options.jobs, "table")
	check("loglens", options.loglens, "table")
```

(e) Toujours dans `M.validate`, remplacer

```lua
	if type(options.keymaps) == "table" then
		for context, maps
```

par

```lua
	if type(options.jobs) == "table" then
		check("jobs.history", options.jobs.history, "number")
		check("jobs.notice", options.jobs.notice, "table")
		if type(options.jobs.notice) == "table" then
			check("jobs.notice.close_after", options.jobs.notice.close_after, "number")
		end
	end
	if type(options.compose) == "table" then
		check("compose.defaults", options.compose.defaults, "table")
		local defaults = options.compose.defaults
		if type(defaults) == "table" then
			for _, name in ipairs({ "force_recreate", "build", "no_deps", "wait", "remove_orphans" }) do
				check("compose.defaults." .. name, defaults[name], "boolean")
			end
			local pull = defaults.pull
			if pull ~= false and pull ~= "always" and pull ~= "missing" and pull ~= "never" then
				table.insert(errors, 'compose.defaults.pull: expected false, "always", "missing" or "never", got ' .. vim.inspect(pull))
			end
		end
	end
	if type(options.keymaps) == "table" then
		for context, maps
```

(la ligne `for context, maps in pairs(options.keymaps) do` continue après ce `maps`, ne pas la casser).

Dans `lua/dockyard/core/keymaps.lua` :

(a) Avant `---@class DockyardLogLensKeymaps`, ajouter :

```lua
---@class DockyardJobsKeymaps
---@field open_output? DockyardKeymapValue
---@field rerun? DockyardKeymapValue
---@field cancel? DockyardKeymapValue
---@field clear? DockyardKeymapValue
---@field copy_command? DockyardKeymapValue

```

(b) Dans `DockyardKeymapsConfig`, remplacer `---@field volumes? DockyardVolumesKeymaps` par les deux lignes

```lua
---@field volumes? DockyardVolumesKeymaps
---@field jobs? DockyardJobsKeymaps
```

(c) Avant `local LOGLENS_IDS = {`, ajouter :

```lua
local JOBS_IDS = {
	"jobs.open_output",
	"jobs.rerun",
	"jobs.cancel",
	"jobs.clear",
	"jobs.copy_command",
}

```

(d) Dans `M.validate`, remplacer

```lua
function M.validate()
	return {
```

par

```lua
function M.validate()
	-- the Jobs view is a flat list: it has no expand / collapse key to clash with
	local ui_without_tree = vim.tbl_filter(function(id)
		return id ~= "ui.toggle_node"
	end, UI_IDS)
	return {
```

et, après la ligne `volumes = conflicts_for(concat(UI_IDS, VOLUMES_IDS), {}),`, ajouter :

```lua
		jobs = conflicts_for(concat(ui_without_tree, JOBS_IDS), {}),
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: `0 failed` (tous les specs existants restent verts).

- [ ] **Step 5: Commit**

```bash
git add lua/dockyard/config.lua lua/dockyard/core/keymaps.lua tests/modules_spec.lua
git commit -m "feat: jobs, compose and keymaps.jobs options" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Constructeur de commandes compose

**Files:**
- Create: `lua/dockyard/commands/compose.lua`
- Test: `tests/compose_spec.lua`

**Interfaces:**
- Consumes: rien.
- Produces:
  - `compose.base_cmd(): string[]` (`{"docker","compose"}` ou `{"docker-compose"}`)
  - `compose.project(file: string): DockyardComposeProject` (`{ files = {file}, dir = dirname }`)
  - `compose.build(project, action, opts?): string[]|nil, string|nil` avec `action ∈ up|down|stop|restart|build|pull|profiles` et `opts` = `DockyardComposeOpts` (`profiles, all_profiles, services, build, pull, force_recreate, no_deps, wait, remove_orphans, renew_anon_volumes, volumes, rmi`).

- [ ] **Step 1: Write the failing test**

Créer `tests/compose_spec.lua` :

```lua
local compose = require("dockyard.commands.compose")

-- do not depend on the docker binary of the machine running the tests
local real_base = compose.base_cmd
compose.base_cmd = function()
	return { "docker", "compose" }
end

local project = { files = { "/p/docker-compose.yml" }, dir = "/p" }

describe("compose.build", function()
	it("defaults to up -d", function()
		eq({ "docker", "compose", "-f", "/p/docker-compose.yml", "up", "-d" }, compose.build(project, "up"))
	end)

	it("puts global options before the verb and verb flags after it", function()
		local argv = compose.build(
			{ files = { "/p/a.yml", "/p/b.yml" }, dir = "/p", name = "demo", env_file = "/p/.env.dev" },
			"up",
			{ profiles = { "debug", "e2e" }, build = true, force_recreate = true, services = { "api", "db" } }
		)
		eq({
			"docker", "compose",
			"-f", "/p/a.yml", "-f", "/p/b.yml",
			"-p", "demo",
			"--env-file", "/p/.env.dev",
			"--profile", "debug", "--profile", "e2e",
			"up", "-d", "--build", "--force-recreate",
			"api", "db",
		}, argv)
	end)

	it("supports every up flag", function()
		local argv = compose.build(project, "up", {
			build = true,
			pull = "always",
			force_recreate = true,
			no_deps = true,
			wait = true,
			remove_orphans = true,
			renew_anon_volumes = true,
		})
		eq({
			"docker", "compose", "-f", "/p/docker-compose.yml",
			"up", "-d", "--build", "--pull", "always", "--force-recreate", "--no-deps", "--wait",
			"--remove-orphans", "-V",
		}, argv)
	end)

	it("treats pull = false as absent", function()
		eq({ "docker", "compose", "-f", "/p/docker-compose.yml", "up", "-d" }, compose.build(project, "up", { pull = false }))
	end)

	it("passes the active profiles to down, stop and restart too", function()
		for _, verb in ipairs({ "down", "stop", "restart" }) do
			eq(
				{ "docker", "compose", "-f", "/p/docker-compose.yml", "--profile", "debug", verb },
				compose.build(project, verb, { profiles = { "debug" } }),
				verb
			)
		end
	end)

	it("builds down -v --rmi --remove-orphans", function()
		eq(
			{ "docker", "compose", "-f", "/p/docker-compose.yml", "down", "-v", "--rmi", "local", "--remove-orphans" },
			compose.build(project, "down", { volumes = true, rmi = "local", remove_orphans = true })
		)
	end)

	it("uses --profile '*' for all profiles, ignoring the list", function()
		eq(
			{ "docker", "compose", "-f", "/p/docker-compose.yml", "--profile", "*", "up", "-d" },
			compose.build(project, "up", { all_profiles = true, profiles = { "debug" } })
		)
	end)

	it("ignores flags that do not belong to the action", function()
		eq(
			{ "docker", "compose", "-f", "/p/docker-compose.yml", "stop", "api" },
			compose.build(project, "stop", { build = true, volumes = true, services = { "api" } })
		)
	end)

	it("builds and pulls the given services", function()
		eq({ "docker", "compose", "-f", "/p/docker-compose.yml", "build", "api" }, compose.build(project, "build", { services = { "api" } }))
		eq({ "docker", "compose", "-f", "/p/docker-compose.yml", "pull" }, compose.build(project, "pull"))
	end)

	it("lists profiles without any profile flag", function()
		eq(
			{ "docker", "compose", "-f", "/p/docker-compose.yml", "config", "--profiles" },
			compose.build(project, "profiles", { profiles = { "debug" }, services = { "api" } })
		)
	end)

	it("keeps a path with spaces as a single argument", function()
		local argv = compose.build({ files = { "/my projects/app one/compose.yml" }, dir = "/my projects/app one" }, "up")
		eq("/my projects/app one/compose.yml", argv[4])
		eq(6, #argv)
	end)

	it("does not modify the options it is given", function()
		local opts = { profiles = { "debug" }, services = { "api" } }
		compose.build(project, "up", opts)
		eq({ profiles = { "debug" }, services = { "api" } }, opts)
	end)

	it("reports a missing file and an unknown action", function()
		local argv, err = compose.build({ files = {}, dir = "/p" }, "up")
		eq(nil, argv)
		eq("No compose file found", err)
		argv, err = compose.build(project, "explode")
		eq(nil, argv)
		eq("Unknown compose action: explode", err)
	end)
end)

describe("compose.base_cmd", function()
	it("prefers `docker compose`, falls back to docker-compose", function()
		compose.base_cmd = real_base
		local expected = vim.fn.executable("docker") == 1 and { "docker", "compose" } or { "docker-compose" }
		eq(expected, compose.base_cmd())
		compose.base_cmd = function()
			return { "docker", "compose" }
		end
	end)
end)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim --headless --clean -l tests/run.lua tests/compose_spec.lua`
Expected: FAIL `could not load: … module 'dockyard.commands.compose' not found`.

- [ ] **Step 3: Write the implementation**

Créer `lua/dockyard/commands/compose.lua` :

```lua
-- Builds `docker compose` command lines. Pure: no I/O besides the docker/docker-compose lookup.

local M = {}

---@class DockyardComposeProject
---@field files string[] compose files, in `-f` order
---@field dir string working directory
---@field name? string project name (`-p`)
---@field env_file? string `--env-file`

---@class DockyardComposeOpts
---@field profiles? string[]
---@field all_profiles? boolean `--profile '*'`
---@field services? string[]
---@field build? boolean up: `--build`
---@field pull? false|"always"|"missing"|"never" up: `--pull`
---@field force_recreate? boolean up
---@field no_deps? boolean up
---@field wait? boolean up
---@field remove_orphans? boolean up, down
---@field renew_anon_volumes? boolean up: `-V`
---@field volumes? boolean down: `-v`
---@field rmi? false|"local"|"all" down

---@return string[] base command parts
function M.base_cmd()
	if vim.fn.executable("docker") == 1 then
		return { "docker", "compose" }
	end
	return { "docker-compose" }
end

---The project of a compose file: the file alone, run from its directory.
---@param file string
---@return DockyardComposeProject
function M.project(file)
	return { files = { file }, dir = vim.fs.dirname(file) }
end

local function push(list, ...)
	for _, value in ipairs({ ... }) do
		table.insert(list, value)
	end
end

-- verb + its flags; `o` is the options table
local VERBS = {
	up = function(o)
		local a = { "up", "-d" }
		if o.build then
			push(a, "--build")
		end
		if o.pull then
			push(a, "--pull", o.pull == true and "always" or o.pull)
		end
		if o.force_recreate then
			push(a, "--force-recreate")
		end
		if o.no_deps then
			push(a, "--no-deps")
		end
		if o.wait then
			push(a, "--wait")
		end
		if o.remove_orphans then
			push(a, "--remove-orphans")
		end
		if o.renew_anon_volumes then
			push(a, "-V")
		end
		return a
	end,
	down = function(o)
		local a = { "down" }
		if o.volumes then
			push(a, "-v")
		end
		if o.rmi then
			push(a, "--rmi", o.rmi == true and "local" or o.rmi)
		end
		if o.remove_orphans then
			push(a, "--remove-orphans")
		end
		return a
	end,
	stop = function()
		return { "stop" }
	end,
	restart = function()
		return { "restart" }
	end,
	build = function()
		return { "build" }
	end,
	pull = function()
		return { "pull" }
	end,
	-- names of the profiles of a file; profile flags would be meaningless here
	profiles = function()
		return { "config", "--profiles" }
	end,
}

---@param project DockyardComposeProject
---@param action "up"|"down"|"stop"|"restart"|"build"|"pull"|"profiles"
---@param opts? DockyardComposeOpts
---@return string[]|nil argv, string|nil err
function M.build(project, action, opts)
	opts = opts or {}
	if not project or not project.files or #project.files == 0 then
		return nil, "No compose file found"
	end
	local verb = VERBS[action]
	if not verb then
		return nil, "Unknown compose action: " .. tostring(action)
	end

	local argv = M.base_cmd()
	for _, file in ipairs(project.files) do
		push(argv, "-f", file)
	end
	if project.name and project.name ~= "" then
		push(argv, "-p", project.name)
	end
	if project.env_file and project.env_file ~= "" then
		push(argv, "--env-file", project.env_file)
	end
	if action ~= "profiles" then
		if opts.all_profiles then
			push(argv, "--profile", "*")
		else
			for _, profile in ipairs(opts.profiles or {}) do
				push(argv, "--profile", profile)
			end
		end
	end
	for _, part in ipairs(verb(opts)) do
		table.insert(argv, part)
	end
	if action ~= "profiles" then
		for _, service in ipairs(opts.services or {}) do
			table.insert(argv, service)
		end
	end
	return argv
end

return M
```

- [ ] **Step 4: Run it to verify it passes**

Run: `nvim --headless --clean -l tests/run.lua tests/compose_spec.lua`
Expected: `14 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lua/dockyard/commands/compose.lua tests/compose_spec.lua
git commit -m "feat: pure builder for docker compose command lines" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Détection des profils

**Files:**
- Create: `lua/dockyard/commands/profiles.lua`
- Modify: `lua/dockyard/commands/context.lua` (profils de chaque service)
- Test: `tests/profiles_spec.lua`, `tests/context_spec.lua`

**Interfaces:**
- Consumes: `compose.build(project, "profiles")` (Task 2).
- Produces:
  - `profiles.parse_at(lines: string[], i: integer): string[]`
  - `profiles.scan(lines): string[]` (tous les profils du fichier, triés, uniques)
  - `profiles.parse_output(stdout): string[]`
  - `profiles.detect(file, on_done: fun(profiles: string[], source: "config"|"scan", err: string|nil))` (asynchrone, en cache par fichier+mtime)
  - `profiles.invalidate(file)`
  - `DockyardComposeService.profiles: string[]` (dans `context.compose_services(buf).services[i]`).

- [ ] **Step 1: Write the failing tests**

Créer `tests/profiles_spec.lua` :

```lua
local profiles = require("dockyard.commands.profiles")

describe("profiles.parse_at", function()
	it("reads an inline list", function()
		eq({ "debug", "e2e" }, profiles.parse_at({ "    profiles: [debug, 'e2e']" }, 1))
		eq({ "debug" }, profiles.parse_at({ '    profiles: ["debug"]  # dev only' }, 1))
	end)

	it("reads a block list, skipping comments and blank lines", function()
		local lines = {
			"    profiles:",
			"      - debug",
			"      # a comment",
			"",
			"      - \"tools\"",
			"    image: x",
		}
		eq({ "debug", "tools" }, profiles.parse_at(lines, 1))
	end)

	it("returns nothing for other keys", function()
		eq({}, profiles.parse_at({ "    image: x" }, 1))
	end)
end)

describe("profiles.scan", function()
	it("collects every profile of the file, sorted and unique", function()
		local lines = {
			"services:",
			"  api:",
			"    image: x",
			"  adminer:",
			"    profiles: [debug]",
			"  seed:",
			"    profiles:",
			"      - tools",
			"      - debug",
		}
		eq({ "debug", "tools" }, profiles.scan(lines))
	end)
end)

describe("profiles.parse_output", function()
	it("reads one profile per line", function()
		eq({ "debug", "tools" }, profiles.parse_output("tools\ndebug\n\n"))
		eq({}, profiles.parse_output(""))
	end)
end)

describe("profiles.detect", function()
	it("answers with no profile for a file that does not exist", function()
		local got
		profiles.detect("/definitely/not/here/compose.yml", function(list, source)
			got = { list, source }
		end)
		vim.wait(10000, function()
			return got ~= nil
		end)
		truthy(got, "detect never answered")
		eq({}, got[1])
		eq("scan", got[2])
	end)

	it("falls back to a text scan when docker cannot read the file", function()
		local dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
		local file = dir .. "/compose.yml"
		-- an unset required variable makes `docker compose config` fail
		vim.fn.writefile({
			"services:",
			"  api:",
			"    image: ${MISSING_VAR:?must be set}",
			"    profiles: [debug]",
		}, file)
		local got
		profiles.detect(file, function(list, source)
			got = { list, source }
		end)
		vim.wait(10000, function()
			return got ~= nil
		end)
		truthy(got, "detect never answered")
		eq({ "debug" }, got[1])
		-- without docker the answer is the scan as well
		truthy(got[2] == "scan" or got[2] == "config")
	end)
end)
```

Dans `tests/context_spec.lua`, juste avant `describe("compose_services", function()`, ajouter :

```lua
describe("compose_services profiles", function()
	it("reads inline and block profiles of each service", function()
		local block = context.compose_services(buffer({
			"services:",
			"  api:",
			"    image: x",
			"  adminer:",
			"    profiles: [debug]",
			"  seed:",
			"    profiles:",
			"      - tools",
			"      - debug",
		}))
		eq({}, block.services[1].profiles)
		eq({ "debug" }, block.services[2].profiles)
		eq({ "tools", "debug" }, block.services[3].profiles)
	end)
end)

```

- [ ] **Step 2: Run them to verify they fail**

Run: `nvim --headless --clean -l tests/run.lua tests/profiles_spec.lua tests/context_spec.lua`
Expected: FAIL (`module 'dockyard.commands.profiles' not found`, puis `attempt to index a nil value (field 'profiles')`).

- [ ] **Step 3: Write the implementation**

Créer `lua/dockyard/commands/profiles.lua` :

```lua
-- Compose profiles of a file: asked to `docker compose config --profiles`, with a text scan as fallback.

local M = {}

---@type table<string, { profiles: string[], source: "config"|"scan" }>
local cache = {}

local function unique_sorted(list)
	local seen, out = {}, {}
	for _, name in ipairs(list) do
		if name ~= "" and not seen[name] then
			seen[name] = true
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

local function clean(item)
	item = item:gsub("%s+#.*$", "")
	item = vim.trim(item)
	return (item:gsub("^[\"']", ""):gsub("[\"']$", ""))
end

---Profiles listed by the `profiles:` key at `lines[i]` (`[a, b]` or a `- a` list below it).
---@param lines string[]
---@param i integer
---@return string[]
function M.parse_at(lines, i)
	local line = lines[i] or ""
	local inline = line:match("profiles:%s*%[(.-)%]")
	if inline then
		return vim.tbl_map(clean, vim.split(inline, ",", { plain = true, trimempty = true }))
	end
	if not line:match("profiles:%s*$") and not line:match("profiles:%s+#") then
		return {}
	end
	local out = {}
	for j = i + 1, #lines do
		local item = lines[j]:match("^%s*%-%s*(.-)%s*$")
		if item then
			table.insert(out, clean(item))
		elseif not lines[j]:match("^%s*$") and not lines[j]:match("^%s*#") then
			break
		end
	end
	return out
end

---Every profile named in the file, found by text (a service's `profiles:` key).
---@param lines string[]
---@return string[]
function M.scan(lines)
	local out = {}
	for i, line in ipairs(lines) do
		if line:match("^%s+profiles:") then
			vim.list_extend(out, M.parse_at(lines, i))
		end
	end
	return unique_sorted(out)
end

---@param stdout string
---@return string[]
function M.parse_output(stdout)
	return unique_sorted(vim.tbl_map(vim.trim, vim.split(stdout or "", "\n", { plain = true })))
end

local function cache_key(file)
	local stat = vim.uv.fs_stat(file)
	return file .. ":" .. (stat and (stat.mtime.sec .. "." .. stat.mtime.nsec) or "missing")
end

function M.invalidate(file)
	for key in pairs(cache) do
		if vim.startswith(key, file .. ":") then
			cache[key] = nil
		end
	end
end

---@param file string
---@param on_done fun(profiles: string[], source: "config"|"scan", err: string|nil)
function M.detect(file, on_done)
	local key = cache_key(file)
	if cache[key] then
		return on_done(cache[key].profiles, cache[key].source, nil)
	end

	local function finish(profiles, source, err)
		cache[key] = { profiles = profiles, source = source }
		on_done(profiles, source, err)
	end
	local function fallback(err)
		local ok, lines = pcall(vim.fn.readfile, file)
		finish(M.scan(ok and lines or {}), "scan", err)
	end

	local argv = require("dockyard.commands.compose").build({ files = { file }, dir = vim.fs.dirname(file) }, "profiles")
	local ok, err = pcall(vim.system, argv, { text = true, cwd = vim.fs.dirname(file) }, function(res)
		vim.schedule(function()
			if res.code == 0 then
				finish(M.parse_output(res.stdout), "config", nil)
			else
				fallback(vim.trim(res.stderr or ""))
			end
		end)
	end)
	if not ok then
		vim.schedule(function()
			fallback(tostring(err))
		end)
	end
end

return M
```

Dans `lua/dockyard/commands/context.lua` :

(a) Remplacer

```lua
---@field has_build boolean the service defines a `build:` section
```

par

```lua
---@field has_build boolean the service defines a `build:` section
---@field profiles string[] its `profiles:`
```

(b) Remplacer

```lua
table.insert(result.services, { name = name, lnum = i, has_build = false })
```

par

```lua
table.insert(result.services, { name = name, lnum = i, has_build = false, profiles = {} })
```

(c) Remplacer

```lua
				if #lead == child_indent and name == "build" then
					result.services[#result.services].has_build = true
				end
```

par

```lua
				if #lead == child_indent and name == "build" then
					result.services[#result.services].has_build = true
				elseif #lead == child_indent and name == "profiles" then
					result.services[#result.services].profiles = require("dockyard.commands.profiles").parse_at(lines, i)
				end
```

- [ ] **Step 4: Run them to verify they pass**

Run: `nvim --headless --clean -l tests/run.lua tests/profiles_spec.lua tests/context_spec.lua`
Expected: `0 failed`. (Le test `falls back to a text scan…` accepte `source == "config"` ou `"scan"` selon que Docker est disponible.)

- [ ] **Step 5: Commit**

```bash
git add lua/dockyard/commands/profiles.lua lua/dockyard/commands/context.lua tests/profiles_spec.lua tests/context_spec.lua
git commit -m "feat: detect compose profiles, per file and per service" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Préférences par projet

**Files:**
- Create: `lua/dockyard/commands/prefs.lua`
- Modify: `lua/dockyard/health.lua`
- Test: `tests/prefs_spec.lua`

**Interfaces:**
- Consumes: `config.options.compose.defaults` (Task 1).
- Produces:
  - `prefs.path(): string` (remplaçable dans les tests)
  - `prefs.reset()` (oublie le cache mémoire)
  - `prefs.key(file): string` (chemin réel du fichier compose)
  - `prefs.defaults(): table` (`{ profiles = {}, all_profiles = false, <flags de la config> }`)
  - `prefs.get(file): table` (préférences sauvegardées par-dessus les défauts)
  - `prefs.set(file, prefs): boolean` (n'enregistre que `profiles`, `all_profiles`, `build, pull, force_recreate, no_deps, wait, remove_orphans`)
  - `prefs.check(): boolean, string|nil` (lecture seule, pour `:checkhealth`).

- [ ] **Step 1: Write the failing test**

Créer `tests/prefs_spec.lua` :

```lua
local prefs = require("dockyard.commands.prefs")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local store = dir .. "/data/projects.json"
prefs.path = function()
	return store
end

local project = dir .. "/compose.yml"
vim.fn.writefile({ "services: {}" }, project)

local function fresh()
	prefs.reset()
	vim.fn.delete(dir .. "/data", "rf")
	vim.fn.delete(store .. ".bak")
end

describe("prefs.get", function()
	it("returns the configured defaults for an unknown project", function()
		fresh()
		eq({
			profiles = {},
			all_profiles = false,
			force_recreate = true,
			build = false,
			pull = false,
			no_deps = false,
			wait = false,
			remove_orphans = false,
		}, prefs.get(project))
	end)
end)

describe("prefs.set", function()
	it("round-trips through the file", function()
		fresh()
		local p = prefs.get(project)
		p.profiles = { "debug" }
		p.build = true
		p.pull = "always"
		truthy(prefs.set(project, p))
		prefs.reset() -- read it back from disk
		local back = prefs.get(project)
		eq({ "debug" }, back.profiles)
		eq(true, back.build)
		eq("always", back.pull)
		eq(true, back.force_recreate)
	end)

	it("never stores destructive flags", function()
		fresh()
		local p = prefs.get(project)
		p.volumes = true
		p.rmi = "all"
		p.renew_anon_volumes = true
		prefs.set(project, p)
		local text = table.concat(vim.fn.readfile(store), "\n")
		eq(nil, text:find("volumes\":true", 1, true))
		eq(nil, text:find("rmi", 1, true))
		eq(nil, text:find("renew_anon_volumes", 1, true))
		prefs.reset()
		local back = prefs.get(project)
		eq(nil, back.volumes)
		eq(nil, back.rmi)
	end)

	it("keeps projects apart", function()
		fresh()
		local other = dir .. "/other.yml"
		vim.fn.writefile({ "services: {}" }, other)
		prefs.set(project, vim.tbl_extend("force", prefs.get(project), { profiles = { "a" } }))
		eq({}, prefs.get(other).profiles)
		eq({ "a" }, prefs.get(project).profiles)
	end)
end)

describe("prefs with a broken file", function()
	it("moves it aside and starts from the defaults", function()
		fresh()
		vim.fn.mkdir(dir .. "/data", "p")
		vim.fn.writefile({ "{ not json" }, store)
		local warned
		local orig = vim.notify
		vim.notify = function(msg)
			warned = msg
		end
		local got = prefs.get(project)
		vim.notify = orig
		eq(true, got.force_recreate)
		truthy(warned and warned:find("projects.json.bak", 1, true), tostring(warned))
		eq(1, vim.fn.filereadable(store .. ".bak"))
		eq(0, vim.fn.filereadable(store))
	end)

	it("ignores a file from another version", function()
		fresh()
		vim.fn.mkdir(dir .. "/data", "p")
		vim.fn.writefile({ '{"version":99,"projects":{}}' }, store)
		local orig = vim.notify
		vim.notify = function() end
		local got = prefs.get(project)
		vim.notify = orig
		eq(true, got.force_recreate)
		eq(1, vim.fn.filereadable(store .. ".bak"))
	end)
end)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim --headless --clean -l tests/run.lua tests/prefs_spec.lua`
Expected: FAIL `module 'dockyard.commands.prefs' not found`.

- [ ] **Step 3: Write the implementation**

Créer `lua/dockyard/commands/prefs.lua` :

```lua
-- Per-project compose preferences, kept in stdpath("data")/dockyard/projects.json.

local M = {}

local VERSION = 1

-- flags worth remembering; -v, --rmi and -V are deliberately left out: they destroy data
local FLAGS = { "build", "pull", "force_recreate", "no_deps", "wait", "remove_orphans" }

---@return string
function M.path()
	return vim.fn.stdpath("data") .. "/dockyard/projects.json"
end

---@type { version: integer, projects: table<string, table> }|nil
local data

---Forget what was read (tests, or after the file changed on disk).
function M.reset()
	data = nil
end

local function warn(msg)
	vim.notify("Dockyard: " .. msg, vim.log.levels.WARN)
end

local function load()
	if data then
		return data
	end
	data = { version = VERSION, projects = {} }
	local path = M.path()
	local fd = io.open(path, "r")
	if not fd then
		return data
	end
	local text = fd:read("*a")
	fd:close()
	local ok, decoded = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
	if ok and type(decoded) == "table" and decoded.version == VERSION and type(decoded.projects) == "table" then
		data = decoded
	else
		vim.uv.fs_rename(path, path .. ".bak")
		warn("could not read " .. path .. "; it was moved to projects.json.bak")
	end
	return data
end

---Read-only check of the file, for :checkhealth.
---@return boolean ok, string|nil problem
function M.check()
	local fd = io.open(M.path(), "r")
	if not fd then
		return true
	end
	local text = fd:read("*a")
	fd:close()
	local ok, decoded = pcall(vim.json.decode, text)
	if ok and type(decoded) == "table" and decoded.version == VERSION then
		return true
	end
	return false, "not valid JSON, or written by another version"
end

---@param file string compose file
---@return string
function M.key(file)
	return vim.uv.fs_realpath(file) or vim.fs.normalize(file)
end

---The defaults of a project that has no preferences yet.
---@return table
function M.defaults()
	local defaults = require("dockyard.config").options.compose.defaults
	return vim.tbl_extend("force", { profiles = {}, all_profiles = false }, vim.deepcopy(defaults))
end

---Saved preferences over the defaults.
---@param file string compose file
---@return table
function M.get(file)
	local saved = load().projects[M.key(file)] or {}
	local prefs = M.defaults()
	for _, name in ipairs(FLAGS) do
		if saved[name] ~= nil then
			prefs[name] = saved[name]
		end
	end
	if type(saved.profiles) == "table" then
		prefs.profiles = vim.deepcopy(saved.profiles)
	end
	if saved.all_profiles ~= nil then
		prefs.all_profiles = saved.all_profiles
	end
	return prefs
end

---Remember the persistent part of `prefs` for the project of `file`.
---@param file string compose file
---@param prefs table
---@return boolean ok
function M.set(file, prefs)
	local entry = { profiles = vim.deepcopy(prefs.profiles or {}), all_profiles = prefs.all_profiles == true }
	for _, name in ipairs(FLAGS) do
		entry[name] = prefs[name]
	end
	local current = load()
	current.projects[M.key(file)] = entry

	local path = M.path()
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	local tmp = path .. "." .. vim.uv.os_getpid() .. ".tmp"
	local fd, err = io.open(tmp, "w")
	if not fd then
		warn("could not save preferences: " .. tostring(err))
		return false
	end
	fd:write(vim.json.encode(current))
	fd:close()
	local renamed, rename_err = vim.uv.fs_rename(tmp, path)
	if not renamed then
		warn("could not save preferences: " .. tostring(rename_err))
		return false
	end
	return true
end

return M
```

Dans `lua/dockyard/health.lua`, remplacer

```lua
	--- Configuration
	vim.health.start("Configuration")
```

par

```lua
	local prefs_ok, prefs_problem = require("dockyard.commands.prefs").check()
	if prefs_ok then
		vim.health.ok("compose preferences file is readable")
	else
		vim.health.warn("compose preferences file (" .. require("dockyard.commands.prefs").path() .. "): " .. prefs_problem)
	end

	--- Configuration
	vim.health.start("Configuration")
```

- [ ] **Step 4: Run it to verify it passes**

Run: `nvim --headless --clean -l tests/run.lua tests/prefs_spec.lua && make test`
Expected: `6 passed` pour prefs, puis `0 failed` pour tout.

- [ ] **Step 5: Commit**

```bash
git add lua/dockyard/commands/prefs.lua lua/dockyard/health.lua tests/prefs_spec.lua
git commit -m "feat: per-project compose preferences" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Registre de jobs

**Files:**
- Create: `lua/dockyard/commands/runner.lua`
- Test: `tests/runner_spec.lua`

**Interfaces:**
- Consumes: `config.options.jobs.history` (Task 1).
- Produces (`DockyardJob = { id, title, argv, cwd, status = "running"|"ok"|"failed"|"cancelled", code, started_at (hrtime), started_time (os.time), ended_at, lines, omitted, project }`) :
  - `runner.start(spec: { argv, cwd?, title?, project?, on_exit?: fun(job) }): DockyardJob`
  - `runner.get(id)`, `runner.last()`, `runner.list()` (récent d'abord)
  - `runner.output(job): string[]` (avec la ligne « … N earlier lines omitted »)
  - `runner.cancel(id): boolean`, `runner.rerun(id): DockyardJob|nil`, `runner.clear_finished()`
  - `runner.subscribe(fn: fun(job|nil)): fun()` (renvoie la fonction de désabonnement ; `nil` = la liste a changé) ; l'autocmd `User DockyardJobChanged` est aussi émis
  - `runner.duration(job): number`, `runner.format_duration(seconds): string`, `runner.format_cmd(argv): string`.

- [ ] **Step 1: Write the failing test**

Créer `tests/runner_spec.lua` :

```lua
local runner = require("dockyard.commands.runner")
local config = require("dockyard.config")

local function wait_done(job)
	vim.wait(10000, function()
		return job.status ~= "running"
	end, 10)
	truthy(job.status ~= "running", "job never finished: " .. job.title)
end

local function sh(script, spec)
	return runner.start(vim.tbl_extend("force", { argv = { "sh", "-c", script } }, spec or {}))
end

describe("runner.start", function()
	it("keeps the output of stdout and stderr and marks success", function()
		local job = sh("echo one; echo two >&2")
		wait_done(job)
		eq("ok", job.status)
		eq(0, job.code)
		table.sort(job.lines)
		eq({ "one", "two" }, job.lines)
		truthy(job.ended_at >= job.started_at)
	end)

	it("marks a non-zero exit as failed and keeps the code", function()
		local job = sh("echo boom >&2; exit 3")
		wait_done(job)
		eq("failed", job.status)
		eq(3, job.code)
		eq({ "boom" }, job.lines)
	end)

	it("does not lose the last line when it has no newline", function()
		local job = sh("printf 'a\\nb'")
		wait_done(job)
		eq({ "a", "b" }, job.lines)
	end)

	it("does not lose output that arrives just before the exit", function()
		local job = sh("seq 1 20000")
		wait_done(job)
		eq(20000, #job.lines + job.omitted)
		eq("20000", job.lines[#job.lines])
	end)

	it("reassembles lines split across chunks", function()
		local job = sh("printf 'hel'; sleep 0.1; printf 'lo\\nworld\\n'")
		wait_done(job)
		eq({ "hello", "world" }, job.lines)
	end)

	it("strips ANSI sequences and keeps the last write of a carriage-return line", function()
		local job = sh("printf '\\033[32mgreen\\033[0m\\nload 1%%\\rload 100%%\\n'")
		wait_done(job)
		eq({ "green", "load 100%" }, job.lines)
	end)

	it("keeps output that is not valid UTF-8", function()
		local job = sh("printf '\\377\\376 bytes\\n'")
		wait_done(job)
		eq({ "\255\254 bytes" }, job.lines)
		eq("ok", job.status)
	end)

	it("fails without throwing when the binary does not exist", function()
		local job = runner.start({ argv = { "definitely-not-a-binary-xyz" } })
		wait_done(job)
		eq("failed", job.status)
		truthy(#job.lines >= 1)
	end)

	it("calls on_exit with the finished job", function()
		local seen
		local job = sh("exit 0", {
			on_exit = function(j)
				seen = j.status
			end,
		})
		wait_done(job)
		vim.wait(1000, function()
			return seen ~= nil
		end)
		eq("ok", seen)
	end)

	it("uses the cwd and the title it is given", function()
		local dir = vim.fn.resolve(vim.fn.tempname())
		vim.fn.mkdir(dir, "p")
		local job = sh("pwd", { cwd = dir, title = "where" })
		wait_done(job)
		eq("where", job.title)
		eq({ dir }, job.lines)
	end)
end)

describe("runner registry", function()
	it("lists newest first and finds jobs by id", function()
		runner.clear_finished()
		local a = sh("exit 0")
		local b = sh("exit 0")
		wait_done(a)
		wait_done(b)
		eq({ b.id, a.id }, vim.tbl_map(function(j)
			return j.id
		end, runner.list()))
		eq(b, runner.get(b.id))
		eq(b, runner.last())
	end)

	it("evicts the oldest finished jobs past the history limit, never a running one", function()
		runner.clear_finished()
		config.options.jobs.history = 2
		local running = sh("sleep 5")
		local a = sh("exit 0")
		wait_done(a)
		local b = sh("exit 0")
		wait_done(b)
		local c = sh("exit 0")
		wait_done(c)
		vim.wait(200)
		eq("running", runner.get(running.id).status)
		eq(nil, runner.get(a.id))
		truthy(runner.get(c.id))
		runner.cancel(running.id)
		wait_done(running)
		config.options.jobs.history = 50
	end)

	it("clear_finished keeps running jobs", function()
		runner.clear_finished()
		local running = sh("sleep 5")
		local done = sh("exit 0")
		wait_done(done)
		runner.clear_finished()
		truthy(runner.get(running.id))
		eq(nil, runner.get(done.id))
		runner.cancel(running.id)
		wait_done(running)
	end)

	it("cancels a running job", function()
		local job = sh("sleep 30")
		eq(true, runner.cancel(job.id))
		wait_done(job)
		eq("cancelled", job.status)
		eq(false, runner.cancel(job.id))
	end)

	it("reruns a job with the same command", function()
		local job = sh("echo again", { title = "t" })
		wait_done(job)
		local again = runner.rerun(job.id)
		wait_done(again)
		truthy(again.id ~= job.id)
		eq(job.argv, again.argv)
		eq({ "again" }, again.lines)
		eq("t", again.title)
	end)

	it("tells the subscribers about changes", function()
		local seen = {}
		local off = runner.subscribe(function(job)
			table.insert(seen, job and job.status or "list")
		end)
		local job = sh("exit 0")
		wait_done(job)
		off()
		truthy(vim.tbl_contains(seen, "running"), vim.inspect(seen))
		truthy(vim.tbl_contains(seen, "ok"), vim.inspect(seen))
		local n = #seen
		sh("exit 0")
		vim.wait(200)
		eq(n, #seen)
	end)

	it("drops the oldest lines of a huge output and says so", function()
		local job = sh("seq 1 6000")
		wait_done(job)
		truthy(job.omitted > 0)
		local out = runner.output(job)
		truthy(out[1]:find("earlier lines omitted", 1, true), out[1])
		eq("6000", out[#out])
		eq(6000, #job.lines + job.omitted)
	end)
end)

describe("runner helpers", function()
	it("formats durations", function()
		eq("250ms", runner.format_duration(0.25))
		eq("3.2s", runner.format_duration(3.24))
		eq("1m 04s", runner.format_duration(64))
	end)

	it("formats a command line, quoting what needs it", function()
		eq("docker compose -f /p/a.yml up -d", runner.format_cmd({ "docker", "compose", "-f", "/p/a.yml", "up", "-d" }))
		eq("docker --profile '*' up", runner.format_cmd({ "docker", "--profile", "*", "up" }))
		eq("echo 'a b'", runner.format_cmd({ "echo", "a b" }))
	end)
end)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim --headless --clean -l tests/run.lua tests/runner_spec.lua`
Expected: FAIL `module 'dockyard.commands.runner' not found`.

- [ ] **Step 3: Write the implementation**

Créer `lua/dockyard/commands/runner.lua` :

```lua
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
```

- [ ] **Step 4: Run it to verify it passes**

Run: `nvim --headless --clean -l tests/run.lua tests/runner_spec.lua`
Expected: `19 passed, 0 failed` (quelques secondes : certains cas attendent des commandes de 0,2 s).

- [ ] **Step 5: Commit**

```bash
git add lua/dockyard/commands/runner.lua tests/runner_spec.lua
git commit -m "feat: job registry that keeps the command line and the whole output" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Façade `executor` et flottant persistant en cas d'échec

**Files:**
- Modify: `lua/dockyard/commands/executor.lua` (réécrit : façade)
- Create: `lua/dockyard/ui/popups/job_notice.lua`
- Test: `tests/notice_spec.lua`

**Interfaces:**
- Consumes: `runner.start`, `runner.subscribe`, `runner.output`, `runner.format_cmd`, `runner.format_duration`, `runner.duration` (Task 5) ; `config.options.jobs.notice.close_after` (Task 1) ; `dockyard.ui.views.jobs.output.open(id)` (Task 8, appelé seulement sur `<CR>` : le module n'existe pas encore, il n'est requis qu'à ce moment-là).
- Produces:
  - `executor.run(args, opts?: { cwd?, title?, project?, on_exit?: fun(ok: boolean) }): DockyardJob|nil` (même signature qu'avant, plus `project`)
  - `job_notice.show(job)`, `job_notice.close()`, `job_notice.build_lines(job): string[]`.

- [ ] **Step 1: Write the failing test**

Créer `tests/notice_spec.lua` :

```lua
local config = require("dockyard.config")
local notice = require("dockyard.ui.popups.job_notice")

local function wait_done(job)
	vim.wait(10000, function()
		return job.status ~= "running"
	end, 10)
	truthy(job.status ~= "running", "job never finished")
end

local function fake(fields)
	return vim.tbl_extend("force", {
		id = 1,
		title = "compose up api",
		argv = { "docker", "compose", "up", "-d", "api" },
		cwd = "/p",
		status = "ok",
		code = 0,
		started_at = 0,
		started_time = 0,
		ended_at = 3.2e9,
		lines = {},
		omitted = 0,
	}, fields or {})
end

describe("job notice", function()
	it("shows the command, the last five lines and a failure hint", function()
		local lines = {}
		for i = 1, 8 do
			table.insert(lines, "line " .. i)
		end
		local got = notice.build_lines(fake({ lines = lines, status = "failed", code = 2 }))
		eq(" $ docker compose up -d api", got[1])
		eq(" line 4", got[2])
		eq(" line 8", got[6])
		eq(" ✖ Failed (exit 2) · <CR> full output · q close", got[7])
	end)

	it("stays open for a failure and closes after a success", function()
		config.options.jobs.notice.close_after = 100
		local executor = require("dockyard.commands.executor")
		local function count_floats()
			return #vim.tbl_filter(function(w)
				return vim.api.nvim_win_get_config(w).relative ~= ""
			end, vim.api.nvim_list_wins())
		end

		local bad = executor.run({ "sh", "-c", "echo boom >&2; exit 2" }, { title = "bad" })
		wait_done(bad)
		vim.wait(400)
		eq(1, count_floats())
		notice.close()
		eq(0, count_floats())

		local good = executor.run({ "sh", "-c", "echo fine" }, { title = "good" })
		wait_done(good)
		eq(true, vim.wait(2000, function()
			return count_floats() == 0
		end, 20))
		config.options.jobs.notice.close_after = 3000
	end)

	it("calls on_exit with a boolean, as before", function()
		local executor = require("dockyard.commands.executor")
		local seen = {}
		local ok = executor.run({ "sh", "-c", "exit 0" }, { on_exit = function(v) seen.ok = v end })
		local ko = executor.run({ "sh", "-c", "exit 1" }, { on_exit = function(v) seen.ko = v end })
		wait_done(ok)
		wait_done(ko)
		vim.wait(1000, function()
			return seen.ok ~= nil and seen.ko ~= nil
		end)
		eq({ ok = true, ko = false }, seen)
		notice.close()
	end)
end)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim --headless --clean -l tests/run.lua tests/notice_spec.lua`
Expected: FAIL `module 'dockyard.ui.popups.job_notice' not found`.

- [ ] **Step 3: Write the implementation**

Créer `lua/dockyard/ui/popups/job_notice.lua` :

```lua
-- Small floating notice for the job that was just started: the command, the tail of its output and
-- how it ended. A failed job stays until `q`; <CR> opens its whole output.

local M = {}

local runner = require("dockyard.commands.runner")
local statusline = require("dockyard.ui.statusline")

local WIN_WIDTH = 60
local RIGHT_PADDING = 4
local OUTPUT_LINES = 5
local MAX_HEIGHT = 10

local ns = vim.api.nvim_create_namespace("dockyard.job_notice")

---@type { job: DockyardJob, win: integer, buf: integer, off: fun(), spinner: SpinnerInstance, timer: uv.uv_timer_t|nil }|nil
local current

---@param job DockyardJob
---@return string[]
function M.build_lines(job)
	local lines = { " $ " .. runner.format_cmd(job.argv) }
	local tail = {}
	local output = runner.output(job)
	for i = #output, 1, -1 do
		if output[i]:match("%S") then
			table.insert(tail, 1, " " .. output[i])
			if #tail == OUTPUT_LINES then
				break
			end
		end
	end
	vim.list_extend(lines, tail)
	if job.status == "ok" then
		table.insert(lines, (" ✔ Done in %s"):format(runner.format_duration(runner.duration(job))))
	elseif job.status == "failed" then
		table.insert(lines, (" ✖ Failed (exit %s) · <CR> full output · q close"):format(tostring(job.code)))
	elseif job.status == "cancelled" then
		table.insert(lines, " ⊘ Cancelled")
	end
	return lines
end

---@param lines string[]
---@param width integer
---@return integer
local function wrapped_height(lines, width)
	local height = 0
	for _, line in ipairs(lines) do
		height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
	end
	return height
end

function M.close()
	local c = current
	if not c then
		return
	end
	current = nil
	c.off()
	c.spinner:stop()
	if c.timer and not c.timer:is_closing() then
		c.timer:stop()
		c.timer:close()
	end
	if vim.api.nvim_win_is_valid(c.win) then
		pcall(vim.api.nvim_win_close, c.win, true)
	end
end

local function set_title(c, prefix)
	if vim.api.nvim_win_is_valid(c.win) then
		pcall(vim.api.nvim_win_set_config, c.win, { title = " " .. prefix .. " " .. c.job.title .. " ", title_pos = "center" })
	end
end

local function render(c)
	if not vim.api.nvim_buf_is_valid(c.buf) or not vim.api.nvim_win_is_valid(c.win) then
		return M.close()
	end
	local lines = M.build_lines(c.job)
	vim.api.nvim_set_option_value("modifiable", true, { buf = c.buf })
	vim.api.nvim_buf_set_lines(c.buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = c.buf })
	vim.api.nvim_buf_clear_namespace(c.buf, ns, 0, -1)
	vim.api.nvim_buf_set_extmark(c.buf, ns, 0, 0, { end_row = 0, end_col = #lines[1], hl_group = "DockyardMuted" })
	local status = c.job.status
	if status ~= "running" then
		local last = #lines - 1
		local hl = status == "ok" and "DiagnosticOk" or status == "failed" and "DiagnosticError" or "DiagnosticWarn"
		vim.api.nvim_buf_set_extmark(c.buf, ns, last, 0, { end_row = last, end_col = #lines[#lines], hl_group = hl, hl_eol = true })
	end
	local width = vim.api.nvim_win_get_width(c.win)
	pcall(vim.api.nvim_win_set_height, c.win, math.min(MAX_HEIGHT, wrapped_height(lines, width)))
	pcall(vim.api.nvim_win_set_cursor, c.win, { #lines, 0 })
end

local function on_finished(c)
	c.spinner:stop()
	local icons = { ok = "✔", failed = "✖", cancelled = "⊘" }
	set_title(c, icons[c.job.status] or "")
	local delay = require("dockyard.config").options.jobs.notice.close_after
	if c.job.status ~= "failed" and delay > 0 then
		c.timer = vim.defer_fn(function()
			if current == c then
				M.close()
			end
		end, delay)
	end
end

---@param job DockyardJob
function M.show(job)
	M.close()
	local source_win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	local width = math.max(20, math.min(WIN_WIDTH, vim.o.columns - 2))
	local win = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		width = width,
		height = 1,
		row = 1,
		col = math.max(0, vim.o.columns - width - RIGHT_PADDING),
		style = "minimal",
		border = "rounded",
		title = " " .. job.title .. " ",
		title_pos = "center",
		zindex = 260,
		focusable = true,
	})
	vim.api.nvim_set_option_value("wrap", true, { win = win })
	vim.api.nvim_set_option_value("cursorline", false, { win = win })
	statusline.inherit(win, source_win)

	local c = { job = job, win = win, buf = buf }
	current = c
	c.spinner = require("dockyard.ui.components.spinner").create({
		on_tick = function(frame)
			set_title(c, frame)
		end,
	})
	c.spinner:start()

	local finished = false
	local function refresh()
		if current ~= c then
			return
		end
		render(c)
		if job.status ~= "running" and not finished then
			finished = true
			on_finished(c)
		end
	end
	c.off = runner.subscribe(function(changed)
		if changed == job then
			refresh()
		end
	end)

	vim.keymap.set("n", "q", M.close, { buffer = buf, silent = true, nowait = true })
	vim.keymap.set("n", "<CR>", function()
		M.close()
		require("dockyard.ui.views.jobs.output").open(job.id)
	end, { buffer = buf, silent = true, nowait = true })

	refresh()
end

vim.api.nvim_create_autocmd("VimLeavePre", {
	group = vim.api.nvim_create_augroup("DockyardJobNotice", { clear = true }),
	callback = M.close,
})

return M
```

Remplacer **tout** le contenu de `lua/dockyard/commands/executor.lua` par :

```lua
-- Runs a command and shows it in a notice. The job itself lives in commands/runner.

local M = {}

local runner = require("dockyard.commands.runner")

---@param args string[] Command and arguments
---@param opts { cwd?: string, title?: string, project?: string, on_exit?: fun(ok: boolean) }|nil
---@return DockyardJob|nil
function M.run(args, opts)
	opts = opts or {}
	if not args or #args == 0 then
		vim.notify("Dockyard: no command to run", vim.log.levels.WARN)
		return nil
	end

	local job = runner.start({
		argv = args,
		cwd = opts.cwd,
		title = opts.title,
		project = opts.project,
		on_exit = function(finished)
			if opts.on_exit then
				opts.on_exit(finished.status == "ok")
			end
		end,
	})
	require("dockyard.ui.popups.job_notice").show(job)
	return job
end

return M
```

- [ ] **Step 4: Run it to verify it passes**

Run: `make test`
Expected: `0 failed`. Les appelants existants (`compose_lens`, `commands/init`, `dockerfile_lens`) passent toujours `{ cwd, title, on_exit }` : rien d'autre à changer ici.

- [ ] **Step 5: Commit**

```bash
git add lua/dockyard/commands/executor.lua lua/dockyard/ui/popups/job_notice.lua tests/notice_spec.lua
git commit -m "feat: keep failed command notices open and show the exact command" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `compose_run` et branchement des actions existantes

**Files:**
- Create: `lua/dockyard/commands/compose_run.lua`
- Modify: `lua/dockyard/commands/init.lua`, `lua/dockyard/commands/builder.lua`, `lua/dockyard/compose_lens.lua`
- Test: `tests/compose_run_spec.lua`

**Interfaces:**
- Consumes: `compose.project`, `compose.build` (Task 2), `prefs.get`, `prefs.key` (Task 4), `executor.run` (Task 6).
- Produces: `compose_run.run(file, action, extra?, run_opts?: { on_exit?: fun(ok: boolean) }): DockyardJob|nil` — applique les préférences du projet, puis `extra` (services, drapeaux ponctuels). Titre du job : `compose <action> <services|all services>`.

- [ ] **Step 1: Write the failing test**

Créer `tests/compose_run_spec.lua` :

```lua
local prefs = require("dockyard.commands.prefs")
local compose = require("dockyard.commands.compose")
local executor = require("dockyard.commands.executor")
local compose_run = require("dockyard.commands.compose_run")

compose.base_cmd = function()
	return { "docker", "compose" }
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
prefs.path = function()
	return dir .. "/data/projects.json"
end
local file = dir .. "/compose.yml"
vim.fn.writefile({ "services: {}" }, file)

-- capture what would be run
local calls = {}
local real_run = executor.run
executor.run = function(argv, opts)
	table.insert(calls, { argv = argv, opts = opts })
	return { id = 0 }
end

describe("compose_run.run", function()
	it("runs up with the defaults of a project that has no preferences", function()
		prefs.reset()
		calls = {}
		compose_run.run(file, "up")
		eq({ "docker", "compose", "-f", file, "up", "-d", "--force-recreate" }, calls[1].argv)
		eq(dir, calls[1].opts.cwd)
		eq("compose up all services", calls[1].opts.title)
		eq(prefs.key(file), calls[1].opts.project)
	end)

	it("uses the saved profiles and flags, and the given services", function()
		prefs.reset()
		local saved = prefs.get(file)
		saved.profiles = { "debug" }
		saved.build = true
		prefs.set(file, saved)
		calls = {}
		compose_run.run(file, "up", { services = { "api", "db" } })
		eq({ "docker", "compose", "-f", file, "--profile", "debug", "up", "-d", "--build", "--force-recreate", "api", "db" }, calls[1].argv)
		eq("compose up api, db", calls[1].opts.title)
	end)

	it("lets one-shot flags through without saving them", function()
		prefs.reset()
		calls = {}
		compose_run.run(file, "down", { volumes = true })
		eq({ "docker", "compose", "-f", file, "--profile", "debug", "down", "-v" }, calls[1].argv)
		prefs.reset()
		eq(nil, prefs.get(file).volumes)
	end)

	it("hands on_exit to the executor", function()
		calls = {}
		local function cb() end
		compose_run.run(file, "stop", nil, { on_exit = cb })
		eq(cb, calls[1].opts.on_exit)
	end)

	it("reports an unknown action instead of running", function()
		calls = {}
		local orig = vim.notify
		local msg
		vim.notify = function(m)
			msg = m
		end
		compose_run.run(file, "explode")
		vim.notify = orig
		eq(0, #calls)
		truthy(msg and msg:find("Unknown compose action"), tostring(msg))
	end)
end)

executor.run = real_run
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim --headless --clean -l tests/run.lua tests/compose_run_spec.lua`
Expected: FAIL `module 'dockyard.commands.compose_run' not found`.

- [ ] **Step 3: Write the implementation**

Créer `lua/dockyard/commands/compose_run.lua` :

```lua
-- Runs a compose action for a file with the project's saved preferences.

local compose = require("dockyard.commands.compose")
local prefs = require("dockyard.commands.prefs")
local executor = require("dockyard.commands.executor")

local M = {}

---@param file string compose file
---@param action "up"|"down"|"stop"|"restart"|"build"|"pull"
---@param extra? DockyardComposeOpts overrides the saved preferences (services, one-shot flags)
---@param run_opts? { on_exit?: fun(ok: boolean) }
---@return DockyardJob|nil
function M.run(file, action, extra, run_opts)
	local project = compose.project(file)
	local opts = vim.tbl_extend("force", prefs.get(file), extra or {})
	local argv, err = compose.build(project, action, opts)
	if not argv then
		vim.notify("Dockyard: " .. tostring(err), vim.log.levels.ERROR)
		return nil
	end
	local services = opts.services or {}
	local label = #services > 0 and table.concat(services, ", ") or "all services"
	return executor.run(argv, {
		cwd = project.dir,
		title = "compose " .. action .. " " .. label,
		project = prefs.key(file),
		on_exit = run_opts and run_opts.on_exit,
	})
end

return M
```

Remplacer **tout** le contenu de `lua/dockyard/commands/init.lua` par :

```lua
local M = {}

local context = require("dockyard.commands.context")
local builder = require("dockyard.commands.builder")
local executor = require("dockyard.commands.executor")
local compose_run = require("dockyard.commands.compose_run")

local function save_if_modified()
	if vim.bo.modified then
		vim.cmd("silent! write")
	end
end

function M.build()
	save_if_modified()
	local ctx = context.detect()

	if ctx.type ~= "dockerfile" then
		vim.notify("Dockyard: not in a Dockerfile context", vim.log.levels.WARN)
		return
	end

	local args, err = builder.build_cmd(ctx)
	if not args then
		vim.notify("Dockyard: " .. tostring(err), vim.log.levels.ERROR)
		return
	end

	executor.run(args, { cwd = ctx.dir, title = "docker build" })
end

---@param line1 integer 1-based start line
---@param line2 integer 1-based end line
function M.run_visual(line1, line2)
	save_if_modified()
	local file = context.current_file()
	if not file or not context.is_compose_file(file) then
		vim.notify("Dockyard: not in a compose file", vim.log.levels.WARN)
		return
	end

	local services = context.services_in_range(line1, line2)
	if #services == 0 then
		vim.notify("Dockyard: no services found in selection", vim.log.levels.WARN)
		return
	end

	compose_run.run(file, "up", { services = services })
end

function M.run_all()
	save_if_modified()
	local ctx = context.detect()

	if ctx.type ~= "compose" and ctx.type ~= "project" then
		vim.notify("Dockyard: no compose file found", vim.log.levels.WARN)
		return
	end

	compose_run.run(ctx.file, "up")
end

return M
```

Remplacer **tout** le contenu de `lua/dockyard/commands/builder.lua` par (seules les parties Dockerfile restent ; `run_cmd`/`run_all_cmd`/`compose_base` sont remplacés par `compose.build`) :

```lua
local M = {}

---Image tag used by :DockyardBuild: the build directory's name.
---@param dir string
---@return string
function M.image_tag(dir)
	local tag = vim.fn.fnamemodify(dir, ":t"):lower():gsub("[^%w%-_]", "")
	if tag == "" then
		tag = "dockyard-build"
	end
	return tag
end

---@param ctx DockyardContext
---@return string[]|nil args, string|nil error
function M.build_cmd(ctx)
	if not ctx or not ctx.file then
		return nil, "No docker file found"
	end

	if ctx.type == "dockerfile" then
		local dir = ctx.dir
		local args = { "docker", "build", "-f", ctx.file, "-t", M.image_tag(dir), dir }
		return args, nil
	end

	return nil, "Cannot build command for context type: " .. tostring(ctx.type)
end

return M
```

Dans `lua/dockyard/compose_lens.lua` :

(a) Remplacer

```lua
local builder = require("dockyard.commands.builder")
local executor = require("dockyard.commands.executor")
local lens = require("dockyard.lens")
```

par

```lua
local compose_run = require("dockyard.commands.compose_run")
local lens = require("dockyard.lens")
```

(b) Remplacer les fonctions `compose_base` et `compose_cmd` (utilisée seulement par `refresh` pour `ps`) par :

```lua
local function compose_cmd(file, ...)
	local args = vim.list_extend(require("dockyard.commands.compose").base_cmd(), { "-f", file })
	return vim.list_extend(args, { ... })
end
```

(c) Remplacer **toute** la fonction `M.run_action` (du bloc de commentaires `---@param buf integer` / `---@param action string run|stop…` jusqu'au `end` qui précède `local function attach(buf)`) par :

```lua
---@param buf integer
---@param action string run|stop|restart|build|down|logs|shell|open
---@param service string|nil nil means every service
---@param port integer|nil for "open"; defaults to the first published port
function M.run_action(buf, action, service, port)
	local file = vim.api.nvim_buf_get_name(buf)
	if vim.bo[buf].modified then
		vim.api.nvim_buf_call(buf, function()
			vim.cmd("silent! write")
		end)
	end

	local function on_exit()
		refresh(buf)
	end
	local run_opts = { on_exit = on_exit }
	local extra = { services = service and { service } or {} }

	if action == "run" then
		compose_run.run(file, "up", extra, run_opts)
	elseif action == "stop" or action == "restart" or action == "build" then
		compose_run.run(file, action, extra, run_opts)
	elseif action == "down" then
		compose_run.run(file, "down", nil, run_opts)
	elseif action == "open" then
		local s = (statuses[buf] or {})[service]
		port = port or (s and s.ports and s.ports[1])
		if not port then
			vim.notify("Dockyard: " .. tostring(service) .. " publishes no port", vim.log.levels.WARN)
			return
		end
		require("dockyard.ui.utils").open_url("http://localhost:" .. port)
	elseif action == "logs" or action == "shell" then
		local s = (statuses[buf] or {})[service]
		if not is_up(s) or s.name == "" then
			vim.notify("Dockyard: " .. tostring(service) .. " is not running", vim.log.levels.WARN)
			return
		end
		if action == "logs" then
			vim.cmd.DockyardLogs(s.name)
		else
			require("dockyard.ui.views.terminal").open(s.name, "sh", { mode = "split" })
		end
	end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: `0 failed`.

Vérification manuelle rapide (Docker requis, plugin chargé depuis ce clone — voir Task 10, étape « Charger le clone ») : ouvrir un `docker-compose.yml`, cliquer `▶ Run` sur un service : le flottant affiche `$ docker compose -f … up -d --force-recreate <service>` — même commande qu'avant.

- [ ] **Step 5: Commit**

```bash
git add lua/dockyard/commands/compose_run.lua lua/dockyard/commands/init.lua lua/dockyard/commands/builder.lua lua/dockyard/compose_lens.lua tests/compose_run_spec.lua
git commit -m "refactor: run compose actions through compose.build with the project preferences" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Vue « Jobs », buffer de sortie et commandes

**Files:**
- Create: `lua/dockyard/ui/views/jobs/{state,renderer,controller,keymaps,init,output}.lua`
- Modify: `lua/dockyard/ui/init.lua`, `lua/dockyard/ui/state.lua`, `lua/dockyard/ui/icons.lua`, `lua/dockyard/config.lua`, `lua/dockyard/commands/cli.lua`, `plugin/dockyard.lua`
- Test: `tests/jobs_spec.lua`, `tests/modules_spec.lua`

**Interfaces:**
- Consumes: `runner.*` (Task 5), `config.options.keymaps.jobs` (Task 1), `ui.components.table`, `navigation`, `help`, `resolver` (existants).
- Produces:
  - `require("dockyard.ui.views.jobs.output").open(id: integer)` et `.build(job): lines, spans`
  - `require("dockyard.ui.views.jobs.renderer").build_rows(jobs): table[]`
  - `require("dockyard.ui").open_view(view)`
  - `:Dockyard jobs`, `:Dockyard job [id|last]`, `:Dockyard rerun [id|last]`, `<Plug>(dockyard-jobs)`, `<Plug>(dockyard-job-last)`
  - la vue `"jobs"` dans `display.views` (dernière par défaut).

- [ ] **Step 1: Write the failing tests**

Créer `tests/jobs_spec.lua` :

```lua
local runner = require("dockyard.commands.runner")
local output = require("dockyard.ui.views.jobs.output")
local renderer = require("dockyard.ui.views.jobs.renderer")

local function wait_done(job)
	vim.wait(10000, function()
		return job.status ~= "running"
	end, 10)
	truthy(job.status ~= "running", "job never finished")
end

local function fake(fields)
	return vim.tbl_extend("force", {
		id = 1,
		title = "compose up api",
		argv = { "docker", "compose", "up", "-d", "api" },
		cwd = "/p",
		status = "ok",
		code = 0,
		started_at = 0,
		started_time = 0,
		ended_at = 3.2e9,
		lines = {},
		omitted = 0,
	}, fields or {})
end

describe("jobs view rows", function()
	it("shows status, duration, command and directory", function()
		local rows = renderer.build_rows({ fake(), fake({ id = 2, status = "failed", code = 1 }) })
		eq("✔ ok", rows[1].status)
		eq("3.2s", rows[1].duration)
		eq("compose up api", rows[1].title)
		eq("✖ failed", rows[2].status)
		eq("DockyardStopped", rows[2]._hl)
		eq("job", rows[1]._item.kind)
		eq(1, rows[1]._item.item.id)
	end)
end)

describe("job output", function()
	it("has the command, the directory, the output and how it ended", function()
		local lines = output.build(fake({ lines = { "one", "two" }, status = "failed", code = 3 }))
		eq("$ docker compose up -d api", lines[1])
		eq("# in /p", lines[2])
		eq({ "one", "two" }, vim.list_slice(lines, 4, 5))
		eq("✖ failed · exit 3 · 3.2s", lines[#lines])
	end)

	it("says how many lines were dropped", function()
		local lines = output.build(fake({ lines = { "x" }, omitted = 12 }))
		eq("… 12 earlier lines omitted", lines[4])
	end)
end)

describe("job output buffer", function()
	it("opens on a job, follows its output and closes with q", function()
		local job = runner.start({ argv = { "sh", "-c", "printf 'a%s\\n' 1; sleep 0.2; printf 'b%s\\n' 2" } })
		output.open(job.id)
		local buf = vim.api.nvim_get_current_buf()
		eq("dockyardjob", vim.bo[buf].filetype)
		wait_done(job)
		vim.wait(500, function()
			return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("b2", 1, true) ~= nil
		end, 20)
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		truthy(text:find("a1", 1, true), text)
		truthy(text:find("b2", 1, true), text)
		truthy(text:find("✔ ok · exit 0", 1, true), text)
		vim.cmd("normal q")
		eq(false, vim.api.nvim_buf_is_valid(buf))
	end)
end)

describe("job output with odd bytes", function()
	it("opens without error when the output is not valid UTF-8", function()
		local job = runner.start({ argv = { "sh", "-c", "printf '\\377\\376 bytes\\n'" } })
		wait_done(job)
		output.open(job.id)
		local buf = vim.api.nvim_get_current_buf()
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		truthy(text:find(" bytes", 1, true), text)
		vim.cmd("normal q")
	end)
end)

describe("Jobs in the dashboard", function()
	it("refuses to open when the user left the view out of display.views", function()
		local config = require("dockyard.config")
		local state = require("dockyard.ui.state")
		local views = config.options.display.views
		config.options.display.views = { "containers", "images" }
		local msg
		local orig = vim.notify
		vim.notify = function(m)
			msg = m
		end
		require("dockyard.ui").open_view("jobs")
		vim.notify = orig
		config.options.display.views = views
		truthy(msg and msg:find("display.views", 1, true), tostring(msg))
		eq(nil, state.win_id)
	end)

	it("is a view of the dashboard, listing the jobs", function()
		local ui = require("dockyard.ui")
		local state = require("dockyard.ui.state")
		local job = runner.start({ argv = { "sh", "-c", "exit 0" }, title = "visible job" })
		wait_done(job)
		ui.open_view("jobs")
		vim.wait(500)
		eq("jobs", state.current_view)
		local text = table.concat(vim.api.nvim_buf_get_lines(state.buf_id, 0, -1, false), "\n")
		truthy(text:find("visible job", 1, true), text)
		truthy(text:find("Jobs", 1, true), text)
		ui.close()
	end)
end)

describe(":Dockyard job commands", function()
	local cli = require("dockyard.commands.cli")

	it("completes ids and last", function()
		local job = runner.start({ argv = { "sh", "-c", "exit 0" } })
		wait_done(job)
		local items = cli.complete("", "Dockyard job ")
		truthy(vim.tbl_contains(items, "last"))
		truthy(vim.tbl_contains(items, tostring(job.id)))
	end)

	it("lists the new subcommands", function()
		local items = cli.complete("", "Dockyard ")
		for _, name in ipairs({ "jobs", "job", "rerun" }) do
			truthy(vim.tbl_contains(items, name), name)
		end
	end)
end)
```

Dans `tests/modules_spec.lua` :

(a) dans le test `defines the <Plug> mappings`, remplacer la liste `{ "dockyard-open", "dockyard-pick", "dockyard-service-run", "dockyard-service-open" }` par

```lua
{
			"dockyard-open",
			"dockyard-pick",
			"dockyard-service-run",
			"dockyard-service-open",
			"dockyard-jobs",
			"dockyard-job-last",
		}
```

(b) dans `describe("config", …)`, avant le test `finds unknown options…`, ajouter

```lua
	it("has the Jobs view in the default views", function()
		truthy(vim.tbl_contains(config.defaults.display.views, "jobs"))
	end)
```

- [ ] **Step 2: Run them to verify they fail**

Run: `nvim --headless --clean -l tests/run.lua tests/jobs_spec.lua tests/modules_spec.lua`
Expected: FAIL (`module 'dockyard.ui.views.jobs.renderer' not found`, `<Plug>(dockyard-jobs)` absent, `jobs` absent des vues par défaut).

- [ ] **Step 3: Write the view**

Créer `lua/dockyard/ui/views/jobs/state.lua` :

```lua
---@class DockyardJobsViewState
---@field off fun()|nil unsubscribe from the runner
---@field pending boolean a re-render is already scheduled

---@type DockyardJobsViewState
local M = {
	off = nil,
	pending = false,
}

return M
```

Créer `lua/dockyard/ui/views/jobs/renderer.lua` :

```lua
local navigation = require("dockyard.ui.navigation")
local M = {}

local runner = require("dockyard.commands.runner")
local ui_state = require("dockyard.ui.state")
local config = require("dockyard.config")
local table_view = require("dockyard.ui.components.table")
local header = require("dockyard.ui.components.header")
local navbar = require("dockyard.ui.components.navbar")
local statusline = require("dockyard.ui.statusline")
local ui_utils = require("dockyard.ui.utils")

local STATUS = {
	running = { icon = "⟳", hl = "DockyardPending" },
	ok = { icon = "✔", hl = "DockyardRunning" },
	failed = { icon = "✖", hl = "DockyardStopped" },
	cancelled = { icon = "⊘", hl = "DockyardMuted" },
}

local function current_width()
	if ui_state.win_id ~= nil and vim.api.nvim_win_is_valid(ui_state.win_id) then
		return vim.api.nvim_win_get_width(ui_state.win_id)
	end
	return vim.o.columns
end

---@param jobs DockyardJob[]
---@return table[] rows
function M.build_rows(jobs)
	local rows = {}
	for _, job in ipairs(jobs) do
		local status = STATUS[job.status] or STATUS.failed
		table.insert(rows, {
			status = status.icon .. " " .. job.status,
			started = os.date("%H:%M:%S", job.started_time),
			duration = runner.format_duration(runner.duration(job)),
			title = job.title,
			dir = job.cwd and vim.fn.fnamemodify(job.cwd, ":~") or "-",
			_hl = status.hl,
			_item = { kind = "job", item = job },
		})
	end
	return rows
end

local function cell_hl(row, col)
	if col.key == "status" then
		return row._hl
	elseif col.key == "title" then
		return "DockyardName"
	end
	return "DockyardMuted"
end

---@param jobs DockyardJob[]
local function set_statusline_items(jobs)
	local running = #vim.tbl_filter(function(job)
		return job.status == "running"
	end, jobs)
	local items = { { text = ("%d jobs"):format(#jobs), hl_group = "DockyardFooterAccent" } }
	if running > 0 then
		table.insert(items, { text = ("⟳ %d running"):format(running), hl_group = "DockyardFooterPending" })
	end
	statusline.set_items(items)
end

---@param width number
---@param jobs DockyardJob[]
local function build_body(width, jobs)
	local lines, line_map, spans = table_view.render({
		width = width,
		margin = 1,
		columns = {
			{ key = "status", name = "Status", min_width = 12 },
			{ key = "started", name = "Started", min_width = 8 },
			{ key = "duration", name = "Duration", min_width = 8 },
			{ key = "title", name = "Command", min_width = 30 },
			{ key = "dir", name = "Directory", min_width = 20 },
		},
		rows = M.build_rows(jobs),
		cell_hl = cell_hl,
	})
	if #jobs == 0 then
		local hint = " No jobs yet. Commands started from Dockyard show up here."
		table.insert(lines, hint)
		table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #hint, hl_group = "DockyardMuted" })
	end
	return lines, line_map, spans
end

local function draw()
	local buf = ui_state.buf_id
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local lines = {}
	local spans = {}
	local width = current_width()
	local jobs = runner.list()

	ui_utils.append_block(lines, spans, header.render(ui_state.mode, width))
	ui_utils.append_block(
		lines,
		spans,
		navbar.render({
			width = width,
			current_view = ui_state.current_view,
			views = config.options.display.views,
		})
	)
	table.insert(lines, "")

	local body_lines, body_line_map, body_spans = build_body(width, jobs)
	local body_start = ui_utils.append_body(lines, spans, body_lines, body_spans)
	ui_state.line_map = {}
	for lnum, item in pairs(body_line_map or {}) do
		ui_state.line_map[body_start + lnum] = item
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	ui_utils.apply_spans(buf, spans)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	set_statusline_items(jobs)
end

function M.render()
	navigation.keep_selection(draw)
end

return M
```

Créer `lua/dockyard/ui/views/jobs/controller.lua` :

```lua
local M = {}

local renderer = require("dockyard.ui.views.jobs.renderer")
local runner = require("dockyard.commands.runner")
local ui_state = require("dockyard.ui.state")
local navigation = require("dockyard.ui.navigation")
local view_state = require("dockyard.ui.views.jobs.state")

---@param opts { focus_first?: boolean }|nil
function M.render(opts)
	if ui_state.current_view ~= "jobs" then
		return
	end
	if ui_state.win_id ~= nil and vim.api.nvim_win_is_valid(ui_state.win_id) then
		renderer.render()
		-- only when the previous selection is gone (first open, view switch)
		if opts and opts.focus_first == true and not navigation.restored then
			navigation.first()
		end
	end
end

---Re-render soon, once for a burst of changes. While a job runs, keep its duration ticking.
---@param delay? integer milliseconds
function M.schedule_render(delay)
	if view_state.pending then
		return
	end
	view_state.pending = true
	vim.defer_fn(function()
		view_state.pending = false
		M.render()
		local running = vim.tbl_filter(function(job)
			return job.status == "running"
		end, runner.list())
		if #running > 0 and ui_state.current_view == "jobs" then
			M.schedule_render(1000)
		end
	end, delay or 100)
end

---@param node { kind: string, item: DockyardJob }|nil
function M.open_output(node)
	if node and node.kind == "job" then
		require("dockyard.ui.views.jobs.output").open(node.item.id)
	end
end

return M
```

Créer `lua/dockyard/ui/views/jobs/keymaps.lua` :

```lua
local M = {}

local runner = require("dockyard.commands.runner")
local ui_state = require("dockyard.ui.state")
local help = require("dockyard.ui.popups.help")
local resolver = require("dockyard.core.keymaps")

local GROUP = "Jobs"
local INDEX = 50

local function job_at_cursor()
	local node = ui_state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
	if node and node.kind == "job" then
		return node
	end
end

---@param buf number
---@param notify fun(msg:string,level?:"success"|"warn"|"error"|"info"|"loading")
function M.setup(buf, notify)
	local items = {}
	local function on_job(fn)
		return function()
			local node = job_at_cursor()
			if node then
				fn(node.item)
			end
		end
	end

	resolver.push(
		items,
		resolver.item("jobs.open_output", {
			desc = "Open the full output",
			callback = on_job(function(job)
				require("dockyard.ui.views.jobs.output").open(job.id)
			end),
			index = 1,
		})
	)
	resolver.push(
		items,
		resolver.item("ui.open_details", {
			desc = "Open the full output",
			callback = on_job(function(job)
				require("dockyard.ui.views.jobs.output").open(job.id)
			end),
			index = 2,
			hidden = true,
		})
	)
	resolver.push(
		items,
		resolver.item("jobs.rerun", {
			desc = "Run the command again",
			callback = on_job(function(job)
				if runner.rerun(job.id) then
					notify("Started again: " .. job.title, "info")
				end
			end),
			index = 3,
		})
	)
	resolver.push(
		items,
		resolver.item("jobs.cancel", {
			desc = "Cancel the running command",
			callback = on_job(function(job)
				if not runner.cancel(job.id) then
					notify("Not running", "warn")
				end
			end),
			index = 4,
		})
	)
	resolver.push(
		items,
		resolver.item("jobs.clear", {
			desc = "Forget the finished jobs",
			callback = function()
				runner.clear_finished()
			end,
			index = 5,
		})
	)
	resolver.push(
		items,
		resolver.item("jobs.copy_command", {
			desc = "Copy the command line",
			callback = on_job(function(job)
				local cmd = runner.format_cmd(job.argv)
				vim.fn.setreg("+", cmd)
				vim.fn.setreg('"', cmd)
				notify("Copied: " .. cmd, "success")
			end),
			index = 6,
		})
	)

	help.register(GROUP, items, { buffer = buf, index = INDEX })
end

---@param buf number
function M.teardown(buf)
	local items = {}
	for _, id in ipairs({ "jobs.open_output", "ui.open_details", "jobs.rerun", "jobs.cancel", "jobs.clear", "jobs.copy_command" }) do
		resolver.push(items, resolver.removal(id))
	end
	help.remove(GROUP, items, { buffer = buf })
end

return M
```

Créer `lua/dockyard/ui/views/jobs/init.lua` :

```lua
local M = {}

local runner = require("dockyard.commands.runner")
local keymaps = require("dockyard.ui.views.jobs.keymaps")
local controller = require("dockyard.ui.views.jobs.controller")
local view_state = require("dockyard.ui.views.jobs.state")

---@param buf number
---@param notify fun(msg:string,level?:"success"|"warn"|"error"|"info"|"loading")
function M.setup(buf, notify)
	keymaps.setup(buf, notify)
	if view_state.off then
		view_state.off()
	end
	view_state.off = runner.subscribe(function()
		controller.schedule_render()
	end)
end

---@param on_done fun()|nil
function M.update(on_done)
	controller.render({ focus_first = true })
	if on_done then
		on_done()
	end
end

---@param buf number
function M.teardown(buf)
	keymaps.teardown(buf)
	if view_state.off then
		view_state.off()
		view_state.off = nil
	end
end

return M
```

Créer `lua/dockyard/ui/views/jobs/output.lua` :

```lua
-- The whole output of a job in a buffer, updated while the job runs.

local M = {}

local runner = require("dockyard.commands.runner")
local resolver = require("dockyard.core.keymaps")

local ns = vim.api.nvim_create_namespace("dockyard.job_output")

---@type table<integer, integer> job id -> buffer
local buffers = {}

local FOOTER = {
	running = { "⟳ running", "DockyardPending" },
	ok = { "✔ ok", "DockyardRunning" },
	failed = { "✖ failed", "DockyardStopped" },
	cancelled = { "⊘ cancelled", "DockyardMuted" },
}

---@param job DockyardJob
---@return string[] lines, table[] spans {line, start_col, end_col, hl_group}
function M.build(job)
	local lines = { "$ " .. runner.format_cmd(job.argv) }
	local spans = { { line = 0, start_col = 0, end_col = #lines[1], hl_group = "DockyardTitle" } }
	if job.cwd then
		table.insert(lines, "# in " .. vim.fn.fnamemodify(job.cwd, ":~"))
		table.insert(spans, { line = 1, start_col = 0, end_col = #lines[2], hl_group = "DockyardMuted" })
	end
	table.insert(lines, "")
	vim.list_extend(lines, runner.output(job))
	table.insert(lines, "")
	local footer = FOOTER[job.status] or FOOTER.failed
	local text = footer[1]
	if job.status == "ok" or job.status == "failed" then
		text = text .. " · exit " .. tostring(job.code)
	end
	text = text .. " · " .. runner.format_duration(runner.duration(job))
	table.insert(lines, text)
	table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #text, hl_group = footer[2] })
	return lines, spans
end

local function render(buf, job)
	-- keep following the output only when the cursor is on the last line
	local following = {}
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		following[win] = vim.api.nvim_win_get_cursor(win)[1] >= vim.api.nvim_buf_line_count(buf)
	end
	local lines, spans = M.build(job)
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(buf, ns, span.line, span.start_col, {
			end_row = span.line,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	for win, follow in pairs(following) do
		if follow and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_cursor(win, { #lines, 0 })
		end
	end
end

local function map(buf, action_id, fn)
	for _, key in ipairs(resolver.resolve(action_id) or {}) do
		vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true })
	end
end

local function create(job)
	local buf = vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, buf, "dockyard-job://" .. job.id)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "dockyardjob", { buf = buf })
	render(buf, job)

	local pending = false
	local off = runner.subscribe(function(changed)
		if changed ~= job or pending then
			return
		end
		pending = true
		vim.defer_fn(function()
			pending = false
			if vim.api.nvim_buf_is_valid(buf) then
				render(buf, job)
			end
		end, 50)
	end)
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			off()
			buffers[job.id] = nil
		end,
	})

	map(buf, "ui.close", function()
		pcall(vim.api.nvim_win_close, 0, true)
	end)
	map(buf, "jobs.rerun", function()
		local again = runner.rerun(job.id)
		if again then
			M.open(again.id)
		end
	end)
	map(buf, "jobs.cancel", function()
		runner.cancel(job.id)
	end)
	return buf
end

local function open_window(buf)
	if vim.api.nvim_win_get_config(0).relative ~= "" then
		-- from a floating dashboard: splitting a float is awkward, open another one
		local width = math.floor(vim.o.columns * 0.85)
		local height = math.floor(vim.o.lines * 0.7)
		return vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = width,
			height = height,
			row = math.floor((vim.o.lines - height) / 2),
			col = math.floor((vim.o.columns - width) / 2),
			style = "minimal",
			border = "rounded",
			zindex = 270,
		})
	end
	vim.cmd("botright 18split")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	return win
end

---@param id integer job id
function M.open(id)
	local job = runner.get(id)
	if not job then
		vim.notify("Dockyard: no job " .. tostring(id), vim.log.levels.WARN)
		return
	end
	local buf = buffers[id]
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		buf = create(job)
		buffers[id] = buf
	end
	local win = vim.fn.bufwinid(buf)
	if win ~= -1 then
		vim.api.nvim_set_current_win(win)
	else
		win = open_window(buf)
	end
	vim.api.nvim_set_option_value("wrap", false, { win = win })
	vim.api.nvim_set_option_value("number", false, { win = win })
	vim.api.nvim_set_option_value("signcolumn", "no", { win = win })
	vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
end

return M
```

- [ ] **Step 4: Wire the view, the commands and the defaults**

Dans `lua/dockyard/ui/init.lua` :

(a) Remplacer

```lua
	volumes = require("dockyard.ui.views.volumes.init"),
}
```

par

```lua
	volumes = require("dockyard.ui.views.volumes.init"),
	jobs = require("dockyard.ui.views.jobs.init"),
}
```

(b) Remplacer la ligne `M.open_float = M.open` par :

```lua
M.open_float = M.open

---Open the dashboard on `view`, or switch to it when it is already open.
---@param view DockyardView
M.open_view = function(view)
	local views = config.options.display.views or {}
	if not vim.tbl_contains(views, view) then
		vim.notify("Dockyard: the '" .. view .. "' view is not in display.views", vim.log.levels.WARN)
		return
	end
	if M.is_open() then
		vim.api.nvim_set_current_win(state.win_id)
		if state.current_view ~= view then
			teardown_active_view()
			state.current_view = view
			setup_active_view()
			update_active_view(nil, { force_update = true })
		end
		return
	end
	state.current_view = view
	M.open_with_strategy(nil, nil)
end
```

(c) Dans `require("dockyard.ui.popups.help").register_command("Commands", { … })`, ajouter après l'entrée `DockyardRun` :

```lua
		{ name = "Dockyard jobs", desc = "Commands Dockyard ran, with their output" },
```

Dans `lua/dockyard/ui/state.lua`, remplacer `"containers"|"compose"|"images"|"networks"|"volumes" The currently` par `"containers"|"compose"|"images"|"networks"|"volumes"|"jobs" The currently`.

Dans `lua/dockyard/ui/icons.lua`, dans `view = { … }`, remplacer

```lua
		volumes = "󰋊",
		fallback = "•",
```

par

```lua
		volumes = "󰋊",
		jobs = "󰔟",
		fallback = "•",
```

Dans `lua/dockyard/config.lua` : remplacer `--- @alias DockyardView "containers"|"compose"|"images"|"networks"|"volumes"` par la même ligne avec `|"jobs"` en plus, et dans `M.options.display` remplacer

```lua
		views = { "containers", "images", "networks", "volumes" },
		open_strategy = "tab",
```

par

```lua
		views = { "containers", "images", "networks", "volumes", "jobs" },
		open_strategy = "tab",
```

Dans `lua/dockyard/commands/cli.lua` :

(a) Remplacer le commentaire d'en-tête `-- :Dockyard [strategy] | pick | files | logs | build | run | service` par `-- :Dockyard [strategy] | pick | files | logs | build | run | service | jobs | job | rerun`.

(b) Juste avant `---@type table<string, { run: fun(args: string[], opts: table), complete?`, ajouter :

```lua
local function job_ids(lead)
	local ids = vim.tbl_map(function(job)
		return tostring(job.id)
	end, require("dockyard.commands.runner").list())
	table.insert(ids, 1, "last")
	return starting_with(lead, ids)
end

-- "last" or nil is the most recent job
local function find_job(arg)
	local runner = require("dockyard.commands.runner")
	local job = (arg == nil or arg == "last") and runner.last() or runner.get(tonumber(arg))
	if not job then
		notify(arg and ("no job '" .. arg .. "'") or "no job yet", vim.log.levels.WARN)
	end
	return job
end

```

(c) Dans `M.subcommands`, après le sous-commande `service = { … },`, ajouter :

```lua
	jobs = {
		run = function()
			require("dockyard.ui").open_view("jobs")
		end,
	},
	job = {
		run = function(args)
			local job = find_job(args[1])
			if job then
				require("dockyard.ui.views.jobs.output").open(job.id)
			end
		end,
		complete = function(lead, args)
			return #args == 0 and job_ids(lead) or {}
		end,
	},
	rerun = {
		run = function(args)
			local job = find_job(args[1])
			if job then
				require("dockyard.commands.runner").rerun(job.id)
			end
		end,
		complete = function(lead, args)
			return #args == 0 and job_ids(lead) or {}
		end,
	},
```

Dans `plugin/dockyard.lua`, remplacer

```lua
	build = "build",
	run = "run",
}
```

par

```lua
	build = "build",
	run = "run",
	jobs = "jobs",
	["job-last"] = "job last",
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: `0 failed` (dont `every dockyard module loads`, qui charge les six nouveaux modules, et `does not load the plugin modules at startup`).

Vérification manuelle (Docker inutile) : `nvim` avec le plugin du clone, `:Dockyard jobs` ouvre le dashboard sur l'onglet Jobs ; `:!true` n'est pas un job — lancer un `▶ Run` (Task 7) puis vérifier la ligne dans la vue, `<CR>` ouvre la sortie, `r` rejoue, `y` copie, `D` efface les terminés.

- [ ] **Step 6: Commit**

```bash
git add lua/dockyard/ui lua/dockyard/config.lua lua/dockyard/commands/cli.lua plugin/dockyard.lua tests/jobs_spec.lua tests/modules_spec.lua
git commit -m "feat: Jobs view with the full output of every command" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Menu d'options compose, bouton `⚙ Options` et chips de profils

**Files:**
- Create: `lua/dockyard/ui/popups/compose_menu/model.lua`, `lua/dockyard/ui/popups/compose_menu/init.lua`
- Modify: `lua/dockyard/compose_lens.lua`, `lua/dockyard/commands/cli.lua`, `plugin/dockyard.lua`, `lua/dockyard/ui/init.lua`, `tests/modules_spec.lua`
- Test: `tests/compose_menu_spec.lua`, `tests/compose_lens_spec.lua`

**Interfaces:**
- Consumes: `compose.build`, `compose.project` (Task 2), `profiles.detect` (Task 3), `prefs.get/set/defaults` (Task 4), `runner.format_cmd` (Task 5), `compose_run.run` (Task 7), `service.profiles` (Task 3).
- Produces:
  - `model.new(file, available, saved, action?)`, `model.items(state)`, `model.toggle(state, id): boolean`, `model.opts(state)`, `model.command(state, action)`, `model.render(state)`, `model.summary(saved): string`
  - `require("dockyard.ui.popups.compose_menu").open(file, opts?: { action?, on_exit? })`
  - `compose_lens.build_lines(buf, status, summary?)` (bouton `options`, chip de profils)
  - `:Dockyard compose [up|down|build|pull|stop|restart]`, `<Plug>(dockyard-compose)`.

- [ ] **Step 1: Write the failing tests**

Créer `tests/compose_menu_spec.lua` :

```lua
local model = require("dockyard.ui.popups.compose_menu.model")
local compose = require("dockyard.commands.compose")

compose.base_cmd = function()
	return { "docker", "compose" }
end

local defaults = {
	profiles = {},
	all_profiles = false,
	force_recreate = true,
	build = false,
	pull = false,
	no_deps = false,
	wait = false,
	remove_orphans = false,
}

local function state(available, saved, action)
	return model.new("/p/compose.yml", available, vim.tbl_extend("force", vim.deepcopy(defaults), saved or {}), action)
end

local function checked(st)
	local out = {}
	for _, item in ipairs(model.items(st)) do
		if item.checked then
			table.insert(out, item.id)
		end
	end
	return out
end

describe("compose menu model", function()
	it("offers the profiles of the file and the ones already saved", function()
		local st = state({ "tools", "debug" }, { profiles = { "old" } })
		local ids = vim.tbl_map(function(i)
			return i.id
		end, model.items(st))
		eq({ "profile:debug", "profile:old", "profile:tools", "all_profiles" }, vim.list_slice(ids, 1, 4))
	end)

	it("hides the profile section when there is no profile", function()
		local st = state({})
		eq("flag:force_recreate", model.items(st)[1].id)
	end)

	it("checks what is saved", function()
		eq({ "flag:force_recreate" }, checked(state({})))
		eq({ "profile:debug", "flag:force_recreate", "flag:build" }, checked(state({ "debug" }, { profiles = { "debug" }, build = true })))
	end)

	it("toggles a profile and reports that it must be saved", function()
		local st = state({ "debug", "e2e" })
		eq(true, model.toggle(st, "profile:e2e"))
		eq(true, model.toggle(st, "profile:debug"))
		eq({ "debug", "e2e" }, st.prefs.profiles)
		eq(true, model.toggle(st, "profile:debug"))
		eq({ "e2e" }, st.prefs.profiles)
	end)

	it("toggles flags, with pull standing for --pull always", function()
		local st = state({})
		model.toggle(st, "flag:build")
		model.toggle(st, "flag:pull")
		model.toggle(st, "flag:force_recreate")
		eq(true, st.prefs.build)
		eq("always", st.prefs.pull)
		eq(false, st.prefs.force_recreate)
		model.toggle(st, "flag:pull")
		eq(false, st.prefs.pull)
	end)

	it("keeps destructive flags out of the saved part", function()
		local st = state({})
		eq(false, model.toggle(st, "once:volumes"))
		eq(false, model.toggle(st, "once:rmi"))
		eq(true, st.once.volumes)
		eq("local", st.once.rmi)
		eq(nil, st.prefs.volumes)
		eq(true, model.opts(st).volumes)
	end)

	it("previews the command of an action", function()
		local st = state({ "debug" }, { profiles = { "debug" }, build = true })
		eq("docker compose -f /p/compose.yml --profile debug up -d --build --force-recreate", model.command(st, "up"))
		model.toggle(st, "once:volumes")
		eq("docker compose -f /p/compose.yml --profile debug down -v", model.command(st, "down"))
	end)

	it("renders the boxes, the command and the keys", function()
		local st = state({ "debug" }, { profiles = { "debug" } })
		local lines, item_lines = model.render(st)
		eq(" Compose · compose.yml", lines[1])
		local text = table.concat(lines, "\n")
		truthy(text:find("[x] debug", 1, true), text)
		truthy(text:find("[ ] all profiles (*)", 1, true), text)
		truthy(text:find("[x] --force-recreate", 1, true), text)
		truthy(text:find("$ docker compose -f /p/compose.yml --profile debug up -d --force-recreate", 1, true), text)
		truthy(text:find("<CR> up", 1, true), text)
		eq("profile:debug", item_lines[4])
	end)

	it("summarises what differs from the defaults", function()
		eq("", model.summary(defaults))
		eq("debug +build", model.summary(vim.tbl_extend("force", defaults, { profiles = { "debug" }, build = true })))
		eq("*", model.summary(vim.tbl_extend("force", defaults, { all_profiles = true })))
		eq("-force-recreate +pull", model.summary(vim.tbl_extend("force", defaults, { force_recreate = false, pull = "always" })))
	end)
end)

describe(":Dockyard compose completion", function()
	local cli = require("dockyard.commands.cli")

	it("completes the compose actions and is a subcommand", function()
		eq({ "down" }, cli.complete("d", "Dockyard compose d"))
		truthy(vim.tbl_contains(cli.complete("", "Dockyard "), "compose"))
	end)
end)

describe("compose menu window", function()
	local prefs = require("dockyard.commands.prefs")
	local menu = require("dockyard.ui.popups.compose_menu")
	local compose_run = require("dockyard.commands.compose_run")

	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	prefs.path = function()
		return dir .. "/data/projects.json"
	end
	local file = dir .. "/compose.yml"
	vim.fn.writefile({ "services:", "  api:", "    image: alpine", "    profiles: [debug]" }, file)

	local function open_menu(action)
		prefs.reset()
		menu.open(file, { action = action })
		vim.wait(10000, function()
			return vim.bo.filetype == "dockyardmenu"
		end, 20)
		eq("dockyardmenu", vim.bo.filetype)
		return vim.api.nvim_get_current_buf()
	end

	local function goto_line(buf, needle)
		for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
			if line:find(needle, 1, true) then
				vim.api.nvim_win_set_cursor(0, { i, 0 })
				return
			end
		end
		error("no line with " .. needle)
	end

	it("saves the boxes of the project and keeps the one-shot ones out of the file", function()
		local buf = open_menu()
		goto_line(buf, "--build")
		vim.cmd("normal x")
		goto_line(buf, "debug")
		vim.cmd("normal x")
		goto_line(buf, "-v  remove volumes")
		vim.cmd("normal x")
		prefs.reset()
		local saved = prefs.get(file)
		eq(true, saved.build)
		eq({ "debug" }, saved.profiles)
		eq(nil, saved.volumes)
		vim.cmd("normal q")
	end)

	it("runs the action of the key with the saved options", function()
		local calls = {}
		local real = compose_run.run
		compose_run.run = function(f, action, extra)
			table.insert(calls, { f, action, extra })
		end
		open_menu()
		vim.cmd("normal b")
		compose_run.run = real
		eq(1, #calls)
		eq({ file, "build" }, { calls[1][1], calls[1][2] })
	end)

	it("does not run down -v when the confirmation is declined", function()
		local calls = {}
		local real_run, real_select = compose_run.run, vim.ui.select
		compose_run.run = function(f, action)
			table.insert(calls, action)
		end
		local asked
		vim.ui.select = function(items, opts, on_choice)
			asked = { items = items, prompt = opts.prompt }
			on_choice("No")
		end
		local buf = open_menu()
		goto_line(buf, "-v  remove volumes")
		vim.cmd("normal x")
		vim.cmd("normal d")
		eq({ "No", "Yes" }, asked.items)
		truthy(asked.prompt:find("volumes", 1, true), asked.prompt)
		eq({}, calls)

		vim.ui.select = function(_, _, on_choice)
			on_choice("Yes")
		end
		buf = open_menu()
		goto_line(buf, "-v  remove volumes")
		vim.cmd("normal x")
		vim.cmd("normal d")
		compose_run.run, vim.ui.select = real_run, real_select
		eq({ "down" }, calls)
	end)

	it("runs down without asking when nothing destructive is ticked", function()
		local calls = {}
		local real_run, real_select = compose_run.run, vim.ui.select
		compose_run.run = function(_, action)
			table.insert(calls, action)
		end
		vim.ui.select = function()
			error("must not ask")
		end
		open_menu()
		vim.cmd("normal d")
		compose_run.run, vim.ui.select = real_run, real_select
		eq({ "down" }, calls)
	end)
end)
```

Dans `tests/compose_lens_spec.lua`, dans `describe("build_lines", …)` :

(a) remplacer `eq("▶▶ Run all  ⟳ Build all", text(lines[1]))` par `eq("▶▶ Run all  ⟳ Build all  ⚙ Options", text(lines[1]))` ;

(b) remplacer `eq("▶▶ Run all  ■ Stop all  ⟳ Build all  ▼ Down", text(lines[1]))` par `eq("▶▶ Run all  ■ Stop all  ⟳ Build all  ▼ Down  ⚙ Options", text(lines[1]))` ;

(c) avant le test `has no lens without services`, ajouter :

```lua
	it("shows what the project options change next to the options button", function()
		local lines = compose_lens.build_lines(buf, {}, "debug +build")
		eq("▶▶ Run all  ⟳ Build all  ⚙ Options · debug +build", text(lines[1]))
		eq("options", lines[1].buttons[#lines[1].buttons].data.action)
	end)

	it("tags the services that have profiles", function()
		local with_profiles = buffer({
			"services:",
			"  api:",
			"    image: x",
			"  adminer:",
			"    image: adminer",
			"    profiles: [debug, tools]",
		})
		local lines = compose_lens.build_lines(with_profiles, {})
		eq("▶ Run", text(lines[2]))
		eq("[debug,tools]  ▶ Run", text(lines[4]))
	end)
```

Dans `tests/modules_spec.lua`, ajouter `"dockyard-compose",` à la liste des `<Plug>` du test `defines the <Plug> mappings`.

- [ ] **Step 2: Run them to verify they fail**

Run: `nvim --headless --clean -l tests/run.lua tests/compose_menu_spec.lua tests/compose_lens_spec.lua tests/modules_spec.lua`
Expected: FAIL (`module 'dockyard.ui.popups.compose_menu.model' not found`, textes du lens sans `⚙ Options`, `<Plug>(dockyard-compose)` absent).

- [ ] **Step 3: Write the menu**

Créer `lua/dockyard/ui/popups/compose_menu/model.lua` :

```lua
-- State and text of the compose options menu. No windows here, so it can be tested.

local compose = require("dockyard.commands.compose")
local prefs = require("dockyard.commands.prefs")
local runner = require("dockyard.commands.runner")

local M = {}

-- saved for the project; `on` is the value a checked box stands for when it is not `true`
local FLAG_ROWS = {
	{ key = "force_recreate", label = "--force-recreate" },
	{ key = "build", label = "--build" },
	{ key = "pull", label = "--pull", on = "always" },
	{ key = "no_deps", label = "--no-deps" },
	{ key = "wait", label = "--wait" },
	{ key = "remove_orphans", label = "--remove-orphans" },
}

-- never saved: they destroy data, or are only useful once
local ONCE_ROWS = {
	{ key = "volumes", label = "-v  remove volumes (down)" },
	{ key = "rmi", label = "--rmi", on = "local", suffix = "  remove images (down)" },
	{ key = "renew_anon_volumes", label = "-V  renew anonymous volumes (up)" },
}

local ACTION_KEYS = "<CR> %s · d down · b build · p pull · s stop · r restart"

---@class DockyardComposeMenuState
---@field file string
---@field project DockyardComposeProject
---@field action string action run by <CR>
---@field profiles string[] every profile to offer
---@field prefs table saved part
---@field once table this run only

---@param file string
---@param available string[] profiles found in the file
---@param saved table preferences of the project
---@param action? string
---@return DockyardComposeMenuState
function M.new(file, available, saved, action)
	local profiles = vim.deepcopy(available)
	for _, name in ipairs(saved.profiles or {}) do
		if not vim.tbl_contains(profiles, name) then
			table.insert(profiles, name)
		end
	end
	table.sort(profiles)
	return {
		file = file,
		project = compose.project(file),
		action = action or "up",
		profiles = profiles,
		prefs = vim.deepcopy(saved),
		once = { volumes = false, rmi = false, renew_anon_volumes = false },
	}
end

local function is_on(value)
	return value ~= nil and value ~= false
end

---@class DockyardComposeMenuItem
---@field id string
---@field section string
---@field label string
---@field checked boolean

---@param state DockyardComposeMenuState
---@return DockyardComposeMenuItem[]
function M.items(state)
	local items = {}
	local function add(section, id, label, checked)
		table.insert(items, { id = id, section = section, label = label, checked = checked })
	end
	if #state.profiles > 0 then
		for _, name in ipairs(state.profiles) do
			add("Profiles", "profile:" .. name, name, vim.tbl_contains(state.prefs.profiles, name))
		end
		add("Profiles", "all_profiles", "all profiles (*)", state.prefs.all_profiles == true)
	end
	for _, row in ipairs(FLAG_ROWS) do
		local value = state.prefs[row.key]
		local label = row.on and (row.label .. " " .. tostring(is_on(value) and value or row.on)) or row.label
		add("Saved for this project", "flag:" .. row.key, label, is_on(value))
	end
	for _, row in ipairs(ONCE_ROWS) do
		local value = state.once[row.key]
		local label = row.on and (row.label .. " " .. tostring(is_on(value) and value or row.on) .. (row.suffix or "")) or row.label
		add("This run only", "once:" .. row.key, label, is_on(value))
	end
	return items
end

---Flip a box.
---@param state DockyardComposeMenuState
---@param id string
---@return boolean saved whether the change belongs in the project preferences
function M.toggle(state, id)
	local function flip(tbl, key, on)
		tbl[key] = not is_on(tbl[key]) and (on or true) or false
	end
	local kind, name = id:match("^(%w+):(.+)$")
	if kind == "profile" then
		local list = state.prefs.profiles
		local at = vim.fn.index(list, name)
		if at >= 0 then
			table.remove(list, at + 1)
		else
			table.insert(list, name)
			table.sort(list)
		end
		return true
	elseif id == "all_profiles" then
		state.prefs.all_profiles = not state.prefs.all_profiles
		return true
	elseif kind == "flag" then
		for _, row in ipairs(FLAG_ROWS) do
			if row.key == name then
				flip(state.prefs, name, row.on)
			end
		end
		return true
	elseif kind == "once" then
		for _, row in ipairs(ONCE_ROWS) do
			if row.key == name then
				flip(state.once, name, row.on)
			end
		end
		return false
	end
	return false
end

---Options for compose.build: the saved preferences and the one-shot flags.
---@param state DockyardComposeMenuState
---@return DockyardComposeOpts
function M.opts(state)
	return vim.tbl_extend("force", state.prefs, state.once)
end

---The command a key would run.
---@param state DockyardComposeMenuState
---@param action string
---@return string
function M.command(state, action)
	local argv, err = compose.build(state.project, action, M.opts(state))
	return argv and runner.format_cmd(argv) or tostring(err)
end

---@param state DockyardComposeMenuState
---@return string[] lines, table<integer, string> item_lines line -> item id, table[] spans
function M.render(state)
	local lines, item_lines, spans = {}, {}, {}
	local function add(text, hl)
		table.insert(lines, text)
		if hl then
			table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #text, hl_group = hl })
		end
	end

	add(" Compose · " .. vim.fn.fnamemodify(state.file, ":t"), "DockyardTitle")
	local section
	for _, item in ipairs(M.items(state)) do
		if item.section ~= section then
			section = item.section
			add("")
			add(" " .. section, "DockyardColumnHeader")
		end
		add(("   [%s] %s"):format(item.checked and "x" or " ", item.label))
		item_lines[#lines] = item.id
	end
	add("")
	add(" $ " .. M.command(state, state.action), "DockyardMuted")
	add(" " .. ACTION_KEYS:format(state.action) .. " · <Space> toggle · q close", "DockyardMuted")
	return lines, item_lines, spans
end

---Short text for the lens: what differs from the defaults ("debug +build").
---@param saved table
---@return string
function M.summary(saved)
	local defaults = prefs.defaults()
	local parts = {}
	if saved.all_profiles then
		table.insert(parts, "*")
	elseif #(saved.profiles or {}) > 0 then
		table.insert(parts, table.concat(saved.profiles, ","))
	end
	for _, row in ipairs(FLAG_ROWS) do
		local now, was = is_on(saved[row.key]), is_on(defaults[row.key])
		if now ~= was then
			table.insert(parts, (now and "+" or "-") .. row.label:gsub("^%-%-", ""))
		end
	end
	return table.concat(parts, " ")
end

return M
```

Créer `lua/dockyard/ui/popups/compose_menu/init.lua` :

```lua
-- Compose options menu: profiles and flags as check boxes, and the command they produce.

local M = {}

local model = require("dockyard.ui.popups.compose_menu.model")
local prefs = require("dockyard.commands.prefs")
local profiles = require("dockyard.commands.profiles")
local compose_run = require("dockyard.commands.compose_run")

local ns = vim.api.nvim_create_namespace("dockyard.compose_menu")
local WIDTH = 78

local ACTIONS = { d = "down", b = "build", p = "pull", s = "stop", r = "restart", u = "up" }

---@param state DockyardComposeMenuState
---@param run_opts { on_exit?: fun(ok: boolean) }
local function open_window(state, run_opts)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "dockyardmenu", { buf = buf })

	local item_lines = {}
	local win

	local function item_line_list()
		local list = vim.tbl_keys(item_lines)
		table.sort(list)
		return list
	end

	local function draw()
		local lines, spans
		lines, item_lines, spans = model.render(state)
		vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		for _, span in ipairs(spans) do
			vim.api.nvim_buf_set_extmark(buf, ns, span.line, span.start_col, {
				end_row = span.line,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_set_height, win, #lines)
		end
	end

	local width = math.min(WIDTH, vim.o.columns - 4)
	win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = 10,
		row = 2,
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " Compose options ",
		title_pos = "center",
		zindex = 280,
	})
	vim.api.nvim_set_option_value("cursorline", true, { win = win })
	vim.api.nvim_set_option_value("winhighlight", "CursorLine:DockyardCursorLine", { win = win })
	draw()

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end

	local function move(step)
		local list = item_line_list()
		local row = vim.api.nvim_win_get_cursor(win)[1]
		local target
		if step > 0 then
			for _, l in ipairs(list) do
				if l > row then
					target = l
					break
				end
			end
		else
			for i = #list, 1, -1 do
				if list[i] < row then
					target = list[i]
					break
				end
			end
		end
		if target then
			vim.api.nvim_win_set_cursor(win, { target, 0 })
		end
	end

	local function toggle()
		local row = vim.api.nvim_win_get_cursor(win)[1]
		local id = item_lines[row]
		if not id then
			return
		end
		if model.toggle(state, id) then
			prefs.set(state.file, state.prefs)
		end
		draw()
		pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
	end

	local function run(action)
		local opts = model.opts(state)
		local function go()
			close()
			compose_run.run(state.file, action, {
				volumes = state.once.volumes,
				rmi = state.once.rmi,
				renew_anon_volumes = state.once.renew_anon_volumes,
			}, run_opts)
		end
		if action == "down" and (opts.volumes or opts.rmi) then
			local what = opts.volumes and "the volumes" or "the images"
			vim.ui.select({ "No", "Yes" }, {
				prompt = ("Remove %s of %s?"):format(what, vim.fn.fnamemodify(state.project.dir, ":~")),
			}, function(choice)
				if choice == "Yes" then
					go()
				end
			end)
		else
			go()
		end
	end

	local function map(keys, fn)
		for _, key in ipairs(type(keys) == "table" and keys or { keys }) do
			vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true })
		end
	end
	map({ "j", "<Down>" }, function()
		move(1)
	end)
	map({ "k", "<Up>" }, function()
		move(-1)
	end)
	map({ "<Space>", "x" }, toggle)
	map({ "q", "<Esc>" }, close)
	map("<CR>", function()
		run(state.action)
	end)
	for key, action in pairs(ACTIONS) do
		map(key, function()
			run(action)
		end)
	end

	local first = item_line_list()[1]
	if first then
		vim.api.nvim_win_set_cursor(win, { first, 0 })
	end
end

---@param file string compose file
---@param opts? { action?: string, on_exit?: fun(ok: boolean) }
function M.open(file, opts)
	opts = opts or {}
	require("dockyard.ui.highlights").setup()
	profiles.detect(file, function(available, source, err)
		if source == "scan" and err and err ~= "" then
			vim.notify("Dockyard: could not ask docker for the profiles, read them from the file instead:\n" .. err, vim.log.levels.INFO)
		end
		open_window(model.new(file, available, prefs.get(file), opts.action), { on_exit = opts.on_exit })
	end)
end

return M
```

- [ ] **Step 4: Wire the lens, the command and the mapping**

Dans `lua/dockyard/compose_lens.lua` :

(a) Remplacer

```lua
local compose_run = require("dockyard.commands.compose_run")
local lens = require("dockyard.lens")
```

par

```lua
local compose_run = require("dockyard.commands.compose_run")
local prefs = require("dockyard.commands.prefs")
local menu_model = require("dockyard.ui.popups.compose_menu.model")
local lens = require("dockyard.lens")
```

(b) Remplacer

```lua
---@param buf integer
---@param status table<string, DockyardServiceStatus>
---@return table<integer, DockyardLensLine>
function M.build_lines(buf, status)
```

par

```lua
---@param buf integer
---@param status table<string, DockyardServiceStatus>
---@param summary? string what the project's options change, shown next to the options button
---@return table<integer, DockyardLensLine>
function M.build_lines(buf, status, summary)
```

(c) Dans `build_lines`, remplacer

```lua
		local name = service.name
		if s and s.state ~= "" then
			any_created = true
		end
```

par

```lua
		local name = service.name
		if #service.profiles > 0 then
			line:add("[" .. table.concat(service.profiles, ",") .. "]", "DockyardLensMuted")
		end
		if s and s.state ~= "" then
			any_created = true
		end
```

(d) Toujours dans `build_lines`, remplacer

```lua
	lines[block.lnum] = top
	return lines
```

par

```lua
	local options = "⚙ Options" .. ((summary and summary ~= "") and (" · " .. summary) or "")
	top:add(options, "DockyardLensMuted", { action = "options" })
	lines[block.lnum] = top
	return lines
```

(e) Remplacer la fonction `render`

```lua
local function render(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		lens.render(buf, M.build_lines(buf, statuses[buf] or {}))
	end
end
```

par

```lua
local function render(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local file = vim.api.nvim_buf_get_name(buf)
	local summary = file ~= "" and menu_model.summary(prefs.get(file)) or ""
	lens.render(buf, M.build_lines(buf, statuses[buf] or {}, summary))
end
```

(f) Dans `M.run_action`, remplacer `---@param action string run|stop|restart|build|down|logs|shell|open` par `---@param action string run|stop|restart|build|down|options|logs|shell|open` et, après la branche `elseif action == "down" then … end`, insérer :

```lua
	elseif action == "options" then
		require("dockyard.ui.popups.compose_menu").open(file, { on_exit = on_exit })
```

(g) Dans `attach`, juste après l'autocmd `{ "BufEnter", "BufWritePost", "FocusGained" }`, ajouter (le fichier a pu changer : ses profils aussi) :

```lua
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		buffer = buf,
		callback = function()
			require("dockyard.commands.profiles").invalidate(vim.api.nvim_buf_get_name(buf))
		end,
	})
```

Dans `lua/dockyard/commands/cli.lua` :

(a) Après la ligne `local SERVICE_ACTIONS = …`, ajouter `local COMPOSE_ACTIONS = { "up", "down", "build", "pull", "stop", "restart" }`.

(b) Juste avant `local function job_ids(lead)`, ajouter :

```lua
local function compose_file()
	local context = require("dockyard.commands.context")
	local file = context.current_file()
	if file and context.is_compose_file(file) then
		return file
	end
	return context.find_compose_file(vim.fn.getcwd())
end

```

(c) Dans `M.subcommands`, avant `jobs = {`, ajouter :

```lua
	compose = {
		run = function(args)
			local action = args[1] or "up"
			if not vim.tbl_contains(COMPOSE_ACTIONS, action) then
				return notify("unknown compose action '" .. action .. "'", vim.log.levels.ERROR)
			end
			local file = compose_file()
			if not file then
				return notify("no compose file found", vim.log.levels.WARN)
			end
			require("dockyard.ui.popups.compose_menu").open(file, { action = action })
		end,
		complete = function(lead)
			return starting_with(lead, COMPOSE_ACTIONS)
		end,
	},
```

et compléter le commentaire d'en-tête : `… | service | compose | jobs | job | rerun`.

Dans `plugin/dockyard.lua`, dans la table `plugs`, ajouter `compose = "compose",` (avant `jobs = "jobs",`).

Dans `lua/dockyard/ui/init.lua`, dans `register_command("Commands", { … })`, ajouter après l'entrée `Dockyard jobs` :

```lua
		{ name = "Dockyard compose", desc = "Compose options: profiles, --build, down -v…" },
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: `0 failed`.

Vérification manuelle (Docker requis) : dans un `docker-compose.yml`, cliquer `⚙ Options` : la liste des profils apparaît, `<Space>` coche `--build`, le chip `⚙ Options · +build` s'affiche dans le fichier ; `<CR>` lance `docker compose … up -d --build --force-recreate` ; cocher `-v` puis `d` demande confirmation.

- [ ] **Step 6: Commit**

```bash
git add lua/dockyard tests plugin/dockyard.lua
git commit -m "feat: compose options menu with profiles, flags and per-project defaults" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Documentation, changelog et vérification finale

**Files:**
- Modify: `README.md`, `doc/dockyard.txt`, `CHANGELOG.md`

**Interfaces:**
- Consumes: tout ce qui précède.
- Produces: documentation utilisateur à jour, entrée `## Unreleased`.

- [ ] **Step 1: CHANGELOG**

Dans `CHANGELOG.md`, insérer avant `## 0.4.2` :

```markdown
## Unreleased

### Added

- Compose options: a menu (`⚙ Options` on the `services:` line, `:Dockyard compose [action]`) with the profiles of the file,
  `--build`, `--pull`, `--force-recreate`, `--no-deps`, `--wait`, `--remove-orphans` and, for one run only, `-v`, `--rmi`
  and `-V`. Profiles and flags are remembered per project; `▶ Run` and the other buttons use them, and `down`, `stop` and
  `restart` get the active profiles too
- Jobs view: every command Dockyard runs is kept with its exact command line, status, duration and whole output; open it
  (`<CR>`), run it again (`r`), cancel it (`x`) or copy it (`y`). `:Dockyard jobs`, `:Dockyard job [id|last]`,
  `:Dockyard rerun [id|last]`
- `[profile]` chips next to the services that have `profiles:`
- Options `jobs.history`, `jobs.notice.close_after`, `compose.defaults.*` and `keymaps.jobs.*`, and `:checkhealth` checks the
  preferences file

### Changed

- The notice of a command starts with the exact command line and no longer closes when the command fails (`q` closes it,
  `<CR>` opens the whole output)
- `-v` and `--rmi` are never remembered, and `down` asks before removing volumes or images
- The Jobs view is added to the default `display.views`
```

- [ ] **Step 2: README**

Dans `README.md` :

(a) Dans le bloc `> [!NOTE]` du fork, ajouter avant la puce `**Open ports**` :

```markdown
> - **Compose options**: profiles, `--build`, `--pull`, `down -v`… from a menu, remembered per project
> - **Jobs view**: every command Dockyard runs, with its exact command line and whole output, replayable
```

(b) Dans la liste `## Features`, après `- [x] Build and run a Dockerfile from its \`FROM\` line`, ajouter :

```markdown
- [x] Choose compose profiles and flags (`--build`, `--pull`, `down -v`…) from a menu, remembered per project
- [x] Keep every command's output in a Jobs view, and run it again
```

(c) Dans le bloc de configuration, remplacer `views = { "containers", "images", "networks", "volumes" },` par `views = { "containers", "images", "networks", "volumes", "jobs" },` et remplacer la ligne `-- Available views: "containers", "compose", "images", "networks", "volumes"` par `-- Available views: "containers", "compose", "images", "networks", "volumes", "jobs"`. Puis, après `compose_lens = { enabled = true },`, ajouter :

```lua
  -- flags of the projects that have no saved preferences (the menu saves the rest per project)
  compose = {
    defaults = {
      force_recreate = true, build = false, pull = false, -- pull = false | "always" | "missing" | "never"
      no_deps = false, wait = false, remove_orphans = false,
    },
  },
  jobs = {
    history = 50,                    -- finished jobs kept in the Jobs view
    notice = { close_after = 3000 }, -- ms before the notice of a successful command closes (0 keeps it)
  },
```

(d) Avant `## LogLens`, ajouter :

````markdown
## Compose options

On the `services:` line of a compose file, `⚙ Options` (or `:Dockyard compose [action]`, or
`<Plug>(dockyard-compose)`) opens a menu:

```
 Compose · docker-compose.yml

 Profiles
   [x] debug
   [ ] tools
   [ ] all profiles (*)

 Saved for this project
   [x] --force-recreate
   [ ] --build
   [ ] --pull always
   ...

 This run only
   [ ] -v  remove volumes (down)
   [ ] --rmi local  remove images (down)
   [ ] -V  renew anonymous volumes (up)

 $ docker compose -f docker-compose.yml --profile debug up -d --force-recreate
```

`<Space>` ticks a box, `j`/`k` move, `<CR>` runs `up` (or the action given to `:Dockyard compose`), `d` `b` `p` `s` `r` run
`down`, `build`, `pull`, `stop`, `restart`, `q` closes. The boxes under *Saved for this project* and the profiles are
remembered per project (`stdpath("data")/dockyard/projects.json`) and used by `▶ Run` and the other buttons, so `down`,
`stop` and `restart` also see the active profiles. The *This run only* boxes are never saved, and `down` with `-v` or
`--rmi` asks before it runs. The line under the boxes is the exact command. Services with `profiles:` get a `[profile]`
chip in the file.

## Jobs

Every command Dockyard runs (compose actions, `docker build`…) is a job. The notice that appears when it starts shows the
exact command line and the tail of its output; it closes by itself after a success and stays after a failure (`q` closes
it, `<CR>` opens the whole output). The **Jobs** tab of the dashboard (`:Dockyard jobs`) lists them, newest first:

| Key | Action |
|---|---|
| `<CR>` / `K` | open the whole output (`:Dockyard job [id\|last]`) |
| `r` | run it again (`:Dockyard rerun [id\|last]`) |
| `x` | cancel a running job |
| `y` | copy the command line |
| `D` | forget the finished jobs |

Jobs live in memory for the session (`jobs.history` finished ones are kept).

````

- [ ] **Step 3: Vimdoc**

Dans `doc/dockyard.txt` (les retraits sont des tabulations, `tw=78`) :

(a) Dans la section 4, après le bloc `:Dockyard service [{action}]` (et avant `*dockyard-aliases*`), ajouter :

```
:Dockyard compose [{action}]                             *:Dockyard-compose*
    Open the compose options menu (|dockyard-compose-options|) for the
    current compose file, or the one in the working directory. {action} is
    what <CR> runs: `up` (default), `down`, `build`, `pull`, `stop`,
    `restart`.

:Dockyard jobs                                              *:Dockyard-jobs*
    Open the dashboard on the Jobs view (|dockyard-jobs|).

:Dockyard job [{id}|last]                                    *:Dockyard-job*
    Open the whole output of a job; `last` (default) is the most recent.

:Dockyard rerun [{id}|last]                                *:Dockyard-rerun*
    Run a job again.
```

(b) Dans la liste des `<Plug>`, après `*<Plug>(dockyard-service-open)*`, ajouter :

```
  *<Plug>(dockyard-compose)*          |:Dockyard-compose|
  *<Plug>(dockyard-jobs)*             |:Dockyard-jobs|
  *<Plug>(dockyard-job-last)*         `:Dockyard job last`
```

(c) Dans la section 5, après la ligne `Images view: …`, ajouter :

```
Jobs view: `<CR>` `K` open the output, `r` run again, `x` cancel, `y` copy
the command, `D` forget the finished jobs (|dockyard-jobs|).
```

(d) Dans la section 7, remplacer

```
- `▶ Run` / `▶▶ Run all`   `docker compose up -d --force-recreate`
```

par

```
- `▶ Run` / `▶▶ Run all`   `docker compose up -d`, with the options of the
                           project (|dockyard-compose-options|); the default
                           keeps `--force-recreate`
```

et, après le paragraphe qui se termine par `…offers the same actions from the keyboard.`, ajouter :

```
The `services:` line also has `⚙ Options`, with what differs from the
defaults next to it (`debug +build`), and services that have `profiles:` show
a `[profile]` chip.

                                                   *dockyard-compose-options*
`⚙ Options`, |:Dockyard-compose| or `<Plug>(dockyard-compose)` open a menu:

  Profiles        the profiles of the file (asked to `docker compose config
                  --profiles`, read from the file when that fails), and
                  `all profiles (*)`
  Saved           `--force-recreate` `--build` `--pull` `--no-deps` `--wait`
                  `--remove-orphans`: remembered for the project
  This run only   `-v` `--rmi` `-V`: never remembered

`<Space>` ticks a box, `<CR>` runs the action, `d` `b` `p` `s` `r` run `down`,
`build`, `pull`, `stop`, `restart`, `q` closes. The last line is the exact
command. Profiles and saved flags live in `stdpath("data")` under
`dockyard/projects.json`, one entry per compose file, and are used by every
button, so `down`, `stop` and `restart` see the active profiles too. `down`
with `-v` or `--rmi` asks first.
```

(e) Ajouter la section Jobs (numérotée 13) et décaler Highlights en 14 :

- dans la table des matières, remplacer

```
 13. Highlights ................................. |dockyard-highlights|
```

par

```
 13. Jobs ....................................... |dockyard-jobs|
 14. Highlights ................................. |dockyard-highlights|
```

- remplacer l'en-tête `13. HIGHLIGHTS                                           *dockyard-highlights*` par `14. HIGHLIGHTS                                           *dockyard-highlights*` (même alignement de la balise) ;
- insérer, juste avant la ligne de `====` qui précède cet en-tête, la section :

```
==============================================================================
13. JOBS                                                       *dockyard-jobs*

Every command Dockyard runs is a job with its command line, status, duration
and whole output. A notice shows the command and the tail of the output; it
closes after a success (`jobs.notice.close_after`, in milliseconds, 0 keeps
it) and stays after a failure: `q` closes it, `<CR>` opens the output.

The Jobs view lists them, newest first, up to `jobs.history` finished ones,
in memory only. Keys (`keymaps.jobs`):

  `<CR>` `K`   open the output     `r`   run again
  `x`          cancel              `y`   copy the command line
  `D`          forget the finished jobs

The output buffer (`dockyard-job://{id}`) follows a running job while the
cursor is on its last line; `q` closes it, `r` runs the job again, `x`
cancels it. The `User DockyardJobChanged` autocommand fires on every change,
with `data = { id = {job id} }`.

```

(f) Dans la section Configuration, dans le bloc `require("dockyard").setup({ … })`, remplacer `views = { "containers", "images", "networks", "volumes" },` par `views = { "containers", "images", "networks", "volumes", "jobs" },`, remplacer le commentaire `-- "containers", "compose", "images", "networks", "volumes"` par `-- "containers", "compose", "images", "networks", "volumes", "jobs"`, et après `compose_lens = { enabled = true },` ajouter :

```
    compose = {
      defaults = {             -- projects without saved preferences
        force_recreate = true, build = false, no_deps = false,
        wait = false, remove_orphans = false,
        pull = false,          -- false | "always" | "missing" | "never"
      },
    },
    jobs = {
      history = 50,
      notice = { close_after = 3000 },
    },
```

ainsi que, après `volumes = { remove = "d" },` :

```
      jobs = {
        open_output = "<CR>", rerun = "r", cancel = "x", clear = "D",
        copy_command = "y",
      },
```

- [ ] **Step 4: Verify the docs**

Run: `nvim --headless --clean --cmd "set rtp^=." -c "helptags doc" -c "qa" && grep -c "dockyard-jobs" doc/dockyard.txt`
Expected: pas d'erreur `E154` (tag dupliqué) ; le compte est ≥ 3. Puis `git status --short` ne doit pas montrer `doc/tags` (le fichier est ignoré ou à retirer : `command rm -f doc/tags` s'il apparaît).

- [ ] **Step 5: Final verification**

Run: `make test`
Expected: `0 failed` (≈ 120 tests).

Run: `make typecheck` si `lua-language-server` est installé ; sinon noter « typecheck non exécuté ».

Run: `nvim --headless --clean -c "set rtp^=." -c "checkhealth dockyard" -c "w! /tmp/dockyard-health.txt" -c "qa!"; grep -e ERROR -e WARNING /tmp/dockyard-health.txt`
Expected: aucune ligne `ERROR` liée à Dockyard ; `compose preferences file is readable` et `jobs: no conflicting mapped keys` présents.

Vérification manuelle avec Docker réel (charger le clone : dans `lua/plugins/init.lua` de la config Neovim, la spec `loisBreant/dockyard.nvim` cherche `~/dockyard.nvim` ; pointer `dir` vers `/home/lois/dotfiles/.config/nvim/dockyard.nvim` le temps du test, sans commiter ce changement sans demander) avec ce fichier `compose.yml` dans un dossier temporaire :

```yaml
services:
  api:
    image: alpine
    command: sleep 300
  adminer:
    image: alpine
    command: sleep 300
    profiles: [debug]
```

1. Ouvrir `compose.yml` : `adminer` porte `[debug]`, la ligne `services:` porte `⚙ Options`.
2. `⚙ Options` → cocher `debug` et `--build` → `<CR>` : le flottant montre `$ docker compose -f … --profile debug up -d --build --force-recreate` ; `adminer` et `api` démarrent ; le chip devient `⚙ Options · debug +build`.
3. Rouvrir le menu : les cases enregistrées sont cochées, `-v` ne l'est pas.
4. `down` avec `-v` coché : la confirmation apparaît ; répondre `No` ne lance rien, `Yes` lance `down -v`.
5. Casser volontairement le YAML puis `▶ Run` : le flottant reste ouvert (`✖ Failed`), `<CR>` ouvre la sortie complète.
6. `:Dockyard jobs` : les jobs sont listés, `r` rejoue, `x` annule un `docker compose build` long, `y` copie la commande.
7. `:checkhealth dockyard` : sections OK.

Nettoyer : `docker compose -f compose.yml --profile debug down`.

- [ ] **Step 6: Commit**

```bash
git add README.md doc/dockyard.txt CHANGELOG.md
git commit -m "docs: compose options, Jobs view and their options" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

## Self-Review (rempli avant la relecture par l'utilisateur)

**Couverture de la spec :** constructeur pur (T2) ; détection des profils, repli par balayage, chip `[profile]` (T3, T9) ; préférences persistantes, flags jamais mémorisés (T4) ; registre de jobs, historique borné, troncature, annulation, rejeu, `User DockyardJobChanged` (T5) ; flottant avec commande exacte et échec persistant (T6) ; `▶ Run` & co. passent par les préférences (T7) ; vue Jobs, buffer de sortie, commandes `jobs`/`job`/`rerun`, `<Plug>` (T8) ; menu, bouton `⚙ Options` avec résumé, confirmation `-v`/`--rmi`, `:Dockyard compose` (T9) ; options, validation, health, README, vimdoc, CHANGELOG (T1, T4, T10). Migration : `builder.run_cmd`/`compose_cmd` supprimés (T7).

**Types et noms :** `compose.build/project/base_cmd`, `profiles.detect/parse_at/scan/parse_output/invalidate`, `prefs.get/set/key/defaults/reset/path/check`, `runner.start/get/last/list/output/cancel/rerun/clear_finished/subscribe/duration/format_duration/format_cmd`, `executor.run`, `compose_run.run`, `job_notice.show/close/build_lines`, `output.open/build`, `renderer.build_rows`, `model.new/items/toggle/opts/command/render/summary` sont définis une fois et utilisés avec la même signature dans les tâches suivantes.

**Ordre de dépendance :** `job_notice` référence `dockyard.ui.views.jobs.output` (Task 8) uniquement dans le callback de `<CR>` : pas de `require` au chargement. `compose_lens` n'importe `prefs` et `menu_model` qu'en Task 9.
