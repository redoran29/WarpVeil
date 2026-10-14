# Privileged helper hardening: root runs only its own copy of sing-box, on a config it checked

Status: done — built in `4c275f5`, `fb4bfb8`, `6bb3017`, verified live on 2026-10-14 (see "Live
results"). Written against `2dd58cc`, macOS 27.0.1 (Darwin 27.0.0), Xcode 27.0, bundled
sing-box 1.14.0 and Xray 26.3.27, deployment target 14.0, `CFBundleShortVersionString` = `1.2`,
sudo 1.9.17p2, `/usr/bin/jq` 1.7.1-apple, `/bin/bash` 3.2.57.

## Owner's ask

Close the hole in passwordless mode. `run.sh` is whitelisted in sudoers with `NOPASSWD` and takes
the engine binaries and their configs as arguments, checking only that each path is absolute, a
regular file and not a symlink — so `sudo -n /usr/local/libexec/warpveil-1-2/run.sh /path/to/anything
/any/file` is root for any process running as the user. The owner's first idea, "allow only bundle
binaries", is not enough on its own and the brief lists what else has to be covered: the bundle is
the user's (so a pinned path still runs whatever was swapped in), the config is attacker-controlled
and a root sing-box reads and writes files on its say-so, xray needs no root at all, the
non-passwordless path runs the same binaries as root, the staleness check must cover whatever new
root state is introduced, and older tags' installs keep the hole alive.

Reading the machine found two more live holes, both older than this plan:

- `/etc/sudoers.d/vpnswift` (dated 2026-03-04 21:54, eight minutes before the first commit) still
  grants `(ALL) NOPASSWD: /bin/bash /private/tmp/vpnswift-run.sh` and `…/vpnswift-stop.sh`
  (`sudo -n -l`, read-only). Neither script exists, `/private/tmp` is world-writable: **any local
  process can create that file and run it as root, today.** `installPasswordless` purges only
  `warpveil` and `warpveil-1-0`.
- macOS's sudoers has `env_reset` but **no `secure_path`** (`sudo -n -l` shows the Defaults), so the
  caller's `PATH` reaches `run.sh` and `stop.sh` as root, and both resolve `ps`, `cat`, `seq`,
  `sleep`, `rm` through it. A `PATH` entry with a `ps` in it is root as well, even with the argument
  checks.

Out of scope and untouched: `PingService` (user-space engines, no root), `SubscriptionService`'s
builders, `BypassService`, the `.xray` branch of `connect`'s `switch` and `buildTunWrapperConfig`
(the hostname plan rewrites them), `project.pbxproj`, `fetch-binaries.sh`, `release.sh`.

## Verified facts

Checked in this run on this machine, not recalled. Line numbers are against `2dd58cc`.

### Code

- `Sources/ProcessManager.swift:30-38` the libexec, sudoers and PID-file paths carry
  `versionTag`; `:46-62` `killPidFileFunction` (shared by `run.sh`, `stop.sh` and both osascript
  commands) kills only a PID whose `ps -o comm=` ends in the engine name; `:66-138` `runShContent`
  takes `<singbox> <singbox_cfg> [<xray> <xray_cfg>]`, `validate_arg` (`:70-76`) checks absolute /
  exists / regular / not a symlink, then — **before** anything is validated beyond that —
  `kill_pid_file`s the running engines (`:89-90`) and starts whatever paths it was given;
  `:141-146` `stopShContent`; `:168-172` `passwordlessInstalled()` compares the two installed
  scripts byte-for-byte with what this build would install; `:174-244` `installPasswordless()`
  purges `warpveil` and `warpveil-1-0` by hand and installs scripts + sudoers through one
  `osascript … with administrator privileges`; `:246-271` `removePasswordless()` removes only its
  own three files; `:280-283` `init` logs the stale-install line; `:371-487` `connect` writes the
  configs 0600 into `$TMPDIR`, then `sudo run.sh …` (`:450-460`, output to
  `FileHandle(forWritingAtPath:)` — no `O_APPEND`) or the osascript command (`:461-465`);
  `:469-477` the termination handler reports only for `p === self.helperProcess`; `:492-532`
  `buildNonPrivilegedShellCommand` duplicates `run.sh` inline with `exec > log` and runs the
  bundle binaries as root; `:651-657` `tearDownEngines`; `:671-699` `killVPNProcesses` (`stop.sh`
  or the inline kill); `:738-742` `findBinary` resolves from `Bundle.main.resourcePath` only.
- `Sources/ProcessManager.swift:567-631` `buildTunWrapperConfig`: the wrapper routes the server
  `direct` by `ip_cidr` (`:576-581`) — the rule never looks at the dialing process or uid, so xray's
  dial is routed the same whoever owns xray. `plans/xray-hostname-server.md` saw the live sockets:
  xray's connections to the server have local address `172.19.0.1` (the TUN) and sing-box holds a
  matching one from `192.168.1.86` — the dial enters the TUN and is re-dialed direct.
- `Sources/AppState.swift:85-101` `connect()` passes `binaryPath: findBinary(engine.rawValue)` and
  `singBoxPath: findBinary("sing-box") ?? ""`; `:72-83` `bootstrap` runs auto-connect after
  `refreshAll`. `Sources/WarpVeilApp.swift:88-98` the quit path waits `awaitTeardown(timeout: 30)`.
- `Sources/SubscriptionService.swift:650-680` `parseSingBox` keeps **every top-level key of the
  feed's config** and replaces only `outbounds`; `:739-762` `addManualConfig` stores pasted JSON
  whole. So a `?format=singbox` feed or a paste can carry `log.output`, `experimental`, `services`,
  `certificate`, anything — a hostile *subscription* is a remote path to the same root primitives.
  `:492-528` `buildSingBoxConfigFromOutbound` and `:567-631` the wrapper use only `log`, `inbounds`,
  `outbounds`, `route`, `dns`; `:532-637` `buildXrayConfig` is never run by root after this plan.
- `install.sh:43-45, 54-68, 70-105`: the sweep reads the installed tag's two root PID files and
  `sudo stop.sh`s / `sudo kill`s what they name; `dev-run.sh:34-35, 43-97` the same for the dev tag.
- `project.pbxproj:136` the "Bundle VPN Binaries" phase `cp`s `Binaries/{xray,sing-box}` into
  `Contents/Resources`. `install.sh:135-153` and `release.sh:82-101` **re-sign** the bundled engines
  (ad-hoc here: no Developer ID identity in the keychain; the installed app's signature is
  `adhoc`). A re-sign changes the file's bytes, so a hash recorded by `fetch-binaries.sh` or the
  build phase would not describe what the bundle carries.
- Git: `a40843b` (first commit, 2026-03-04 22:02) had `sudoersFile = "/etc/sudoers.d/vpnswift"`
  with `NOPASSWD: /bin/bash /private/tmp/vpnswift-run.sh`; `7f46133` renamed it. The file on disk
  predates the first commit by eight minutes — it is this app's.

### Engine (bundled sing-box 1.14.0, probed in user space, no TUN)

- **Field names are matched case-insensitively with Unicode simple folding.** `{"log":{"OUTPUT":
  "<path>"}}` passes `sing-box check` and `sing-box run` **writes the file**; `{"log":{"timeſtamp":
  true}}` (U+017F) and `cache_file.store_fa\u212Aeip` (Kelvin sign) pass `check`; a genuinely
  unknown key (`log.bogus`) fails with `json: unknown field`. So a policy has to compare lowercased
  keys and refuse non-ASCII keys outright.
- These pass `check` and are root primitives: `log.output` (file write); `experimental.clash_api.
  external_ui` (serve a directory over HTTP) and `external_ui_download_url` (download + extract
  into it); `experimental.cache_file.path` (bbolt file); `outbounds[].type: tor` with
  `executable_path` (**runs a program**); `endpoints[].type: tailscale` with `state_directory`;
  `ntp.write_to_system` (sets the clock); `dns.servers[].type: hosts` with `path`; `tls.acme`
  (deprecated, writes `data_directory`); `inbounds[].tls.certificate_path`/`key_path`,
  `ech.config_path`. These read a file *at check time* and fail on a non-PEM/non-rule-set file:
  `certificate.certificate_path` (`invalid certificate PEM file: /etc/hosts`), `route.rule_set[]`
  of `type: local` (`parse rule-set[0]: invalid character`), `outbounds[].type: ssh` with
  `private_key_path` (`open /var/root/.ssh/id_ed25519: permission denied` — as the user).
  `services[].type: ssm-api` with `cache_path` crashes `check` with a nil-pointer panic.
- The legacy `wireguard` outbound is gone (`outbounds[0].server: unknown field`) — WireGuard is an
  `endpoints` entry now, so `endpoints` must stay allowed. `route.geoip`/`geosite` still parse but
  a rule using them fails (`removed in sing-box 1.12.0`); denied anyway. A `remote` rule-set
  without `cache_file` passes `check`. `process_path`/`process_path_regex` rules pass. A DoH
  server's `path` passes. A config file with no extension is accepted by `-c`.
- Docs (context7, sing-box testing branch): the file/directory keys are `log.output`,
  `clash_api.external_ui`, `cache_file.path`, `certificate.{certificate_path,
  certificate_directory_path}`, `services.derp.{config_path, mesh_psk_file}`,
  `services.ssm-api.cache_path`, `tor.{executable_path, data_directory}`,
  `tailscale.{state_directory, taildrop_directory}`, TLS `{certificate_path, key_path,
  client_certificate_path, client_key_path}`, `ech.{key_path, config_path}`,
  `acme.data_directory`, `ssh.private_key_path`, `hosts.path`, local rule-set `path`; remote
  rule-set `download_detour` is deprecated for `http_client` in 1.14.

### Machine and tooling

- `sudo -n -l` (lists, runs nothing): Defaults `env_reset` plus `env_keep` for locale/HOME/MAIL and
  friends, **no `secure_path`**; entries `(ALL) ALL`, the two `vpnswift` lines above, and
  `(root) NOPASSWD: /usr/local/libexec/warpveil-1-2/{run,stop}.sh`. `/etc/sudoers.d/` holds
  `vpnswift` (Mar 4) and `warpveil-1-2` (Sep 15); `/usr/local/libexec/` holds only `warpveil-1-2`.
- `/usr/bin/jq` is `jq-1.7.1-apple`; it came with macOS 15 (HN thread on the Sequoia release:
  "you can now find jq in /usr/bin/ in Sequoia" — community source, no Apple note found).
  `/bin/sh` → `/bin/bash` 3.2.57 (`/private/var/select/sh`), so `[[ ]]`, `local`, `$(…)` work
  inside `do shell script` — the current inline command already relies on it. `/var/run` is
  `root:daemon 775`. `/usr/bin/python3` is the CLT shim, not guaranteed; `plutil` sees keys only
  flat (no parent `type`), which cannot tell a transport `path` from a hosts-file `path`.
- SHA-256 of the bundled sing-box (83 MB) with CryptoKit, `.mappedIfSafe`: 146 ms cold (after
  `purge`), 27 ms warm. `proc_pidpath` is reachable from Swift through `Darwin`. Two children
  writing through one `FileHandle` opened `O_WRONLY|O_APPEND` interleave line by line; two
  descriptors opened without `O_APPEND` would overwrite each other. `Process.terminate()` on a
  process that already exited raises nothing. `kill(pid, 0)` on a reaped pid → `ESRCH`.
- The project builds clean under Xcode 27.0 into a scratch derived-data dir (baseline), and after
  each step below, in a private scratch copy — see "Validation of this plan".

## Design

### D1. Root runs only its own copy of sing-box — no binary argument at all

`run.sh` loses its binary arguments: it takes one path, the sing-box config, and executes
`/usr/local/libexec/warpveil-<tag>/sing-box`, a root-owned 0755 copy that `installPasswordless`
makes from the bundle in the same admin command that installs the scripts — the one moment the
user has typed the password. The `.app` is the user's, so pinning the bundle path would run
whatever the attacker put there; the libexec copy is in a root 755 directory the user cannot
touch. Chosen over "SHA-256 pins baked into run.sh with copy-then-verify-then-exec" because that
copies and hashes 83 MB on every connect, and the pins would have to be regenerated after every
re-sign of the engine (see the next decision), making `runShContent` depend on the bundle's bytes.

### D2. Staleness is a hash compared at launch, not a manifest shipped in the bundle

Root writes `shasum -a 256 sing-box > sing-box.sha256` next to its copy at install time.
`passwordlessInstalled()` keeps the byte-for-byte script comparison and adds: the manifest exists
and starts with the CryptoKit SHA-256 of the bundled binary. So a `fetch-binaries.sh` bump reads
as stale (toggle again, one prompt), as the brief asks. A manifest produced by `fetch-binaries.sh`
or the build phase was rejected: `install.sh`/`release.sh` re-sign the bundled engines, which
changes their bytes, so such a manifest would need regenerating in three places and a missed one
would make passwordless impossible to enable. Cost: 27 ms warm / 146 ms cold once at launch, only
when the cheap checks already pass (no passwordless → no hash), in `ProcessManager.init` on the
main thread before the window appears.

### D3. The config is copied into a root-owned 0700 directory, then checked by `jq`, before any engine is touched

`stage_config` copies the app's file into `/var/run/warpveil-<tag>/` (root, 0700, created by
root, re-checked with `stat -f %u` and `! -L`), `mktemp`-named, 0600; the engine runs **that
copy**, so what passed the check is what runs — swapping the app's file after the check changes
nothing (TOCTOU closed). `check_config` runs the policy on the copy and exits before
`kill_pid_file`: a refused connect leaves the running tunnel up (the brief's requirement; the
current `run.sh` kills first). A refused copy is removed; an accepted one is removed by the
`cleanup` trap. `PATH` is pinned to `/usr/bin:/bin:/usr/sbin:/sbin` at the top of every root
shell (run.sh, stop.sh, both osascript commands) and `jq` is called as `/usr/bin/jq`.

The policy (`ProcessManager.configPolicy`, a jq program; run over the parsed document, so it
sees what sing-box's decoder sees, last duplicate key wins in both):

- the root must be an object; top-level keys ⊆ {`log`, `dns`, `ntp`, `inbounds`, `outbounds`,
  `endpoints`, `route`, `experimental`} — `services` and `certificate` are out whole;
- any key, at any depth, containing a non-ASCII character is refused (Unicode folding, above);
- any key, lowercased, matching `(_path|_directory|_file)$` except `process_path`, or starting
  with `output`, `external_ui`, `cache_file`, `acme`, `write_to_system`, `download_url`, `geoip`,
  `geosite` is refused — this covers every file/directory key in the docs list above, including
  ones no probe exercised (`client_key_path`, `taildrop_directory`, `mesh_psk_file`);
- a `path` key is refused when its object's `type` (lowercased) is `local` or `hosts`; a transport
  `path` (`ws`, `httpupgrade`, `splithttp`) and a DoH `path` stay allowed;
- `type` `tor` or `tailscale` (lowercased) is refused.

It prints `ok` or one line per finding; the shell requires exactly `ok`, so an empty file or two
concatenated documents are refused too. Why a denylist with a top-level allowlist and not a full
allowlist: the app's own configs use ~40 keys, but a `?format=singbox` feed legitimately uses
dozens more (`utls`, `reality`, `transport.headers`, `rule_set`, `clash_mode` …) and the set moves
with every sing-box release — an allowlist would break feeds on each bump, while the set of
*file-touching* keys is small, named in the docs, and now has a shape (`_path`, `_directory`,
`_file`) the regex covers forward. The fragility is real and is recorded in the canon: a new
sing-box version is reviewed for new file keys when the pin moves. What the app's generated
configs contain was checked against the policy: the server shape with bypass and IPv6 injected, the
wrapper, and the parity plan's additions (`experimental.clash_api.external_controller` + `secret`
+ `default_mode`, `route_exclude_address`, `dns.servers[].type: local`, a DoH server with `path`,
a `remote` and an `inline` rule-set, `process_path`/`process_path_regex`/`process_name` rules, a
`wireguard` endpoint, `ntp` without `write_to_system`) — all `ok`.

Why `jq` and not something on macOS 14: it is the only stock tool that sees structure (plutil
flattens, python3 is a shim), and the policy needs the parent's `type` to tell one `path` from
another. On a macOS 14 host `check_config` refuses with `/usr/bin/jq not found: macOS 15 or newer
is required` — connecting then fails in both modes. **Owner's call** whether to raise
`LSMinimumSystemVersion` to 15 to match; this plan leaves it at 14 and records the floor in the
canon. The alternative that keeps 14 is a JavaScript validator under `osascript -l JavaScript`
(JavaScriptCore has `JSON.parse`); it is ~40 lines of JS inside a bash string inside a Swift
string and was not built.

### D4. xray runs as the user, started by the app

xray is a SOCKS proxy on `127.0.0.1:10808`; its dial to the server enters the TUN and the
wrapper routes it direct by `ip_cidr`, a rule that never looks at the uid (facts above). So it
needs no root, and running it as the user removes the need for an xray policy entirely (`log.access`,
`log.error`, `masterKeyLog`, `certificateFile`, `dsSettings`, a unix-socket `listen`, `api`,
`metrics` … — a second denylist to keep in step with Xray releases). `ProcessManager.startXray`
runs it as a `Process` from the bundle, writes its PID to `$TMPDIR/warpveil-<tag>-xray.pid`, and
`killOrphanedXray` at the next connect kills an xray a crashed app left holding the port — only a
live PID whose `proc_pidpath` ends in `/xray`, then up to 5 s for it to exit, mirroring
`kill_pid_file`. `tearDownEngines` terminates it; the helper's termination handler terminates it
too, since it no longer dies with `run.sh`. The log file is opened once per connect with
`O_WRONLY|O_APPEND` and the one `FileHandle` is given to xray and to `sudo run.sh`; the osascript
command uses `exec >>` — three writers, one file offset, no overwrites.

Rejected: `sudo -u "$SUDO_USER" xray` inside `run.sh` — sudo stays the parent, `$!` names sudo and
`ps -o comm=` says `sudo`, so the PID file would never match the engine; `su -c` forks the same
way on macOS. Kept: the user-space PID file is in `$TMPDIR`, not `/tmp` — the root-owned
`/tmp/warpveil-1-2-xray.pid` from today's build would block the write (EACCES) and `/tmp` is
world-writable. `install.sh` and `dev-run.sh` sweep the user xray by that file without sudo; the
root xray file of a build older than this plan is no longer swept (its quit path still takes it
down; the live check looks for a leftover once).

### D5. The non-passwordless path gets the same staging, policy and PATH

`buildNonPrivilegedShellCommand` becomes `exec >> log` + the same `engineShell` body with the
bundled sing-box as the binary. The config policy there blocks the *remote* attacker — a hostile
subscription — in both modes for the price of sharing the string; the password dialog is the
user's consent for the *local* threat, which a swapped bundle binary rides either way. Keeping the
bundle binary there is the only divergence from the passwordless path, and it is forced: there is
no root-owned copy without an install.

### D6. Enabling or disabling passwordless in any build removes every other build's install

`installPasswordless` and `removePasswordless` both run `rm -f /etc/sudoers.d/warpveil*
/etc/sudoers.d/vpnswift && rm -rf /usr/local/libexec/warpveil*` first. An older tag's `run.sh`
with the hole is root for as long as its sudoers line exists, and `vpnswift` is root today. The
cost to the documented dev-run.sh coexistence: enabling passwordless in the 1.2 build turns the
`1-2-dev` build's install off — that copy's running engines are unaffected (sudoers is consulted at
`sudo` time, its `run.sh` trap still stops them on terminate), its next `sudo` fails with
`[Disconnected (exit 1)]`, its toggle shows on until it reconciles, and flipping it on again is one
prompt. Both builds holding passwordless at once was never the point of the isolation (PID, log
and defaults are). Recorded in the canon's dev-run.sh section.

### D7. What is argued away

- **A hostile `--kill-switch` ruleset file** (parity plan item 3) is a root primitive of the same
  kind (`pfctl -f` reads files; `load anchor from` loads more). That item cannot pass a file to
  `run.sh`; see "Rebasing the queued plans".
- **A FIFO swapped in for the config** between `validate` and `cp` blocks the root `cp` until a
  writer appears — a DoS of that connect only (the app's terminate kills the shell). Not addressed.
- **Reading root-only files through the copy**: a symlink swapped in after the `-L` check makes
  `cp` copy its target into the root 0700 directory; it is then refused (not JSON, or not this
  policy) and never echoed — jq's parse errors carry line/column only, and the one path that
  echoes a value (`keys` on a non-object) is cut off by the `type != "object"` branch.
- **`clash_api.external_controller` without a `secret`**: allowed by the policy; the parity plan
  sets one. A policy rule for it was not added — it is not a file or exec primitive.
- **`route.geoip`/`geosite`** are denied though 1.14 ignores them without a rule: the key shape is
  a download target and costs nothing to refuse.

## Steps

Each step compiles on its own and is one commit. Steps 1 and 2 were applied in that order to a
private scratch copy of the repo and built with `xcodebuild` after each — see "Validation of this
plan". Step 1 leaves the hole open for sing-box (one engine instead of two); step 2 closes it.
The owner's installed passwordless reads as stale after either step is deployed.

### 1. xray runs as the user

Commit: `Run xray as the user and let the app own its lifetime`.

`Sources/ProcessManager.swift`:

- `:12` after `helperProcess`: `private var xrayProcess: Process?`.
- `:36-38` the PID-file block becomes:

```swift
    // PID files: run.sh and stop.sh kill exactly our sing-box, nothing else on the machine. xray
    // runs as the user, so its file is the app's own, in $TMPDIR — the next connect and the
    // sweeps in install.sh and dev-run.sh read it.
    private static let singboxPidFile = "/tmp/warpveil-\(versionTag)-singbox.pid"
    private static let xrayPidFile = FileManager.default.temporaryDirectory.path + "/warpveil-\(versionTag)-xray.pid"
```

- `runShContent` (`:64-138`) loses the 4-argument branch: `argv: run.sh <singbox_path>
  <singbox_config>`, `[[ $# -ne 2 ]]` usage check, one `kill_pid_file … sing-box`, the single-engine
  start and `cleanup` that the `else` branch has today (unindented). `stopShContent` (`:141-146`)
  loses its xray line. The inline stop in `killVPNProcesses` (`:684-688`) loses its xray line.
- `connect`, the stop wait (`:381-395`): the condition covers an xray still exiting — it holds the
  port the next one needs:

```swift
        let exiting = [teardownProcess, xrayProcess].compactMap { $0 }.filter(\.isRunning)
        if !exiting.isEmpty {
            logs.append("[Waiting for the previous engines to stop...]")
            reconnectTask = Task {
                while exiting.contains(where: \.isRunning), !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
```

- `connect`, from the `[Connecting…]` line (`:442`) to the osascript branch (`:465`) becomes:

```swift
        logs.append(isPasswordless ? "[Connecting...]" : "[Connecting (password prompt)...]")

        // 0600: other local users shouldn't read VPN logs. One append-mode handle for everything
        // that writes it — xray, the helper and its sing-box share one file offset, so their
        // lines interleave instead of overwriting each other.
        FileManager.default.createFile(atPath: logFile, contents: nil, attributes: [.posixPermissions: 0o600])
        let logDescriptor = open(logFile, O_WRONLY | O_APPEND)
        guard logDescriptor >= 0 else {
            logs.append("[Error: cannot open the log file]")
            return
        }
        let engineLog = FileHandle(fileDescriptor: logDescriptor, closeOnDealloc: true)

        startLogTail()

        if engine == .xray, !startXray(binaryPath: binaryPath, configFile: configFile, log: engineLog) {
            stopLogTail()
            return
        }

        let singBox = engine == .xray ? singBoxPath : binaryPath
        let process = Process()
        if isPasswordless {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = [Self.runScriptPath, singBox, singboxConfigFile]
            process.standardOutput = engineLog
            process.standardError = engineLog
        } else {
            let cmd = buildNonPrivilegedShellCommand(singBoxPath: singBox, configFile: singboxConfigFile)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \(Self.appleScriptEscape(cmd)) with administrator privileges"]
        }
```

  (`AppState.connect` always passes both bundle paths, so the `findBinary` re-resolution the two
  branches did is gone.) The termination handler and the `do { try process.run() … }` are unchanged
  in this step (step 2 touches them).
- `buildNonPrivilegedShellCommand(engine:binaryPath:singBoxPath:configFile:)` (`:492-532`) →
  `buildNonPrivilegedShellCommand(singBoxPath:configFile:)`: the `else` branch only, with
  `exec >> …` instead of `exec > …` (xray is already writing the file).
- After it, two new functions:

```swift
    // xray is a SOCKS proxy on loopback and needs no root: it runs as the user, from the bundle.
    // Its dial to the server enters the TUN like any other connection, and the wrapper routes it
    // direct by address — that rule never looks at who dialed. The PID file is the handle on an
    // xray a crashed app left holding the port.
    private func startXray(binaryPath: String, configFile: String, log: FileHandle) -> Bool {
        killOrphanedXray()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["run", "-config", configFile]
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                guard let self, p === self.xrayProcess else { return }
                self.xrayProcess = nil
                try? FileManager.default.removeItem(atPath: Self.xrayPidFile)
                if self.isRunning { self.logs.append("[xray exited (exit \(status))]") }
            }
        }
        do {
            try process.run()
        } catch {
            logs.append("[Error: cannot start xray: \(error.localizedDescription)]")
            return false
        }
        xrayProcess = process
        try? String(process.processIdentifier).write(toFile: Self.xrayPidFile, atomically: true, encoding: .utf8)
        logs.append("[xray] started pid=\(process.processIdentifier)")
        return true
    }

    // Mirrors kill_pid_file: only a live process whose executable is xray is signalled, then
    // given up to 5 s to let go of the port before the next xray binds it.
    private func killOrphanedXray() {
        guard let text = try? String(contentsOfFile: Self.xrayPidFile, encoding: .utf8) else { return }
        defer { try? FileManager.default.removeItem(atPath: Self.xrayPidFile) }
        guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              String(cString: path).hasSuffix("/xray") else { return }
        kill(pid, SIGTERM)
        var waited = 0
        while kill(pid, 0) == 0, waited < 50 {
            usleep(100_000)
            waited += 1
        }
    }
```

- `tearDownEngines` (`:651-657`): `xrayProcess?.terminate()` after `helperProcess = nil`.

`install.sh` — `:45` `PID_FILES=("/tmp/warpveil-${INSTALLED_TAG}-singbox.pid")` plus
`XRAY_PID_FILE="${TMPDIR%/}/warpveil-${INSTALLED_TAG}-xray.pid"`; `live_engine_pids`'s `case`
matches `*sing-box)` only; a new `stop_user_xray` (reads the file, removes it, `kill`s the PID
without sudo when `ps -o comm=` ends in `xray`) called right after the app is stopped, before the
root sweep; the header comment and the two echo lines say `sing-box`. `dev-run.sh` — the same
four edits with `DEV_TAG`/`DEV_XRAY_PID_FILE`/`stop_dev_xray`. Both pass `bash -n`.

```bash
stop_user_xray() {
    local pid
    [ -f "$XRAY_PID_FILE" ] || return 0
    pid=$(cat "$XRAY_PID_FILE" 2>/dev/null || true)
    rm -f "$XRAY_PID_FILE"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
        *xray) kill "$pid" 2>/dev/null || true; echo "stopped: xray" ;;
    esac
}
```

Behaviour after the step: the xray topology shows `[xray] started pid=N` from the app, then
`[sing-box] starting...` from the helper; `ps` shows xray owned by the user from the bundle path
and sing-box owned by root; a disconnect ends both; `$TMPDIR/warpveil-1-2-xray.pid` exists while
connected and is gone after. The sing-box topology is unchanged.

### 2. run.sh runs only the root-owned copy, on a staged config it checked first

Commit: `Make run.sh run only its own sing-box on a config it checked`.

`Sources/ProcessManager.swift`:

- `import CryptoKit` after `import AppKit`.
- After `sudoersFile` (`:34`):

```swift
    // The sing-box run.sh starts is a root-owned copy taken while the user typed the password:
    // the .app is the user's, so a swapped bundle binary must never be what sudoers lets
    // through. The manifest next to it is root's `shasum` of that copy; the bundle binary
    // hashing to the same value is what "installed" means after an engine bump.
    private static let rootSingBoxPath = "/usr/local/libexec/warpveil-\(versionTag)/sing-box"
    private static let rootManifestPath = "/usr/local/libexec/warpveil-\(versionTag)/sing-box.sha256"

    // Root-owned, 0700. A config is copied here before anything reads it, and the engine runs
    // the copy: what passed the policy is what runs, whatever happens to the app's file.
    private static let stageDir = "/var/run/warpveil-\(versionTag)"
```

- `runShContent` is replaced by four constants — the policy, the shared shell functions, the
  engine body, and run.sh itself:

```swift
    // What a config may ask of a root sing-box. Out: everything that names a file or a
    // directory (sing-box reads and writes them as root), what changes the system
    // (ntp.write_to_system) and what runs a program (tor). Keys are compared lowercased and a
    // non-ASCII key is refused outright: the engine's JSON decoder matches field names
    // case-insensitively with Unicode folding, so "OUTPUT" and "timeſtamp" land on the same
    // fields (probed on the bundled build). A `path` is a transport or DoH path, except under
    // a local rule-set or a hosts server, where it is a file. One line per finding, or "ok".
    private static let configPolicy = """
        def lower: with_entries(.key |= ascii_downcase);
        [ if type != "object" then "root is not an object" else
            (keys[] | select(IN("log", "dns", "ntp", "inbounds", "outbounds", "endpoints", "route", "experimental") | not) | "top-level key " + .),
            (.. | objects |
              (keys[] | select(test("[^ -~]")) | "non-ASCII key"),
              (lower |
                (keys[] | select(test("(_path|_directory|_file)$|^(output|external_ui|cache_file|acme|write_to_system|download_url|geoip|geosite)") and . != "process_path") | "key " + .),
                (select(has("path") and ((.type | strings | ascii_downcase) | IN("local", "hosts"))) | "path in a " + .type + " object"),
                (.type | strings | ascii_downcase | select(IN("tor", "tailscale")) | "type " + .)))
          end
        ] | if length == 0 then "ok" else .[] end
        """

    // Shared by run.sh and the osascript fallback. stage_config copies the app's config into
    // the stage directory and prints the copy's path; check_config runs the policy on that
    // copy. Both exit before any engine is touched, so a refused connect leaves a running
    // tunnel up. Error lines name the path and the finding, never the file's contents. jq
    // ships with macOS 15.
    private static let configFunctions = """
        stage_config() {
            local src="$1" dst
            [[ "$src" == /* && -f "$src" && ! -L "$src" ]] || { echo "[error] not a regular file: $src" >&2; exit 1; }
            mkdir -p -m 0700 '\(stageDir)' && chmod 0700 '\(stageDir)'
            [[ ! -L '\(stageDir)' && "$(stat -f %u '\(stageDir)')" == 0 ]] || { echo '[error] stage directory is not root-owned' >&2; exit 1; }
            dst=$(mktemp '\(stageDir)/singbox.XXXXXX') || exit 1
            cp "$src" "$dst" && chmod 0600 "$dst" || { rm -f "$dst"; echo "[error] cannot copy $src" >&2; exit 1; }
            echo "$dst"
        }
        check_config() {
            local verdict
            [[ -x /usr/bin/jq ]] || { echo '[error] /usr/bin/jq not found: macOS 15 or newer is required' >&2; exit 1; }
            verdict=$(/usr/bin/jq -r '\(configPolicy)' "$1" 2>&1) || { rm -f "$1"; echo "[error] config is not valid JSON: $verdict" >&2; exit 1; }
            [[ "$verdict" == ok ]] || { rm -f "$1"; echo "[error] config rejected: $verdict" >&2; exit 1; }
        }
        """

    // The engine start shared by run.sh (the root-owned copy, config from argv) and the
    // osascript fallback (the bundled binary, config path baked in). PATH is pinned first:
    // sudo passes the caller's through, and every name below would resolve against it as
    // root. Then stage, check, and only then kill the previous engine.
    private static func engineShell(binary: String, config: String) -> String {
        """
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        \(configFunctions)
        \(killPidFileFunction)
        CFG=$(stage_config \(config)) || exit 1
        check_config "$CFG"
        kill_pid_file \(singboxPidFile) sing-box || { echo '[error] previous sing-box still running'; exit 1; }
        cd '\(stageDir)'
        echo '[sing-box] starting...'
        \(binary) run -c "$CFG" &
        VPN_PID=$!
        echo $VPN_PID > \(singboxPidFile)
        echo "[sing-box] started pid=$VPN_PID"
        cleanup() {
            echo '[stopping...]'
            kill $VPN_PID 2>/dev/null || true
            wait
            rm -f \(singboxPidFile) "$CFG"
            echo '[stopped]'
            exit 0
        }
        trap cleanup TERM INT
        wait
        """
    }

    // run.sh: the only argument is the sing-box config; the binary is the root-owned copy.
    private static let runShContent: String = """
        #!/bin/bash
        set -euo pipefail
        [[ $# -eq 1 ]] || { echo '[error] usage: run.sh <singbox_cfg>'; exit 1; }
        \(engineShell(binary: "'\(rootSingBoxPath)'", config: "\"$1\""))
        """
```

  `stopShContent` gets `export PATH=/usr/bin:/bin:/usr/sbin:/sbin` as its second line; so does the
  inline stop in `killVPNProcesses`. The `exit 1` inside `stage_config` runs in the `$(…)`
  subshell, which is why the caller has `|| exit 1`; `check_config` runs in the main shell.
- `passwordlessInstalled()` and a helper:

```swift
    // Passwordless is on only while the installed scripts are the ones this build would install
    // and the root-owned sing-box is the bundled one. Only an explicit install writes to
    // /usr/local/libexec, so after a script change or an engine bump an existing install would
    // keep running the old files indefinitely; instead it reads as off, the log says why, and
    // the toggle re-installs. The hash is ~30 ms warm and runs only once the cheap checks pass.
    private static func passwordlessInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: sudoersFile),
              (try? String(contentsOfFile: runScriptPath, encoding: .utf8)) == runShContent,
              (try? String(contentsOfFile: stopScriptPath, encoding: .utf8)) == stopShContent,
              let manifest = try? String(contentsOfFile: rootManifestPath, encoding: .utf8),
              let bundled = findBinary("sing-box"), let hash = sha256(ofFile: bundled)
        else { return false }
        return manifest.hasPrefix(hash + " ")
    }

    private static func sha256(ofFile path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
```

- `installPasswordless()`: after the busy guard, `guard let bundledSingBox = Self.findBinary("sing-box")
  else { logs.append("[Error: bundled sing-box not found]"); return }`; the admin command becomes
  (paths through `shellEscape`, which quotes — the old `'\(shellEscape(x))'` double-quoted them):

```swift
        // One osascript call. Every other build's entry goes first — an older run.sh with the
        // hole stays exploitable for as long as its sudoers line exists, and the pre-rename
        // `vpnswift` entry pointed at a script in /private/tmp that anyone can create. The
        // engine is copied and then hashed as root, so the manifest describes the copy itself.
        let shellCmd = """
            rm -f /etc/sudoers.d/warpveil* /etc/sudoers.d/vpnswift && \
            rm -rf /usr/local/libexec/warpveil* && \
            mkdir -p '\(Self.libexecDir)' && \
            install -m 0755 -o root -g wheel \(Self.shellEscape(bundledSingBox)) '\(Self.rootSingBoxPath)' && \
            (cd '\(Self.libexecDir)' && shasum -a 256 sing-box > sing-box.sha256) && \
            install -m 0755 -o root -g wheel \(Self.shellEscape(tmpRun)) '\(Self.runScriptPath)' && \
            install -m 0755 -o root -g wheel \(Self.shellEscape(tmpStop)) '\(Self.stopScriptPath)' && \
            rm -f \(Self.shellEscape(tmpRun)) \(Self.shellEscape(tmpStop)) && \
            visudo -cf \(Self.shellEscape(tmpSudoers)) && \
            install -m 0440 -o root -g wheel \(Self.shellEscape(tmpSudoers)) '\(Self.sudoersFile)' && \
            rm -f \(Self.shellEscape(tmpSudoers))
            """
```

- `removePasswordless()`: `let shellCmd = "rm -f /etc/sudoers.d/warpveil* /etc/sudoers.d/vpnswift
  && rm -rf /usr/local/libexec/warpveil*"` with the comment `// Off means off for every build: the
  other tags' entries are the same hole.`
- `init`: the stale line reads `[Passwordless install is from another build — turn Passwordless on
  again in Advanced]`.
- `connect`: `process.arguments = [Self.runScriptPath, singboxConfigFile]`; the helper's
  termination handler and the catch terminate xray, which no longer dies with the shell:

```swift
        // A helper torn down by a restart can exit after its successor started; only the
        // current one speaks for the connection. xray no longer dies with the helper, so a
        // helper that exits on its own — a refused config, sudo saying no — takes it down here.
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                guard let self, self.isRunning, p === self.helperProcess else { return }
                self.isRunning = false
                self.xrayProcess?.terminate()
                self.stopLogTail()
                self.logs.append("[Disconnected (exit \(status))]")
            }
        }

        do {
            try process.run()
            helperProcess = process
            isRunning = true
        } catch {
            logs.append("[Error: \(error.localizedDescription)]")
            xrayProcess?.terminate()
            stopLogTail()
        }
```

- `buildNonPrivilegedShellCommand`:

```swift
    // The non-passwordless path: the same engine shell, run by osascript as root with the
    // bundled sing-box — the root-owned copy exists only in passwordless mode. `>>`: xray is
    // already writing the log through the app's append-mode handle.
    private func buildNonPrivilegedShellCommand(singBoxPath: String, configFile: String) -> String {
        """
        exec >> \(Self.shellEscape(logFile)) 2>&1
        \(Self.engineShell(binary: Self.shellEscape(singBoxPath), config: Self.shellEscape(configFile)))
        """
    }
```

  `rg -n "validate_arg|xrayPidFile\\) xray|cd /tmp" Sources` must then find nothing.

What `/usr/local/libexec/warpveil-1-2/run.sh` contains after the toggle (rendered from the
constants above; the main session can `diff` the installed file against this):

```bash
#!/bin/bash
set -euo pipefail
[[ $# -eq 1 ]] || { echo '[error] usage: run.sh <singbox_cfg>'; exit 1; }
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
stage_config() {
    local src="$1" dst
    [[ "$src" == /* && -f "$src" && ! -L "$src" ]] || { echo "[error] not a regular file: $src" >&2; exit 1; }
    mkdir -p -m 0700 '/var/run/warpveil-1-2' && chmod 0700 '/var/run/warpveil-1-2'
    [[ ! -L '/var/run/warpveil-1-2' && "$(stat -f %u '/var/run/warpveil-1-2')" == 0 ]] || { echo '[error] stage directory is not root-owned' >&2; exit 1; }
    dst=$(mktemp '/var/run/warpveil-1-2/singbox.XXXXXX') || exit 1
    cp "$src" "$dst" && chmod 0600 "$dst" || { rm -f "$dst"; echo "[error] cannot copy $src" >&2; exit 1; }
    echo "$dst"
}
check_config() {
    local verdict
    [[ -x /usr/bin/jq ]] || { echo '[error] /usr/bin/jq not found: macOS 15 or newer is required' >&2; exit 1; }
    verdict=$(/usr/bin/jq -r '<the policy, verbatim>' "$1" 2>&1) || { rm -f "$1"; echo "[error] config is not valid JSON: $verdict" >&2; exit 1; }
    [[ "$verdict" == ok ]] || { rm -f "$1"; echo "[error] config rejected: $verdict" >&2; exit 1; }
}
kill_pid_file() { … unchanged … }
CFG=$(stage_config "$1") || exit 1
check_config "$CFG"
kill_pid_file /tmp/warpveil-1-2-singbox.pid sing-box || { echo '[error] previous sing-box still running'; exit 1; }
cd '/var/run/warpveil-1-2'
echo '[sing-box] starting...'
'/usr/local/libexec/warpveil-1-2/sing-box' run -c "$CFG" &
VPN_PID=$!
echo $VPN_PID > /tmp/warpveil-1-2-singbox.pid
echo "[sing-box] started pid=$VPN_PID"
cleanup() {
    echo '[stopping...]'
    kill $VPN_PID 2>/dev/null || true
    wait
    rm -f /tmp/warpveil-1-2-singbox.pid "$CFG"
    echo '[stopped]'
    exit 0
}
trap cleanup TERM INT
wait
```

Behaviour after the step: the installed passwordless reads as stale (`[Passwordless install is
from another build…]` in Logs); connecting goes through the password dialog until the toggle is
flipped on again, which asks once, copies the engine, and the next connect runs `sudo
/usr/local/libexec/warpveil-1-2/run.sh $TMPDIR/warpveil-singbox-<pid>.json`. `sudo -n -l` no
longer lists `vpnswift`. A refused config shows `[error] config rejected: key output` followed by
`[Disconnected (exit 1)]` and the previous tunnel, if any, stays up.

### 3. Canon and README

Commit: `Record the privileged helper hardening in the canon`.

`CLAUDE.md` — replacements, by section:

- Architecture tree, `ProcessManager.swift` line: `# VPN process lifecycle, sudo/passwordless,
  config policy, log tailing, sleep/wake`.
- "Two connection topologies": after "with a sing-box TUN wrapper in front of it", add: `xray
  runs as the user, started by the app — only the sing-box that holds the TUN runs as root, and
  the wrapper's server rule is by address, so it does not care who dialed.`
- "dev-run.sh" section, the "Not isolated" sentence gains: `and passwordless — enabling or
  disabling it in one build removes every other build's sudoers entry and libexec directory (they
  are the same hole), so the other copy asks for its toggle again.`
- "install.sh" section, the sweep sentences become: `Engines still alive afterwards are swept
  by the **installed** copy's version tag (read from its `Info.plist`), not the one being built:
  after a version bump the new `run.sh` cannot see the old tag's PID file. An xray is the user's
  — its PID file is `$TMPDIR/warpveil-<tag>-xray.pid` and it is killed without sudo; a sing-box
  is swept with `sudo stop.sh` of that tag when installed, else `sudo kill`, and a PID is
  signalled only while its executable is one of our engines. An Xcode-launched copy of the same
  version shares those files and loses its tunnel too. Under the same version a stale PID file is
  dropped by `kill_pid_file` at the next connect; after a bump the old tag's PID file stays behind
  — the sudoers entry and libexec directory are removed by the next passwordless toggle in any
  build.`
- Key Decisions, "No sandbox": `the app runs sing-box as a root child process (sudo in
  passwordless mode, osascript otherwise), which needs full system access for the TUN; xray runs
  as the user`.
- Key Decisions, "Passwordless mode" — replace with:

```
- **Passwordless mode**: installs into `/usr/local/libexec/warpveil-<tag>/` (root:wheel) a copy
  of the bundled `sing-box` with its `sing-box.sha256`, plus `run.sh`/`stop.sh` (0755), and a
  sudoers entry whitelisting those two exact script paths — no wildcards. `run.sh` takes one
  argument, the config; the binary it runs is its own root-owned copy, never a path it was
  given, because the `.app` is the user's and a bundled binary can be swapped by anyone running
  as the user. Enabling or disabling in any build first removes every `/etc/sudoers.d/warpveil*`
  and `/etc/sudoers.d/vpnswift` and every `/usr/local/libexec/warpveil*` — an older tag's
  `run.sh` is the old hole for as long as its entry exists. The install reads as on only while
  the two scripts match byte-for-byte what this build would install and the bundled sing-box's
  SHA-256 (CryptoKit, ~30 ms at launch) is the one in the manifest; a script change or an engine
  bump reads as off, the log says so, and switching the toggle on re-installs with one prompt
- **Config policy**: every root sing-box — passwordless or not — runs a copy of its config that
  `run.sh` (or the osascript command) made in the root-owned 0700 `/var/run/warpveil-<tag>/`,
  and only after `/usr/bin/jq` (macOS 15+) accepted that copy: top-level keys limited to `log`,
  `dns`, `ntp`, `inbounds`, `outbounds`, `endpoints`, `route`, `experimental`; any key ending in
  `_path`/`_directory`/`_file` (except `process_path`) or starting with `output`, `external_ui`,
  `cache_file`, `acme`, `write_to_system`, `download_url`, `geoip`, `geosite` refused; `path`
  refused under a `local` rule-set or a `hosts` server; `tor` and `tailscale` refused; keys
  compared lowercased, non-ASCII keys refused. The check runs before `kill_pid_file`, so a
  refused connect never takes a tunnel down. It is a denylist of sing-box's file, directory,
  exec and system-state keys (`ProcessManager.configPolicy`), so a sing-box bump is reviewed for
  new ones. `PATH` is pinned in every root shell: macOS's sudoers has no `secure_path`
```

- Key Decisions, "PID files" — replace with:

```
- **PID files**: `run.sh`, `stop.sh` and the osascript fallbacks kill by PID file only — one
  shared `kill_pid_file`, which checks that the PID's executable is sing-box, then waits up to
  5 s for it to exit before the file is removed; nothing else on the machine is touched. xray's
  file is the app's own (`$TMPDIR/warpveil-<tag>-xray.pid`), read by `ProcessManager.
  killOrphanedXray` at the next connect under the same rule (`proc_pidpath` ends in `/xray`) and
  by `install.sh`/`dev-run.sh`. A sing-box with no PID file at our path (another build's tag, a
  hand-started one) survives, and the next connect fails with sing-box's own error in Logs. PID
  files are not deleted at launch: they are the handle on an engine a crash orphaned
```

- Key Decisions, "Bundled binaries only": `` `ProcessManager.findBinary` resolves engines from
  `Bundle.main.resourcePath` and nowhere else — Homebrew, MacPorts and `$PATH` are ignored. The
  bundle is what xray, the ping and the non-passwordless path run; the passwordless `run.sh` runs
  the root-owned copy made from it at install ``.
- Runtime Files: add `` `/usr/local/libexec/warpveil-<tag>/{run.sh,stop.sh,sing-box,sing-box.sha256}`
  — the passwordless install, root-owned ``, `` `/var/run/warpveil-<tag>/singbox.XXXXXX` — the
  root-owned copy of the sing-box config the engine runs, removed with it ``; the PID-file line
  becomes `` `/tmp/warpveil-<tag>-singbox.pid` — sing-box's PID, root's `` plus
  `` `$TMPDIR/warpveil-<tag>-xray.pid` — xray's PID, the user's ``.
- Gotchas, add:

```
- sing-box's JSON decoder matches field names case-insensitively with Unicode folding: `OUTPUT`
  and `timeſtamp` reach `output` and `timestamp`. Anything that filters config keys compares
  them lowercased and refuses non-ASCII keys
- macOS's sudoers has `env_reset` but no `secure_path`: a `NOPASSWD` script inherits the
  caller's `PATH`. Every root shell here pins `PATH` on its first line
- A `sudo -u user cmd` from a root script keeps sudo as the parent — `$!` is sudo's PID and
  `ps -o comm=` says `sudo`, so it cannot be tracked by PID file. xray is started by the app
- Two `FileHandle(forWritingAtPath:)` on one log overwrite each other: they are separate open
  file descriptions at offset 0. Writers that share a log get one handle opened `O_APPEND`
- `/usr/bin/jq` exists from macOS 15; the deployment target is still 14, and on 14 a connect
  fails with `[error] /usr/bin/jq not found` in both modes
```

`README.md:12` → `- **Passwordless mode** — optional sudoers setup to skip password prompts; root
runs only its own copy of sing-box, on a config it checked`.

Then move this file to `plans/done/` and run `/code-review` (canon workflow, step 3).

## Rebasing the queued plans

- `plans/xray-hostname-server.md` — applies as written: its step 1 inserts between the binary
  guard and `lastConnection` and rewrites the `.xray` `switch` case and `buildTunWrapperConfig`,
  none of which this plan touches. Its `connect` signature change has one more call site to
  carry: the stop-wait re-entry now sits under `let exiting = …` instead of `if let stop = …`
  (line numbers move). Its live check asserts `/etc/sudoers.d/warpveil-1-2` exists — still true.
- `plans/client-feature-parity.md` — item 1 (DNS) is untouched. Item 2 (D1, Clash API): the policy
  allows `experimental.clash_api.external_controller`/`secret`/`default_mode`; a user config
  carrying `external_ui*` or `cache_file` is now **refused by run.sh**, so "`external_ui` and
  friends are left alone; `cache_file` is left alone" must become "stripped, with a log line" or
  the connect fails — item 2's call. Item 3 (D2, kill switch): `run.sh … --kill-switch <pf_conf>`
  hands root a file to load, which is the hole in another coat; the ruleset has to be generated
  inside `run.sh` from arguments it validates (IP literals, the TUN address) or checked the way
  the config is. Its "pass everything root opens (the engines run as root)" rule no longer covers
  xray, which is the user's: the pass rule becomes the server addresses the wrapper already routes
  direct. `stop.sh` lifting the anchor is unaffected. Item 7 (`process_path` rules): allowed by
  name; the `_path` regex exempts it.

## Verification

### 1. Build

```bash
cd "/Users/lortan29/Documents/Home Projects/vpn-swift"
xcodebuild -project WarpVeil.xcodeproj -scheme WarpVeil -configuration Debug \
  -derivedDataPath "$TMPDIR/warpveil-dd" build 2>&1 | rg -n "Sources/.*(error|warning):|BUILD (SUCCEEDED|FAILED)"
```

Expect `BUILD SUCCEEDED` after each step and no `Sources/` warnings (a clean build of the final
state in this run had none). Never `swift build`.

### 2. Policy and scripts, rendered from the real source, under /bin/bash 3.2 (no sudo)

After step 2. Renders `run.sh`, `stop.sh` and the osascript body out of `ProcessManager.swift`
by substituting the interpolations with scratch paths (the `== 0` owner check becomes the
harness's uid, since it runs as the user), runs the policy over the app's config shapes and a
hostile set, then drives the scripts with a compiled fake engine named `sing-box`. This exact
harness ran green in this run.

```bash
T="$TMPDIR/helper-harness"; mkdir -p "$T/stage" "$T/bin" "$T/evil"; cd "$T"
SRC="/Users/lortan29/Documents/Home Projects/vpn-swift/Sources/ProcessManager.swift"
python3 -I - "$SRC" "$T" <<'PY'
import re, sys, pathlib, textwrap
src = pathlib.Path(sys.argv[1]).read_text(); T = sys.argv[2]
def block(name):
    m = re.search(r'static (?:let|func) ' + name + r'[^\n]*?(?:\n[ ]*)?"""\n(.*?)\n        """', src, re.S); assert m, name
    return textwrap.dedent(m.group(1))
vals = {"stageDir": T + "/stage", "singboxPidFile": T + "/singbox.pid", "rootSingBoxPath": T + "/bin/sing-box",
        "configPolicy": block("configPolicy"), "killPidFileFunction": block("killPidFileFunction")}
def sub(t, extra={}):
    v = dict(vals); v.update(extra); out = t
    for k, val in v.items(): out = out.replace("\\(" + k + ")", val)
    return out
vals["configFunctions"] = sub(block("configFunctions"))
run = block("runShContent").replace('\\(engineShell(binary: "\'\\(rootSingBoxPath)\'", config: "\\"$1\\""))',
                                    sub(block("engineShell"), {"binary": "'" + T + "/bin/sing-box'", "config": '"$1"'}))
assert "\\(" not in run
pathlib.Path(T + "/run.sh").write_text(run.replace('== 0 ]]', '== $(id -u) ]]'))
pathlib.Path(T + "/stop.sh").write_text(sub(block("stopShContent")))
pathlib.Path(T + "/osa.sh").write_text("exec >> '" + T + "/osa.log' 2>&1\n" + sub(block("engineShell"),
    {"binary": "'" + T + "/bin/sing-box'", "config": "'" + T + "/good.json'"}).replace('== 0 ]]', '== $(id -u) ]]'))
pathlib.Path(T + "/policy.jq").write_text(vals["configPolicy"])
PY
chmod +x run.sh stop.sh; bash -n run.sh && bash -n stop.sh && bash -n osa.sh && echo "syntax ok"

# --- policy over the app's shapes and a hostile set: expect ok / finding ---
cat > good.json <<'EOF'
{"dns":{"servers":[{"detour":"proxy","server":"1.1.1.1","tag":"remote","type":"tls"},{"server":"8.8.8.8","tag":"local","type":"tls"}],"strategy":"prefer_ipv4"},"inbounds":[{"address":["172.19.0.1/30","fdfe:dcba:9876::1/126"],"auto_route":true,"strict_route":true,"tag":"tun-in","type":"tun"}],"log":{"level":"info"},"outbounds":[{"flow":"xtls-rprx-vision","server":"203.0.113.7","server_port":443,"tag":"proxy","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"k","short_id":"s"},"server_name":"rust-lang.org","utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"type":"ws","path":"/ws","headers":{"Host":"cdn.example.com"}},"type":"vless","uuid":"u"},{"tag":"direct","type":"direct"}],"route":{"auto_detect_interface":true,"default_domain_resolver":{"server":"local"},"final":"proxy","rules":[{"action":"hijack-dns","protocol":"dns"},{"action":"sniff"},{"action":"route","domain_suffix":["example.com",".ru"],"outbound":"direct"}]}}
EOF
cat > wrapper.json <<'EOF'
{"dns":{"servers":[{"detour":"xray-proxy","server":"1.1.1.1","tag":"remote","type":"tls"},{"server":"8.8.8.8","tag":"local","type":"tls"}],"strategy":"prefer_ipv4"},"inbounds":[{"address":["172.19.0.1/30"],"auto_route":true,"strict_route":true,"tag":"tun-in","type":"tun"}],"log":{"level":"info"},"outbounds":[{"server":"127.0.0.1","server_port":10808,"tag":"xray-proxy","type":"socks"},{"tag":"direct","type":"direct"}],"route":{"auto_detect_interface":true,"default_domain_resolver":{"server":"local"},"final":"xray-proxy","rules":[{"action":"route","ip_cidr":["203.0.113.7/32"],"outbound":"direct"},{"action":"hijack-dns","protocol":"dns"},{"action":"sniff"}]}}
EOF
cat > parity.json <<'EOF'
{"log":{"level":"info","timestamp":true},"ntp":{"enabled":true,"server":"time.apple.com"},"experimental":{"clash_api":{"external_controller":"127.0.0.1:54321","secret":"S","default_mode":"Rule"}},"dns":{"servers":[{"type":"local","tag":"warpveil-system"},{"type":"https","tag":"doh","server":"1.1.1.1","path":"/dns-query","detour":"proxy"}],"rules":[{"domain_suffix":["example.com"],"action":"route","server":"warpveil-system"},{"clash_mode":"Direct","server":"warpveil-system"}],"final":"doh"},"inbounds":[{"type":"tun","tag":"tun-in","address":["172.19.0.1/30"],"auto_route":true,"strict_route":true,"route_exclude_address":["192.168.1.128/25"],"mtu":1400}],"endpoints":[{"type":"wireguard","tag":"wg","address":["10.0.0.2/32"],"private_key":"k","peers":[{"address":"1.2.3.4","port":51820,"public_key":"p","allowed_ips":["0.0.0.0/0"]}]}],"outbounds":[{"type":"vless","tag":"proxy","server":"203.0.113.7","server_port":443,"uuid":"u"},{"type":"direct","tag":"direct"}],"route":{"auto_detect_interface":true,"find_process":true,"rule_set":[{"type":"remote","tag":"geo","format":"binary","url":"https://example.invalid/x.srs","download_detour":"proxy"},{"type":"inline","tag":"in","rules":[{"domain":["a.b"]}]}],"rules":[{"action":"sniff"},{"action":"hijack-dns","protocol":"dns"},{"process_path":["/usr/bin/curl"],"outbound":"direct"},{"process_path_regex":["^/Applications/"],"outbound":"direct"},{"process_name":["curl"],"outbound":"direct"},{"rule_set":["geo"],"outbound":"direct"},{"clash_mode":"Global","outbound":"proxy"}],"final":"proxy"}}
EOF
echo '{"log":{"OUTPUT":"/etc/x"},"inbounds":[],"outbounds":[]}' > h-OUTPUT.json
printf '{"log":{"timeſtamp":true},"inbounds":[],"outbounds":[]}' > h-fold.json
echo '{"experimental":{"clash_api":{"external_ui_download_url":"http://x/y.zip","external_ui":"/tmp/z"}},"inbounds":[],"outbounds":[]}' > h-ui.json
echo '{"experimental":{"cache_file":{"enabled":true,"path":"/etc/sudoers.d/x"}},"inbounds":[],"outbounds":[]}' > h-cache.json
echo '{"route":{"rule_set":[{"Type":"Local","tag":"l","Path":"/etc/master.passwd"}]},"inbounds":[],"outbounds":[]}' > h-rs.json
echo '{"dns":{"servers":[{"type":"hosts","tag":"h","path":["/etc/hosts"]}]},"inbounds":[],"outbounds":[]}' > h-hosts.json
echo '{"inbounds":[{"type":"trojan","tls":{"enabled":true,"certificate_path":"/etc/x","key_path":"/etc/y","acme":{"data_directory":"/x"}}}],"outbounds":[]}' > h-tls.json
echo '{"outbounds":[{"type":"Tor","tag":"t","executable_path":"/bin/sh"}],"inbounds":[]}' > h-tor.json
echo '{"outbounds":[{"type":"ssh","private_key_path":"/var/root/.ssh/id_ed25519"}],"endpoints":[{"type":"tailscale","state_directory":"/x"}],"inbounds":[]}' > h-ssh-ts.json
echo '{"services":[{"type":"ssm-api","cache_path":"/x"}],"certificate":{"certificate_path":["/etc/hosts"]},"ntp":{"write_to_system":true},"inbounds":[],"outbounds":[]}' > h-top.json
echo '[1,2]' > h-array.json; printf '' > h-empty.json; echo '{"log":{"level":"info"}} {"log":{"output":"/x"}}' > h-two.json
for f in good.json wrapper.json parity.json h-*.json; do printf '%-14s %s\n' "$f" "$(/usr/bin/jq -r -f policy.jq "$f" 2>&1 | tr '\n' ';')"; done
```

Expect `good.json ok;`, `wrapper.json ok;`, `parity.json ok;`, and for the rest exactly:
`h-OUTPUT key output;` · `h-array root is not an object;` · `h-cache key cache_file;` ·
`h-empty` (nothing — not `ok`, so refused) · `h-fold non-ASCII key;` ·
`h-hosts path in a hosts object;` · `h-rs path in a Local object;` ·
`h-ssh-ts key private_key_path;key state_directory;type tailscale;` ·
`h-tls key acme;key certificate_path;key key_path;key data_directory;` ·
`h-top top-level key certificate;top-level key services;key cache_path;key certificate_path;key write_to_system;` ·
`h-tor key executable_path;type tor;` · `h-two ok;key output;` ·
`h-ui key external_ui;key external_ui_download_url;`.

```bash
# --- the scripts, with a fake engine whose comm is "sing-box" (same $T as above) ---
T="$TMPDIR/helper-harness"; cd "$T"
cat > fake.c <<'EOF'
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
static void onterm(int s) { (void)s; printf("fake sing-box: TERM\n"); fflush(stdout); _exit(0); }
int main(int argc, char **argv) { printf("fake sing-box argv:"); for (int i = 1; i < argc; i++) printf(" %s", argv[i]); printf("\n"); fflush(stdout); signal(SIGTERM, onterm); for (;;) pause(); }
EOF
clang -o bin/sing-box fake.c
printf '#!/bin/bash\necho EVIL >> "$(dirname "$0")/../evil.log"; exec /bin/ps "$@"\n' > evil/ps; chmod +x evil/ps
ln -sf good.json link.json
bin/sing-box run -c /dev/null > /dev/null 2>&1 & PREV=$!; sleep 0.3; echo $PREV > singbox.pid
for args in "" "/bin/sh /etc/passwd" "/bin/sh" "$T/h-OUTPUT.json" "link.json" "$T/link.json" "$T/nope.json"; do
    printf '%-28s -> ' "run.sh ${args:-<none>}"; /bin/bash run.sh $args 2>&1 | tr '\n' ' '; echo "rc=${PIPESTATUS[0]}"
done
kill -0 $PREV 2>/dev/null && echo "previous engine survived every refusal: ok" || echo "FAIL: a refusal killed the engine"
echo "staged leftovers: $(ls stage | wc -l | tr -d ' ') (expect 0)"
/bin/bash run.sh "$T/good.json" > run.log 2>&1 & RUN=$!; sleep 1.5
kill -0 $PREV 2>/dev/null && echo "FAIL: previous engine not replaced" || echo "previous engine replaced: ok"
NEW=$(cat singbox.pid); echo "pid file -> $NEW ($(ps -o comm= -p $NEW))"
kill -TERM $RUN; wait $RUN; echo "run.sh exit=$? (expect 0)"; cat run.log
echo "after TERM: pid file $([ -f singbox.pid ] && echo PRESENT || echo removed), staged $(ls stage | wc -l | tr -d ' '), engine $(kill -0 $NEW 2>/dev/null && echo ALIVE || echo gone)"
rm -f evil.log; PATH="$T/evil:$PATH" /bin/bash run.sh "$T/good.json" > /dev/null 2>&1 & RUN=$!; sleep 1; kill -TERM $RUN; wait $RUN
[ -f evil.log ] && echo "FAIL: PATH hijack ran evil ps" || echo "PATH hijack neutralised: ok"
bin/sing-box run -c x > /dev/null 2>&1 & E=$!; echo $E > singbox.pid; sleep 0.2; /bin/bash stop.sh
kill -0 $E 2>/dev/null && echo "FAIL: stop.sh left the engine" || echo "stop.sh: ok ($([ -f singbox.pid ] && echo 'pid file PRESENT' || echo 'pid file removed'))"
rm -f osa.log; /bin/sh -c "$(cat osa.sh)" & O=$!; sleep 1.2; kill -TERM $O; wait $O; echo "osascript body under /bin/sh: exit=$? (expect 0)"; grep -c "started pid" osa.log
sed "s#good.json#h-OUTPUT.json#" osa.sh > osa-h.sh; /bin/sh -c "$(cat osa-h.sh)"; echo "hostile under /bin/sh: rc=$? (expect 1): $(tail -1 osa.log)"
pkill -f "$T/bin/sing-box" 2>/dev/null; echo "done"
```

Expect: usage for no args and for the old two-argument call; `not valid JSON` for `/bin/sh`;
`rejected: key output` for the hostile file; `not a regular file` for the relative path, the
symlink and the missing file — all `rc=1`, the previous engine alive, no staged leftovers; then
the good config replaces the engine, the PID file names a `…/bin/sing-box`, TERM prints
`[stopping...]`/`fake sing-box: TERM`/`[stopped]`, exit 0, PID file and staged copy removed;
`PATH hijack neutralised`; `stop.sh: ok (pid file removed)`; the osascript body starts and stops
the engine under `/bin/sh` and refuses the hostile file with `rejected: key output`.

### 3. Live check (main session, one script, two runs)

Saves nothing but a few 0600 files under `$TMPDIR`; never reads the subscriptions file. The
first run deploys and waits for the tunnel; **the relaunched app's auto-connect shows a macOS
password dialog, because the changed `run.sh` reads the installed passwordless as stale —
answer it.** Then turn Passwordless on in Advanced (one admin prompt) and run the script again
with `probe`: it refuses to proceed until the new install is in place, proves the hole is closed
without using it, checks the tunnel survived each refused call, and finally quits and relaunches
the app so a normal connect goes through the new `run.sh`.

```bash
cat > "$TMPDIR/helper-live.sh" <<'EOF'
#!/bin/bash
# Live check for plans/privileged-helper-hardening.md.
#   helper-live.sh deploy   build + install.sh, wait for the tunnel (password dialog: answer it)
#   helper-live.sh probe    after Passwordless is turned on again: prove the hole is closed
set -uo pipefail
REPO="/Users/lortan29/Documents/Home Projects/vpn-swift"
APP="/Applications/WarpVeil.app"; BIN="$APP/Contents/MacOS/WarpVeil"
TAG="1-2"; LIBEXEC="/usr/local/libexec/warpveil-$TAG"; RUN_SH="$LIBEXEC/run.sh"
HOME_IP="198.51.100.10"; LOG="${TMPDIR%/}/warpveil-$TAG.log"
W="${TMPDIR%/}/helper-live"; mkdir -p "$W"; umask 077
fails=0
log() { printf '%s %s\n' "$(date +%T)" "$*"; }
ok()  { log "ok   $*"; }
bad() { log "FAIL $*"; fails=$((fails + 1)); }
exit_ip() { curl -s --max-time 10 https://api.ipify.org || true; }
tun_up() { ifconfig 2>/dev/null | grep -q "inet 172.19.0.1"; }
app_pid() { pgrep -f "^${BIN}$" | head -1; }
wait_tunnel() {   # $1 seconds; up = TUN address present and the public IP is not the home IP
    local deadline=$((SECONDS + $1)) ip
    while [ $SECONDS -lt $deadline ]; do
        if tun_up; then ip=$(exit_ip); [ -n "$ip" ] && [ "$ip" != "$HOME_IP" ] && { log "tunnel up, exit $ip"; return 0; }; fi
        sleep 3
    done
    log "tunnel NOT up within $1 s (exit now: $(exit_ip))"; return 1
}

case "${1:-}" in
deploy)
    [ -n "$(app_pid)" ] || { bad "installed app not running"; exit 1; }
    [ "$(defaults read com.warpveil.app autoConnect 2>/dev/null)" = 1 ] || { bad "autoConnect is off — the relaunch would not connect"; exit 1; }
    log "deploying; after the relaunch a password dialog appears (passwordless reads as stale) — answer it"
    (cd "$REPO" && ./install.sh) || { bad "install.sh failed"; exit 1; }
    wait_tunnel 480 || { bad "tunnel did not come back on the new build"; exit 1; }
    ok "tunnel back on the new build through the password path"
    ps -axo user=,comm= | grep -q "^root .*Resources/sing-box$" && ok "sing-box runs as root from the bundle (non-passwordless path)" || log "note: no root sing-box from the bundle (sing-box topology? check ps)"
    if ps -axo user=,comm= | grep "Resources/xray$" | grep -qv "^root"; then ok "xray runs as the user"; else bad "no user-owned xray (xray topology expected)"; fi
    ps -axo user=,comm= | grep -q "^root .*xray$" && bad "a ROOT xray is still running — a leftover of the old build; kill it once by hand: sudo kill \$(pgrep -x xray)" || ok "no root xray left"
    [ -f "${TMPDIR%/}/warpveil-$TAG-xray.pid" ] && ok "user xray PID file present" || log "note: no user xray PID file (sing-box topology?)"
    log "now: Advanced → Passwordless on (one admin prompt), then run: $0 probe"
    ;;
probe)
    if ! { [ -f "/etc/sudoers.d/warpveil-$TAG" ] && [ -x "$LIBEXEC/sing-box" ] && grep -q check_config "$RUN_SH" 2>/dev/null; }; then
        log "passwordless is not re-installed on the new build yet — Advanced → Passwordless on, then run: $0 probe"; exit 2
    fi
    tun_up || { bad "tunnel is down — connect first"; exit 1; }
    BEFORE=$(exit_ip); [ -n "$BEFORE" ] && [ "$BEFORE" != "$HOME_IP" ] || { bad "not on the VPN (exit $BEFORE)"; exit 1; }
    SB_PID=$(cat /tmp/warpveil-$TAG-singbox.pid 2>/dev/null || true)
    log "exit IP $BEFORE, sing-box pid ${SB_PID:-?}"

    # --- the install itself ---
    sudo -n -l 2>/dev/null | grep -q vpnswift && bad "/etc/sudoers.d/vpnswift still grants root" || ok "vpnswift sudoers entry gone"
    [ -e /etc/sudoers.d/vpnswift ] && bad "/etc/sudoers.d/vpnswift still exists" || ok "/etc/sudoers.d/vpnswift removed"
    others=$(ls /usr/local/libexec | grep '^warpveil' | grep -v "^warpveil-$TAG$" || true); [ -z "$others" ] && ok "no other warpveil libexec dirs" || bad "other libexec dirs left: $others"
    [ "$(stat -f '%Su:%Sg %Lp' "$LIBEXEC/sing-box")" = "root:wheel 755" ] && ok "root-owned sing-box copy, 0755" || bad "sing-box copy: $(stat -f '%Su:%Sg %Lp' "$LIBEXEC/sing-box")"
    [ "$(awk '{print $1}' "$LIBEXEC/sing-box.sha256")" = "$(shasum -a 256 "$APP/Contents/Resources/sing-box" | awk '{print $1}')" ] && ok "manifest matches the bundled sing-box" || bad "manifest does not match the bundle"
    grep -q 'validate_arg\|XRAY' "$RUN_SH" && bad "run.sh still has the old shape" || ok "run.sh is the new shape"

    # --- the hole, without using it: every call must be refused and leave the tunnel alone ---
    cat > "$W/hostile.json" <<'JSON'
{"log":{"level":"info","OUTPUT":"/etc/warpveil-pwned"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":0}],"outbounds":[{"type":"direct"}]}
JSON
    cat > "$W/hostile2.json" <<'JSON'
{"experimental":{"clash_api":{"external_controller":"127.0.0.1:1","external_ui":"/"},"cache_file":{"enabled":true,"path":"/etc/sudoers.d/x"}},"inbounds":[],"outbounds":[]}
JSON
    printf '{"log":{"timeſtamp":true},"inbounds":[],"outbounds":[]}' > "$W/hostile3.json"
    ln -sf "$W/hostile.json" "$W/link.json"
    probe() {   # $1 label, $2 expected fragment, rest: run.sh args
        local label="$1" expect="$2"; shift 2
        local out rc; out=$(sudo -n "$RUN_SH" "$@" 2>&1); rc=$?
        if [ $rc -ne 0 ] && echo "$out" | grep -q "$expect"; then ok "$label refused: $(echo "$out" | tail -1)"; else bad "$label rc=$rc: $out"; fi
        sleep 1
        if [ -n "$SB_PID" ]; then ps -p "$SB_PID" -o comm= 2>/dev/null | grep -q sing-box && ok "  sing-box $SB_PID still running" || bad "  sing-box $SB_PID gone after $label"; fi
        tun_up && ok "  TUN still up" || bad "  TUN down after $label"
    }
    probe "run.sh /bin/sh"                 "not valid JSON" /bin/sh
    probe "old-style run.sh <bin> <cfg>"   "usage"          /bin/sh /etc/passwd
    probe "hostile log.OUTPUT"             "key output"     "$W/hostile.json"
    probe "hostile external_ui+cache_file" "external_ui"    "$W/hostile2.json"
    probe "hostile Unicode-folded key"     "non-ASCII"      "$W/hostile3.json"
    probe "a symlink to a config"          "not a regular"  "$W/link.json"
    [ -e /etc/warpveil-pwned ] && bad "/etc/warpveil-pwned was written" || ok "nothing written to /etc"
    AFTER=$(exit_ip); [ "$AFTER" = "$BEFORE" ] && ok "exit IP unchanged after the refusals ($AFTER)" || bad "exit IP changed: $BEFORE -> $AFTER"
    [ "$(stat -f '%Su %Lp' /var/run/warpveil-$TAG 2>/dev/null)" = "root 700" ] && ok "stage dir root 0700" || bad "stage dir: $(stat -f '%Su %Lp' /var/run/warpveil-$TAG 2>&1)"
    ls /var/run/warpveil-$TAG >/dev/null 2>&1 && bad "stage dir is listable by the user" || ok "stage dir not readable by the user"

    # --- a normal reconnect through the new run.sh: quit (stop.sh), relaunch (auto-connect) ---
    log "quitting the app through its own quit path and relaunching"
    osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 200); do [ -n "$(app_pid)" ] || break; sleep 0.2; done
    [ -z "$(app_pid)" ] && ok "app quit" || { bad "app did not quit in 40 s"; exit 1; }
    for _ in $(seq 1 50); do tun_up || break; sleep 0.2; done
    tun_up && bad "TUN still up after quit" || ok "TUN released on quit"
    ps -axo comm= | grep -q "Resources/xray$" && bad "xray survived the quit" || ok "xray stopped with the app"
    open -n "$APP"
    wait_tunnel 90 || { bad "no tunnel after relaunch (a password dialog would mean passwordless is not in effect)"; exit 1; }
    ps -axo args= | grep -q "^/usr/bin/sudo $RUN_SH " && ok "connected through sudo run.sh (passwordless in effect)" || bad "no 'sudo run.sh' helper in ps — did it go through osascript?"
    ps -axo user=,comm= | grep -q "^root  *$LIBEXEC/sing-box$" && ok "sing-box is the root-owned copy, running as root" || bad "root sing-box is not $LIBEXEC/sing-box: $(ps -axo user=,comm= | grep sing-box)"
    if ps -axo user=,comm= | grep "Resources/xray$" | grep -qv "^root"; then ok "xray runs as the user"; else log "note: no user xray (sing-box topology?)"; fi
    grep -q "\[error\]" "$LOG" && bad "errors in the engine log: $(grep '\[error\]' "$LOG" | tail -2)" || ok "no [error] lines in $LOG"
    grep -q "started pid=" "$LOG" && ok "helper logged the engine start" || bad "no 'started pid=' in the log"
    log "staged copies while connected (root-only dir, count via sudo not possible) — run.sh removes its copy on stop"
    [ -f /tmp/warpveil-$TAG-xray.pid ] && log "note: /tmp/warpveil-$TAG-xray.pid is a root-owned leftover of the old build; harmless, nothing removes it"
    ;;
*)
    echo "usage: $0 deploy | probe" >&2; exit 1 ;;
esac
log "finished with $fails failure(s)"; exit $((fails > 0))
EOF
chmod +x "$TMPDIR/helper-live.sh"
"$TMPDIR/helper-live.sh" deploy      # answer the password dialog; then Advanced → Passwordless on
"$TMPDIR/helper-live.sh" probe
```

Expect every line `ok` and `finished with 0 failure(s)` in both runs. In `probe`: six
refusals, each followed by `sing-box <pid> still running` and `TUN still up`; `exit IP
unchanged`; after the relaunch `connected through sudo run.sh` and `sing-box is the root-owned
copy`. What the script cannot see: the Logs page's `[Passwordless install is from another
build…]` line and the toggle's state (in-memory), and the contents of the root-only stage
directory.

## Risks and what is not verified

- **Root-only behaviour is not exercised here**: the stage-directory owner check (`stat -f %u ==
  0`), `install -o root`, `shasum` as root, `rm -rf /usr/local/libexec/warpveil*`, `visudo`. All
  are the commands the current install already runs or their one-line siblings; the live check
  runs them for real. The harness proved the same shell with the owner check pointed at the
  harness's uid, and that the real rendering refuses as the user (`stage directory is not
  root-owned`).
- **The policy is a denylist.** It covers every file/directory/exec/system key the 1.14.0 docs
  and the probes name, by name and by shape, but a future sing-box key that writes a file under a
  new name slips through until the pin bump is reviewed. The canon says so. The top-level
  allowlist bounds the blast radius: a new *section* is refused by default.
- **macOS 14 cannot connect** in either mode after step 2 (`/usr/bin/jq` is macOS 15+). The owner
  is on 27; the deployment target stays 14 unless the owner raises it.
- **The dev build's passwordless goes off** when the production build's toggle is used, and the
  other way round (D6); one prompt to bring it back.
- **Launch cost**: `passwordlessInstalled()` hashes 83 MB on the main thread in `ProcessManager.init`
  — 27 ms warm, 146 ms cold on this Mac, only while passwordless is installed.
- **`killOrphanedXray` blocks the main actor** up to 5 s, only when a PID file names a live xray
  that ignores SIGTERM — a crash-recovery path that never ran here.
- **The transition deploy**: the installed (old) app's xray is root's with a root PID file; the
  new `install.sh` no longer sweeps it, so if the old app's quit path failed, a root xray would
  keep port 10808 and the new user xray could not bind. The quit path has worked on every recent
  deploy; the live check looks for a root xray and says how to kill it once.
- **A local DoS** (a FIFO swapped in for the config) is not addressed (D7).
- Not run on the sing-box topology live (the owner's live server is xray); the harness covers its
  config shape and the shell is the same.
- The `PATH`-hijack and symlink/relative/missing-path refusals were verified on the rendered
  script, not on the installed one; the live check repeats the symlink one.

## Validation of this plan

Done in this run; repo untouched except this file (`git status --porcelain` shows only
`plans/privileged-helper-hardening.md`); no engine of the app's started, stopped or reconfigured;
nothing under `/usr/local/libexec`, `/etc/sudoers.d` or `/var/run` touched; no sudo command run
(`sudo -n -l` lists policy and executes nothing):

- Baseline `xcodebuild … Debug` into a scratch derived-data dir: `BUILD SUCCEEDED`.
- Steps 1 and 2 applied in order to a private scratch copy of the repo (`git archive HEAD`), each
  built with `xcodebuild … Debug` into its own derived-data dir: `BUILD SUCCEEDED` twice, no
  `Sources/` warnings. The diffs quoted above are the scratch commits' diffs.
- The policy harness of Verification 2, run over the app's server shape (bypass + IPv6
  injected), the wrapper shape, the parity-plan shape and 26 hostile files: the three shapes
  `ok`, every hostile file refused with the finding listed, an empty file and two concatenated
  documents refused (no `ok` / `ok;key output`), a 5000-rule config checked in 0.17 s.
- `sing-box check`/`run` probes on the bundled 1.14.0: case-insensitive and Unicode-folded keys
  (`OUTPUT` wrote the file at runtime), every denied primitive accepted by `check` (so the policy
  is what stops them), the legacy wireguard outbound gone, a config with no `.json` extension
  accepted, a remote rule-set without `cache_file` accepted, `process_path` rules accepted.
- The scripts of Verification 2, rendered from the scratch source: all seven refusals with the
  previous (fake, `comm` = `…/bin/sing-box`) engine untouched and no staged leftovers; a valid
  config replaced it, TERM cleaned up (exit 0, PID file and staged copy removed); a `PATH` with a
  trojan `ps`/`cat`/`mktemp`/`cp` ahead ran none of them; `stop.sh` killed by PID file and removed
  it, and dropped a stale PID without killing; the osascript body ran and refused under
  `/bin/sh -c`; the real rendering refused as the user at the owner check; a FIFO swapped in is
  refused by `-f` when present before the check (the window after it is the D7 DoS).
- Swift probes compiled with `swiftc -target arm64-apple-macosx14.0`: `proc_pidpath` via `Darwin`;
  two children on one `O_APPEND` handle interleave; `Process.terminate()` on an exited process is
  silent; `kill(dead, 0)` → `ESRCH`; CryptoKit SHA-256 of the bundled sing-box 146 ms cold / 27 ms
  warm.
- `/bin/sh --version` → bash 3.2.57; `/usr/bin/jq --version` → `jq-1.7.1-apple`; `/var/run` →
  `root:daemon 775`; `sudo -n -l` → the Defaults (no `secure_path`) and the `vpnswift` entries
  quoted above; `/etc/sudoers.d/vpnswift` mtime 2026-03-04 21:54:55 vs the first commit at 22:02:22;
  `a40843b` had the `/private/tmp/vpnswift-run.sh` sudoers line.
- Every symbol named above was read in the source at the cited lines; the parity and hostname
  plans were read for the `connect` regions they touch.

## Live results

Run on 2026-10-14 against the installed build, xray topology (New Jersey).

- Steps 1–3 were deployed once, after step 3, not after each step: every deploy that changes
  `run.sh` costs the owner two password prompts (the connect, then the toggle), and step 1 alone
  would have cost them twice. The deploy ran `helper-live.sh deploy` in the background with
  `wait_tunnel 1800` instead of 480, so the wait was not bound by the tool's 10-minute limit.
- `deploy`: 0 failures. The password dialog was answered, the tunnel came back on the new build
  through the osascript path (root sing-box from the bundle), xray ran as the user with its
  `$TMPDIR` PID file, and no root xray was left behind.
- The owner turned Passwordless on again at 18:25. `/etc/sudoers.d/` then held only `warpveil-1-2`;
  `/etc/sudoers.d/vpnswift` was gone. `/usr/local/libexec/warpveil-1-2/` held `run.sh`, `stop.sh`,
  `sing-box` and `sing-box.sha256`, all root:wheel.
- `probe`: every check passed except one, which was a bug in the check itself. All six
  `sudo -n run.sh` calls were refused: `/bin/sh` → not valid JSON; the old two-argument call →
  usage; `log.OUTPUT` → key output; `external_ui` + `cache_file`; a Unicode-folded key →
  non-ASCII; a symlink → not a regular file. After each one the sing-box PID was unchanged, the
  TUN was still up and the exit IP was the same. Nothing was written to `/etc`. The stage
  directory was root 0700 and the user could not list it. On quit and relaunch, the TUN and xray
  went away with the app and came back in 5 s with no password prompt.
- The failing check was `"^sudo $RUN_SH "`. `Process` passes the executable's full path as
  `argv[0]`, so `ps` shows `/usr/bin/sudo /usr/local/libexec/warpveil-1-2/run.sh
  $TMPDIR/warpveil-singbox-<pid>.json`. The pattern is fixed above. Run by hand, `ps` showed the
  chain `/usr/bin/sudo run.sh` → `/bin/bash run.sh` → `/usr/local/libexec/warpveil-1-2/sing-box run -c
  /var/run/warpveil-1-2/singbox.XXXXXX` (root), with xray as the user.
- Not exercised live: the sing-box topology, `killOrphanedXray` after a crash, and a connect on
  macOS 14.

## Review

`/code-review 526a3d4..HEAD` (first pass) found 14. Fixed:

- **R1. jq ran with the caller's `HOME`** (finding 1). macOS sudoers keeps `HOME` in `env_keep`,
  and jq loads `~/.jq` on start, which can redefine builtins: a user file turned the policy into
  `ok` (reproduced). Every root shell now pins `HOME=/var/empty`, and jq runs under `env -i`.
  The harness repeats the case with a `~/.jq` in the caller's `HOME`. Commit `3375371`.
- **R2. Root wrote sing-box's PID file in `/tmp`** (finding 2), where the write follows a symlink
  planted at its name. The file is now `/var/run/warpveil-<tag>/singbox.pid` (root, 0755
  directory, still readable for `install.sh`/`dev-run.sh`), and the staged configs moved one
  level down into `stage/` (0700). `3375371`.
- **R3. Root opened a path the caller chose** (finding 7). `run.sh` takes no arguments now and
  reads the config on stdin; the app passes the file as the helper's standard input. The
  osascript path redirects the app's own file, a path baked into a command the user authorises
  with the password. `3375371`.
- **R4. The staged config outlived its shell** (finding 5). The osascript shell never gets a TERM,
  and an engine that exits by itself skipped the TERM trap. An EXIT trap now removes the copy
  however the shell ends, and the PID file once it is ours — unless a newer `run.sh` already
  wrote its own. `3375371`.
- **R5. Provider templates were refused** (finding 3). `BypassService.dropUnneededFileKeys` drops
  from a sing-box server config what such templates carry by default and the tunnel does not
  need: extra top-level sections, `log.output`, `experimental.cache_file`, the
  `clash_api.external_ui*` keys and `route.geoip`/`geosite`. It logs a line naming them.
  Anything else that touches a file still fails the connect, by name. `97c9855`. This also
  settles the parity plan's item 2 rebase note: the dashboard keys are now stripped.
- **R6. macOS 14 could not connect** (finding 4). The deployment target is 15.0, where
  `/usr/bin/jq` ships. `ef0e0a0`.
- **R7. Nothing waited for xray's port** (finding 9). **An xray that died left the TUN up**
  (finding 8). **The orphan wait blocked the main actor and dropped a survivor's handle**
  (finding 11). The xray start now runs in `reconnectTask`. `stopOrphanedXray` waits
  asynchronously, and a survivor keeps its PID file and stops the connect. The wrapper starts
  once `127.0.0.1:10808` accepts a TCP connect. xray's termination handler tears the engines
  down while connected. The start task releases `reconnectTask` when it finishes, because wake
  reads a non-nil one as "a restart is pending". `8c616da`.
- **R8. Another build's toggle left this build's cached state stale** (finding 10).
  `refreshPasswordless()` re-reads the install before every connect and disconnect, but not
  during an install, where the toggle is flipped optimistically. `dfa3acc`.
- **R9. The manifest was unneeded** (finding 13). `FileManager.contentsEqual` compares the root
  copy with the bundle. `sing-box.sha256`, CryptoKit and the root `shasum` step are gone.
  `dfa3acc`.
- **R10. `${TMPDIR%/}` is empty outside a login shell** (finding 12). Both scripts use
  `getconf DARWIN_USER_TEMP_DIR`, verified equal to the app's `$TMPDIR` with `TMPDIR` unset.
  `a942e74`.
- **R11. The plan's closing commit carried only the rename** (finding 14). Fixed by `3bd033a`.

Argued, not changed:

- **Finding 6: the root copy is taken from a bundle the user can write.** True. The copy pins
  what the bundle held when the password was typed, and code already running as the user before
  that rides the prompt, as it can ride any admin prompt. A hash pinned at build time would live
  in the same user-writable bundle — in the app's executable or its `Info.plist` — and a swap
  of the engine could swap the pin with it. The canon now says this in "Passwordless mode",
  instead of claiming a swapped bundle can never run as root.

Verified before deploying:

- `xcodebuild` is green after every commit.
- The rendered-script harness (`harness3.sh`, built like Verification 2 but for the stdin shape)
  passed 21 of 21. It covered: an argument refused; a binary on stdin; a hostile config; empty
  stdin; a caller `HOME` with `~/.jq` (refused, and confirmed to print `ok` without `env -i`);
  the previous engine alive with nothing staged after every refusal; replacement; cleanup on
  TERM; cleanup after the engine exits by itself; a newer PID file left alone; a `PATH` hijack
  neutralised; `stop.sh`; and the osascript body cleaning up after a stop it never gets a TERM
  for.
- `dropUnneededFileKeys` with the real policy: a provider template with `$schema`, `log.Output`,
  `cache_file`, `external_ui*` and `route.geoip` comes out `ok`, keeping `external_controller`
  and the transport `path`. A clean config comes back byte-for-byte. A local rule-set is still
  refused.

The live check for this round is `helper-live2.sh` below. It is the same `deploy`/`probe` flow,
with stdin calls and the new paths:

```bash
#!/bin/bash
# Live check for the hardening's first review round.
#   helper-live2.sh deploy   build + install.sh, wait for the tunnel (password dialog: answer it)
#   helper-live2.sh probe    after Passwordless is turned on again: every refusal leaves the tunnel up
set -uo pipefail
REPO="/Users/lortan29/Documents/Home Projects/vpn-swift"
APP="/Applications/WarpVeil.app"; BIN="$APP/Contents/MacOS/WarpVeil"
TAG="1-2"; LIBEXEC="/usr/local/libexec/warpveil-$TAG"; RUN_SH="$LIBEXEC/run.sh"
RUN_DIR="/var/run/warpveil-$TAG"; PID_FILE="$RUN_DIR/singbox.pid"
HOME_IP="198.51.100.10"; LOG="$(getconf DARWIN_USER_TEMP_DIR)warpveil-$TAG.log"
W="$(getconf DARWIN_USER_TEMP_DIR)helper-live2"; mkdir -p "$W/home"; umask 077
fails=0
log() { printf '%s %s\n' "$(date +%T)" "$*"; }
ok()  { log "ok   $*"; }
bad() { log "FAIL $*"; fails=$((fails + 1)); }
exit_ip() { curl -s --max-time 10 https://api.ipify.org || true; }
tun_up() { ifconfig 2>/dev/null | grep -q "inet 172.19.0.1"; }
app_pid() { pgrep -f "^${BIN}$" | head -1; }
wait_tunnel() {
    local deadline=$((SECONDS + $1)) ip
    while [ $SECONDS -lt $deadline ]; do
        if tun_up; then ip=$(exit_ip); [ -n "$ip" ] && [ "$ip" != "$HOME_IP" ] && { log "tunnel up, exit $ip"; return 0; }; fi
        sleep 3
    done
    log "tunnel NOT up within $1 s (exit now: $(exit_ip))"; return 1
}

case "${1:-}" in
deploy)
    [ -n "$(app_pid)" ] || { bad "installed app not running"; exit 1; }
    [ "$(defaults read com.warpveil.app autoConnect 2>/dev/null)" = 1 ] || { bad "autoConnect is off"; exit 1; }
    (cd "$REPO" && ./install.sh) || { bad "install.sh failed"; exit 1; }
    wait_tunnel 1800 || { bad "tunnel did not come back on the new build"; exit 1; }
    ok "tunnel back on the new build through the password path"
    ps -axo user=,comm= | grep >/dev/null "^root .*Resources/sing-box$" && ok "root sing-box from the bundle (osascript path)" || log "note: no root sing-box from the bundle"
    if ps -axo user=,comm= | grep "Resources/xray$" | grep -v "^root" >/dev/null; then ok "xray runs as the user"; else bad "no user-owned xray"; fi
    [ -f "$PID_FILE" ] && ok "sing-box PID file in $RUN_DIR" || bad "no $PID_FILE"
    [ -e "/tmp/warpveil-$TAG-singbox.pid" ] && log "note: old /tmp PID file still there" || ok "no PID file in /tmp"
    [ "$(stat -f '%Su %Lp' "$RUN_DIR" 2>/dev/null)" = "root 755" ] && ok "run dir root 0755" || bad "run dir: $(stat -f '%Su %Lp' "$RUN_DIR" 2>&1)"
    ;;
probe)
    if ! { [ -f "/etc/sudoers.d/warpveil-$TAG" ] && [ -x "$LIBEXEC/sing-box" ] && grep -q 'env -i /usr/bin/jq' "$RUN_SH" 2>/dev/null; }; then
        log "passwordless is not re-installed on the new build yet — Advanced → Passwordless on, then: $0 probe"; exit 2
    fi
    tun_up || { bad "tunnel is down"; exit 1; }
    BEFORE=$(exit_ip); [ -n "$BEFORE" ] && [ "$BEFORE" != "$HOME_IP" ] || { bad "not on the VPN (exit $BEFORE)"; exit 1; }
    SB_PID=$(cat "$PID_FILE" 2>/dev/null || true)
    log "exit IP $BEFORE, sing-box pid ${SB_PID:-?}"
    [ -e "$LIBEXEC/sing-box.sha256" ] && bad "old manifest still installed" || ok "no manifest file"
    cmp -s "$LIBEXEC/sing-box" "$APP/Contents/Resources/sing-box" && ok "root copy equals the bundled sing-box" || bad "root copy differs from the bundle"
    others=$(ls /usr/local/libexec | grep '^warpveil' | grep -v "^warpveil-$TAG$" || true); [ -z "$others" ] && ok "no other libexec dirs" || bad "other libexec dirs: $others"
    ls /etc/sudoers.d | grep -qv "^warpveil-$TAG$" && bad "other sudoers entries: $(ls /etc/sudoers.d)" || ok "only warpveil-$TAG in sudoers.d"

    echo '{"log":{"level":"info","OUTPUT":"/etc/warpveil-pwned"},"inbounds":[],"outbounds":[{"type":"direct"}]}' > "$W/hostile.json"
    echo '{"experimental":{"clash_api":{"external_ui":"/"},"cache_file":{"enabled":true}},"inbounds":[],"outbounds":[]}' > "$W/hostile2.json"
    printf '{"log":{"timeſtamp":true},"inbounds":[],"outbounds":[]}' > "$W/hostile3.json"
    echo '{"log":{"output":"/etc/warpveil-pwned"},"zzz":1,"inbounds":[],"outbounds":[]}' > "$W/hostile4.json"
    printf 'def keys: []; def has($k): false;\n' > "$W/home/.jq"
    probe() {   # $1 label, $2 expected fragment, $3 stdin file, rest: extra args / env prefix handled by caller
        local label="$1" expect="$2" input="$3"; shift 3
        local out rc; out=$("$@" < "$input" 2>&1); rc=$?
        if [ $rc -ne 0 ] && echo "$out" | grep -q "$expect"; then ok "$label refused: $(echo "$out" | tail -1)"; else bad "$label rc=$rc: $out"; fi
        sleep 1
        [ -n "$SB_PID" ] && { ps -p "$SB_PID" -o comm= 2>/dev/null | grep -q sing-box && ok "  sing-box $SB_PID still running" || bad "  sing-box $SB_PID gone after $label"; }
        tun_up && ok "  TUN still up" || bad "  TUN down after $label"
    }
    probe "an argument"                "usage"          "$W/hostile.json"  sudo -n "$RUN_SH" /bin/sh
    probe "a binary on stdin"          "not valid JSON" /bin/sh            sudo -n "$RUN_SH"
    probe "empty stdin"                "no config"      /dev/null          sudo -n "$RUN_SH"
    probe "hostile log.OUTPUT"         "key output"     "$W/hostile.json"  sudo -n "$RUN_SH"
    probe "hostile external_ui"        "external_ui"    "$W/hostile2.json" sudo -n "$RUN_SH"
    probe "Unicode-folded key"         "non-ASCII"      "$W/hostile3.json" sudo -n "$RUN_SH"
    probe "caller HOME with ~/.jq"     "key output"     "$W/hostile4.json" env HOME="$W/home" sudo -n "$RUN_SH"
    [ -e /etc/warpveil-pwned ] && bad "/etc/warpveil-pwned was written" || ok "nothing written to /etc"
    AFTER=$(exit_ip); [ "$AFTER" = "$BEFORE" ] && ok "exit IP unchanged ($AFTER)" || bad "exit IP changed: $BEFORE -> $AFTER"
    [ "$(stat -f '%Su %Lp' "$RUN_DIR/stage" 2>/dev/null)" = "root 700" ] && ok "stage dir root 0700" || bad "stage dir: $(stat -f '%Su %Lp' "$RUN_DIR/stage" 2>&1)"
    ls "$RUN_DIR/stage" >/dev/null 2>&1 && bad "stage dir listable by the user" || ok "stage dir not readable by the user"

    log "quitting the app through its own quit path and relaunching"
    osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 200); do [ -n "$(app_pid)" ] || break; sleep 0.2; done
    [ -z "$(app_pid)" ] && ok "app quit" || { bad "app did not quit in 40 s"; exit 1; }
    for _ in $(seq 1 50); do tun_up || break; sleep 0.2; done
    tun_up && bad "TUN still up after quit" || ok "TUN released on quit"
    [ -e "$PID_FILE" ] && bad "PID file left after quit" || ok "PID file removed on quit"
    ps -axo comm= | grep >/dev/null "Resources/xray$" && bad "xray survived the quit" || ok "xray stopped with the app"
    open -n "$APP"
    wait_tunnel 90 || { bad "no tunnel after relaunch"; exit 1; }
    ps -axo args= | grep >/dev/null "^/usr/bin/sudo $RUN_SH$" && ok "connected through sudo run.sh, no arguments" || bad "no 'sudo run.sh' helper: $(ps -axo args= | grep run.sh)"
    ps -axo user=,args= | grep >/dev/null "^root  *$LIBEXEC/sing-box run -c $RUN_DIR/stage/singbox\." && ok "root copy runs the staged config" || bad "sing-box: $(ps -axo user=,args= | grep 'sing-box run')"
    if ps -axo user=,comm= | grep "Resources/xray$" | grep -v "^root" >/dev/null; then ok "xray runs as the user"; else bad "no user xray"; fi
    grep -q "\[error\]" "$LOG" && bad "errors in the engine log: $(grep '\[error\]' "$LOG" | tail -2)" || ok "no [error] lines in the engine log"
    for h in ifconfig.me api.ipify.org; do log "  $h -> $(curl -s --max-time 10 https://$h 2>/dev/null)"; done
    ;;
*) echo "usage: $0 deploy | probe" >&2; exit 1 ;;
esac
log "finished with $fails failure(s)"; exit $((fails > 0))
```

Live, 2026-10-14, xray topology:

- `deploy`: the tunnel came back at 19:30 through the password path. Running then: the osascript
  shell, a root `…/Resources/sing-box run -c /var/run/warpveil-1-2/stage/singbox.XXXXXX`, xray as
  the user, the PID file in `/var/run/warpveil-1-2` (root 0755), and none in `/tmp`.
- The owner turned Passwordless on again at 19:31. `probe`: every security check passed. All seven
  calls to `sudo -n run.sh` were refused: an argument, a binary on stdin, empty stdin, `log.OUTPUT`,
  `external_ui`, a Unicode-folded key, and a caller `HOME` carrying a `~/.jq`. After each one the
  sing-box PID and the TUN were unchanged. Nothing was written to `/etc`. The exit IP stayed
  `203.0.113.30`. `stage/` was root 0700 and the user could not list it. There was no manifest,
  and the root copy was byte-for-byte the bundled binary (`cmp`). `/etc/sudoers.d` held only
  `warpveil-1-2`. On quit, the TUN, the PID file and xray all went away. On relaunch, the tunnel
  was back in 4 s with no prompt, with no `[error]` in the engine log.
- Two checks failed because of a bug in the script, not in the build. Under `set -o pipefail`,
  `ps … | grep -q` fails whenever `grep -q` exits at its first match before `ps` has finished
  writing: `ps` dies of SIGPIPE, and that fails the pipeline. The bytes of the `ps` output
  matched both patterns exactly (`od -c`): `/usr/bin/sudo /usr/local/libexec/warpveil-1-2/run.sh`
  with no arguments, and root `/usr/local/libexec/warpveil-1-2/sing-box run -c
  /var/run/warpveil-1-2/stage/singbox.LssOIX`. The first deploy's "no root sing-box from the
  bundle" note had the same cause. Every `ps … | grep -q` in the script above now reads
  `grep >/dev/null`.

`/code-review 3bd033a..HEAD` (second pass) found 15. Five of them (3, 4, 5, 8 and 9) are about
the xray start that R7 made asynchronous. That makes this the third change to the same place:
step 1, then R7, then this round. The canon's "third fix is a signal" applies, and the
construction was questioned before any more patching. The shape was wrong in one way: the start
window was invisible to the state machine. `isRunning` stayed false while xray started, so a
second Connect, Cmd+Q, a routing edit and a cancelled task each raced it. The fix changes the
shape instead of patching each race: the session starts at `connect`. Fixed:

- **R12. A pending start is part of the session** (findings 3, 4, 5). `isRunning` is true from
  `connect` on, so a second connect is refused. Disconnect, restart, wake and quit all tear a
  pending start down, and a routing edit during the start restarts it with the new list. A
  cancelled start touches nothing, because whoever cancelled it cleans up. `stopOrphanedXray`
  checks for cancellation and does not delete a PID file that may already belong to the next
  start. A session that never reached the helper skips the root stop, so there is no password
  dialog for an engine that never ran. `508511c`.
- **R13. The comparison of the 83 MB engine ran on every call** (finding 1). It cost 0.6–1.3 s
  on the main actor; measured on this machine, `contentsEqual` took 589 ms cold and 76 ms warm.
  It now compares mapped pages (225 ms cold, 10 ms warm) at launch and after an install or a
  removal. Each call re-reads only the sudoers entry and the scripts. `3d17992`.
- **R14. "Inbounds" in another case was dropped silently** (finding 2), and the root sing-box
  then started with no TUN while the app showed Connected. Sections are compared lowercased and
  kept, so the policy refuses them by name. Both lists come from `BypassService.configSections`,
  which also closes finding 14. `4f6e35f`.
- **R15. An endless stdin filled the disk with a root file** (finding 12). `stage_config` copies
  at most 4 MiB, a copy that hits the cap is refused, and an EXIT trap inside `stage_config`
  removes the copy on any failure. `c8ef428`.
- **R16. The osascript path's redirect followed a symlink as root** (finding 11). That path now
  reads the app's file with `/usr/bin/sudo -n -u '#<uid>' /bin/cat`, so root never opens a path
  a caller chose, in either mode. `c8ef428`.
- **R17. A foreign listener on 10808 took the wrapper's traffic** (finding 7a). A port that is
  already taken is refused before xray starts. The loopback probe is `PingService.isListening`,
  shared, which closes finding 13. `508511c`.
- **R18. A failed start lost xray's last lines** (finding 8). `stopLogTail` reads the log to its
  end before closing. `4064c56`.

For the owner, not fixed:

- **Finding 9: an xray that dies while connected disconnects.** Without passwordless, that is an
  unrequested password dialog. If the user declines it, the root wrapper keeps the TUN and
  blackholes traffic while the app says Disconnected. This finding pulls against the first
  pass's finding 8, which asked for exactly this teardown, so under the canon rule it goes to
  the owner. The options:
  - keep the teardown (now);
  - relaunch xray once as the user — no prompt, and the wrapper is still up — and tear down only
    if it dies again within a few seconds;
  - leave the session up, log it, and make the user reconnect.
- **Finding 6: an install from an earlier build of the same tag stays in sudoers** until the
  toggle is flipped. The app only logs that it is stale. Removing it at launch would be an
  unrequested admin prompt. The owner's machine was re-installed at 19:31 and has no stale
  install. The choice is between keeping the log line and prompting once at launch to replace
  or remove it.

Argued, not changed:

- **Finding 7b: a `?format=xray` feed whose SOCKS inbound is not 10808.** The wrapper has always
  pointed at 10808, so such feeds never worked. That bug is older than this plan and outside it.
- **Finding 10: the PID file moved under the same tag.** This only matters for an engine started
  by the first hardening build whose quit failed. Here the quit worked every time. Two staged
  copies that build left in `/var/run/warpveil-1-2/` (root 0600) need root to remove, and the
  owner is asked to delete them with one command.
- **Finding 15: three JSON round trips per connect, and the "[Config] dropped" line on every
  restart.** The configs are a few KB, the round trips cost about a millisecond, and the log line
  says what that connect did.

Verified before deploying: `xcodebuild` is green after every commit. The rendered-script harness
passes 22 of 22: everything from the first round plus an endless stdin, refused at 4 MiB with no
leftover. The renderer now takes the section list from `BypassService.swift`, and the rendered
`IN(…)` is byte-for-byte the one before. `dropUnneededFileKeys` keeps `"Inbounds"`, which the
policy refuses as `top-level key Inbounds`, and a provider template still comes out `ok`.

Live check for this round: `helper-live3.sh`. It is `helper-live2.sh` with the pipefail fix and
an endless-stdin probe. The deploy's first connect runs through the osascript path, which is
where R16's read-as-user is exercised.

```bash
#!/bin/bash
# Live check for the hardening's second review round.
#   helper-live3.sh deploy   build + install.sh, wait for the tunnel (password dialog: answer it)
#   helper-live3.sh probe    after Passwordless is turned on again: every refusal leaves the tunnel up
set -uo pipefail
REPO="/Users/lortan29/Documents/Home Projects/vpn-swift"
APP="/Applications/WarpVeil.app"; BIN="$APP/Contents/MacOS/WarpVeil"
TAG="1-2"; LIBEXEC="/usr/local/libexec/warpveil-$TAG"; RUN_SH="$LIBEXEC/run.sh"
RUN_DIR="/var/run/warpveil-$TAG"; PID_FILE="$RUN_DIR/singbox.pid"
HOME_IP="198.51.100.10"; LOG="$(getconf DARWIN_USER_TEMP_DIR)warpveil-$TAG.log"
W="$(getconf DARWIN_USER_TEMP_DIR)helper-live3"; mkdir -p "$W/home"; umask 077
fails=0
log() { printf '%s %s\n' "$(date +%T)" "$*"; }
ok()  { log "ok   $*"; }
bad() { log "FAIL $*"; fails=$((fails + 1)); }
exit_ip() { curl -s --max-time 10 https://api.ipify.org || true; }
tun_up() { ifconfig 2>/dev/null | grep -q "inet 172.19.0.1"; }
app_pid() { pgrep -f "^${BIN}$" | head -1; }
wait_tunnel() {
    local deadline=$((SECONDS + $1)) ip
    while [ $SECONDS -lt $deadline ]; do
        if tun_up; then ip=$(exit_ip); [ -n "$ip" ] && [ "$ip" != "$HOME_IP" ] && { log "tunnel up, exit $ip"; return 0; }; fi
        sleep 3
    done
    log "tunnel NOT up within $1 s (exit now: $(exit_ip))"; return 1
}

case "${1:-}" in
deploy)
    [ -n "$(app_pid)" ] || { bad "installed app not running"; exit 1; }
    [ "$(defaults read com.warpveil.app autoConnect 2>/dev/null)" = 1 ] || { bad "autoConnect is off"; exit 1; }
    (cd "$REPO" && ./install.sh) || { bad "install.sh failed"; exit 1; }
    wait_tunnel 1800 || { bad "tunnel did not come back on the new build"; exit 1; }
    ok "tunnel back on the new build through the password path"
    ps -axo user=,comm= | grep >/dev/null "^root .*Resources/sing-box$" && ok "root sing-box from the bundle (osascript path)" || log "note: no root sing-box from the bundle"
    if ps -axo user=,comm= | grep "Resources/xray$" | grep -v "^root" >/dev/null; then ok "xray runs as the user"; else bad "no user-owned xray"; fi
    [ -f "$PID_FILE" ] && ok "sing-box PID file in $RUN_DIR" || bad "no $PID_FILE"
    [ -e "/tmp/warpveil-$TAG-singbox.pid" ] && log "note: old /tmp PID file still there" || ok "no PID file in /tmp"
    [ "$(stat -f '%Su %Lp' "$RUN_DIR" 2>/dev/null)" = "root 755" ] && ok "run dir root 0755" || bad "run dir: $(stat -f '%Su %Lp' "$RUN_DIR" 2>&1)"
    ;;
probe)
    if ! { [ -f "/etc/sudoers.d/warpveil-$TAG" ] && [ -x "$LIBEXEC/sing-box" ] && grep -q 'env -i /usr/bin/jq' "$RUN_SH" 2>/dev/null; }; then
        log "passwordless is not re-installed on the new build yet — Advanced → Passwordless on, then: $0 probe"; exit 2
    fi
    tun_up || { bad "tunnel is down"; exit 1; }
    BEFORE=$(exit_ip); [ -n "$BEFORE" ] && [ "$BEFORE" != "$HOME_IP" ] || { bad "not on the VPN (exit $BEFORE)"; exit 1; }
    SB_PID=$(cat "$PID_FILE" 2>/dev/null || true)
    log "exit IP $BEFORE, sing-box pid ${SB_PID:-?}"
    [ -e "$LIBEXEC/sing-box.sha256" ] && bad "old manifest still installed" || ok "no manifest file"
    cmp -s "$LIBEXEC/sing-box" "$APP/Contents/Resources/sing-box" && ok "root copy equals the bundled sing-box" || bad "root copy differs from the bundle"
    others=$(ls /usr/local/libexec | grep '^warpveil' | grep -v "^warpveil-$TAG$" || true); [ -z "$others" ] && ok "no other libexec dirs" || bad "other libexec dirs: $others"
    ls /etc/sudoers.d | grep -qv "^warpveil-$TAG$" && bad "other sudoers entries: $(ls /etc/sudoers.d)" || ok "only warpveil-$TAG in sudoers.d"

    echo '{"log":{"level":"info","OUTPUT":"/etc/warpveil-pwned"},"inbounds":[],"outbounds":[{"type":"direct"}]}' > "$W/hostile.json"
    echo '{"experimental":{"clash_api":{"external_ui":"/"},"cache_file":{"enabled":true}},"inbounds":[],"outbounds":[]}' > "$W/hostile2.json"
    printf '{"log":{"timeſtamp":true},"inbounds":[],"outbounds":[]}' > "$W/hostile3.json"
    echo '{"log":{"output":"/etc/warpveil-pwned"},"zzz":1,"inbounds":[],"outbounds":[]}' > "$W/hostile4.json"
    printf 'def keys: []; def has($k): false;\n' > "$W/home/.jq"
    probe() {   # $1 label, $2 expected fragment, $3 stdin file, rest: extra args / env prefix handled by caller
        local label="$1" expect="$2" input="$3"; shift 3
        local out rc; out=$("$@" < "$input" 2>&1); rc=$?
        if [ $rc -ne 0 ] && echo "$out" | grep -q "$expect"; then ok "$label refused: $(echo "$out" | tail -1)"; else bad "$label rc=$rc: $out"; fi
        sleep 1
        [ -n "$SB_PID" ] && { ps -p "$SB_PID" -o comm= 2>/dev/null | grep -q sing-box && ok "  sing-box $SB_PID still running" || bad "  sing-box $SB_PID gone after $label"; }
        tun_up && ok "  TUN still up" || bad "  TUN down after $label"
    }
    probe "an argument"                "usage"          "$W/hostile.json"  sudo -n "$RUN_SH" /bin/sh
    probe "a binary on stdin"          "not valid JSON" /bin/sh            sudo -n "$RUN_SH"
    probe "empty stdin"                "no config"      /dev/null          sudo -n "$RUN_SH"
    probe "hostile log.OUTPUT"         "key output"     "$W/hostile.json"  sudo -n "$RUN_SH"
    probe "hostile external_ui"        "external_ui"    "$W/hostile2.json" sudo -n "$RUN_SH"
    probe "Unicode-folded key"         "non-ASCII"      "$W/hostile3.json" sudo -n "$RUN_SH"
    probe "caller HOME with ~/.jq"     "key output"     "$W/hostile4.json" env HOME="$W/home" sudo -n "$RUN_SH"
    probe "endless stdin"              "4 MiB"          /dev/zero          sudo -n "$RUN_SH"
    [ -e /etc/warpveil-pwned ] && bad "/etc/warpveil-pwned was written" || ok "nothing written to /etc"
    AFTER=$(exit_ip); [ "$AFTER" = "$BEFORE" ] && ok "exit IP unchanged ($AFTER)" || bad "exit IP changed: $BEFORE -> $AFTER"
    [ "$(stat -f '%Su %Lp' "$RUN_DIR/stage" 2>/dev/null)" = "root 700" ] && ok "stage dir root 0700" || bad "stage dir: $(stat -f '%Su %Lp' "$RUN_DIR/stage" 2>&1)"
    ls "$RUN_DIR/stage" >/dev/null 2>&1 && bad "stage dir listable by the user" || ok "stage dir not readable by the user"

    log "quitting the app through its own quit path and relaunching"
    osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 200); do [ -n "$(app_pid)" ] || break; sleep 0.2; done
    [ -z "$(app_pid)" ] && ok "app quit" || { bad "app did not quit in 40 s"; exit 1; }
    for _ in $(seq 1 50); do tun_up || break; sleep 0.2; done
    tun_up && bad "TUN still up after quit" || ok "TUN released on quit"
    [ -e "$PID_FILE" ] && bad "PID file left after quit" || ok "PID file removed on quit"
    ps -axo comm= | grep >/dev/null "Resources/xray$" && bad "xray survived the quit" || ok "xray stopped with the app"
    open -n "$APP"
    wait_tunnel 90 || { bad "no tunnel after relaunch"; exit 1; }
    ps -axo args= | grep >/dev/null "^/usr/bin/sudo $RUN_SH$" && ok "connected through sudo run.sh, no arguments" || bad "no 'sudo run.sh' helper: $(ps -axo args= | grep run.sh)"
    ps -axo user=,args= | grep >/dev/null "^root  *$LIBEXEC/sing-box run -c $RUN_DIR/stage/singbox\." && ok "root copy runs the staged config" || bad "sing-box: $(ps -axo user=,args= | grep 'sing-box run')"
    if ps -axo user=,comm= | grep "Resources/xray$" | grep -v "^root" >/dev/null; then ok "xray runs as the user"; else bad "no user xray"; fi
    grep -q "\[error\]" "$LOG" && bad "errors in the engine log: $(grep '\[error\]' "$LOG" | tail -2)" || ok "no [error] lines in the engine log"
    for h in ifconfig.me api.ipify.org; do log "  $h -> $(curl -s --max-time 10 https://$h 2>/dev/null)"; done
    ;;
*) echo "usage: $0 deploy | probe" >&2; exit 1 ;;
esac
log "finished with $fails failure(s)"; exit $((fails > 0))
```
