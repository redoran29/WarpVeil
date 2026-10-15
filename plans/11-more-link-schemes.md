## 11. Feeds and the Add field take ss, trojan and hysteria2 links
Owner, 2026-10-15: a feed understands only `vless://` and `vmess://` and silently drops every other
line, so a provider with a mixed list loses servers without a word. The owner's own feed is vless; this
is for the people the public build (backlog 17) brings, with other providers. Backlog 11.

### Done when
- A feed mixing `vless://`, `vmess://`, `ss://`, `trojan://` and `hysteria2://` (and `hy2://`) lines
  lists every server; a line no parser takes — `tuic://` among them — is counted in Logs with its
  scheme.
- Each new scheme pasted alone into Add becomes a server; several links pasted at once become one
  manual subscription "Pasted (N)".
- Each new scheme carries traffic: a local server for that protocol on localhost, a user-space xray
  client built from the parsed link, and `curl` through it succeeds. Ping shows a delay for the same
  server.
- The owner's vless feed lists the same eight servers as before.

### Decided
- Links only, in a feed and in the Add field; no Clash YAML and no QR import (owner, 2026-10-15).
- The new schemes run on xray, like every server after plan 19; tuic is not taken — xray has none
  (owner, 2026-10-15).

### Open for the owner
- Several links in one paste. Default: one manual subscription named "Pasted (N)".
- A link that duplicates a server already present. Default: refused, as for vless today.

### Depends on
- Every server on xray, and a server rule for trojan, shadowsocks and socks behind the wrapper —
  built and closed 2026-10-15 (plans 18 and 19, now in the canon).
- No live server of these protocols exists for the owner; the local-server check stands in for it.

### Risk
- A parser that misreads a field connects to the wrong place or not at all; guarded by the local
  end-to-end check per scheme.
- A feed refresh must not lose the owner's servers: the vless check above.

### Steps
1. **ss and trojan.** Both schemes parse in feeds and in Add, and carry traffic in the local check.
2. **hysteria2.** The same for the QUIC scheme.
3. **Several links at once, and no silent drops.** One paste of many links; skipped feed lines are
   counted in Logs.

### Leaves out
- Clash YAML subscriptions and QR import (owner, 2026-10-15).
- tuic (owner, 2026-10-15: xray has none).
- Other schemes (`socks://`, `wireguard://`, `anytls://`): only on request.

### What we know (2026-10-15)
- A feed's lines go through the vless and the vmess parser only; a comment in that loop says "Can add
  trojan://, ss:// etc. later" (code: the subscription service's URI feed path).
- The Add field takes one `vless://`/`vmess://` link or a subscription URL; manual JSON has its own
  field (code: the Servers page's add sheet).
- Xray 26.3.27 implements ss, trojan, vless, vmess and a Hysteria 2 client (`infra/conf/hysteria.go`,
  version 2 only), not tuic. The old plan said it had no hysteria2; that was wrong. Its parser design:
  `git show 975f8b4:plans/client-feature-parity.md`, item 11.
