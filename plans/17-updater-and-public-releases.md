## 17. WarpVeil updates itself from GitHub, and anyone can install it
Owner, 2026-10-14: the app should update itself from GitHub releases without an Apple Developer ID,
and anyone should be able to download it. Owner, 2026-10-15: 1.3 ships as soon as the updater is
ready — what is in `main` plus the updater — and every later feature arrives through it. Backlog 17.

### Done when
- `release.sh` refuses, each in a throwaway repo: uncommitted tracked changes, an existing tag or
  release, a version not newer than the last tag, no `CHANGELOG.md` section for the version, no
  signing key or a key that does not match the app's public key.
- A dev copy offered a newer signed release from a local feed: Install stops the engines, swaps the
  bundle and relaunches into the new version; a bad signature, another bundle id, an older version
  and an unsigned zip are refused, with the reason in the Updates row.
- 1.3 is on GitHub with the zip, its signature and notes from `CHANGELOG.md`; the README has a
  Download section.
- On a clean macOS user account, the README's steps install 1.3 and the tunnel connects.
- The owner's Mac runs 1.3, and Check for Updates reads "Up to date".

### Decided
- A homegrown updater over the GitHub releases API; no Sparkle — the canon allows no packages
  (owner, 2026-10-14).
- Each release zip carries an ed25519 signature made with our own key; the app checks it before
  anything is unpacked (owner, 2026-10-14).
- One row in Advanced — Check for Updates, or Install once a release is known — and an "Update to …"
  item in the menu-bar menu while one is known; a check once a day. No toggle, no notification, no
  dialog (owner, 2026-10-14).
- An update installs on a click, not by itself (owner, 2026-10-14).
- Ad-hoc signed releases: the README and the notes tell a stranger exactly what macOS will show
  and what to click (owner, 2026-10-14).
- `release.sh` refuses what cannot be released, and its notes come from a hand-written
  `CHANGELOG.md` (owner, 2026-10-14).
- 1.3 is the first release with the updater, installed by hand once; it ships before the other
  planned features (owner, 2026-10-15).

### Open for the owner
- A version bump re-asks the password twice on the first connect (a new tag, then the passwordless
  toggle). Default: accepted, and the 1.3 notes say so; reducing it is its own plan.
- The signing key is made by the builder and lives outside the repo. Default: the builder says
  where; the owner keeps a copy in a password manager — without it no installed copy can verify an
  update again.
- The 1.3 section of `CHANGELOG.md` is public text. Default: the builder drafts it, the owner edits.
- Publishing 1.3 is outward-facing. Default: the builder asks the owner before the release is
  created on GitHub.

### Depends on
- `gh` logged in to the repository's account — true on 2026-10-14.
- The release signing key — does not exist yet; step 1 makes it.

### Risk
- A lost signing key strands every installed copy: no update verifies, and the way out is a new key
  plus one install by hand everywhere. Guarded by the backup above.
- A broken updater in 1.3 cannot fix itself; the first real update is 1.3 → 1.4. Guarded by the
  local-feed check on a dev copy before 1.3 is published.
- An update must not leave root engines behind or the app gone from `/Applications`: the engines
  stop first, and the new bundle is staged next to the old one and renamed in, as `install.sh` does.
- The engines nested in a quarantined bundle may be blocked after Open Anyway; if the clean-account
  check shows it, the app clears the quarantine from its own bundle at launch.

### Steps
1. **Trusted releases.** The signing key, `release.sh`'s refusals and signature, and notes from
   `CHANGELOG.md`. Done when: the first check above, and a signed zip verifies.
2. **The updater.** The Updates row, the daily check, and Install. Done when: the second check above.
3. **Publish 1.3.** The version bump, the README's Download section, the release on GitHub, the
   owner's Mac on 1.3. Done when: the last three checks above.

### Leaves out
- Notarization and a Developer ID; Sparkle; delta updates; a progress bar.
- Installing an update without a click.
- Fewer password prompts after a version bump (see Open).

### What we know (2026-10-15)
- Releases v1.0, v1.1 and v1.2 exist on GitHub with one asset each, `WarpVeil-<version>-macOS.zip`,
  built by `release.sh`; the installed app is 1.2, ad-hoc signed.
- `release.sh` today replaces an existing tag and release instead of refusing.
- The old plan holds the verified facts — the GitHub API, quarantine and Gatekeeper on macOS 15–27,
  translocation, App Management — and the full design:
  `git show 975f8b4:plans/in-app-updater.md`.
