# Changelog

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
