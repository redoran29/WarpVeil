# WarpVeil

Lightweight macOS app for VPN connections: every server runs on **xray**, behind a **sing-box** TUN.

## Features

- **Menu bar status** — connection state and country flag, with connect/disconnect in its menu
- **One-click connect/disconnect** with admin privileges
- **Subscription support** — add via URL (`vless://`, `vmess://`) or an xray JSON config
- **Domain bypass** — route specific domains outside the VPN tunnel
- **Auto-reconnect** after sleep/wake
- **Passwordless mode** — optional sudoers setup to skip password prompts; root runs only its own copy of sing-box, on a config it checked
- **Bundled engines** — `sing-box` and `xray` ship inside the app, no installation required
- **Server ping** — real delay through each proxy, measured by the bundled engines in user space
- **In-app updates** — checks GitHub releases daily and installs only a release signed with the project's key
- **Real-time logs** with copy/clear

## Screenshots

| Servers | Routing | Advanced | Logs |
|---------|---------|----------|------|
| Servers grouped by subscription, with refresh and delete per subscription | Domain bypass | Auto-connect, passwordless, components | VPN log with copy and clear |

The power button, uptime, traffic stats and location sit in the right-hand column on every page.

## Requirements

- macOS 15+, Apple Silicon

`sing-box` and `xray` are bundled inside the `.app` — no separate installation needed.

## Download

[Latest release](https://github.com/redoran29/WarpVeil/releases/latest) → `WarpVeil-<version>-macOS.zip`. Unzip it and drag `WarpVeil.app` to `/Applications`.

The app is not notarized by Apple, so the first launch is blocked with a dialog saying Apple could not verify it. Click **Done**, open **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway** next to the WarpVeil line and enter your password. The button stays for about an hour after the blocked launch; Control-click → Open does not work since macOS 15.

Or from Terminal, with no dialog — a `curl` download carries no quarantine (the release page has the exact URL). Quit WarpVeil first if an older version runs; the command replaces it only once the download succeeded:

```bash
D=$(mktemp -d) && curl -fL -o "$D/WarpVeil.zip" https://github.com/redoran29/WarpVeil/releases/download/v<version>/WarpVeil-<version>-macOS.zip && rm -rf /Applications/WarpVeil.app && ditto -x -k "$D/WarpVeil.zip" /Applications && open /Applications/WarpVeil.app
```

Later releases install themselves: Advanced → Updates in the window, or "Update to …" in the menu-bar menu. Quit from the app menu or from the menu-bar icon.

## Build from Source

1. Run `./fetch-binaries.sh` once to populate `Binaries/` with arm64 `sing-box` and `xray` binaries (pinned versions, sha256-verified).
2. Open `WarpVeil.xcodeproj` in Xcode and press **Cmd+R**. The "Bundle VPN Binaries" build phase copies them into `WarpVeil.app/Contents/Resources/`.
3. Or skip Xcode: `./install.sh` builds Release, signs it (Developer ID when the keychain has one, ad-hoc otherwise), quits the installed copy, replaces `/Applications/WarpVeil.app` and relaunches it. To call it from anywhere: `ln -sf "$PWD/install.sh" ~/.local/bin/warpveil-install`.

> Do not use `swift build` — the project requires a proper `.app` bundle with `Info.plist`.

## Release

Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`, add a `## <version>` section to `CHANGELOG.md`, commit, then:

```bash
./release.sh                                 # ad-hoc signed
NOTARY_PROFILE=NOTARY_PROFILE ./release.sh   # with a Developer ID in the keychain: signed and notarized
```

Before building it refuses uncommitted changes, an existing tag or release, a version that is not newer than the latest tag, a missing changelog section, and a signing key that is missing or does not match `WVUpdatePublicKey` in `Info.plist`. Then it builds Release, signs `xray`/`sing-box` and the `.app`, packages the `.zip`, signs it with the release key (`~/.config/warpveil/release-signing.key`, see `CLAUDE.md`), tags, and creates the GitHub release with the zip, its `.sig` and the changelog section as notes.

One-time notary setup: `xcrun notarytool store-credentials NOTARY_PROFILE --apple-id <id> --team-id <team> --password <app-specific-password>`.

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
├── PingService.swift          # Proxy delay through user-space xray and sing-box's Clash API
├── BypassService.swift        # Bypass rule, TUN IP families, xray server pin, domain input normalization
├── Updater.swift              # In-app updates from GitHub releases, ed25519-verified
└── Models.swift               # Server, Subscription, Engine types
```

## License

MIT
