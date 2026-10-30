# Glass Monitor — instructions for Claude

Glass Monitor is a small macOS menu-less agent app: a Liquid Glass pill floating at the top-right of
the screen with live CPU / GPU / RAM / swap / disk / network, which expands into a panel listing the
processes eating resources (with Quit / Force Quit / admin kill), a 7-day History tab ("why was my Mac
slow at 3pm?"), runaway-CPU and memory-leak alerts, a Dev tab (Laravel log errors per project, Docker
containers, listening ports) and a developer-cache cleaner. Plain SwiftUI + AppKit + Swift Charts +
SQLite, built with `swiftc` (no Xcode project).

## Reinstall (what the user wants when they hand you this folder)

1. Check the requirements:
   - macOS 26 (Tahoe) or later, Apple Silicon (`uname -m` → `arm64`).
   - Swift toolchain: `swiftc --version` (Xcode or Command Line Tools). If missing, ask the user to run
     `xcode-select --install` themselves (it opens a system dialog).
2. Build and install:
   ```bash
   ./build.sh
   ```
   This compiles `Sources/*.swift`, creates `~/Applications/Glass Monitor.app`, ad-hoc codesigns it and
   launches it (through the login agent when that is loaded). It kills any running copy first.
   If the sandbox blocks writing to `~/Applications` ("operation not permitted"), rerun it unsandboxed.
3. Turn on "Open at Login" (also gives crash auto-restart):
   ```bash
   pkill -x GlassMonitor; open "$HOME/Applications/Glass Monitor.app" --args --register-login
   ```
   (Kill first: a second copy started outside launchd exits immediately without registering.)
   This writes `~/Library/LaunchAgents/com.elabidi.glassmonitor.login.plist` and bootstraps it; the
   launchd copy then replaces the one `open` started. macOS may show a "Background item added"
   notification — that's expected.
4. Verify:
   - `pgrep -lx GlassMonitor` shows exactly one process.
   - `launchctl print gui/$(id -u)/com.elabidi.glassmonitor.login | grep -E 'state|pid'` → running.
   - CPU cost: `top -l 2 -pid $(pgrep -x GlassMonitor) -stats cpu` should be ≈0.4–1% collapsed.
   - After a minute, `sqlite3 ~/Library/Application\ Support/GlassMonitor/history.sqlite 'SELECT count(*) FROM samples'` ≥ 1.
   - The first time the Dev tab opens, macOS asks "Glass Monitor would like to access files in your
     Documents folder" (the Laravel log scan). Tell the user to click **Allow**; until then that section
     shows a spinner. Ad-hoc signing changes on every rebuild, so macOS may ask again after a rebuild.
   - The pill is hidden from screenshots by default ("Hide from Screen Sharing"), so a blank
     `screencapture` is normal. To check visually, ask the user to look, or temporarily run
     `defaults write com.elabidi.glassmonitor hideFromSharing -bool false` and restart the app
     (set it back to `true` afterwards).

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.elabidi.glassmonitor.login 2>/dev/null
rm -f ~/Library/LaunchAgents/com.elabidi.glassmonitor.login.plist
pkill -x GlassMonitor; rm -rf "$HOME/Applications/Glass Monitor.app" "$HOME/Library/Application Support/GlassMonitor"
defaults delete com.elabidi.glassmonitor
```

## Using it

- Click the pill to expand; ⌥⌘M toggles from anywhere. Drag it to move it (any screen); position is
  remembered. Right-click for settings (pill items, opacity, click-through, hide in full screen,
  hide from screen sharing, runaway & leak alerts, open at login, move to screen, quit).
- History tab: 1h / 6h / 24h / 7d chart of CPU and memory. Hover a minute to see which apps were
  using it, click to pin; with nothing selected the list is the range average.
- Memory-leak alert: a process grows ≥500 MB and ≥50% over an hour with every 10-minute average rising.
  Same banner/notification as runaway CPU (Quit / Ignore; ignoring applies to both).
- Dev tab, Laravel section: every folder with an `artisan` file under ~/Documents, ~/Projects, ~/Sites,
  ~/code, ~/dev, ~/src, ~/Developer, ~/Herd (depth 6); counts ERROR/CRITICAL/ALERT/EMERGENCY entries in
  `storage/logs/**/*.log` from the last 24 h (line format and JSON/ECS format; newest 4 MB of each log).
  Hover: Open Log, Restart (the project's running compose containers). Rescans every 5 min.
- Debug launch args: `--expanded`, `--tab=cpu|memory|disk|network|history|dev|clean`, `--test-alert`,
  `--register-login`, `--unregister-login`.

## Code map (`Sources/`)

| File | What |
|---|---|
| `main.swift` | `FloatingPanel` (borderless non-activating NSPanel), Carbon hotkey, `AppDelegate` (placement, drag, click-through, full-screen hiding), app entry |
| `LoginItem.swift` | Per-user launch agent (login + crash restart), migration from old SMAppService items, single-instance logic |
| `History.swift` | SQLite store (`~/Library/Application Support/GlassMonitor/history.sqlite`, 7-day retention) + `Timeline` model |
| `HistoryView.swift` | History tab (Swift Charts, hover/pin) |
| `Stats.swift` | CPU ticks, memory/swap/pressure, disk space & I/O, GPU, network, battery (Mach/sysctl/IOKit) |
| `Processes.swift` | `ps` sampling, per-process disk/net rates, app grouping, icon cache |
| `Monitor.swift` | `ObservableObject` model, 1.5 s tick, per-minute history recording, kill/dev/clean actions |
| `Alerts.swift` | Runaway-CPU and memory-leak detectors + notifications (Quit / Ignore actions) |
| `DevTools.swift` | Docker, Laravel log scanner, listening ports (`lsof`), disk-cache cleaner |
| `Shell.swift` | Process runner, admin commands via AppleScript, system tools |
| `Prefs.swift` | UserDefaults-backed settings |
| `Components.swift`, `ListViews.swift`, `RootView.swift` | SwiftUI views and formatting |

## Lessons already learned — don't regress these

- **No looping/per-tick SwiftUI animations behind the glass** (animated ring trims, `.numericText`,
  animated list reorders, `.clipShape`): they forced software re-rendering at ~24% CPU.
- **Disk-space query (`volumeAvailableCapacityForImportantUsage`) is expensive** — only every 20 ticks.
- **Counters can go backwards** (a disk/disk image ejected): skip the sample. All number formatting
  goes through `safe()` in `Components.swift`; converting a huge/NaN Double to `Int64` crashes.
- **Docker cleanup is `image prune -af` + `builder prune -af` only** — never `system prune`, which
  deletes stopped compose containers. Cleanup moves files to the Trash, never deletes permanently.
- The launch agent uses `KeepAlive.SuccessfulExit = false`: crash → relaunch in ~1–2 s; Quit → stays quit
  until next login. Keep `claimSingleInstance()` so a Finder launch doesn't create a second pill.
- **Don't go back to `SMAppService.agent` / `.mainApp`.** build.sh replaces the bundle on every build and
  SMAppService then can't spawn it (launchd: `last exit code = 78: EX_CONFIG`, forever). The plain
  `~/Library/LaunchAgents` plist with an absolute path survives rebuilds.
- History is recorded once a minute from the existing process sample; the chart lives in its own
  `Timeline` ObservableObject so hovering doesn't redraw the whole panel.
- Build is plain `swiftc` with `-swift-version 5`; top-level code must stay in `main.swift`.
