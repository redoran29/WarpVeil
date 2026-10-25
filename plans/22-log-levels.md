## 22. Logs show what the app did, with connection traffic one level down
Owner, 2026-10-25: Logs is useless — nothing can be found there. The tunnel's engines write a line
per connection, and the app's own lines (a restart, the helper, an error) are pushed out of the 500
kept within a minute. App events are to be kept apart from engine traffic, with several levels, and
by default only the important ones shown. Backlog 22.

### Done when
- Connected, two minutes of browsing: at the default level Logs still shows the connect's lines from
  its first one, and none of the per-connection lines.
- Everything shows the per-connection lines of xray and sing-box as today.
- Errors shows a refused connect — port 10808 taken by `nc -l 10808`, then Connect — and none of the
  lines of a connect that went through.
- A bypass toggle that restarts the tunnel, and a cancelled helper install, each leave their line at
  the default level after ten minutes of traffic (plan 21's last two live checks).
- Copy copies the lines the chosen level shows.

### Decided
- Levels are a filter on the Logs page; the engines keep writing at info and the tunnel is never
  restarted for a level (owner, 2026-10-25).
- Three levels: Errors — errors of the app and the engines; Events, the default — every app line and
  the engines' warnings and errors; Everything — plus the engines' connection traffic (owner,
  2026-10-25).
- App events are kept apart from engine traffic, so traffic never pushes them out (owner,
  2026-10-25).
- Lands in 1.3, before plan 21 closes (owner, 2026-10-25).

### Open for the owner
- The level across launches. Default: every launch opens on Events.
- What an engine line with no level of its own is — a crash trace, a start failure, a line from
  run.sh. Default: an event, so nothing an engine says outside its info traffic is hidden by default.
- How much is kept. Default: the last 500 of each buffer — the app's lines, the engines' other lines,
  the engines' traffic.

### Steps
1. **Levels on the Logs page.** App lines and engine lines are kept apart, every line carries its
   level, and the page shows Errors, Events or Everything; done when every check above holds.

### Leaves out
- A search field, an export to a file, a log kept on disk across launches.
- A setting for the engines' own log level; a separate page per engine.

### Built (2026-10-25)
`f6bfee1`, then `7cd9fb2` and `3993fa3` from the review below. Checked live on the 1.3 install with
`curl` traffic: Events shows the app's lines and xray's warnings and no connection line, Everything
shows both engines' traffic without sing-box's colour codes, Errors shows only the refused connect
of a taken port 10808. The classifier over 1572 lines of a live log: 1566 traffic, 6 events. Open:
the restart and the cancelled install at the default level after ten minutes (needs the owner).

### Review (2026-10-25, round 1)
`/code-review f6bfee1`, findings and what was done:
- Splitting engine lines by level left a run of failed connections (sing-box ERROR per connection)
  or a crash trace pushing the app's lines out: three buffers by source (`3993fa3`).
- A regex built per line, three per engine line on the main actor; Everything sorted 1,200 lines on
  every tick; an unused ordering of levels; a closure per app line; the canon's "500 rows": prefix
  checks, one strip per read, a one-pass merge, and the canon and comments say up to 1,800
  (`3993fa3`).
- A skipped restart and a cancelled install were events, invisible at Errors (`7cd9fb2`).
- Not changed: sing-box's session INFO lines (default interface, the utun taken) count as traffic
  and show only at Everything; Errors has no buffer of its own beyond the app's 500 lines.

### What we know (2026-10-25)
- The tunnel's xray runs at `loglevel: info` with the access log on, the TUN wrapper's sing-box at
  `level: info`; the ping's engines already run at warning (the code).
- App and engine lines share one array of 500, newest first; app lines are written as `[...]`,
  xray's carry `[Info]`/`[Warning]`/`[Error]`, sing-box's `INFO`/`WARN`/`ERROR` (the code and a live
  log of 1.3).
