## 9. Choosing another server while connected moves the tunnel to it
Owner, 2026-10-15: today a tap on a server while connected changes only the selection — the power
button names the new server while the tunnel still runs the old one. A tap should move the tunnel.
Backlog 9.

### Done when
- Connected, a tap on another server: within 5 s Logs show the reconnect, the status names the new
  server, and `curl https://api.ipify.org` prints the new server's exit address.
- Three taps on different servers within two seconds: one reconnect, to the last one tapped.
- A tap on the server already in use: nothing happens.
- Disconnected, a tap only selects, as today.
- Works between a server given by an address and one given by a name, in both directions.

### Decided
- Only the tap in the window; the menu-bar menu gets no server list (owner, 2026-10-15).

### Open for the owner
- The pause that merges a burst of taps. Default: 2 s, as for routing changes.

### Depends on
- Nothing missing today. Plan 6's "Fastest" row, if built first, switches the same way.

### Risk
- A switch racing a wake, watchdog or IPv6 restart: a restart replays the last connection, so a
  switch must replace it, not be replaced by it. Guarded by the done-when checks and by the
  existing rule that a connect waits for a running stop.

### Steps
1. **Tap to switch.** A tap on another server while connected reconnects to it after the pause.
   Done when: every check above.

### Leaves out
- A server submenu in the menu-bar menu (owner, 2026-10-15).
- Keeping the old tunnel up until the new one is ready: one tunnel at a time (CLAUDE.md, dev-run.sh).

### What we know (2026-10-15)
- The server rows set the selection and nothing else (code: the Servers page's tap handler); the
  selection is an observable on the app state, persisted on write.
- The restart path replays the last connection's config, so it cannot carry a new server (code: the
  process manager's restart). A connect parked behind a stopping xray starts from the last connection
  as well (code: connect's xray wait, 2026-10-16).
- The old plan's design: `git show 975f8b4:plans/client-feature-parity.md`, item 9.
