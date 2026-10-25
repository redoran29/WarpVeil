## 7. Chosen apps bypass the VPN
Owner, 2026-10-15: like domain bypass, but for apps — the apps on the list go direct, everything else
goes through the VPN. One list, no modes (routing modes were dropped). Backlog 7.

### Done when
- Safari added to the list, VPN on: `https://api.ipify.org` opened in Safari shows the home address,
  in Chrome the VPN's exit address; the engine log shows Safari matched by its path.
- The same check holds for a server given by an address and one given by a name (whose wrapper
  rule already reads xray's process path).
- Safari removed from the list: after the reconnect, Safari shows the VPN's exit address again.
- The bypass toggle off: apps on the list go through the VPN like everything else.
- An app moved or deleted after it was added: its row says it is not found, and the connect goes on.

### Decided
- One list, "go direct"; no "only these through the VPN" list (owner, 2026-10-15).
- The list lives on the Routing page under the bypass toggle that already governs domains — no new
  toggle (owner, 2026-10-15, with "fewer toggles").

### Open for the owner
- Apps are added with a file picker opened at `/Applications`, and the rule covers every executable
  inside the bundle (helpers, XPC services). Default: yes.
- A change to the list reconnects after the same 2 s pause as a domain change. Default: yes.

### Depends on
- Process matching works only in the root engine: on this macOS the socket list it reads is empty for
  a user process and full for root (measured below). Every server routes in the root sing-box
  wrapper (one topology since plan 19), so nothing is missing today.

### Risk
- Traffic an app hands to a system daemon (background downloads through `nsurlsessiond`, App Store)
  cannot be attributed to the app and goes through the VPN; the section's footer says so.
- With a non-empty list the engine looks up the process of every new connection (a ~600 KB sysctl
  snapshot, cached 200 ms). Guarded by adding the rule only when the list is not empty; Done when is
  checked with a normal browsing load.
- A wrong rule position would send everything direct or nothing; guarded by the browser check for
  both kinds of server.

### Steps
1. **App bypass.** An "Apps" section under the bypass toggle with "Add app…"; listed apps go direct.
   Done when: every check above.

### Leaves out
- An "only these apps through the VPN" list, and any routing mode (owner, 2026-10-15).
- App icons in the list.
- Per-app rules for command-line tools outside an app bundle.

### What we know (2026-10-15)
- `net.inet.tcp.pcblist_n` read by a plain C program: 48 bytes (header only) as the user, 548 KB
  as root — macOS 27 serves the socket list to root without the entitlement `netstat` carries.
  sing-box's process rules read exactly this sysctl (`git show 975f8b4:plans/xray-hostname-server.md`,
  "Engine facts").
- sing-box matches a TCP connection to its socket on the exact local and remote address and port; a
  TUN connection's local address is the TUN's own (same source).
- The owner's domain bypass list holds one domain, left from plan 22's restart check (2026-10-25).
- A server given by name already has a process rule in the wrapper — xray's path and its addresses,
  a `logical` and — so sing-box looks up every TUN connection's process while one is connected
  (CLAUDE.md, Architecture); app bypass adds rules of the same kind.
- The old plan's design: `git show 975f8b4:plans/client-feature-parity.md`, item 7.
