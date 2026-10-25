## 6. "Fastest server": the connect picks the server with the lowest ping
Owner, 2026-10-15: instead of choosing a server by hand, the owner can choose "Fastest", and every
connect takes the server with the lowest ping at that moment. A server that dies after the connect is
not this stage's business. Backlog 6.

### Done when
- The Servers page has a "Fastest server" row above the subscriptions, selectable like a server, with
  the server it would pick and its ping as a subtitle; the choice survives a relaunch.
- "Fastest" selected, connect: Logs name the chosen server, the status line shows "Fastest → <name>",
  and it is the row with the lowest ping on the Servers page.
- Measurements older than 10 minutes, or none: the connect pings first, the status line says
  "Measuring…", then connects; fresher ones are used as they are.
- Every server failing its ping: the app stays disconnected and Logs say no server answered.
- Wake, the watchdog and an IPv6 change reconnect to the same server; only a new connect picks again.

### Decided
- "Fastest" is picked at connect only; no switching away from a server that dies later (owner,
  2026-10-15).

### Open for the owner
- How fresh a measurement must be. Default: 10 minutes.
- Ties. Default: the first in the list.

### Depends on
- Nothing missing today: ping already measures every server, with the tunnel up or down.
- Plan 3 (watchdog) reconnects to the same server — consistent with the above, whichever ships first.

### Risk
- A connect that waits for a measurement starts a few seconds later; auto-connect at login waits too.
- Ping is latency from this Mac, not throughput: the "fastest" can be a server with less bandwidth.

### Steps
1. **The Fastest choice.** A "Fastest server" row on the Servers page; a connect with it selected
   takes the lowest ping, measuring first when the results are stale. Done when: every check above.

### Leaves out
- Moving off a server that stops answering while connected (owner, 2026-10-15).
- Throughput tests, and weighing load or location.
- A setting for the freshness window.

### What we know (2026-10-15)
- Ping results live per server ID and keep the best of three passes; a run measures every server at
  once through user-space engines (code: the ping service; CLAUDE.md, "Ping is a user-space
  measurement").
- The owner has one subscription with nine servers (2026-10-25; eight on 2026-10-15).
- The old plan's design: `git show 975f8b4:plans/client-feature-parity.md`, item 6.
