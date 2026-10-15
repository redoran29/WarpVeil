## 19. Every server runs on xray; sing-box only holds the TUN
Owner, 2026-10-15: servers on Xray 26.7.11 and later refuse sing-box's REALITY, and the owner's
Chicago 1 is down in the app today. One proxy technology for every server — xray — with sing-box left
only as the root TUN layer in front of it, the way the xhttp servers already run. Backlog 19.

### Done when
- Chicago 1 and the RU relay to it connect: `curl https://api.ipify.org` prints their exit address,
  and Logs show xray starting.
- All eight of the owner's servers connect, each through xray, and ping shows a delay for each.
- After the update, the first feed refresh moves every stored server to xray and keeps the selection.
- Domain bypass works on a former sing-box server: a bypassed site sees the home address.
- A pasted sing-box JSON is refused with a message naming what to paste instead; a `vless://` or
  `vmess://` link and an xray JSON are taken.

### Decided
- xray carries every server; sing-box stays only as the TUN wrapper, and the single-process sing-box
  topology goes (owner, 2026-10-15).
- Dropping sing-box altogether waits for a stable Xray with macOS TUN routing: backlog 20 (owner,
  2026-10-15).

### Open for the owner
- Feeds are read as links first, then as `?format=xray`; `?format=singbox` is no longer asked for.
  Default: yes.
- A manual subscription holding a sing-box config from an older build. Default: it stays listed, and
  a connect says to re-add it as a link or an xray JSON. The owner has none.
- The bundled xray stays 26.3.27, the last stable release, which meets today's default
  `minClientVer` exactly. Default: bump it only when a server asks for more.

### Depends on
- Plan 18: with every server behind the wrapper, its server rule must take every shape — hostname,
  trojan, shadowsocks. Not built yet; build 18 first.
- Plan 11 carries its new schemes on xray, and tuic leaves it (xray has none).

### Risk
- Every connect takes the two-process path: a slightly longer start, and an xray that dies takes the
  tunnel down (plan 3's watchdog covers both engines).
- A link parameter the sing-box builder handled and the xray builder misses breaks that server:
  guarded by connecting all eight.

### Steps
1. **Every link on xray.** `vless://` and `vmess://` links build xray configs, feeds stop asking for the
   sing-box format, and stored servers move on the next refresh. Done when: the first four checks.
2. **Remove the sing-box proxy path.** The sing-box server builders, its feed parser and the
   single-process topology go; a pasted sing-box JSON is refused. Done when: the last check, and the
   app builds with no sing-box proxy code left.

### Leaves out
- xray's own TUN and the end of sing-box (backlog 20).
- tuic; converting a sing-box JSON into an xray one.

### What we know (2026-10-15)
- Xray `af7eb680` (in v26.7.11, 2026-07-11): REALITY servers default to `minClientVer: 26.3.27`.
  sing-box v1.14.3 writes 1.8.1 into the REALITY session ID (`common/tls/reality_client.go`), so such a
  server falls back to its camouflage target. SagerNet/sing-box#4520 (open): servers from v26.9.8 also
  require an `X25519MLKEM768` key share.
- Live, user space, bound to `en0`: Chicago 1 and the RU relay to it time out through the bundled
  sing-box 1.14.0 and answer 204 through the bundled xray 26.3.27 (0.9 s); New York - WARP answers
  through both.
- The owner's feed: five xhttp servers already on xray, three gRPC + REALITY servers on sing-box
  (Chicago 1, its RU relay, New York - WARP).
- A `vless://` link goes to xray only for xhttp/splithttp; the xray builder already handles ws, grpc,
  xhttp and tcp with REALITY and TLS. A `vmess://` link always builds a sing-box config (code: the
  subscription service's URI parsers and builders).
- Feeds are tried as links, then `?format=singbox`, then `?format=xray`; manual JSON is tried as
  sing-box first (same file).
- Xray 26.3.27 has a Hysteria 2 client (`infra/conf/hysteria.go`, version 2 only) and no tuic. Every
  Xray release after 26.3.27 is a prerelease (GitHub, 2026-10-15).

### Review (2026-10-15, round 1)
Built in `54e2aec` and `da8863f`. `/code-review 89fcdeb..9d857e6` findings for this plan, and what
was done:
- A sing-box server an earlier build stored could not be re-added (the duplicate check matched the
  dead row), and a feed's server got manual-config advice: the duplicate check skips sing-box rows,
  and a feed's row says to refresh the feed.
- Every link config bound an unused, unauthenticated HTTP proxy on 10809: gone.
- One server xray refuses at load took every ping row down: a refused merge is retried one xray per
  server, and sing-box gets only the tags xray actually serves.
- A panel's or pasted xray config ran as given — its own inbounds, routing to direct (which loops
  through the TUN), log files: every config now runs in the app's frame. A panel serving an array of
  configs is read, each named by `remarks`; a config with no readable server address is not listed.
- The sing-box binary was no longer checked before a connect: both engines are.
- The server-address lookup existed twice: the Servers list reads `BypassService.serverEndpoint`.

### Review (2026-10-15, round 2)
`/code-review 9d857e6..aa6718c`, findings for this plan, and what was done:
- A panel's freedom outbound the proxy dials through (`dialerProxy`, a fragment outbound) was
  dropped from the frame, so every dial failed: it comes along; ping measures without it
  (`8dcd815`).
- Manual configs stored by earlier builds never entered the frame: moved at load (`d8435cf`). That
  check found the subscriptions file rewritten on every launch — JSONEncoder's key order follows the
  hash seed — now written with sorted keys (`b65f8a8`).
- Re-adding a link over a feed's stale row made a manual twin the feed's refresh would duplicate:
  a feed's row still counts as a duplicate (`776b3ab`).
- `remarks` was ignored for a single config and shared by two servers in one: it names a config's
  server only when it holds one (`e96a734`).
- The ping fallback started per-server xrays one after another, kept a timed-out launch's ports,
  left a refused row blank and kept a stale error: started together, stopped when not ready, failed
  rows named in the error (`b0fdf16`).

### Review (2026-10-15, round 3)
`/code-review aa6718c..13a9177`, findings for this plan, and what was done:
- A `proxySettings` dialer reached the freedom sibling with the server's name, past the pin: it
  is rewritten into `sockopt.dialerProxy` in the frame (`d960c48`).
- The ping measured a server without its dialer, so a server that needs fragmentation read as
  dead: dialers come along under per-server tags (`def1e74`).
- The ping fallback was fixed a third time, so its shape changed: after a refused merge each
  server's config is checked with `xray run -test`, the refused ones are failed and named, and the
  merge runs again — no port race, no serial readiness waits, nothing marked failed on a cancel,
  no launch blamed that xray never saw (`bed1a58`).
- The sockopt edit existed three times: one helper (`d0b7ce6`).
- A reframed row kept its old address and transport (`03a76f9`); remarks counted servers that
  were not listed (`e8d6d02`).
- Owner, 2026-10-15: a feed's stale sing-box row still counts as a duplicate when its link is
  added again (round 2's rule kept; a dead feed is removed before its links are re-added).
- Not changed, measured: reframing runs at every load — 500 servers load in 20–34 ms with it.

### Review (2026-10-15, round 4)
`/code-review 13a9177..67366bc`, findings for this plan, and what was done:
- The ping deleted a dialer the frame does not carry and measured a direct dial for a server whose
  connect fails: the name stays (`fcdf38f`).
- The ping fallback's edges: -test only after the merge exited, one retry whatever the cause, a
  single or all-refused list marked and named, names in list order, -test awaited without holding a
  pool thread, no error from a cancelled run (`3fdd50e`).
- remarks applied after listing (`57ad388`); `hasTraffic`, which nothing read, removed (`c3dda5b`).
- From now on a canon change lands in the commit of the behaviour it describes (round 4 noted
  that round 3's landed later, in one docs commit).

### Review (2026-10-15, round 5)
`/code-review 67366bc..4120724`, findings for this plan, and what was done:
- The ping fallback was fixed a fourth time, so its shape changed (`7e63cb8`): an attempt returns
  how it ended and the error is set once, so a retry no longer leaves a stale error over a full
  list or loses its own reason; `-test` runs ten at a time, with the engines (a cancel kills it),
  stopped after 10 s, and only exit 23 counts as refused, so a test that could not launch or hung
  blames no one; refused servers are named with xray's reason, one line per reason; the retry
  waits three times as long.
- An engine's output was dropped whole on one invalid byte (`20761ae`).
- A blank `remarks` or outbound tag named a server blank (`02c773b`).
- Checked: a harness on the real `PingService` — 25 refused tests peak at 10 at once, a cancel
  during them leaves no process and no error, a hung test is killed at 10 s and blamed on no one;
  the owner's eight servers all measure (290–388 ms), and with a broken one added the eight still
  do and the broken one is named with its reason.
