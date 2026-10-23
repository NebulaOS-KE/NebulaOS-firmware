# NebulaOS Update, Rollback, and Health-Check Design

**Status:** Implemented (Phases 8 and 10) — see §6 for the real architecture that shipped, which differs from this document's original draft in one important way (no Moonraker update hook exists, so rollback is an external poller, not a Moonraker-invoked step). Informed by direct investigation of SimpleAF's real, currently-shipping `[update_manager]` configuration (Section 1). This is separate from, and does not replace, NebulaOS's existing whole-image A/B rootfs rollback (`S00revert-safety`/`S99confirm-good`/`flash-spare-slot.sh`) — this document covers component-level (Klipper/Moonraker/Mainsail) mutability, which did not exist in any form before this mission (confirmed in `docs/NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §1.2: previously these three were baked into the read-only squashfs with zero update mechanism).

---

## 1. Reference: SimpleAF's real Moonraker Update Manager configuration

Fetched directly from `https://github.com/pellcorp/creality`, `k1/moonraker.conf`, 2026-07-26 (current HEAD, not a cached/historical copy):

```ini
[update_manager]
enable_auto_refresh: False
refresh_interval: 0
enable_system_updates: False

[update_manager klipper]
channel: dev
pinned_commit: 386fde4fd38e8eda6999e58bf260eceb00051188
report_anomalies: False

[update_manager moonraker]
channel: dev
pinned_commit: abd2026b90d86fb738c6619be3ceefcedee2006c

[update_manager fluidd]
type: web
channel: beta
repo: fluidd-core/fluidd
path: /usr/data/fluidd

[update_manager mainsail]
type: web
channel: beta
repo: mainsail-crew/mainsail
path: /usr/data/mainsail
```

Key confirmed facts this design adopts directly:
- `enable_system_updates: False` at the top level — Moonraker never exposes a general OS/package updater. NebulaOS must set this identically (satisfies the mission's explicit "no general Linux package updater exposed through Moonraker" requirement).
- Klipper and Moonraker are both `channel: dev` (git-checkout, not release-archive) updates, each gated by a `pinned_commit` — Moonraker's Update Manager will refuse to report/apply an update that isn't (or doesn't advance cleanly from) the pinned commit, giving exactly the "compatibility-controlled" behavior the mission asks for.
- Mainsail (and, on SimpleAF, Fluidd) use `type: web`/`channel: beta` — GitHub-release-archive-based updates with automatic extraction, not a git checkout — confirming Mainsail's own update path should be release-based, not git-based, matching the mission's own requirement.
- The pinned Klipper commit (`386fde4`) is **identical** to NebulaOS's own previously-vendored pin — independent confirmation that NebulaOS's Klipper fork (`docs/NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §2) and SimpleAF's own reference deployment started from the exact same base.

## 2. NebulaOS's own `[update_manager]` design (adapted, not copied verbatim)

```ini
[update_manager]
enable_auto_refresh: False
refresh_interval: 0
enable_system_updates: False

[update_manager klipper]
type: git_repo
channel: dev
path: /usr/data/nebulaos/apps/klipper
origin: https://github.com/coreflake1/NebulaOS-klipper.git
primary_branch: nebulaos
managed_services: klipper

[update_manager moonraker]
type: git_repo
channel: dev
path: /usr/data/nebulaos/apps/moonraker
origin: https://github.com/Arksine/moonraker.git
primary_branch: master
managed_services: moonraker
virtualenv: /usr/data/nebulaos/envs/moonraker
requirements: scripts/moonraker-requirements.txt

[update_manager mainsail]
type: web
channel: beta
repo: mainsail-crew/mainsail
path: /usr/data/nebulaos/apps/mainsail
```

Differences from SimpleAF's reference, each deliberate:
- **`path`/`origin` point at NebulaOS's own namespace and fork** (`/usr/data/nebulaos/apps/*`, `coreflake1/NebulaOS-klipper`) rather than SimpleAF's `/usr/data/klipper` and `pellcorp/klipper` — NebulaOS has its own fork specifically so its required extras are committed in-tree (architecture doc §2), which SimpleAF's own deployment does not need since it doesn't carry GuppyScreen-specific extras the same way.
- **No `pinned_commit`** in this draft — Moonraker's Update Manager `pinned_commit` freezes updates entirely at one exact commit, which is appropriate for SimpleAF's own stability goals but is in tension with this mission's own requirement that Klipper/Moonraker be **user-updatable** via Moonraker/Mainsail. Compatibility control here is intended to come from Phase 8's own two-stage health-check-gated rollback (§3) rather than a hard pin — **this is an open decision, not yet settled** (§5).
- **`virtualenv`/`requirements`** on the Moonraker entry — this is standard Moonraker Update Manager syntax for a self-updating Python virtualenv; used here deliberately because (per the architecture doc §1.2's build-pipeline finding) Moonraker's Python dependencies today are **not** in a venv at all — they are extracted directly into the system Python's site-packages at image-build time. Making Moonraker's env real, writable, and Update-Manager-aware is a structural change (Phase 7), not a small config edit; recorded here as the target shape.
- **GuppyScreen and Mainsail are otherwise unlisted for anything beyond what's shown** — GuppyScreen has no `[update_manager guppyscreen]` entry at all (stays immutable, per the mission's explicit scope boundary); Mainsail's entry is otherwise identical in shape to SimpleAF's own (`type: web`/`channel: beta`), since Mainsail's release-based update model needs no NebulaOS-specific adaptation.

## 3. Two-stage update verification (Phase 8)

### Stage 1 — component health (post-install, pre-activation)

For whichever component was just updated (Klipper, Moonraker, or Mainsail):

| Check | Klipper | Moonraker | Mainsail |
|---|---|---|---|
| Required files exist | `klippy/klippy.py` present, importable | `moonraker/server.py` present | `index.html` + asset manifest present |
| Manifest/compatibility metadata valid | New commit is a descendant of (or matches an allowed set relative to) the last known-good commit — exact rule pending §5 | Same | Release tag matches the channel's expected shape |
| Python imports succeed | `python3 -c "import klippy"`-equivalent smoke check inside the target's own interpreter | Same, against the (Phase 7) writable venv, not the system interpreter | N/A (static assets) |
| Process starts | Klipper process starts in a **dry-run/no-MCU-connect** mode if possible, else deferred to Stage 2 | Moonraker process starts and its HTTP listener opens | nginx can serve the new `index.html` (HEAD request, not a full page load) |
| No incomplete staging directory active | Update transaction state (§4) confirms the staging directory was fully committed, not partially copied | Same | Same |

A failed Stage 1 check aborts activation immediately — the previous version is never touched, and the new version's staged files are preserved (not deleted) for evidence, per the mission's own "preserve failure logs+version metadata" requirement.

### Stage 2 — full printer-stack health (post-activation)

Only run once Stage 1 has passed and the new version has been activated (paths switched, dependent services restarted):

- Moonraker running and responding on its HTTP port.
- Moonraker's own connection to Klipper (`server.info`) reports connected, not just "listening."
- Klipper reports `klippy_state == "ready"` (reusing the exact same real-readiness check `S99confirm-good` already implements and that this mission's frozen-functionality list protects — the two mechanisms should share logic, not duplicate it with a subtly different check).
- MCU connected (no `mcu.error`/shutdown state — reusing `S95mcu-boot-recovery`'s own detection logic where applicable, though that guard is itself frozen and must not be modified).
- Moonraker reports no failed required components (`server.info`'s own component-health field).
- Heater targets are exactly zero and no active print is running (the same printer-safety invariant already required before every reboot in this project's existing safety discipline) — verified as a **read-only query**, executed and reviewed as its own separate step, never combined with the activation/restart command that produced this state.
- System remains stable for a defined validation interval (proposed: 60 seconds of continuous `ready` state with no further `mcu.error`/component-failure events) before being recorded as known-good.

Only after **both** stages pass is the new version recorded as the current known-good version (§4). A failure at either stage triggers the rollback path (§3.1).

### 3.1 Rollback path

On any Stage 1 or Stage 2 failure:
1. Preserve the failed version's logs and version metadata (commit hash / release tag) under `/usr/data/nebulaos/backups/<component>/failed-<timestamp>/` — never overwritten by a subsequent attempt.
2. Restore the previous known-good version (Klipper: previous commit/worktree; Moonraker: previous source **and** its matching previous Python env, restored together, never mixed — a mismatched Moonraker-source/env pairing is exactly the kind of failure this two-part restore exists to prevent; Mainsail: previous extracted release).
3. Restart affected services.
4. Re-run Stage 2 (not Stage 1 — the previous version was already proven once) against the restored version.
5. If the previous version **also** fails Stage 2: fall back to the immutable factory copy (`/opt/klipper`, `/opt/moonraker`, `/usr/share/mainsail`) temporarily, and clearly report all three states (failed-new, failed-previous, running-factory) rather than silently succeeding on a degraded configuration.

## 4. Update/rollback state machine (persisted)

Persisted at `/usr/data/nebulaos/updates/<component>/state.json` (exact schema TBD during implementation), tracking at minimum: selected version, previous known-good version, activation state (`inactive`/`staged`/`activating`/`active`/`rollback-in-progress`/`factory-fallback`), pending-update state, last rollback reason, last health-check result. A reboot occurring during any of these states must resume deterministically on next boot (the activation manager, Phase 5, reads this state before starting any dependent service) rather than silently picking an arbitrary version.

## 4.1 Factory-seed-to-mutable-update transition (real constraint found during Phase 4 implementation)

The offline factory seeds (`docs/NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §Phase 4) are git bundles built from **flattened single-commit snapshots** of the (shallow) vendor checkouts, not real preserved history — a real git limitation was found and worked around: bundling a shallow clone's actual history does not survive a clone on the git version this project uses (`git bundle verify` reports the bundle as fine; `git clone` of it fails with "did not send all necessary objects"). The flattened seed commit therefore has **no shared ancestry** with the real `coreflake1/NebulaOS-klipper`/`Arksine/moonraker` history on GitHub.

**Consequence for this design's Stage 1/2 update flow**: the very first real update performed against a freshly-seeded checkout must fetch and **hard-reset**, not merge:
```sh
git fetch origin <branch>
git reset --hard origin/<branch>
```
A `git pull`/merge would attempt to reconcile two unrelated histories and either fail outright or produce a nonsensical merge commit. Every subsequent update (once the checkout is on real, continuous history from origin) can use normal fetch+fast-forward semantics — this constraint only applies to the one-time seed-to-real-history transition.

## 5. Open decisions (as originally drafted — see §6 for how these were actually resolved)

1. **`pinned_commit` vs. no pin for Klipper/Moonraker** (§2): SimpleAF pins hard; this mission wants user-updatable components. Leaning toward **no hard pin**, relying instead on Stage 1/2 health checks and the rollback path as the compatibility gate — but this needs explicit confirmation before Phase 10 configuration is finalized, since it's a real behavioral difference from the proven reference.
2. **Exact commit-ancestry rule for Stage 1's "manifest/compatibility metadata valid" check** — not yet designed; needs to distinguish "a legitimate forward update" from "an unrelated/incompatible checkout" without assuming linear history (a rebase or force-push on the tracked branch could break naive ancestor-checking).
3. **Whether Moonraker's env is upgraded in place or versioned as `envs/moonraker-<n>`** — affects both this document's rollback mechanics and the retention manager's env-rotation row (`docs/NEBULAOS_RETENTION_POLICY.md` §2.2/§3).

## 6. Real implementation (Phase 8, as built)

### 6.1 Real constraint found that the original draft didn't anticipate

Confirmed directly against the vendored Moonraker source (`vendor/moonraker/moonraker/components/update_manager/{app_deploy,git_deploy}.py`): this Moonraker version's `git_repo` update flow has **no pre-update or post-update command hook of any kind**. `AppDeploy.restart_service()` is called automatically, synchronously, from inside Moonraker's own `update()` coroutine the moment a user clicks "update" in Mainsail — there is no injection point between "new commit checked out" and "service restarted" for external code to run Stage 1 against the *not-yet-activated* version, as §3's original draft assumed.

This means the clean Stage-1-before-activation / Stage-2-after-activation split as originally designed is not achievable without either (a) forking Moonraker's update_manager component, which is out of scope, or (b) reimplementing update-triggering entirely outside Moonraker, which would break the mission's own explicit "user-updatable via Moonraker/Mainsail" requirement. The real, shipped design instead runs both stages **after** Moonraker has already restarted the service, as an independent, standalone poller — deliberately not a Moonraker plugin, specifically so a bad update that breaks Moonraker itself doesn't also disable the mechanism meant to recover from it.

### 6.2 Architecture: `nebulaos-update-supervisor.sh`

A persistent backgrounded poller (`/etc/init.d/S59nebulaos-update-supervisor`, starts after `S55klipper`/`S56moonraker`/`S58guppyscreen`), polling every 20s:

1. For each of `klipper`/`moonraker`: read the git repo's current `HEAD` commit (`git -C <path> rev-parse HEAD`).
2. Compare against `last_seen_commit` in `/usr/data/nebulaos/updates/<component>/state.json`. A difference means an update happened (via Moonraker's own update flow, or any other means — this script doesn't care which) since Moonraker has *already* restarted the service by the time this is observed.
3. Run Stage 1 (`nebulaos-healthcheck.sh stage1`, re-used unmodified from §3) against the now-checked-out files, then a stabilized Stage 2 (6 samples, 10s apart, fails fast on the first bad sample rather than waiting out the full window).
4. On any failure: `git -C <path> reset --hard <known_good_commit>` (git's own history is the "previous version" — no separate pre-update backup of the whole tree is needed, resolving open decision unspecified in the original draft about backup mechanics for git-based components specifically), restart the affected service directly via its own init script (bypassing Moonraker's API entirely, since a bad Moonraker update may have broken Moonraker itself), then re-run Stage 2 only (matching §3.1 step 4).
5. If the restored version **also** fails Stage 2: `umount /opt/<app>` (removing the bind mount `S05nebulaos-activate` set up reveals the pristine immutable squashfs copy underneath instantly, no reboot needed) and restart the service against it — the factory-fallback path (§3.1 step 5) — while leaving `/usr/data/nebulaos/updates/locks/<component>.lock` in place so `S05nebulaos-activate`'s own existing lock-check (already present, previously unused by anything) keeps the persistent copy off on every subsequent boot too, until a human clears the lock.
6. Every failure preserves the failing commit hash and the component's own log file under `/usr/data/nebulaos/backups/<component>/failed-<timestamp>/` before any reset — never overwritten by a later attempt.
7. Before any restart: a read-only `print_stats` query (same printer-safety invariant as every other disruptive action in this project) — a print in progress defers the restart (bounded wait, re-checked every 10s for up to 900s) rather than forcing it through.

### 6.3 Open decisions, resolved

1. **No hard pin** — implemented as drafted; `moonraker.conf`'s real `[update_manager klipper]`/`[update_manager moonraker]` sections carry no `pinned_commit`, matching §2's leaning.
2. **Commit-ancestry rule** — turned out to be unnecessary. Since rollback works by `git reset --hard` to a commit this system itself already proved healthy (not by reasoning about ancestry of an arbitrary incoming commit), there's no need to distinguish "legitimate forward update" from "unrelated checkout" ahead of time — an incompatible or rebased update is simply caught by Stage 1/2 failing, same as any other bad update, and reset-back-to-known-good works regardless of whether the bad commit was a fast-forward, a rebase, or a force-push.
3. **Moonraker env versioning** — still open. The current venv (`--system-site-packages`, Phase 7) is not versioned or rolled back independently of the source tree; a Moonraker source rollback via `git reset --hard` does not undo any `pip install` a bad update might have run into the venv. This remains a real gap for the specific case of a Moonraker update whose `requirements.txt` changed in an incompatible way — recorded here rather than silently assumed solved, since it wasn't in scope of what's proven working for this pass.

### 6.4 Live qualification — two real bugs found and fixed, then proven working end-to-end

First live test (simulate a bad Klipper update: commit a syntactically-broken `klippy.py` to the persistent checkout, `git rev-parse HEAD` changes, wait for the supervisor to react) found two real bugs in the supervisor itself, not in the design:

1. **False-positive rollback failure from restarting too soon after boot.** The test was run moments after the very first post-boot Klipper start (before it had even reached `ready` once). The supervisor's own restart-then-validate sequence raced against Klipper's real MCU-reconnect time (confirmed elsewhere in this project to legitimately take 15-25s) — `stabilized_stage2`'s first sample (10s after restart) saw `klippy_state` still `startup`, not `ready`, and treated that as a genuine health failure, cascading straight into the factory-fallback path on the very first attempt. Fixed by adding a 25s grace period inside `restart_component()` between issuing the restart and the caller's first health sample.
2. **Stale `last_seen_commit` written on factory-fallback.** The factory-fallback branches recorded `new_commit` (the bad commit that triggered the fallback) as `last_seen_commit`, even though the persistent repo had already been `git reset --hard` back to `known_good_commit` moments earlier in the same code path. This left `state.json` out of sync with git's real state: the next poll cycle saw `current(known_good) != last_seen(new_commit)`, mistook the already-failed-over state for a brand new update, and re-ran `validate_component` — which happened to pass this time (system had since settled) and silently overwrote the factory-fallback record with a false `"healthy"`, while `/opt/klipper` was, in that instance, still the pre-fallback state (the `umount` itself did not even take effect, a separate, not-yet-root-caused observation about this platform's multi-path bind-mount layout from the same physical partition — recorded here as still needing investigation, since it did not block the primary fix). Fixed by (a) recording the actual post-reset commit (`known_good_commit`) as `last_seen_commit` in both factory-fallback branches, and (b) treating `state == "factory-fallback"` combined with a present lock file as a hard stop in `poll_once` regardless of commit bookkeeping, matching this document's own stated intent (§3.1 step 5: never silently succeed on a degraded configuration).

**Retest, after both fixes, on a fresh boot with `klippy_state` explicitly confirmed `ready` beforehand**: committed a second broken `klippy.py`, watched `state.json` transition `healthy` → `validating` (at commit detection) → `rolled-back` (~90s later, once Stage 1 correctly failed on the bad commit and the restored version passed a full stabilized Stage 2). Confirmed: `known_good_commit == last_seen_commit` (both back to the original good commit), `/opt/klipper`'s own git `HEAD` matched exactly with real (non-corrupted) file content, `klippy_state: ready`, zero `dmesg` OOM events, the failed commit's evidence preserved under a fresh `backups/klipper/failed-<timestamp>/` directory (distinct from the first test's two directories, none overwritten), and the update lock released. Phase 8's rollback mechanism is proven working end-to-end on real hardware, including recovering from the false-positive failure mode found in the first pass.

## 7. Implementation resolution — factory-seed history and real updates (2026-07-28)

The `"is_valid": false` gap this document's rollback machinery lives alongside (Moonraker's own Update Manager, not the NebulaOS supervisor above) was root-caused and fixed by the auto-updates-camera-complete mission — see `docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md` §28 for the full evidence chain. In short: the factory seed's synthetic wrapper commit made every freshly-seeded Klipper/Moonraker checkout permanently `diverged=true` in Moonraker's own git status, independent of this document's own rollback design (which operates on the persistent checkout's real git history once seeded, and was never itself the cause). The fix (real-history seed archives, Klipper's production branch renamed to `master`) does not change anything described in §1-§6 above — the rollback supervisor still operates the same way once a repository is validly seeded. Live qualification of real Klipper/Moonraker updates against the fixed seed is tracked in `docs/NEBULAOS_PHASE12_QUALIFICATION.md`.

## 8. Printer configuration confirmed outside rollback scope (2026-07-29)

The mainline print-controls mission required explicitly confirming that printer configuration (`printer_data/config`) is not, and should never become, part of the rollback machinery described above. A direct check of `nebulaos-update-supervisor.sh`'s rollback code paths confirms it only ever touches `printer_data/logs/*.log` (copying diagnostic logs alongside a failed-commit backup) - never `printer_data/config`. Rollback in this document has always operated exclusively on `/opt/klipper` and `/opt/moonraker`'s own git checkouts; printer configuration lives in an entirely separate directory tree seeded and validated independently (`docs/NEBULAOS_ENDER3_V3_KE_FACTORY_CONFIG_SEED.md`) and was never wired into this state machine at all. Confirmed live: an ordinary reboot and a full genuine empty-namespace requalification both left `printer_data/config`'s own seeding marker and content behaving exactly as that document describes, unaffected by anything in this one. Full evidence: `docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md`.

## 9. Image rollback and persistent state (G91, 2026-10-23)

An A/B rollback (a manual slot swap or a failed image trial) boots an OLDER image against
`/usr/data` that a newer image already wrote. Rules for every persistent file:

- A versioned settings file only ever gains keys: a newer image may ADD keys and then raises
  its schema number; an incompatible change uses a NEW file name (copy, never move - the old
  file stays for the other slot). Readers accept `schema >= their own` and read the keys they
  know (`nebulaos_osconfig.common.schema_readable`, used by network, display and boot display),
  so a rollback keeps the hostname, static IP, brightness and boot logo instead of falling back
  to the defaults. An older image that saves such a file writes its own schema and drops the
  newer keys; the newer image then uses defaults for those keys only.
- Boot readers use the rendered `*.env` files and accept only the keys they know, each
  validated.
- The printer.cfg SAVE_CONFIG block is a rollback barrier: Klipper refuses an unknown section
  or option there too, so a NEW autosaved section/option (today `raw_reference_counts` in
  `[nebulaos_z_offset_probe]` and `[autotune_tmc ...]`) means an image without it does not
  start Klipper until the user deletes those `#*#` lines. New state that needs no restart
  belongs in a small state file (as the G99 load cell mode), not in SAVE_CONFIG; any new
  autosaved option is named in the release notes.
- Downloaded NebulaScreen releases and their state are reset by "the image wins"; persistent
  Klipper extensions older than the image's pin are never activated (S05).

The per-file audit is kept with the Run 18 notes (`_scratch/run18/G91-rollback-audit.md` in
the workspace).
