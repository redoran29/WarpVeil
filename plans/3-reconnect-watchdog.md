## 3. The tunnel comes back by itself after an engine dies
Owner, 2026-10-15: when an engine dies, the app stays Disconnected and traffic leaves with the real IP
until someone presses the button. The app should reconnect on its own — always, with no setting. A pf
kill switch that blocks traffic while there is no tunnel is not wanted. Backlog 3.

### Done when
- Connected through an xray server, `kill -9` of the xray process: within 5 s Logs show the
  reconnect, and `curl https://api.ipify.org` prints the VPN's exit address again.
- An engine that keeps dying is retried after 2, 5, 10, 30 and 60 s, then every 60 s; Logs and the
  status line show the wait and the attempt, and Disconnect stops the retries.
- A tunnel that stays up for a minute starts the next failure from 2 s again.
- `sudo -n /usr/local/libexec/warpveil-<tag>/stop.sh` while connected (a SIGTERM, as another build of
  the same version sends): the app shows Disconnected and does not reconnect.
- Disconnect, quit and sleep never trigger the watchdog.
- A retry that finds no helper for this version (another build's install removed it) asks the
  password once; a cancelled dialog stops the retries, and Logs say so.

### Decided
- A watchdog only, no pf kill switch (owner, 2026-10-15).
- Always on, no setting (owner, 2026-10-15).
- Traffic goes direct for the seconds between the engine's death and the new tunnel — accepted
  (owner, 2026-10-15).

### Open for the owner
- A server that stops answering while its engine keeps running is not an engine death and is not
  caught. Default: not in this stage; noticing a dead server belongs with backlog 6 (auto-select).
- A retry that finds the helper gone installs it, as every connect does since plan 21 — a password
  dialog. Default: one dialog; cancelled, the retries stop and the app stays Disconnected.
- An engine stopped with SIGTERM — `stop.sh`, the sweeps in `install.sh` and `dev-run.sh`, another
  build of the same version taking the tunnel — is a deliberate stop. Default: no reconnect, or two
  copies would take the tunnel from each other forever.
- A connect that fails as it starts (a refused config, a taken port) is not a death of a working
  tunnel. Default: reported as today, no retries.

### Depends on
- Nothing missing today. The root scripts need no change; the update's own version bump asks the
  password once anyway, to install its helper.

### Risk
- A retry loop that never stops: guarded by the backoff's 60 s ceiling, by Disconnect cancelling it,
  and by the SIGTERM and missing-helper rules above.
- A retry racing the existing wake and IPv6 reconnects: they go through one restart path, so a newer
  restart replaces a pending one.

### Steps
1. **Reconnect after an engine dies.** Either engine dying under a working tunnel — the root sing-box
   or the user's xray — brings the tunnel back with the backoff above, and Logs and the status line
   say what is happening. Done when: every check above.

### Leaves out
- The pf kill switch, its setting and its LAN and DNS exceptions (owner, 2026-10-15).
- A setting for the watchdog or its timings.
- Health checks of a running engine (see Open).
- A notification when the tunnel drops: backlog 4.

### What we know (2026-10-15, checked 2026-10-25)
- An unexpected exit of the root helper logs `[Disconnected (exit N)]` and leaves the app
  disconnected; an xray that exits while connected logs `[xray exited (exit N)]` and disconnects
  (code: both termination handlers in the process manager). Both are errors, shown at the Logs
  page's default level (plan 22).
- Since 2026-10-23 an engine that ignores TERM is killed after 5 s — `stop.sh` and the next
  connect's `kill_pid_file` included — and a killed sing-box takes its routes with it (CLAUDE.md,
  Gotchas).
- Wake and a change of the host's IPv6 already reconnect through one delayed restart that replays the
  last connection (code: the process manager's restart path).
- How often engines die is unknown: the engine log is truncated at every connect, and the current
  session's log, two engine starts, has no `panic` or `fatal`.
- Builds of one version share PID files, so a second copy's connect stops the first one's engines
  (CLAUDE.md, dev-run.sh).
- The old plan's mechanism for both parts, written before the helper hardening (its script argv is
  gone): `git show 975f8b4:plans/client-feature-parity.md`, D2 and item 3.
