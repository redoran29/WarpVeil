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
- A dead server that still pings best is reconnected to — a blink of the network does not move the
  tunnel off the fastest. Dead again within 5 minutes of that, the next best is taken; when it is the
  only one that answers, it is reconnected to after a 30 s pause (owner, 2026-10-30).
- Slow is three times the session's best probe, kept between 1.5 s and 4 s. A slow server that is
  still the fastest stays, and slow is not asked again for 10 minutes (owner, 2026-10-30).

### Open for the owner
- How the running server is watched. Default: an HTTPS request to the ping's test URL through xray's
  SOCKS port every 10 s, 5 s timeout, a new connection each time; after a failure the next one goes
  at once.
- What counts as dead. Default: two failed probes in a row.
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

### Built (2026-10-30)
- Step 1, live on the owner's Mac: Logs read `[Auto: measuring every server...]`, then
  `[Auto: 🇺🇸 New Jersey, 307 ms]`, the lowest ping of the eight; the status read
  "Auto → 🇺🇸 New Jersey" and the exit address moved off the hand-picked server's.
- Step 2, live: the session's xray frozen with `kill -STOP` — Logs read `stopped answering —
  measuring every server...`, then `still pings best — reconnecting to it` (only xray was frozen,
  the server pinged fine), and a probe through the new session answered 204 in 0.3 s. 44 s from
  the freeze to the new xray with a probe every 10 s; the confirming probe now goes at once.
- After round 2, live: the same freeze moved the tunnel to another server — the exit address went
  from New Jersey's to Chicago 1's, a probe answered 204 in 0.34 s — 34 s from the freeze to the new
  xray, 5 s of it the KILL a frozen xray needs. The slow path is not seen live.

### Review round 1 (2026-10-30)
- A run where every server failed still counted as fresh, so a connect within 10 minutes refused
  without measuring: a connect measures when nothing on record answered.
- "Slow" is one cold probe against 1.5 s, and a slow server that still pinged best was reconnected
  to — a loop on a distant link: a slow server is left only for another one, and when it is still
  the fastest the slow check rests 10 minutes. A dead one is reconnected to once; failing again
  within 5 minutes, the next best is taken.
- The watch read Auto from the selection, so Auto tapped while on a hand-picked server would leave
  it: the session keeps whether Auto started it, and the status names the session's server.
- The menu-bar menu read Disconnected during Auto's measurement and its Connect did nothing: it says
  Measuring… and offers Disconnect.
- The update hold was checked at the click only, so a pick that finished during a download started
  a session; an update's "was running" missed a pick: both fixed.
- Ping runs restarted each other — Auto's, the Servers page appearing, the launch: a run under way
  is waited for, not started over.

### Review round 2 (2026-10-30)
- Most findings sat in round 1's own additions — a retry marker kept across sessions that skipped a
  needed reconnect or left the user on a dead tunnel, and a slow-check rest lost at every restart.
  The shape changed instead of a third fix: a dead server goes to the fastest other one (itself
  only when alone), and slow is measured against the session's own best probe, which a stay raises —
  neither keeps state past the session.
- The measurement for a move could be a run started before the failure: a move starts a fresh one.
- A failed update brought back the selection, not the session it stopped: it restores the session.
- The session's server was recorded before the connect was accepted: a session already up is not
  replaced. The update hold is checked at the click as well, so Auto does not measure for nothing.
- The watch ran for hand-picked sessions to do nothing: it starts for Auto ones only. An interval
  over 720 h is capped rather than dropped to 24 h.

### Review round 3 (2026-10-30)
- It disagreed with rounds 1 and 2 on the same two points — rounds 1 and 3 against a dead server's
  reconnect loop or against landing on a slower server for good, round 2 against the state that
  bounded the loop; rounds 1, 2 and 3 against a fixed slow bar, a rest lost at restarts, and a
  relative bar that rose past the timeout. Taken to the owner instead of a fourth fix: both
  decisions above. The retry marker now clears at every connect, and falls back to the server
  itself when nothing else answers, which is what round 2 found wrong with it.
- The watch's wait ran on through sleep and read the server as dead at wake: it stops during sleep.
- A move landing during a stop rewrote the last connection with no restart to follow: a refused
  reconnect changes nothing, and the session's server is named only once one is accepted.
- A failed update resumed a server captured at the stop, maybe dropped by a refresh since, and
  then nothing came back: Auto picks again, a hand-picked one is looked up by its ID.
- A disconnect during a measurement left the ping's engines running three passes: a cancelled
  waiter takes the run with it.
- An update clicked within a restart's pending second finds no session to resume — as before this
  plan; not fixed here.

