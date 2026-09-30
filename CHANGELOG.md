# Changelog

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

## 0.4.2

### Fixed

- The dashboard keeps the cursor on the selected item after an action or a refresh instead of jumping to the top
- `:Telescope dockyard` shows up in completion

### Changed

- The selected row is highlighted (`DockyardCursorLine`)

## 0.4.1

### Fixed

- Opening ports in the browser did nothing under WSL (xdg-open without a browser); it now goes through Windows, and
  other failures are reported
- Dockerfile buttons moved to the first `FROM` line, where they are visible when the file opens

## 0.4.0

### Changed

- `setup()` is optional: the plugin loads on its own and needs no lazy-loading rules
- Commands are grouped under `:Dockyard` (`pick`, `files`, `logs`, `build`, `run`, `service`); the `:DockyardXxx`
  commands still work
- Highlight groups use `default = true`, so colour schemes can override them

### Added

- `<Plug>(dockyard-…)` mappings
- `:checkhealth` reports invalid and unknown options
- `make test`, `make typecheck`, `repro.lua` and a bug report template

### Fixed

- `icons.icon()` could return a table
- A nil pid in the log stream when docker printed none
- Failed docker calls returned results of the wrong shape

## 0.3.0

First release of the loisBreant fork, on top of upstream 0.2.2.

### Added

- Compose actions: clickable `▶ Run`, `■ Stop`, `↻ Restart`, `≡ Logs`, `Shell`, `⟳ Build` and `↗ :port` next to every
  service, `▶▶ Run all`, `■ Stop all`, `⟳ Build all` and `▼ Down` on `services:`; live health state;
  `:DockyardService` for the keyboard
- Dockerfile actions: `⟳ Build` and `▶ Build & Run` on the final `FROM` line
- Project scope (`P`): only the containers of the current project, on by default in compose projects
  (`display.project_scope = "auto"`)
- Container picker: `:Telescope dockyard` and `:DockyardPick`
- Open published ports in the browser (`o` in the dashboard, port buttons in compose files)
- File browser: search by name (`s`) and content (`S`), copy / move (`c` / `x` then `p`), download (`D`) and upload
  (`U`), help (`g?`); `dockyard://<container>/<path>` buffers that open from anywhere and keep owner and permissions
  on save
- From jugarpeupv/dockyard.nvim: container filter (`F` / `C`), open strategies for `:Dockyard`, native terminal when
  toggleterm is missing, ANSI colours in logs with baleia.nvim
- `:help dockyard`, a test suite and CI

### Fixed

- File search results opened empty buffers
- The file browser could take over a buffer of a file from the same container
