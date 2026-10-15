## 13. The speed panel counts each byte once
Owner, 2026-10-15: the upload and download speeds add up every network interface, so tunnel traffic is
counted on the TUN, on loopback (the hop to xray) and on the physical interface, plus virtual-machine
bridges. The numbers should be the Mac's real internet speed. No traffic chart. Backlog 13 (and 12,
dropped).

### Done when
- Connected through an xray server, `curl -o /dev/null` of a 100 MB file: the download speed shown
  while it runs is within 15 % of the speed curl reports, as is Activity Monitor's Network tab.
- The same check on a sing-box server and with the VPN off.
- Wi-Fi switched to Ethernet (or a hotspot) while the app runs: the speeds follow the new interface.

### Decided
- The speed is the physical interface's — what the Mac's internet link carries, bypassed traffic and
  the VPN's overhead included (owner, 2026-10-15).
- No traffic chart (owner, 2026-10-15; backlog 12 dropped).

### Open for the owner
- The physical interface is configd's primary one, the one ping already binds to. Default: yes.

### Depends on
- Nothing missing today.

### Risk
- A primary interface that changes between two samples gives one wrong reading; the next tick is
  right again.

### Steps
1. **Count one interface.** The speeds come from the primary physical interface only. Done when:
   every check above.

### Leaves out
- A traffic chart (owner, 2026-10-15).
- Per-app or per-route traffic figures.

### What we know (2026-10-15)
- The monitor sums the byte counters of every link-level interface (code: the network monitor's byte
  reader, `AF_LINK` in `getifaddrs`).
- During a 20 MB download through the xray topology, the interfaces it sums received 178 MB: `en0`
  31 MB, `lo0` 30 MB, `utun4` 118 MB, with other traffic running at the same time (`netstat -ibn`
  before and after).
- configd's `PrimaryInterface` stays the physical one while the TUN is up (CLAUDE.md, ping).
