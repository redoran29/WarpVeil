## 5. Subscriptions refresh by themselves and show their limits
Owner, 2026-10-15: subscriptions are fetched only at launch, so an app that runs for days keeps a
stale server list. They should refresh on the interval the feed asks for, with no setting, and show
traffic and expiry when the feed has a limit or an end date. Backlog 5.

### Done when
- A feed that sends `profile-update-interval: 12` is fetched again 12 h after its last refresh while
  the app keeps running; a feed with no such header after 24 h; Logs show each refresh.
- A feed with a limit or an end date shows a line under its name on the Servers page — used of total,
  and the date — red under 5 % left or past the date. The owner's feed (unlimited, no end date) shows
  no line.
- A refresh while connected keeps the tunnel up and the selected server selected.
- A feed that stops sending its headers loses the line on the next refresh.

### Decided
- The interval is the feed's `profile-update-interval`, 24 h when it sends none; no setting
  (owner, 2026-10-15).
- Traffic and expiry are shown only when the feed has a limit or an end date (owner, 2026-10-15).

### Open for the owner
- A refresh that changes the config of the server the tunnel runs on does not reconnect. Default: the
  new config applies on the next connect, as after a manual refresh today.
- A Mac asleep past the interval. Default: the refresh runs on the first check after wake.

### Depends on
- Nothing missing today.

### Risk
- A feed that sends a tiny interval (`1`) would be fetched every hour. Guarded by nothing more than the
  feed's own word; an hour is harmless.
- A refresh failing (feed down) leaves the previous servers, as today.

### Steps
1. **Refresh on the feed's interval.** A running app refetches each subscription when its interval has
   passed. Done when: the first and third checks above.
2. **Show limits.** The Servers page shows used of total and the end date for a feed that has either.
   Done when: the second and fourth checks above.

### Leaves out
- A refresh-interval picker, and a refresh setting of any kind (owner, 2026-10-15).
- The feed's `profile-title`, `profile-web-page-url` and `support-url`, though the owner's feed sends
  them.
- Reconnecting when a refresh changes the running server.

### What we know (2026-10-15)
- Feeds are refreshed at launch only, all at once (code: the bootstrap's `refreshAll`).
- A refresh keeps the IDs of servers that are still there, so the selection survives it (code: the
  subscription service's `store`).
- The owner's feed sends `profile-update-interval: 12` and `subscription-userinfo` with `total=0` and
  `expire=0` — unlimited, no end date — plus `profile-title`, `profile-web-page-url`, `support-url`
  (one fetch of the feed on 2026-10-15).
- The old plan's design: `git show 975f8b4:plans/client-feature-parity.md`, item 5.
