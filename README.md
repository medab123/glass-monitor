# Glass Monitor

A Liquid Glass system monitor for macOS 26 (Tahoe). A small glass pill floats on your screen with live
CPU, GPU, RAM, swap, disk, network and temperature. Click it to see what is slowing your Mac down, and
quit it in one click.

It uses the native macOS 26 glass effect, so it looks like part of the system rather than a menu-bar
add-on.

## Features

### The pill

- Live **CPU, GPU, RAM, swap, disk, network** and **temperature** readings with colored rings
  (green → orange → red). Choose which ones to show.
- **Drag it anywhere**, on any screen; its position is remembered. Snap back to the top-right from the menu.
- **⌥⌘M** opens and closes the panel from any app.
- **Opacity** 50–100%, **click-through** mode (hold ⌥ to interact), **hidden in full-screen apps** and
  **hidden from screen sharing and recordings** (both on by default).

### Overview

- **Status line**: memory pressure, thermal state (Cool → Throttling), power draw, battery % and
  time left or time to full.
- **Sensors line**: average CPU and GPU temperature, fan speed ("Fans off" when idle),
  battery health and cycle count (the same figures System Information shows).
- **Six live graphs**: CPU (user / system), GPU, memory, swap and compressed memory, disk read/write
  speed and free space, network down/up. Switch between the last minute and the last hour.

### Processes (CPU, Memory, Disk, Network tabs)

- Top processes ranked by CPU, memory, disk activity or network traffic.
- **Grouped by app**: all of Chrome's helpers count as one Chrome, with a row you can expand.
  Or list every single process.
- **Quit, Force Quit** or **kill as admin** (asks for your password) for processes owned by the system.
  Core system processes (kernel_task, WindowServer, launchd, loginwindow) are protected.

### History

- Records **one sample a minute for 7 days**, kept in a local SQLite database.
- Chart of CPU and memory for the last **1 hour, 6 hours, 24 hours or 7 days**.
- **Hover any moment** to see which apps were using CPU and memory then; click to pin it.
  With nothing selected, it shows each app's average CPU and highest memory over the range.

### Alerts

Shown in the pill and as macOS notifications with **Quit** / **Ignore** buttons where it makes sense.

- **Runaway CPU**: a process above 80% CPU for 2 minutes.
- **Memory leak**: a process that grows by 500 MB and 50% over an hour, rising the whole time.
- **Critical memory pressure**, with the biggest app named.
- **Your own limits** (right-click → Alert When…): memory %, swap GB, disk %, CPU temperature.
  Each alert fires once and fires again only after the value drops back below the limit.

### Dev

- **Laravel**: finds every project with an `artisan` file and counts the errors logged in the last
  24 hours (Laravel's line format and JSON logs). Shows the latest error; open the log or restart the
  project's Docker containers in one click.
- **Docker**: all containers with their Compose project, CPU and memory; start, stop, restart.
- **Listening ports**: every local server (Node, PHP, Docker…) with its ports; open in the browser or kill it.

### Clean

Shows how much space each developer cache uses and frees it in one click. Files go to the **Trash**,
never deleted permanently.

- Xcode DerivedData, iOS Device Support, Simulator caches, unavailable simulators
- Homebrew, npm, Yarn, pnpm, Composer and pip caches
- Docker unused images and build cache (never your containers or volumes)
- `node_modules` folders in your projects, biggest first
- Shortcuts to review Xcode Archives and the Trash

### Tools menu

Free Up Memory, Restart Spotlight Indexing, Flush DNS Cache, Restart Finder, Restart Dock and
Open Activity Monitor.

### Reliability and cost

- **Open at Login**, with automatic restart within about 2 seconds if it ever crashes. Quitting it yourself
  keeps it closed until your next login.
- Only one copy runs at a time.
- About **1% CPU** while collapsed. Docker, port and log scans only run while the Dev tab is open.

## Privacy

Everything stays on your Mac. Glass Monitor has no network code of its own, sends nothing anywhere,
and stores its history only in `~/Library/Application Support/GlassMonitor/`.

## Requirements

- macOS 26 (Tahoe) or later on Apple Silicon
- The Swift toolchain: Xcode or the Command Line Tools (`xcode-select --install`)

## Install

```bash
git clone https://github.com/medab123/glass-monitor.git
cd glass-monitor
./build.sh
```

This builds and launches `~/Applications/Glass Monitor.app`. Then right-click the pill →
**Open at Login**.

The first time you open the Dev tab, macOS asks for access to your Documents folder (to read Laravel
logs). Click **Allow**.

Temperatures and fan speeds come from the Mac's System Management Controller (the same source Stats
and iStat Menus use), because macOS has no public API for them.

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.elabidi.glassmonitor.login 2>/dev/null
rm -f ~/Library/LaunchAgents/com.elabidi.glassmonitor.login.plist
pkill -x GlassMonitor
rm -rf ~/Applications/Glass\ Monitor.app ~/Library/Application\ Support/GlassMonitor
defaults delete com.elabidi.glassmonitor
```

## For developers

Plain SwiftUI + AppKit, Swift Charts and SQLite, built with `swiftc` (no Xcode project).
[CLAUDE.md](CLAUDE.md) has the code map and the lessons learned (what not to change and why).
