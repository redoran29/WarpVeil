# WarpVeil

macOS menu bar app for managing VPN connections via sing-box and xray.
Swift 5.10, SwiftUI, macOS 14+, Apple Silicon. Runs entirely in the menu bar (no Dock icon).

This file is the whole canon: workflow, architecture, conventions, decisions. Read it before
changing anything.

---

## Workflow

Every feature and every non-trivial change follows the same three steps. Never go straight
to code.

### 1. Plan

The plan is written by a subagent on the **Fable 5** model, not by the main session:

```
Agent(subagent_type: "general-purpose", model: "fable", prompt: "…")
```

That agent's job is done only when it has:

- read the actual source before proposing anything;
- **validated its own plan inside the same run** — every file, type and symbol it names must
  really exist; every step must leave the project compiling on its own;
- written the finished plan to `plans/<short-kebab-name>.md`.

The main session does not accept a half-plan and does not finish one by hand. If the plan
comes back thin or wrong, send the agent back with what is missing.

### 2. Implement

Follow the plan. When reality contradicts it, correct the plan file in the same commit as the
deviation — the file must never describe something that was not built.

### 3. Close

- Move the plan to `plans/done/` once every step is implemented.
- Then run `/code-review` over the finished work and fix everything it surfaces.
  Work on a plan is not over while review findings are open.

---

## Architecture

```
Sources/
├── WarpVeilApp.swift          # @main + AppDelegate: NSStatusItem, NSPopover, service ownership
├── ContentView.swift          # Tab bar (Servers / Settings), connect/disconnect, location polling
├── ServersView.swift          # Power button, stats, server list with ping, log overlay, add sheet
├── SettingsView.swift         # Toggles, domain bypass, components info
├── ProcessManager.swift       # VPN process lifecycle, sudo/passwordless, log tailing, sleep/wake
├── SubscriptionService.swift  # Subscription fetch, vless:// and vmess:// parsing, config building
├── SetupService.swift         # Bundled-binary detection & version reporting
├── LocationService.swift      # Public IP & geolocation via ipwho.is (HTTPS)
├── NetworkMonitor.swift       # Real-time upload/download speed
├── BypassService.swift        # JSON config injection for domain bypass routing
└── Models.swift               # Server, Subscription, Engine types
```

All services use `@Observable`. They are created in `AppDelegate` and passed down through
`ContentView`. User settings persist via `@AppStorage` (UserDefaults).

`sing-box` and `xray` ship inside the `.app` at `Contents/Resources/` (arm64). They are
committed to `Binaries/` and copied in by the Xcode "Bundle VPN Binaries" build phase.
`./fetch-binaries.sh` refreshes them — pinned tags, SHA-256 verified.

**Two connection topologies.** A sing-box server runs as a single process. An xray server
(needed for `xhttp`/`splithttp`, which sing-box does not implement) runs as a SOCKS proxy on
port 10808 with a sing-box TUN wrapper in front of it; all routing decisions then live in that
wrapper, because it is the only sing-box in the topology.

---

## Build & Run

Build through Xcode, or through `./dev-run.sh` — never `swift build`, the app needs a real
bundle with `Info.plist`.

1. `./fetch-binaries.sh` once, to populate `Binaries/`.
2. `WarpVeil.xcodeproj` → Cmd+R.
3. `./release.sh` for a signed + notarized build (`NOTARY_PROFILE` required for notarization).

### dev-run.sh

Builds and runs a dev copy that coexists with an installed or Xcode-launched build:

```bash
./dev-run.sh          # build and launch
./dev-run.sh --watch  # rebuild and relaunch on every source change; Ctrl+C stops the copy
./dev-run.sh --stop   # stop the copy and its VPN engines
```

Isolation comes from overriding the bundle id (separate `UserDefaults` domain) and suffixing
the version (`ProcessManager` derives its sudoers, libexec, PID and log paths from
`CFBundleShortVersionString`). Not isolated: `~/.config/warpveil/subscriptions.json`, and the
TUN interface — only one build can hold a tunnel at a time.

`--watch` is a rebuild-and-relaunch loop, not hot reload: in-memory state resets on every
change, `@AppStorage` survives.

---

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

- Swift concurrency (async/await, Task)
- `@Observable` for reactive state, not ObservableObject/Published
- `@AppStorage` for persistent user settings
- `Process` + pipes for shell commands, `osascript` for privilege escalation
- All UI in SwiftUI — no AppKit views
- No external Swift package dependencies
- `ProcessManager.logs` is trimmed to the last 500 entries once it passes 600

---

## Key Decisions

- **No sandbox**: the app runs sing-box/xray as child processes under sudo, which needs full system access
- **LSUIElement = true**: menu bar only, no Dock icon, no main window
- **Apple Silicon only**: `ARCHS = arm64`, and `fetch-binaries.sh` pulls arm64 assets. Intel support, if ever needed, is a separate piece of work
- **NSAllowsArbitraryLoads**: user-provided subscription URLs may be HTTP; the app's own calls (`LocationService` → `ipwho.is`) use HTTPS
- **Version-tagged privileged paths**: sudoers, libexec, PID files and the log all carry the app version (`1.2` → `warpveil-1-2`), because `.` is illegal in a `/etc/sudoers.d/` filename. Side effect: every version bump re-asks for the password once
- **Passwordless mode**: installs `run.sh`/`stop.sh` into `/usr/local/libexec/warpveil-<tag>/` (root:wheel 0755) and a sudoers entry whitelisting those two exact paths — no wildcards
- **PID files**: each engine writes its PID so stop targets only our processes. `run.sh` still starts with `pkill -f 'sing-box run'`, so starting a tunnel does kill any other one on the machine
- **JSONSerialization, not Codable**: bypass injection rewrites arbitrary user configs and needs untyped JSON
- **Bundled binaries only**: `ProcessManager.findBinary` resolves engines from `Bundle.main.resourcePath` and nowhere else — Homebrew, MacPorts and `$PATH` are ignored
- **Binary upgrades ship with the app**: no in-app updater; bump the pinned tags in `fetch-binaries.sh` and cut a release

## Runtime Files

`<tag>` is the app version with dots replaced by dashes.

- `$TMPDIR/warpveil-<tag>.log` — VPN process log, tailed by a 0.25s polling timer
- `$TMPDIR/warpveil-singbox-<pid>.json` — injected sing-box config
- `$TMPDIR/warpveil-xray-<pid>.json` — injected xray config
- `/tmp/warpveil-<tag>-{singbox,xray}.pid` — engine PIDs
- `~/.config/warpveil/subscriptions.json` — subscriptions, shared across all builds

## Gotchas

- TUN comes up with a delay — location detection retries at 3, 5 and 10 seconds after connect
- `which` is unreliable inside `.app` bundles (no shell profile) — resolve paths explicitly
- Sleep/wake reconnects after a 5 second delay to let the network settle
- sing-box and xray have different config formats — `BypassService` handles each separately
- The bootstrap (`loc.detect`, `setup.checkAll`, `subs.refreshAll`, autoConnect) hangs off
  `ContentView.task`, so it does not run until the popover is opened for the first time

---

## Communication

- Always respond in Russian, but keep internal reasoning in English
- Code, comments, commit messages, plan files and variable names stay in English

## Git Workflow

- Single `main` branch
- Commit messages in English, imperative mood
- Atomic commits — one logical change each, never bundle unrelated work
- Every commit must leave the project compiling
- Do not commit: `.app` bundles, build output, certificates, `.env` files
