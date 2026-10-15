# Changelog

Each `## <version>` section is what `release.sh` publishes as that release's notes.

## 1.3

- **Updates itself.** The app checks GitHub releases once a day and installs only a release signed with the project's key: Advanced → Updates, or "Update to …" in the menu-bar menu. This is the last version to install by hand.
- **Every server runs on xray.** Servers on Xray 26.7.11 and later refuse sing-box's REALITY client, so sing-box now only holds the tunnel. `vless://` and `vmess://` links, a panel's xray configs and a pasted xray JSON are taken; a pasted sing-box JSON is not.
- **Servers given by a hostname, and trojan, shadowsocks and socks servers, connect.** The name is resolved when you connect, and xray dials only the addresses the tunnel sends direct.
- **Passwordless mode is hardened.** In 1.2 the passwordless helper took the program it ran as root from its caller, so any program running as you could run anything as root. Now root runs only its own copy of sing-box, on a config it has checked, and xray runs as you. After updating, the first connect asks for your password, and Passwordless has to be turned on again in Advanced, which asks once more.
- **A window.** Servers, Routing, Advanced and Logs in three columns, with the connection panel on the right; the menu-bar item keeps the status, connect/disconnect and Open WarpVeil.
- **Server ping**: the real delay through each server, measured by the bundled engines, also while connected.
- **Routing**: bypass rules match again, domains are normalized as they are entered, a whole TLD is written `.ru`, and the tunnel's IPv6 follows your network's.
- **Reconnects** after sleep and when the network gains or loses IPv6; a routing change applies at once.
- Servers keep their identity across subscription refreshes, so the selected one stays selected.
- Requires macOS 15 or newer on Apple Silicon.
