# AGENTS.md

## Project Overview

WarpVeil — macOS menu bar app for managing VPN connections via sing-box and xray.
Built with Swift 5.10, SwiftUI, targets macOS 14+. Runs entirely in the menu bar (no Dock icon).

## Architecture

```
Sources/
├── WarpVeilApp.swift        # @main entry point, MenuBarExtra, service initialization
├── ContentView.swift        # Root container — segmented picker, tab routing, connect/disconnect
├── ServersView.swift        # Two-column server list with subscription management
├── SettingsView.swift       # Toggles, domain bypass, components info, quit
├── StatusIndicator.swift    # Reusable pulse animation indicator
├── ProcessManager.swift     # VPN process lifecycle, sudo/passwordless, log tailing, sleep/wake
├── SetupService.swift       # Bundled-binary detection & version reporting
├── LocationService.swift    # Public IP & geolocation via ipwho.is (HTTPS)
├── NetworkMonitor.swift     # Real-time upload/download speed + 60s history ring buffer
└── BypassService.swift      # JSON config injection for domain bypass routing
```

Binaries `sing-box` and `xray` ship inside the `.app` at `Contents/Resources/` (universal arm64+x86_64). They are committed to `Binaries/` in the repo and bundled by the Xcode "Bundle VPN Binaries" build phase. Use `./fetch-binaries.sh` to refresh them (pinned versions with SHA-256 verification + `lipo` merge).

All services use `@Observable`. State is passed down from `WarpVeilApp` via `@State`.
User settings persist via `@AppStorage` (UserDefaults).

## Build & Run

Build exclusively through Xcode:

1. Run `./fetch-binaries.sh` once to populate `Binaries/` (universal `sing-box` and `xray`, pinned + checksum-verified).
2. Open `WarpVeil.xcodeproj`.
3. Cmd+R to build and run.
4. `./release.sh` for signed + notarized distribution (`NOTARY_PROFILE` env required for notarization).

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
- **NSAllowsArbitraryLoads**: kept enabled because user-provided subscription URLs may be HTTP; the app's own outbound calls (e.g., `LocationService` → `ipwho.is`) use HTTPS
- **Passwordless mode**: writes a fixed-path runner to `/usr/local/libexec/warpveil/{run.sh,stop.sh}` (root:wheel 0755) and a sudoers entry at `/etc/sudoers.d/warpveil` that whitelists ONLY those exact paths — no wildcards. Migration from older wildcard sudoers is automatic on toggle off+on.
- **PID files**: each engine writes its PID to `/tmp/warpveil-{singbox,xray}.pid` so stop targets only our processes (no `pkill -f` collateral damage)
- **JSON manipulation via JSONSerialization**: bypass config injection needs flexible JSON handling, not Codable
- **Bundled binaries only**: `ProcessManager.findBinary` resolves `sing-box`/`xray` from `Bundle.main.resourcePath` and nothing else; system installs (Homebrew, MacPorts, `$PATH`) are ignored
- **Binary upgrades require an app update**: there is no in-app updater for `sing-box`/`xray`; bump the pinned tags in `fetch-binaries.sh` and ship a new release

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
