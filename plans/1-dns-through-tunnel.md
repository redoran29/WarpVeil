## 1. The router's DNS goes through the VPN; a DNS server the user runs keeps working
Owner, 2026-10-15: system DNS leaks past the VPN — for a typical user the resolver is the router, which
forwards every query to the ISP in the clear. No toggle: the app decides by itself. A DNS server someone
runs on purpose on the LAN (AdGuard, Pi-hole, a company DNS) keeps working. Backlog 1.

### Done when
- On a network whose DNS is the router (an iPhone hotspot), VPN on: the extended test on
  dnsleaktest.com lists only resolvers on the VPN side, and Logs show the engine answering the system's
  queries.
- At home, VPN on: the LAN filter still answers — `python3 -c 'import socket;
  print(socket.gethostbyname("doubleclick.net"))'` prints `0.0.0.0` — and Logs say its resolver was
  left alone.
- A bypassed domain is resolved by the system resolver, as today: Logs say so, and the site opens.
- Switching home Wi-Fi ↔ hotspot while connected: within 10 s Logs show one restart, and the checks
  above hold on the new network.

### Decided
- No setting and no toggle for DNS; the app decides at every connect (owner, 2026-10-15).
- A resolver that is the default gateway, or a public address, goes through the VPN. A resolver on
  another LAN host is left alone (owner, 2026-10-15).
- A filter built into the router itself (Keenetic, OpenWrt with AdGuard) stops filtering while the VPN
  is on — accepted with the rule above (owner, 2026-10-15).

### Open for the owner
- If macOS's resolver turns out to ignore a host route into the tunnel (the one thing only a live
  tunnel shows), the route mechanism cannot work; the alternative sets the system DNS from the root
  script — one more password prompt after the update, and a restore path for a crash. Default: the
  build stops at step 1's live check and brings it back to the owner.
- The owner's Mac lists a public resolver second, after the LAN filter. By the rule its queries go
  through the VPN, unfiltered. Default: the rule as it is; drop that second resolver from the Mac's
  DNS list if ads slip through.

### Depends on
- Nothing missing today. The passwordless scripts do not change, so no new password prompt.
- Backlog 3 (kill switch) builds on this: with DNS inside the tunnel, it needs no DNS exception.

### Risk
- A wrong route or rule breaks name resolution for the whole Mac while connected. Guarded by the live
  checks on both networks before it ships; the routes live with the TUN, so a crash leaves nothing
  behind on the system.
- Traffic to the router other than DNS (its admin page) must still reach it once its address is
  routed into the tunnel.

### Steps
1. **The router's DNS through the VPN.** Starts with a live check that macOS's resolver follows a
   host route into the TUN. Then, at connect, a gateway or public resolver is routed in and answered by
   the engine through the VPN, a resolver on another LAN host is left alone, bypassed domains keep the
   system resolver, and Logs name each decision. Done when: the first three checks above.
2. **Follow the network.** A change of the system's resolvers while connected (another Wi-Fi, a
   hotspot) restarts the engines once, so the new network's DNS follows the rule. Done when: the last
   check above.

### Leaves out
- A DNS upstream setting (the old plan's step 4): the owner wants fewer settings.
- Setting the system DNS with `networksetup`/`scutil` — only if the live check forces it, and only
  after the owner says so.
- Probing a resolver for ad filtering: rejected for the gateway rule (owner, 2026-10-15).
- A link-local IPv6 resolver (a router advertising `fe80::…`) cannot be routed; it stays outside the
  tunnel and is logged.
- A leak-check screen: backlog 14.

### What we know (2026-10-15)
- Both config builders put `hijack-dns` before `sniff`, where it never matches, so the engine's DNS
  module answers nothing from the system; it serves only as `default_domain_resolver`. Its `remote`
  server is DoT to 1.1.1.1 through the proxy (code: both builders).
- sing-box sets no system resolver on macOS, and `auto_route` installs eight sub-ranges, so a
  resolver inside the LAN subnet stays on its connected route to the physical interface. The route
  mechanism (the resolver carved out of its subnet with `route_exclude_address`) and the rejected
  alternatives were researched against sing-tun and the bundled binary on 2026-10-13:
  `git show 975f8b4:plans/client-feature-parity.md`, D4 and item 1.
- The owner's Mac, tunnel up (xray topology): resolver one is a LAN host other than the gateway that
  filters ads (`doubleclick.net` → `0.0.0.0`); resolver two is 1.1.1.1. The LAN resolver routes via
  `en0`, 1.1.1.1 via `utun`. Today's engine log: 284 flows to `1.1.1.1:53` proxied as plain UDP, none
  to the LAN resolver (configd, `route -n get`, `$TMPDIR/warpveil-1-2.log`).
- On 2026-10-13 the same Mac's resolver was the router, and every system query went to the ISP in the
  clear (the old plan, "This Mac").
