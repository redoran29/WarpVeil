# WarpVeil

Lightweight macOS app for managing **sing-box** and **xray** VPN connections.

## Features

- **Menu bar status** — connection state and country flag, with connect/disconnect in its menu
- **One-click connect/disconnect** with admin privileges
- **Subscription support** — add via URL (`vless://`, `vmess://`) or JSON config
- **Domain bypass** — route specific domains outside the VPN tunnel
- **Auto-reconnect** after sleep/wake
- **Passwordless mode** — optional sudoers setup to skip password prompts
- **Bundled engines** — `sing-box` and `xray` ship inside the app, no installation required
- **Server ping** — real delay through each proxy, measured by the bundled engines in user space
- **Real-time logs** with copy/clear

## Screenshots

| Servers | Routing | Advanced | Logs |
|---------|---------|----------|------|
| Servers grouped by subscription, with refresh and delete per subscription | Domain bypass | Auto-connect, passwordless, components | VPN log with copy and clear |

The power button, uptime, traffic stats and location sit in the right-hand column on every page.

## Requirements

- macOS 14+, Apple Silicon

`sing-box` and `xray` are bundled inside the `.app` — no separate installation needed.

## Install

Download the latest `.zip` from [Releases](../../releases), unzip, and drag `WarpVeil.app` to `/Applications`.

Quit from the app menu or from the menu-bar icon.

## Build from Source

1. Run `./fetch-binaries.sh` once to populate `Binaries/` with arm64 `sing-box` and `xray` binaries (pinned versions, sha256-verified).
2. Open `WarpVeil.xcodeproj` in Xcode and press **Cmd+R**. The "Bundle VPN Binaries" build phase copies them into `WarpVeil.app/Contents/Resources/`.
3. Or skip Xcode: `./install.sh` builds Release, signs it (Developer ID when the keychain has one, ad-hoc otherwise), quits the installed copy, replaces `/Applications/WarpVeil.app` and relaunches it. To call it from anywhere: `ln -sf "$PWD/install.sh" ~/.local/bin/warpveil-install`.

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
├── WarpVeilApp.swift          # Main window, menu-bar status item and its menu
├── AppState.swift             # Owns every service, connect/disconnect, bootstrap
├── ContentView.swift          # Split view and the collapsible icon rail
├── ConnectionView.swift       # Power button, stats, location — the right column
├── ServersView.swift          # Servers grouped by subscription
├── RoutingView.swift          # Domain bypass
├── AdvancedView.swift         # Auto-connect, passwordless, components
├── LogView.swift              # VPN log
├── ProcessManager.swift       # VPN process lifecycle, sudo, log tailing, sleep/wake
├── SubscriptionService.swift  # Subscription fetch, vless/vmess URI parsing
├── SetupService.swift         # Bundled-binary detection & version reporting
├── LocationService.swift      # Public IP & geolocation via ipwho.is (HTTPS)
├── NetworkMonitor.swift       # Real-time upload/download speed
├── PingService.swift          # Proxy delay via sing-box's Clash API
├── BypassService.swift        # Domain bypass config injection
└── Models.swift               # Server, Subscription, Engine types
```

## License

MIT
