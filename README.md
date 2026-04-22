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
- **Bundled engines** — `sing-box` and `xray` ship inside the app, no installation required
- **Real-time logs** with copy/clear

## Screenshots

| Servers | Settings |
|---------|----------|
| Power button, uptime timer, download/upload stats, server list with ping | Auto-connect, passwordless, kill switch, domain bypass, components |

## Requirements

- macOS 14+ (universal binary, runs on Apple Silicon and Intel)

`sing-box` and `xray` are bundled inside the `.app` — no separate installation needed.

## Install

Download the latest `.zip` from [Releases](../../releases), unzip, and drag `WarpVeil.app` to `/Applications`.

The app runs in the menu bar (no Dock icon). Right-click the tray icon to quit.

## Build from Source

1. Run `./fetch-binaries.sh` once to populate `Binaries/` with universal `sing-box` and `xray` binaries (pinned versions, sha256-verified).
2. Open `WarpVeil.xcodeproj` in Xcode and press **Cmd+R**. The "Bundle VPN Binaries" build phase copies them into `WarpVeil.app/Contents/Resources/`.

> Do not use `swift build` — the project requires a proper `.app` bundle with `Info.plist`.

## Release

```bash
NOTARY_PROFILE=NOTARY_PROFILE ./release.sh
```

Builds Release, signs `xray`/`sing-box` and the `.app` with Developer ID, notarizes via `notarytool`, staples, packages a `.zip`, then creates a GitHub Release. If no Developer ID identity is found, signs ad-hoc and skips notarization.

One-time notary setup: `xcrun notarytool store-credentials NOTARY_PROFILE --apple-id <id> --team-id <team> --password <app-specific-password>`.

To bump version, edit `CFBundleShortVersionString` in `Info.plist`.

## Architecture

```
Sources/
├── WarpVeilApp.swift          # NSStatusItem + NSPopover, right-click menu
├── ContentView.swift          # Tab bar (Servers / Settings), connect/disconnect
├── ServersView.swift          # Power button, stats, server list with ping, log overlay
├── SettingsView.swift         # Toggles, domain bypass, components info
├── ProcessManager.swift       # VPN process lifecycle, sudo, log tailing, sleep/wake
├── SubscriptionService.swift  # Subscription fetch, vless/vmess URI parsing
├── SetupService.swift         # Bundled-binary detection & version reporting
├── LocationService.swift      # Public IP & geolocation via ipwho.is (HTTPS)
├── NetworkMonitor.swift       # Real-time upload/download speed (circular buffer)
├── BypassService.swift        # Domain bypass config injection
├── Models.swift               # Server, Subscription, Engine types
└── StatusIndicator.swift      # Pulse animation indicator
```

## License

MIT
