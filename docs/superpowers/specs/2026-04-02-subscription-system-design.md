# Subscription System & UI Redesign

## Overview

Replace manual config editing with subscription-based server management. Users add a 3x-ui subscription URL, the app fetches available servers, and the user picks one to connect. Manual JSON configs remain as an alternative subscription type.

## Data Model

### Subscription (group)

```
id: UUID
name: String              — user-given name ("My VPN", "Work")
type: .url | .manual
url: String?              — for type == .url
servers: [Server]
lastUpdated: Date?
engine: .singBox | .xray  — which format to request/parse
```

### Server (within a subscription)

```
id: UUID
name: String              — from outbound tag or config remark
protocol: String          — "vless", "vmess", "trojan", etc.
address: String           — "host:port" for display
config: String            — standalone JSON config for this single server
latency: Int?             — ping result in ms (optional, for future use)
```

### Storage

- `~/.config/warpveil/subscriptions.json` — array of Subscription, Codable
- `@AppStorage("selectedServerID")` — UUID string of the currently selected server
- `@AppStorage` remains for lightweight settings (binary paths, bypass domains, etc.)

## SubscriptionService

`@Observable` class responsible for:

1. **Fetch** — downloads URL with `?format=singbox` or `?format=xray` query parameter
2. **Parse** — extracts individual servers from the full config JSON:
   - sing-box: filter `outbounds` by VPN types (`vless`, `vmess`, `trojan`, `shadowsocks`, `hysteria2`, etc.), skip service types (`direct`, `block`, `dns`)
   - For each VPN outbound: name = `tag`, protocol = `type`, address = `server:server_port`
   - Each server's standalone config = full JSON with only that VPN outbound + service outbounds kept
   - xray: same logic but keys differ: `protocol` instead of `type`, `settings.vnext[0].address` or `settings.servers[0].address` for host
3. **Save/Load** — read/write `subscriptions.json` via Codable
4. **Add manual** — creates `.manual` subscription, parses pasted JSON using same logic
5. **Auto-update** — on app launch, refreshes all URL subscriptions in background

## UI Architecture

### Two tabs: Servers | Settings

Replace current 4-tab layout (Dashboard, Routing, Setup, Settings) with 2 tabs.

### Tab 1: Servers (main screen)

Two-column layout, popup window ~600×500:

**Left column (~220px):**
- "+" button at top — add subscription popup:
  - Text field for URL + name field
  - Toggle to switch to "Manual JSON" mode (shows TextEditor instead of URL field)
  - Engine picker (sing-box / xray)
- Collapsible groups (one per subscription):
  - Group header: name + ↻ refresh button + "..." menu (delete, rename)
  - Server rows: name, protocol as subtitle, selected server highlighted with accent color
- Click server to select it

**Right column:**
- Large circular connect button (power icon), gray → green when connected
- Status text: "Disconnected" / "Connected" + uptime timer
- IP and geolocation
- Speed stats (Download / Upload)
- Sparkline traffic graph
- Compact log view (last ~10 lines, scrollable)

### Tab 2: Settings

Combines current Settings + Routing + Setup:
- Binary Paths section (sing-box, xray paths)
- Passwordless Mode toggle
- Bypass Routing — toggle + domain list (from current RoutingView)
- Dependencies — status + install buttons (from current SetupView)
- Quit button

## Connection Flow

1. User selects server in left column
2. Clicks connect button
3. App takes `server.config` (standalone JSON for selected server)
4. Determines engine from subscription's `engine` field
5. Passes to `ProcessManager.connect()` with simplified signature: `config: String, engine: Engine, bypassDomains: [String]`
6. BypassService injects bypass rules as before
7. ProcessManager writes temp config file and launches process

## sing-box Config Parsing Detail

When fetching `?format=singbox` from 3x-ui:

1. Parse JSON, find `outbounds` array
2. Classify each outbound:
   - VPN types: `vless`, `vmess`, `trojan`, `shadowsocks`, `shadowtls`, `hysteria`, `hysteria2`, `tuic`, `wireguard`
   - Service types: `direct`, `block`, `dns`, `selector`, `urltest`
3. For each VPN outbound, create a Server:
   - `name` = outbound `tag`
   - `protocol` = outbound `type`
   - `address` = `server` + ":" + `server_port`
   - `config` = copy of full JSON, but `outbounds` array contains only this VPN outbound + all service outbounds. Everything else (inbounds, route, dns, log, experimental) stays unchanged.

## xray Config Parsing Detail

1. Parse JSON, find `outbounds` array
2. VPN types by `protocol` field: `vless`, `vmess`, `trojan`, `shadowsocks`
3. Service types: `freedom`, `blackhole`, `dns`
4. For each VPN outbound:
   - `name` = `tag`
   - `protocol` = `protocol` field
   - `address` = `settings.vnext[0].address` + ":" + `settings.vnext[0].port` (or `settings.servers[0]` for shadowsocks/trojan)
   - `config` = same approach as sing-box — keep one VPN outbound + service outbounds

## File Changes

### New files
- `Sources/Models.swift` — Subscription, Server, Engine enum
- `Sources/SubscriptionService.swift` — fetch, parse, save/load
- `Sources/ServersView.swift` — main two-column screen

### Modified files
- `ContentView.swift` — 2 tabs, passes SubscriptionService, wider window
- `SettingsView.swift` — absorbs Routing and Setup sections
- `ProcessManager.swift` — simplified connect() signature: `config: String, engine: Engine, bypassDomains: [String]`
- `WarpVeilApp.swift` — init SubscriptionService, window size ~600×500

### Removed/replaced
- `DashboardView.swift` → replaced by ServersView.swift
- `RoutingView.swift` → content moves into SettingsView.swift

### Unchanged
- `BypassService.swift`
- `LocationService.swift`
- `NetworkMonitor.swift`
- `StatusIndicator.swift`
- `SetupService.swift`
