[![Neovim](https://img.shields.io/badge/Neovim-0.10+-blue.svg)](https://neovim.io/)
[![License](https://img.shields.io/github/license/loisBreant/dockyard.nvim?style=flat-square&color=blue)](LICENCE)

# Dockyard.nvim

Interactive Docker dashboard directly in your editor. It lets you view and manage containers, images, networks, and logs

> [!NOTE]
> This is a fork of [emrearmagan/dockyard.nvim](https://github.com/emrearmagan/dockyard.nvim) that stays in sync
> with upstream and adds:
>
> - **Compose actions**: clickable `▶ Run` / `■ Stop` / `≡ Logs` / `Shell` buttons next to every service in compose files, like VSCode
> - **Container file browser**: search by name or content, edit, copy/move, download and upload files
> - **Project scope** (`P`): only show the containers of the project Neovim is working on
> - **Container filter** (`F` / `C`), open strategies for `:Dockyard`, a native terminal when toggleterm is not installed and
>   ANSI colors in logs, from [jugarpeupv/dockyard.nvim](https://github.com/jugarpeupv/dockyard.nvim)

> [!CAUTION]
> **Still in early development, will have breaking changes!**

<table>
  <thead>
    <tr>
      <th width="50%" align="center">Dockyard</th>
      <th width="50%" align="center">Detail Panel</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td width="50%"><img alt="LogLens" src="https://github.com/user-attachments/assets/06291218-02b6-4733-96a6-27d8ac7dd7b7"></td>
      <td width="50%"><img alt="LogLens" src="https://github.com/user-attachments/assets/1ed7f58d-b407-4b0b-ba8e-ad719e226702"></td>
    </tr>
  </tbody>
</table>

## Introduction

Dockyard provides a single Docker workspace inside Neovim. You can inspect containers, images, and networks, run common container actions, open shell sessions, and stream logs through LogLens without leaving the editor.

## Features

- [x] Inspect and manage containers
- [x] Inspect and manage images
- [x] Inspect and manage networks
- [x] Docker Compose grouping via the `compose` view
- [x] Open shell sessions inside containers
- [x] Stream and inspect logs
- [x] Run Docker build commands from Dockyard
- [x] Filter containers by name, status, image, ports or compose project
- [x] Show only the containers of the current project
- [x] Run, stop, restart services and open their logs or a shell straight from compose files
- [x] Navigate and search the file tree inside a container
- [x] Copy, modify, and manage files inside a container

## Requirements

- Neovim `>= 0.10`
- Docker CLI available in `$PATH`
- [`akinsho/toggleterm.nvim`](https://github.com/akinsho/toggleterm.nvim) (optional: `T` opens a native terminal without it)
- [`m00qek/baleia.nvim`](https://github.com/m00qek/baleia.nvim) (optional, for ANSI colors in logs — e.g. `[0;32m  OK  [0m`)

## Installation

### lazy.nvim

```lua
{
  "loisBreant/dockyard.nvim",
  dependencies = {
    "m00qek/baleia.nvim", -- optional, for ANSI colors in logs
  },
  cmd = { "Dockyard", "DockyardFloat", "DockyardRun", "DockyardBuild", "DockyardFiles", "DockyardLogs" },
  event = {
    -- compose actions show up as soon as a compose file opens
    "BufReadPost *compose.yml,*compose.yaml,*compose.*.yml,*compose.*.yaml",
    -- open container files with :edit dockyard://<container>/<path>
    "BufReadCmd dockyard://*",
  },
  config = function()
    require("dockyard").setup({})
  end,
}
```

<p align="center">
  <img width="49%" alt="Docker stats" src="https://github.com/user-attachments/assets/1aeb9163-a0e9-4f4a-9243-305f4ba9f5f0" />
  <img width="49%" alt="Networks" src="https://github.com/user-attachments/assets/b0d76760-a09c-432b-899b-47119069caaa" />
</p>

## Configuration

> [!tip]
> It's a good idea to run `:checkhealth dockyard` to see if everything is set up correctly.

```lua
require("dockyard").setup({
  display = {
    -- Available views: "containers", "compose", "images", "networks", "volumes"
    -- "compose" shows containers grouped by Docker Compose project
    views = { "containers", "images", "networks", "volumes" },
    -- how :Dockyard opens without an argument: "current" | "split" | "vsplit" | "tab" | "float"
    open_strategy = "tab",
    -- start with only the current project's containers shown (toggle with P)
    project_scope = false,
  },
  -- clickable actions next to services in compose files
  compose_lens = { enabled = true },
  loglens = {
    containers = {
      -- Override highlights only
      ["postgres"] = {
        highlights = {
          { pattern = "%f[%a]ERROR%f[%A]", group = "ErrorMsg" },
        },
      },
      -- Mix docker logs with file sources
      ["api"] = {
        _order = { "time", "level", "message" },
        sources = {
          { name = "Docker Logs" },   -- stdout/stderr, no path needed
          {
            name = "App Logs",
            path = "/var/log/app.json",
            parser = "json",
            tails = 200,
            format = function(entry)
              return {
                time = entry.timestamp and entry.timestamp:sub(12, 19) or "--:--:--",
                level = (entry.level or "info"):upper(),
                message = entry.message or "",
              }
            end,
          },
        },
      },
    },
    default_highlights = { ... } -- Optional global default highlights. Comes with default rules, but you can override them.
  },
})
```

## LogLens

Open LogLens from the containers tab with `L`. Each container can define one or more log sources.

### Source options

- `name` string (optional)
- `path` string (optional) — omit to stream docker stdout/stderr (`docker logs -f`)
- `parser` `"json" | "text"` (defaults to `"text"` when no path)
- `format` function (optional when no path; receives `(entry, ctx)`)
- `tails` number (optional, default `100`)

Container-level defaults (applied to all sources unless overridden):

- `_order` `string[]` (optional column order)
- `format` function
- `highlights` `LogHighlightRule[]` (optional; sensible defaults applied when omitted)
- `max_lines` number (optional, default `1000`)
- `tails` number (optional, default `100`)

If no `sources` are configured for a container, docker logs are streamed automatically.

#### Text parser

For text parser, `format` receives `(line, ctx)`.

```lua
{
  name = "Postgres Logs",
  parser = "text",
  _order = { "logs" },
  format = function(line, ctx)
    return {
      source = ctx.name or "-",
      logs = line,
    }
  end,
}
```

#### JSON parser

For JSON parser, `format` receives `(entry, ctx)` where `ctx` includes source metadata (`name`, `path`, `parser`).

```lua
{
  name = "Backend JSON",
  path = "/var/log/backend.json",
  parser = "json",
  max_lines = 2000,
  tails = 150,

  _order = { "time", "level", "message", "context" },
  format = function(entry, ctx)
    local ts = entry.timestamp and entry.timestamp:sub(12, 19) or "--:--:--"
    local level = (entry.level or "info"):upper()
    local ectx = entry.context or {}
    local user = ectx.user_id or "-"
    local trace = entry.trace_id or ectx.trace_id or "-"
    return {
      time = ts,
      level = level,
      source = ctx.name or "-",
      message = entry.message or "",
      context = string.format("user=%s trace=%s", user, trace),
    }
  end,
  highlights = {
     { pattern = "%d%d:%d%d:%d%d", group = "Comment" },
     { pattern = "%f[%a]ERROR%f[^%a]", group = "ErrorMsg" },
     { pattern = "%f[%a]WARN%f[^%a]", group = "WarningMsg" },
     { pattern = "%f[%a]INFO%f[^%a]", group = "Identifier" },
     { pattern = "%d+%.%d+%.%d+%.%d+", group = "Special" },
     { pattern = "/api/[%w_/%-%.]+", color = "#8be9fd" },
  }
}
```

## Highlight Rules

Each rule supports:

- `pattern` (required)
- `group` (highlight group)
- `color` (hex color)

> [!NOTE]
> Dockyard comes with some default highlights, but you can override or extend them with your own rules.

## Project scope

Press `P` in the containers view to only show the containers of the project you are working on, and again to show
them all. The project is the git root of Neovim's working directory (or the directory itself); a container belongs to
it when its Docker Compose project was started from inside it — or from a parent of it, when Neovim is opened in a
subdirectory. Containers started with a plain `docker run` have no project and are hidden in this mode.

It combines with the filter (`F`): the header shows both, e.g. `Project: ~/my-app (3/12)` and `Filter: db (1/3)`.
Set `display.project_scope = true` to start in this mode.

## Compose actions

Open a `docker-compose.yml` / `compose.yaml` (or a `compose.*.yml` variant) and every service gets its state and actions
at the end of its line; `services:` gets actions for the whole project:

```yaml
services:   ▶▶ Run all  ■ Stop all
  api:   ● running  ↻ Restart  ■ Stop  ≡ Logs   Shell
    image: my/api
  db:   ○ exited  ▶ Run
    image: postgres:16
```

Click a button to run it (`docker compose up -d`, `stop`, `restart`, LogLens, a shell). From the keyboard,
`:DockyardService {run|stop|restart|logs|shell}` acts on the service under the cursor — map it if you use it often:

```lua
vim.keymap.set("n", "<leader>dr", "<cmd>DockyardService run<cr>", { desc = "Run compose service" })
```

## File browser

`:DockyardFiles <container> [path]`, or `f` on a container, browses its filesystem. Press `g?` for the keymaps:

| Key | Action |
|---|---|
| `<CR>` / `l` | open file / enter directory |
| `-` / `h` | parent directory |
| `s` | find files by name (glob or plain text) into the quickfix list |
| `S` | search file contents into the quickfix list |
| `a` | create a file, or a directory when the name ends with `/` |
| `r` / `d` | rename / delete |
| `c` / `x`, then `p` | copy / move an entry into the current directory |
| `D` / `U` | download to the host / upload from the host |
| `y` | yank the path |
| `gh` | toggle hidden files |

Files open as `dockyard://<container>/<path>` buffers: edit them and `:w` writes back into the container, keeping the
file's owner and permissions. You can also `:edit dockyard://<container>/<path>` directly.

## Commands

- `:Dockyard [current|split|vsplit|tab|float]` - open the UI (defaults to `display.open_strategy`; also honors `:vertical` / `:tab` modifiers)
- `:DockyardFloat` - open floating UI
- `:DockyardBuild` - build a Docker image from the nearest `Dockerfile`. Tags the image after the parent directory name.
- `:DockyardRun` - runs Docker Compose services (`docker compose up -d --force-recreate`). Supports visual selection.
- `:DockyardService {run|stop|restart|logs|shell}` - act on the compose service under the cursor
- `:DockyardFiles <container> [path]` - browse a container's filesystem at `path` (defaults to `/`).
- `:DockyardLogs <container>` - open LogLens for a container

## Keymaps

Press `g?` inside any Dockyard buffer to see all bindings for the current view.

Set an action to `false` to disable it, or set it to a list to add aliases.

```lua
require("dockyard").setup({
  keymaps = {
    ui = {
      help = "g?",
      close = "q", -- false would disable it
      refresh = "R",
      next_view = { "<Tab>", "]" }, -- list adds aliases
      prev_view = { "<S-Tab>", "[" },
      toggle_node = "<CR>",
      open_details = "K",
      open_panel = "p",
    },
    containers = {
      toggle_start_stop = "s",
      stop = "x",
      restart = "r",
      remove = "d",
      open_terminal = "T",
      open_logs = "L",
      open_files = "f",
      filter = "F", -- filter containers (e.g. "running" to show only running)
      clear_filter = "C",
      toggle_project_scope = "P", -- only this project's containers / all
    },
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
    loglens = {
      close = "q",
      toggle_follow = "f",
      toggle_raw = "r",
      filter = "/",
      clear_filter = "c",
      open_detail = { "<CR>", "K" },
      help = "g?",
    },
  },
})
```

## Credits

Built on [emrearmagan/dockyard.nvim](https://github.com/emrearmagan/dockyard.nvim) by Emre Armagan, with the container
filter, open strategies and native terminal from [jugarpeupv/dockyard.nvim](https://github.com/jugarpeupv/dockyard.nvim).

## License

MIT - see [LICENSE](LICENCE).
