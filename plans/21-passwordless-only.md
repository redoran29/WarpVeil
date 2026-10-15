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
- Nothing takes the install's dialog down: a disconnect ends the session at once and the install
  runs to its end; a quit and an update wait for it as for the engines (owner, 2026-10-15, on
  review round 3).
- An engine that ignores TERM: TERM only for now. At the 1.3 install, a `kill -9` on the root
  sing-box and `netstat -rn` decide it: if its routes go with the TUN, a KILL after 5 s goes into
  run.sh's cleanup and `kill_pid_file`, and the "a forced kill leaves its routes behind" rule is
  corrected; if they stay, the rule is confirmed (owner, 2026-10-15).

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

### Built (2026-10-15)
`54ffbb4`. Checked: run.sh's shell with a stand-in engine and `ifconfig` — the stop on TERM, a
TERM before the start, an engine that exits by itself, a second TERM inside cleanup, no staged
file or PID file left. Not run live: the install from a connect needs the owner's password — at
the 1.3 install.

### Review (2026-10-15, round 1 — round 7 of plan 17's series)
`/code-review f8548e4..feb5b12`, findings and what was done:
- A restart or a second connect during the install's dialog found the install busy and failed;
  a disconnect, a quit or an update left the dialog up: one shared install, ended by a disconnect
  (`35c6bd2`); its files staged in `$TMPDIR`, not `/private/tmp` (`e55321a`).
- A second TERM inside run.sh's cleanup skipped its EXIT trap, leaving the PID file and the staged
  config; the PID file's trap came after the file: one TERM, cleanup ignores more, trap first
  (`f526e1d`).
- Remove mid-session made the next restart ask for the password; the row went stale after another
  build's install (`c3dc6e0`).
- A log poll appended after the helper's exit had ended the session (`f2a511a`); connect carried
  the bundled sing-box's path for nothing (`a7b2047`); comments and canon still spoke of the removed
  mode (`46dda5e`).
- An engine that ignores TERM: taken to the owner, decided above — live at the 1.3 install.

### Review (2026-10-15, round 2)
`/code-review feb5b12..c8442db`, findings and what was done:
- The shared install was cleared by its first waiter and shared one process field with a
  removal (`bba657b`); a dialog a disconnect took down logged as a failure with exit 15
  (`c04df38`); the app deleted the staged scripts while a root shell could still be installing
  them (`2422035`).
- A quit between a restart's teardown and its connect skipped the disconnect, leaving a pending
  restart and an install's dialog behind the app (`5123f97`).
- A removal could run during a pending restart, and a connect during a removal read the helper as
  there (`6ccbac8`); the row stayed stale while the window was hidden (`434caa2`).
- A second Disconnect while the engine was stopping said nothing true, and a skipped restart gave
  advice that could not help (`72b1ee3`).
- Process slips, history kept: `c3dc6e0` and `35c6bd2` (round 1) and `6ccbac8` and `72b1ee3` (round 2)
  each bundled two findings.

### Review (2026-10-15, round 3)
`/code-review c8442db..bc7e458`. Most findings came from taking the install's dialog down — the
fifth change to that lifecycle: a root shell outliving osascript lost visudo to a closed pipe,
raced the next install's staged files, and left the helper's state read from a half copy. Taken to
the owner, decided above: nothing takes the dialog down, and a quit and an update wait for it
(`c82885b`, which also makes a quit during a pending start wait for xray again, drops the
unreachable busy guard and writes the staged list once). Also:
- A skipped restart always blamed the engine (`b04fa14`); a disconnect during a restart's stop read
  as if it did nothing (this commit's neighbour).
- A removal's dialog outliving a quit or an update: covered by the same wait.
