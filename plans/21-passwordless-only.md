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
- The install's staged files are removed by its root shell when it ends, whatever the outcome; the
  app removes them only where no root shell ran (owner, 2026-10-15, on review round 5).
- The review loop: after round 5's fixes, one control round, fixing from it only what breaks a
  real scenario — a lost tunnel, a leak, a hang — and recording the rest; then the live checks at
  the 1.3 install (owner, 2026-10-15).
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
  as if it did nothing (`93beae4`).
- A removal's dialog outliving a quit or an update: covered by the same wait.

### Review (2026-10-15, round 4)
`/code-review bc7e458..051e63e`, findings and what was done:
- Folding the helper's dialog into the wait every caller shares made a restart give up on the
  install after 30 s and re-ask after a cancel: a restart waits for the session only and its
  connect joins the install; a quit and an update still wait for the dialog; what blocks is named
  in one place (`d1f1ad1`), and the update's failure names it too (`c5dbde3`).
- A connect could start during a quit's wait: the update's hold is now a general one with its
  reason, set by a quit too (`fc9d643`).
- The staged scripts lost their guard against a root shell still reading them (`eb130e0`).
- The install's and the removal's failures say why, not osascript's uninformative exit 1
  (`f599236`); a comment listed what `isTornDown` checks (`b8ccf82`).
- Not changed: a quit that outwaits its 30 s leaves a helper dialog behind, like an engine; answered
  late, it can undo a newer install, and the next connect asks again.
- Process slip: `c82885b` bundled the dialog decision with four smaller changes.

### Review (2026-10-15, round 5)
`/code-review 051e63e..1691509`, findings and what was done:
- The staged files' cleanup, changed a third time: taken to the owner, decided above — the root shell
  removes them, the app only where none ran (`4daf860`).
- A failed update released a quit's connect hold (`dd8cdf6`).
- osascript's stderr, drained from a pipe after exit, could block osascript for good or freeze the
  main thread: a file takes it (`cc7ce71`); its multi-line error broke a log line (`081393f`); an
  empty reason left a dangling colon (`1f8e3e7`).
- A restart's wait also covered xray, which its connect waits for, and `isTornDown` wrapped
  `teardownBlocker` for one caller (`a521655`); the wait ran on the wall clock (`bbb6b62`); the skipped
  restart's line lost "old settings" (`90668be`); the helper's blocker named a dialog that may be
  gone (`be779cf`); a comment restated a signature (`93f8558`).
- Not changed: the connect hold keeps one slot with the quit's and the update's reasons — the update
  now releases only its own, which closes the case found.
- Next, as decided: one control round, fixing only what breaks a real scenario.

### Where it stopped (2026-10-15, session end)
Plans 17 and 21 are built and pushed; nothing of them is installed — the owner's Mac runs 1.2 with
the updater (`f0c7e41`). The control review round (`/code-review 1691509..e3c819b`) was launched and
its result not processed: run it again, and fix only what breaks a real scenario (decided above).
Then, with the owner at the Mac: `./install.sh` 1.3 — the first connect installs the helper (one
password); check Disconnect, a restart, a quit; `kill -9` on the root sing-box and `netstat -rn`
(decided above); then close plans 21 and 17, and ask before `./release.sh` publishes 1.3. The owner
still has to back up `~/.config/warpveil/release-signing.key` and read the 1.3 notes in
`CHANGELOG.md`.

