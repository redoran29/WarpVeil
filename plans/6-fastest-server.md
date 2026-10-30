## 6. "Auto": the fastest server at connect, and a move off one that degrades
Owner, 2026-10-15: instead of choosing a server by hand, the owner can choose "Fastest", and every
connect takes the server with the lowest ping at that moment.
Owner, 2026-10-30: in the office the tunnel keeps dying and the owner walks the list by hand for a
server that is alive. "Auto" also watches the server it runs on and, when it stops answering or turns
slow, reconnects to a faster one by itself. Backlog 6.

### Done when
- The Servers page has an "Auto" row above the subscriptions, selectable like a server, with the
  server it would pick and its ping as a subtitle; the choice survives a relaunch.
- "Auto" selected, connect: Logs name the chosen server, the status line shows "Auto → <name>", and
  it is the row with the lowest ping on the Servers page.
- Measurements older than 10 minutes, or none: the connect pings first, Logs say so, then it
  connects; fresher ones are used as they are.
- Every server failing its ping: the app stays disconnected and Logs say no server answered.
- Connected on "Auto", the running server stops answering (its xray's port blocked, or the server
  down): within 30 s Logs say it degraded, every server is pinged, and the tunnel reconnects to the
  fastest one; `curl https://api.ipify.org` prints that server's exit address.
- Connected on "Auto", nothing degrades: no reconnect, the exit address stays the same.
- Degraded, but no server answers the ping (the office network itself is down): the tunnel stays on
  its server and Logs say so; the watch goes on.
- A server chosen by hand is never left, whatever its probes say.
- Wake and an IPv6 change reconnect to the same server.

### Decided
- The balancer works only with "Auto" selected; a server chosen by hand stays (owner, 2026-10-30).
- A move is a reconnect to one other server — the exit address changes only then, at the price of a
  few seconds without the tunnel. Not xray's own balancer, which spreads connections over servers
  with close pings, so sites see the exit address hop (owner, 2026-10-30).
- Replaces the 2026-10-15 decision "Fastest is picked at connect only; no switching away from a
  server that dies later" (owner, 2026-10-30).

### Open for the owner
- How the running server is watched. Default: an HTTPS request to the ping's test URL through xray's
  SOCKS port every 10 s, 5 s timeout, a new connection each time.
- What counts as degraded. Default: two failed probes in a row, or three in a row slower than 1.5 s.
- Degraded, and the running server pings best anyway. Default: reconnect to it — the session, not the
  server, is what broke.
- How fresh a measurement must be at connect. Default: 10 minutes.
- Ties. Default: the first in the list.

### Depends on
- Nothing missing today: ping already measures every server, with the tunnel up or down, bound to the
  physical interface.
- Plan 9 (tap to switch) can reuse the move's reconnect to another server.

### Risk
- A server that flaps would be left and maybe come back: each move starts the watch from zero, so a
  move happens at most once per ~20 s of failed probes.
- A connect that waits for a measurement starts a few seconds later; auto-connect at login waits too.
- Ping is latency from this Mac, not throughput: the "fastest" can be a server with less bandwidth.
- The seconds of a move go direct, as any reconnect does (plan 3's accepted gap).

### Steps
1. **Auto at connect.** An "Auto" row on the Servers page; a connect with it selected takes the
   lowest ping, measuring first when the results are stale. Done when: the first four checks above.
2. **Move off a degraded server.** Connected on "Auto", the running server is probed, and a degraded
   one is left for the fastest. Done when: the rest of the checks above.

### Leaves out
- A move off a server chosen by hand (owner, 2026-10-30).
- Moving to a faster server while the running one is fine: only degradation moves the tunnel.
- xray's built-in balancer and observatory (owner, 2026-10-30).
- Throughput tests, and weighing load or location.
- A setting for the probe, the thresholds or the freshness window (CLAUDE.md, few settings).
- A dying engine: plan 3.

### What we know (2026-10-15, checked 2026-10-30)
- Ping results live per server ID and keep the best of three passes; a run measures every server at
  once through user-space engines (code: the ping service; CLAUDE.md, "Ping is a user-space
  measurement").
- The owner has one subscription with nine servers (2026-10-25; eight on 2026-10-15).
- The restart path replays the last connection's config, so a move needs a reconnect that carries a
  new one (code: the process manager's restart; plan 9).
- A probe through xray's SOCKS port while connected: HTTPS to the test URL answers 204 in 0.34–0.42 s
  (2026-10-30, the owner's office).
- The old plan's design: `git show 975f8b4:plans/client-feature-parity.md`, item 6.
