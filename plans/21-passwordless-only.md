## 21. The engine always runs through the passwordless helper; the first connect installs it
Owner, 2026-10-15: review rounds 3–6 of plan 17 kept finding cases in the mode without passwordless —
a password dialog in the middle of a session, a root shell no signal from the app reaches, a session
file to watch, a session stuck at Connecting. With the helper, a stop is a TERM to sudo and none of
that exists. One mode: the first connect installs the helper with one password; lands before 1.3.

### Done when
- With no helper for this version, Connect asks for the password once, installs it and connects;
  later connects, disconnects, restarts, quits and updates ask nothing.
- The install's dialog cancelled: no connect, and Logs say the helper is needed to connect.
- A Disconnect or a quit during the install's dialog starts no engine, whatever the dialog's answer.
- Advanced shows whether the helper is installed, with Remove; after Remove the next connect
  installs it again.
- The osascript engine path, its session file and its canon are gone; `stop.sh` stays for
  `install.sh` and an engine a crash orphaned.

### Decided
- Only the passwordless helper; no mode that runs the engine through osascript (owner, 2026-10-15).

### Open for the owner
- What Advanced keeps. Default: one row — the helper installed or not, with Remove — instead of the
  toggle; installing is the connect's job.
- A version bump. Default: its first connect asks once, to install the new version's helper (plan
  17's two prompts become one).

### Depends on
- Plan 17's engine shell, which stops its sing-box on TERM — built.

### Risk
- Every user gets a NOPASSWD sudoers entry for the two root-owned scripts. Guarded as today: exact
  paths, root's own copy of sing-box, the config policy — the canon's "Passwordless mode".

### Steps
1. **Connect installs the helper; the osascript path goes.** Done when: every check above.

### Leaves out
- An uninstaller beyond Remove; a launchd or SMAppService helper.
