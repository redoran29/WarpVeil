## 23. Blocked sites open with the VPN up
Owner, 2026-11-09: approved reversing the 2026-10-15 decision to keep system DNS outside the tunnel,
on the condition checked first: the network has to survive the app dying. Today a local resolver that
answers 127.0.0.1 for a blocked name defeats the VPN for every app on the machine.

### Done when
- With the VPN up, `https://www.instagram.com/` and `https://www.facebook.com/` load in a stock headless
  Chrome, with no Secure DNS, on a network whose resolver answers 127.0.0.1 for them.
- `getaddrinfo` for those names returns public addresses while connected, and the LAN resolver's answer
  again after a disconnect.
- SIGKILL, one at a time, of the app, the engine shell, sing-box, and whatever holds the resolver in place
  leaves `scutil --dns` as it was before the connect, within seconds, and name lookups working, with no reboot
  and no manual repair. App death is the owner's own condition, and today the engines outlive it.
- After each of those kills the app says what is true: no window reads Connected over the LAN resolver's
  answers, and the next connect, to a server given by name too, succeeds.
- With the current server dead, Ping all still answers for the live servers, the ones given by name included,
  and Auto moves off the dead one as it does today.
- A bypassed name's lookup is answered from outside the tunnel, seen in the engine log, and the site connects
  direct. `PrimaryInterface` stays physical and the host's IPv6 state does not change, so neither the ping's
  bind nor the IPv6 restart moves.
- Cold-cache page load, resolver cache and sing-box both fresh, is no worse than the baseline step 1 records by
  more than the spread between that baseline's own runs (github, cnn, youtube, 5 runs each, headless Chrome
  through the real tunnel, on a gRPC server). An xhttp server's load is recorded, not gated: it already varies
  from 10 s to a timeout with no change here.
- A resolver that fails to go in place does not read as Connected with blocked names still answered locally.

### Decided
- System DNS goes into the tunnel while connected (owner, 2026-11-09, reversing 2026-10-15).
- No setting for it (default, 2026-11-09; canon: few settings).
- A name in the bypass list resolves outside the tunnel, as its traffic does (default, 2026-11-09).
- If the experiment finds no resolver override that disappears with its holder, nothing ships and the plan
  goes back to the owner: the survival condition is not traded away (owner, 2026-11-09).
- A cold-load result past the gate in Done when goes to the owner with the numbers, rather than shipping or
  dropping it (default, 2026-11-09).

### Depends on
- The owner at the machine, with the password, for the experiment and for step 2: root is needed for each kill,
  and every edit of the engine shell, and each dev install, reinstalls the helper and asks again.
- A window in which the owner's tunnel may drop. Testing under a working owner already cost one interruption.

### Risk
- DNS left pointing at a dead resolver leaves the machine with no name resolution: the condition above, proved
  by killing each part. This is why the override must vanish with its holder rather than be cleaned up.
- Every lookup now pays a round trip to the US on a cold cache, where the LAN resolver answers in 2-30 ms, and
  waits behind an xhttp stall on those servers. Measured by the page-load line in Done when.
- While the tunnel is dead, the machine has no name resolution until it moves or disconnects, unless step 1
  finds that the system falls back; a fallback would bring the blocked answer back for that moment.
- Names only the LAN or a router knows stop resolving while connected, unless step 1 shows otherwise.

### Steps
1. **Experiment, no shipping.** With a root shell on the live machine, settle what puts a catch-all resolver in
   place through a temporary dynamic-store key, what answers it in the wrapper, what happens to a lookup while
   the tunnel is dead, how the app's own lookups (ping, connect) reach a resolver outside it, and that the
   override goes when each part in Done when is killed, the app's death with the real app as the parent: after
   the config is fed nothing on the root side is tied to it. Record the baseline and the result here; a failure ends
   the plan, and a change Auto would need goes to the owner first (canon, Auto).
2. **Tunnel-up DNS.** The engine shell puts the resolver in place only once its TUN is up, the wrapper answers
   it, and Done when holds on the real app.
3. **Canon and release.** The DNS gotchas and the decision are rewritten to what was built, the release says
   the first connect asks for the password once.

### Leaves out
- NetworkExtension: needs a paid Developer ID and is a rewrite of the engine path.
- A list of blocked domains: the resolver answers for everything.
- Rewriting the service's DNS through `networksetup` or a persistent `Setup:` key: it outlives a crash.

### Traps the code holds (2026-11-09)
- The wrapper's `hijack-dns` rule matches `protocol: dns` and sits before `sniff`, so it never fires today.
- `injectSingBox` puts the bypass rule right after the first unconditional `sniff`; the wrapper's rule order is
  what that insertion relies on.
- `run.sh` is byte-compared by the helper check: any change to the engine shell reads as not installed.
- A child started by the engine shell inherits its descriptors, sing-box included.
- The engine shell assumes one job: `cleanup` takes `jobs -p` as sing-box's PID, and it ends on a bare `wait`.
  A second background child breaks the stop and keeps the session up after sing-box dies.
- App death ends neither the shell nor sing-box: the canon's quit path and PID files leave them to the next
  connect, whose name lookup comes before the step that clears an orphan.
- `PingService` reads configd's `PrimaryInterface` for its bind, but a server's name in a ping still goes to the
  system resolver, inside the measured time. `hostIPv6State` assumes the TUN registers no configd service.
- The wrapper's only DNS server outside the tunnel is DoT to 8.8.8.8, it has no `dns.rules`, and `injectSingBox`
  edits route rules only.

### Measured / What we know (2026-11-09)
- Router answers 127.0.0.1 for www.instagram.com, www.facebook.com and static.xx.fbcdn.net: `dig @<router>`.
  Headless Chrome through the tunnel, www.instagram.com: ERR_CONNECTION_REFUSED, 6 of 6 loads.
- Chrome's Secure DNS with Cloudflare, in a throwaway profile through the tunnel: www.instagram.com and
  www.facebook.com load, where a stock profile is refused. A browser's own workaround, not the fix.
- The real address through the tunnel returns 200: `curl --resolve`.
- The owner's seven servers are all given by IP today, so blockers about names were read in the code, not seen
  on this machine: read from the stored configs.
- 8.8.8.8 and 1.1.1.1 asked over en0 return nothing for those names, and the right answer through the tunnel:
  `dig -b`. So a plain public resolver outside the tunnel does not solve it.
- `scutil` documents `add key ["temporary"]`: read in its own help. That such a key goes when its session does,
  and that a catch-all works from a non-primary service here, is not checked: step 1. Reports of the empty
  `SupplementalMatchDomains` entry as a catch-all: openfortivpn PR 1333 (Tahoe 26.3.1), WireGuard list 2021-11.
