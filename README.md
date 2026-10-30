# Glass Monitor

A Liquid Glass system monitor pill for macOS 26. It floats at the top-right of the screen and shows live
CPU, GPU, RAM, swap, disk and network usage. Click it to expand a panel with:

- **Processes** by CPU, memory, disk or network, grouped by app, with Quit / Force Quit / admin kill
- **History**: 7 days of per-minute CPU and memory, plus which apps were using them at any moment
- **Alerts** for runaway CPU and memory leaks
- **Dev**: Laravel log errors per project, Docker containers, listening ports
- **Clean**: developer caches (DerivedData, npm, Composer, Docker images…), moved to the Trash

## Install

Requires macOS 26 on Apple Silicon and the Swift toolchain (`xcode-select --install`).

```bash
./build.sh
```

This builds and launches `~/Applications/Glass Monitor.app`. Right-click the pill → **Open at Login**
to start it at login and restart it automatically if it crashes. ⌥⌘M toggles the panel.

See [CLAUDE.md](CLAUDE.md) for the full install, uninstall and code notes.
