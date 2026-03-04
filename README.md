# WarpVeil

Lightweight macOS menu bar app for managing **sing-box** and **xray** VPN connections.

## Features

- **Menu bar widget** — connection status, country flag, live upload/download speed
- **One-click connect/disconnect** with admin privileges
- **Auto-reconnect** after sleep/wake
- **Passwordless mode** — optional sudoers setup to skip password prompts
- **Setup tab** — auto-detect and install dependencies (Homebrew, sing-box, xray)
- **Real-time logs** from sing-box and xray processes
- **IP & location detection** via ip-api.com

## Requirements

- macOS 14+
- Swift 5.10+
- [sing-box](https://github.com/SagerNet/sing-box) and/or [xray](https://github.com/XTLS/Xray-core)

## Build & Run

```bash
swift build
swift run
```

## Configuration

Open the app from the menu bar → **Settings** tab:

1. Set paths to `sing-box` and `xray` binaries (auto-detected if installed via Homebrew)
2. Paste your sing-box and/or xray JSON configs
3. Click **Connect**

Missing dependencies? Go to the **Setup** tab and click **Install Missing**.

## Architecture

| File | Description |
|------|-------------|
| `WarpVeilApp.swift` | App entry point, MenuBarExtra |
| `ContentView.swift` | Tabs: Dashboard, Setup, Settings |
| `ProcessManager.swift` | Process lifecycle, sudo/osascript, wake reconnect |
| `SetupService.swift` | Dependency detection & Homebrew installation |
| `LocationService.swift` | IP/geolocation lookup |
| `NetworkMonitor.swift` | Interface traffic speed monitoring |
