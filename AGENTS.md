# AGENTS.md

## Project Overview

WarpVeil — macOS menu bar app for managing VPN connections via sing-box and xray.
Built with Swift 5.10, SwiftUI, targets macOS 14+. Runs entirely in the menu bar (no Dock icon).

## Architecture

```
Sources/
├── WarpVeilApp.swift        # @main entry point, MenuBarExtra, service initialization
├── ContentView.swift        # Root container — segmented picker, tab routing, connect/disconnect
├── DashboardView.swift      # Hero status block, stats row, sparkline, collapsible log
├── RoutingView.swift        # Bypass toggle, domain list, bypass log
├── SetupView.swift          # Dependency detection UI, installation controls
├── SettingsView.swift       # Binary paths, passwordless, config editor with engine picker, quit
├── StatusIndicator.swift    # Reusable pulse animation indicator
├── ProcessManager.swift     # VPN process lifecycle, sudo/passwordless, log tailing, sleep/wake
├── SetupService.swift       # Dependency detection & installation (Homebrew, sing-box, xray)
├── LocationService.swift    # Public IP & geolocation via ip-api.com
├── NetworkMonitor.swift     # Real-time upload/download speed + 60s history ring buffer
└── BypassService.swift      # JSON config injection for domain bypass routing
```

All services use `@Observable`. State is passed down from `WarpVeilApp` via `@State`.
User settings persist via `@AppStorage` (UserDefaults).

## Build & Run

Build exclusively through Xcode:

1. Open `WarpVeil.xcodeproj`
2. Cmd+R to build and run
3. Product → Archive for distribution

Do NOT use `swift build` — the project requires a proper .app bundle with Info.plist.

## Code Style

Write the simplest code that works. Prioritize readability over cleverness.

- Keep functions short and focused — one function does one thing
- Flat is better than nested: use `guard` for early returns instead of deep `if/else`
- No premature abstractions — don't create protocols, generics, or wrappers until there are 3+ concrete uses
- No over-engineering: if a task takes 5 lines, don't write 20
- No unnecessary comments — code should be self-explanatory. Comment only the "why", never the "what"
- No dead code — delete unused functions, variables, imports. Don't comment them out
- Name things clearly: `isConnected` not `flag`, `retryDelay` not `d`
- Avoid force unwraps (`!`) — use `guard let` or `if let`
- Don't add error handling for scenarios that can't happen
- Don't add features or refactor code that wasn't asked for

## Tech Conventions

- Use Swift concurrency (async/await, Task)
- Use `@Observable` macro for reactive state (not ObservableObject/Published)
- Use `@AppStorage` for persistent user settings
- Use `Process` + pipes for shell commands, `osascript` for privilege escalation
- Keep all UI in SwiftUI — no AppKit views
- No external Swift package dependencies — everything is built-in
- Logs are capped (1000 lines in ProcessManager, 2000 in SetupService)

## Key Decisions

- **No sandbox**: the app runs sing-box/xray as child processes with sudo, which requires full system access
- **LSUIElement = true**: menu bar only, no Dock icon, no main window
- **HTTP exception for ip-api.com**: geolocation API only serves HTTP, configured in Info.plist
- **Passwordless mode**: optional sudoers file at `/etc/sudoers.d/warpveil` to avoid password prompts
- **JSON manipulation via JSONSerialization**: bypass config injection needs flexible JSON handling, not Codable
- **Binary detection checks multiple paths**: Homebrew paths differ between Intel (`/usr/local/bin/`) and Apple Silicon (`/opt/homebrew/bin/`)

## Temporary Files at Runtime

- `$TMPDIR/warpveil.log` — VPN process log (tailed in real-time)
- `$TMPDIR/warpveil-run-<pid>.sh` — generated connect script (PID-scoped)
- `$TMPDIR/warpveil-stop-<pid>.sh` — generated stop script (PID-scoped)
- `$TMPDIR/warpveil-xray-<pid>.json` — injected xray config (PID-scoped)
- `$TMPDIR/warpveil-singbox-<pid>.json` — injected sing-box config (PID-scoped)

## Gotchas

- The app needs to handle TUN interface startup delay — location detection retries at 3, 5, 10 seconds after connect
- `which` is unreliable inside .app bundles (no shell profile loaded) — always check hardcoded paths first
- Sleep/wake auto-reconnects after 5 second delay to let the network stabilize
- sing-box and xray have different JSON config formats — BypassService handles both separately
- Config detection (`isSingBoxConfig`) checks for `"type"` vs `"protocol"` keys in outbounds to distinguish formats

## Communication

- Always respond in Russian, but keep internal reasoning in English
- Code, comments, commit messages, and variable names stay in English

## Git Workflow

- Single `main` branch
- Commit messages in English, imperative mood
- Do not commit: `.app` bundles, `.build/`, certificates, `cache.db`, `.env` files
