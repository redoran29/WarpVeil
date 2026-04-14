# WarpVeil

Lightweight macOS menu bar app for managing **sing-box** and **xray** VPN connections.

## Features

- **Menu bar widget** — connection status, country flag, live traffic speed
- **One-click connect/disconnect** with admin privileges
- **Subscription support** — add via URL (`vless://`, `vmess://`) or JSON config
- **Server ping** — TCP latency measurement with color indicators
- **Domain bypass** — route specific domains outside the VPN tunnel
- **Auto-reconnect** after sleep/wake
- **Passwordless mode** — optional sudoers setup to skip password prompts
- **Auto-install** — detect and install dependencies (Homebrew, sing-box, xray)
- **Real-time logs** with copy/clear

## Screenshots

| Servers | Settings |
|---------|----------|
| Power button, uptime timer, download/upload stats, server list with ping | Auto-connect, passwordless, kill switch, domain bypass, components |

## Requirements

- macOS 14+
- [sing-box](https://github.com/SagerNet/sing-box) and/or [xray](https://github.com/XTLS/Xray-core) (auto-installed via Homebrew)

## Install

Download the latest `.zip` from [Releases](../../releases), unzip, and drag `WarpVeil.app` to `/Applications`.

The app runs in the menu bar (no Dock icon). Right-click the tray icon to quit.

## Build from Source

Open `WarpVeil.xcodeproj` in Xcode and press **Cmd+R**.

> Do not use `swift build` — the project requires a proper `.app` bundle with `Info.plist`.

## Release

```bash
./release.sh
```

Builds a Release archive, packages it into a `.zip`, and creates a GitHub Release with auto-generated notes. Runs autonomously — if no changes since the last tag, it skips.

To bump version, edit `CFBundleShortVersionString` in `Info.plist`.

## Architecture

```
Sources/
├── WarpVeilApp.swift          # NSStatusItem + NSPopover, right-click menu
├── ContentView.swift          # Tab bar (Servers / Settings), connect/disconnect
├── ServersView.swift          # Power button, stats, server list with ping, log overlay
├── SettingsView.swift         # Toggles, domain bypass, dependency management
├── ProcessManager.swift       # VPN process lifecycle, sudo, log tailing, sleep/wake
├── SubscriptionService.swift  # Subscription fetch, vless/vmess URI parsing
├── SetupService.swift         # Dependency detection & Homebrew installation
├── LocationService.swift      # Public IP & geolocation via ip-api.com
├── NetworkMonitor.swift       # Real-time upload/download speed (circular buffer)
├── BypassService.swift        # Domain bypass config injection
├── Models.swift               # Server, Subscription, Engine types
└── StatusIndicator.swift      # Pulse animation indicator
```

## License

MIT
