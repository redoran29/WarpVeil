## 4. The tunnel is up after login, and the app says when it stays down
Owner, 2026-10-15: the VPN should come up by itself when the owner logs in, with no new setting, and
the app should speak up when the tunnel is down and not coming back — not for drops the watchdog
fixes in seconds. Backlog 4.

### Done when
- Auto-connect on, log out and back in: WarpVeil is running with no window, the menu-bar icon shows
  the tunnel, `curl https://api.ipify.org` prints the VPN's exit address, and System Settings →
  General → Login Items lists WarpVeil.
- Auto-connect off: Login Items no longer lists WarpVeil, and a launch does not connect.
- After the update, with Auto-connect already on (the owner's Mac today), Login Items lists WarpVeil
  without the toggle being touched.
- WarpVeil removed from Login Items in System Settings: the toggle reads off.
- Connected, `sudo -n /usr/local/libexec/warpveil-<tag>/stop.sh` (the tunnel stops and is not
  restarted): one notification after a minute; clicking it opens the window. Disconnect by the user,
  quit, and a drop the watchdog fixes within the minute show none.

### Decided
- One control: Auto-connect becomes "connect at login" — on means a login item that connects as it
  starts. No separate launch-at-login toggle (owner, 2026-10-15).
- A notification only when the tunnel stays down: a minute without it, or the watchdog has given up,
  and the user did not disconnect. No setting for it (owner, 2026-10-15).

### Open for the owner
- Launched at login, the app opens no window, only the menu-bar icon. Default: yes; a launch by hand
  opens the window as today.
- macOS may ask to approve the login item. Default: the toggle's subtitle says so, with a button that
  opens Login Items.
- One notification per outage, however long it lasts. Default: yes.

### Depends on
- Plan 3 (watchdog): the "given up" signal. Not built yet; the one-minute rule works without it.
- Notification permission: macOS asks once, the first time one is due. Denied, the menu-bar icon is
  all there is.

### Risk
- A login item that connects before the network is up: the connect fails and the watchdog or the
  minute rule takes over. Guarded by the done-when login check.
- The dev build registers its own login item under its own bundle id, so a toggle in it adds a second
  WarpVeil to Login Items.

### Steps
1. **Connect at login.** Auto-connect on makes WarpVeil a login item that starts in the menu bar and
   connects; off removes it; the owner's current "on" carries over, and the toggle follows what
   System Settings says. Done when: the first four checks above.
2. **Say when the tunnel stays down.** A notification when the tunnel has been down for a minute, or
   the watchdog has given up, without the user disconnecting. Done when: the last check above.

### Leaves out
- A separate launch-at-login toggle, and a setting for notifications (owner, 2026-10-15).
- Notifications for drops the watchdog fixes.
- The old plan's "kill switch engaged" wording: there is no kill switch (plan 3).

### What we know (2026-10-15)
- Auto-connect today means "connect on app launch"; it is on on the owner's Mac (`autoConnect = 1`).
- WarpVeil is not among the owner's login items (System Events' list holds other VPN clients).
- Every launch opens the main window (code: the app delegate's launch path).
- The menu-bar icon already shows the state: a checked shield while connected, a crossed one when not.
- The old plan's design for both parts: `git show 975f8b4:plans/client-feature-parity.md`, item 4.
