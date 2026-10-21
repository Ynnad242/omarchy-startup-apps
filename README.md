# Startup Apps for Omarchy

Windows-style startup apps, but with workspaces. Drag app icons onto five
squares, one per workspace, and they open there every time you log in.

- **Drag and drop**: pick from every installed app, webapps and Steam games
  included. Several apps can share one workspace.
- **Terminal apps**: type a command in the search box (say `btop`) and drag the
  tile it makes, like any other app.
- **Remove or move**: drag an app off its square, or right-click it, to remove
  it. Drag it onto another square to move it.
- **Quiet start**: apps are moved to their workspace without pulling you along,
  so you stay where you are while everything opens.

## Install

```bash
omarchy plugin add https://github.com/Ynnad242/omarchy-startup-apps --enable
```

This puts a rocket icon on the bar. Click it to open Startup Apps, and click it
again, or press `Esc`, to close it.

If the window doesn't float, add this to `~/.config/hypr/hyprland.lua`:

```lua
o.window({ class = "^org.quickshell$", title = "^Startup Apps$" }, { float = true, center = true, size = { 940, 640 } })
```

### Run at login

The first time you open Startup Apps it offers a **Run at login** button. It
adds this line to `~/.config/hypr/autostart.lua`, or you can add it yourself:

```lua
o.exec_on_start(os.getenv("HOME") .. "/.config/omarchy/plugins/ynnad.startup-apps/startup-apps")
```

## How it works

Your layout is saved to `~/.config/omarchy/startup-apps.json`. At login the
`startup-apps` script launches every app at once. It then watches for each
app's first window and moves it to its workspace.

Each app is matched to its window by its class, using its desktop ID, its
`StartupWMClass`, the program name, the site for webapps, and `steam_app_<id>`
for Steam games. Updater and splash windows are skipped, so apps like Discord
land correctly once they finish updating. An app whose window doesn't turn up
within 60 seconds is logged to the journal (`journalctl -t startup-apps`).

## Requirements

Omarchy with the Quickshell shell and Hyprland's Lua config, plus `jq`.

Built with Claude Code.
