## 18. An xray server given by hostname, or speaking trojan, shadowsocks or socks, connects without looping
Owner, 2026-10-15: in the xray topology the TUN wrapper sends xray's own connection to the VPN server
direct only when the server is an IP literal in `vnext`. A hostname server (the usual xhttp server
behind a CDN) and a trojan, shadowsocks or socks server get no such rule, so xray's connection loops
back into the tunnel and nothing connects. The owner's servers are all IP-literal vless, so nothing is
broken today; the public build (plan 17) brings servers that are not. Backlog 18.

### Done when
- An xray server whose address is a hostname connects, and `curl https://api.ipify.org` prints its
  exit address; the engine log shows xray dialing only the addresses the wrapper routes direct.
- An xray trojan or shadowsocks server given by IP connects the same way.
- The owner's eight IP-literal servers connect as before, and their wrapper rule is unchanged.
- A hostname that does not resolve: no connect, and Logs say which name failed.
- A wake or a network change re-resolves the name on the reconnect.

### Decided
- Nothing for the owner to decide: a fix of a connect that cannot work today.

### Open for the owner
- The mechanism. Default: the app resolves the server's name at connect, routes every address it got
  direct, and pins those addresses into xray's own DNS so xray dials nothing else — the old plan's
  choice. Not a process rule for xray: root can read the socket list today (plan 7), but if a macOS
  update takes that away the rule fails silently into this same loop, while plan 7 then only fails
  safe.
- A server reached through a hostname that is also an IPv6 address set. Default: every address of
  the answer, both families, is routed direct and pinned.

### Depends on
- Nothing missing today. No live hostname or trojan server exists for the owner; the checks run
  against a name that resolves to an owner server's address (a wildcard DNS service such as sslip.io)
  and against a local xray server for trojan and shadowsocks.

### Risk
- The connect waits for one name lookup; on a bad network that is up to the resolver's timeout.
- A CDN that moves the name mid-session keeps working: xray stays on the pinned addresses until the
  next reconnect.

### Steps
1. **Route xray's own connection direct for every server shape.** Hostname servers are resolved and
   pinned at connect; trojan, shadowsocks and socks servers get their address rule. Done when: every
   check above.

### Leaves out
- The sing-box topology: a sing-box engine routes its own dials and has no such loop.
- A process rule for xray (see Open).
- Moving off a server whose name stops resolving while connected.

### What we know (2026-10-15)
- The wrapper's server rule reads the address from `settings.vnext[0]` only and is an `ip_cidr` for an
  IP literal, a `domain_suffix` for a name — which never matches, because the connection arrives as an
  IP (code: the process manager's server-address extraction and the wrapper builder).
- System DNS stays outside the tunnel (CLAUDE.md, Gotchas), so xray's own name lookups never loop; the
  loop is the server connection alone.
- The old plan compared three mechanisms and verified the pinning end to end in user space (xray
  `dns.hosts` plus `sockopt.domainStrategy: UseIP` dialed the pinned address and kept the SNI):
  `git show 975f8b4:plans/xray-hostname-server.md`.

### Review (2026-10-15, round 1)
Built in `f695e0c`. `/code-review 89fcdeb..9d857e6` findings for this plan, and what was done:
- The lookup ran before the session started, so Disconnect could not cancel it, a routing edit made
  during it was lost, and a wake during it restarted the previous server: the lookup now runs inside
  the session, after `lastConnection` and `isRunning` are set.
- A failed lookup after a wake or a network change ended the session for good: retried every 2 s for
  half a minute while the session is not cancelled.
- `UseIP` dials by name through the system resolver when the pin misses, which can loop: now
  `ForceIP`. Racing several pinned addresses (`happyEyeballs`) was tried and dropped — the TUN
  completes every TCP handshake itself, so a dead address won every race (canon, Gotchas).
- A bracketed IPv6 literal was taken for a name, and a scoped `fe80::…%en0` answer made an invalid
  `ip_cidr`: literals are checked without brackets, scoped answers dropped.
- A config with no readable server address connected with no server rule and looped: refused.
- **Open for the owner:** a hostname server behind a CDN puts the CDN's edge addresses into the
  direct rule, so other sites on those addresses leave outside the VPN. Kept as built until the
  owner picks between the address rule, an address-and-process rule for xray, or binding xray's
  dials to the physical interface.

### Review (2026-10-15, round 2)
`/code-review 9d857e6..aa6718c`, findings for this plan, and what was done:
- Owner, 2026-10-15, on round 1's open item: a server given by name gets a wrapper rule that needs
  both the address and xray's process path (`dde00d3`); an IP-literal server keeps the address rule.
- ForceIP does not fail a pin miss — xray resolves it through its localhost DNS client — and xray
  strips a trailing dot before the lookup: the pin is written under every spelling (`daefe55`).
- A server address written flat in `settings` was not read (`430f3b8`).
- The TUN's IP families were read after the lookup, so the IPv6 watcher compared with a stale value
  during it (`3f1bb67`).
- The lookup's retries were bounded by count, so a slow resolver held the session for minutes
  (`ed1e1a3`).
- The passwordless install was read before the lookup and used after it (`615d7e5`).
- The window and the menu showed Connected while the name resolved, and the location checks ran
  before the tunnel existed: Connected now means the root helper runs (`2d76c09`).
- The reviewer noted that `fed9fbd` and `4acd038` each bundle several fixes; history is public and
  stays as it is, and this round's fixes are one commit each.

### Review (2026-10-15, round 3)
`/code-review aa6718c..13a9177`, findings for this plan, and what was done. Two places were fixed a
third time, so their shape changed instead of a fourth patch:
- Connected followed the helper's launch, which without passwordless is a password dialog: the
  tunnel now counts as up when the engine shell's own `[sing-box] started` line reaches the log
  (`1360a72`; run.sh is byte-for-byte unchanged), and one observer drives the uptime, the speed
  monitor and the location polling (`7a70cb1`).
- The rule's process path was the unresolved bundle path, while the kernel reports the real one
  (`f9bff73`).
- Not changed, recorded: the process rule makes sing-box look up the owning process of every TUN
  connection while a hostname server is connected — the cost of the owner's choice in round 2; the
  socket list is cached 200 ms.

### Review (2026-10-15, round 4)
`/code-review 13a9177..67366bc`, findings for this plan, and what was done:
- `URL.resolvingSymlinksInPath()` strips `/private`, so the process rule missed an app run from App
  Translocation (a regression from round 3): `realpath(3)` (`abe1dc2`).
- Connected was fixed a fourth time in shape: the start line is printed right after sing-box is
  backgrounded, before the TUN exists, so the TUN's address on an interface is now required too
  (`221c7be`), and a log chunk with an invalid byte no longer drops the line (`8a54c99`).

### Review (2026-10-15, round 5)
`/code-review 67366bc..4120724`, findings for this plan, and what was done:
- Connected took the TUN's address on any interface, so a tunnel another build or client already
  holds at 172.19.0.1 read as ours until our sing-box failed. Owner, 2026-10-15: the engine shell
  prints its start line only once a utun it did not find at the start carries the address — a
  run.sh change, which re-asks the password, so it lands with 1.3's version bump, which re-asks it
  anyway (plan 17).
- A log read could end inside a line or a character, and a start line cut in two left the session
  at Connecting: only complete lines are taken (`f80f8dd`).
- The final-read comment sat on `checkTunnel` (`61e5a78`).
- Live, on the installed `7e63cb8`: the menu reads Connected; on `4120724`, Chicago 1 with a
  bypassed domain, and a server given by an sslip.io name with the process rule.
