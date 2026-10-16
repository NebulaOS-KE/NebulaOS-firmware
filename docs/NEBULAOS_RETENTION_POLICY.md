# NebulaOS Retention Policy

**Status:** Implemented and closed out (Phase 9 / closure mission Phase E) — `/etc/nebulaos-retention.sh` + `/etc/init.d/S45nebulaos-cleanup`, verified present by `06-verify.sh`. Informed by direct investigation of SimpleAF's real, currently-shipping cleanup mechanism (Section 1). §3's open decisions are now resolved (§2.3's floor values against real measured data, §2.2's env-rotation row against the paired-backup mechanism Phase D actually shipped) — see §4 for the closure-mission measurement pass and §5 for two real bugs found live during it.

---

## 1. Reference: SimpleAF's proven cleanup pattern (evidence, not yet adapted)

Investigated directly from `https://github.com/pellcorp/creality` (`k1/services/S45cleanup` → `tools/cleanup-files.sh`), 2026-07-26, current HEAD. This is real, currently-shipping behavior on the same board family, not a historical/superseded reference. Full findings recorded in `docs/NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` §1.5; restated here as the basis for NebulaOS's own design:

- **RTC-before-NTP wait**: on Buildroot targets only, detects a start timestamp before a fixed reference date (its own clock hasn't synced yet) and busy-waits for a >20-minute forward jump before doing any `mtime`-based deletion.
- **Emergency gcode threshold**: free space on the data partition `< 1000MB` triggers deletion of `.gcode` files at `-maxdepth 1` (never recurses) in the shared gcodes root, and only those with `mtime +7` (7+ days old).
- **Log rotation**: rolled log files older than 7 days, explicitly excluding the live `moonraker.log`/`klippy.log`/`grumpyscreen.log` (its GuppyScreen-fork counterpart).
- **Backup rotation**: backup tarballs older than 7 days, but **always skips the single newest one** even if it's also past the age threshold ("in case its the only file left").
- **Cache purge**: `/root/.cache` (pip cache) removed every run, unconditionally.
- **Logging**: every deletion (real or `--dry-run`) appended to a `cleanup.log`, truncated at the start of each run.
- **Notable gap in the reference itself**: no active-print check exists anywhere in this script before deleting old gcode files. NebulaOS's own design must not repeat this gap (see §2.4).

## 2. NebulaOS retention manager design

### 2.1 Scope boundary (namespace-restricted, not a literal port)

Unlike SimpleAF's script (which operates directly on `/usr/data`), NebulaOS's retention manager is restricted to an explicit allowlist of paths under `/usr/data/nebulaos/{updates,backups,maintenance,envs,system}` - since G66 (2026-10-16) also `printer_data/config/uploads/system-image` (uploaded images older than 30 days, never during an image install; an installed one is removed by the image trial by sha256) and `printer_data/config/backups/nebulaos-changes-*` (newest 5) - plus the one deliberate special exception below (§2.4). It must:

- Reject any resolved path that escapes the namespace (`realpath` resolution, then a prefix check against `/usr/data/nebulaos`, not a string-prefix check on the unresolved path — must not be foolable by `..` or symlinks).
- Never follow a symlink that resolves outside the namespace.
- Never descend into a USB mount (checked via `/proc/mounts` device match, not just a path-prefix guess, since USB devices could in principle be bind-mounted to look path-adjacent).
- Coordinate with an in-flight update transaction (Phase 8's state machine) — refuse to run (or run in a reduced, backup/log-only mode) while an update transaction is active, to avoid racing a rollback's own file operations.

### 2.2 Allowlisted actions (normal operation, always safe)

| Path | Action | Threshold | Notes |
|---|---|---|---|
| `/usr/data/nebulaos/updates/*/staging` | Remove abandoned staging directories | Age > 24h AND no active transaction owns it | Transaction ownership tracked via Phase 8's state file, not just age |
| `/usr/data/nebulaos/updates/*` (downloads) | Remove incomplete/orphaned downloads | Same as above | |
| `/usr/data/nebulaos/backups/{klipper,moonraker,mainsail}/failed-*` | Rotate failure-evidence directories only | Keep newest 2 per component; never delete the only remaining copy | Real bug found live (§5): must exclude `last-known-good`/`last-known-good-env` by name, not just sort-and-keep-2 across everything in the directory |
| `/usr/data/nebulaos/backups/printer_config` | Rotate to current + previous known-good only | Keep exactly 2 (current, previous); never delete the only remaining copy | |
| `/usr/data/nebulaos/maintenance/*.log`, retention-manager's own log | Rotate | Age > 7 days, adapted from SimpleAF's own 7-day log threshold | Never delete the live/active log |
| `/usr/data/nebulaos/backups/mainsail/last-known-good`, `/usr/data/nebulaos/backups/moonraker/last-known-good-env` | **Never touched by this script at all** | N/A | Resolves the original open decision about env-rotation: Phase D didn't version envs as `envs/moonraker-<n>` — it maintains exactly one continuously-refreshed paired backup per component, owned and rotated by the update-supervisor itself (`nebulaos-update-supervisor.sh`), not by retention. |

### 2.3 Disk-pressure levels (maintenance admission control)

Three levels, adapting SimpleAF's single 1000MB threshold into a graduated response since NebulaOS's namespace-restricted retention has less to reclaim than SimpleAF's whole-partition script:

1. **Normal** (free space above a "safe" floor — **800MB, measured, see §4**): no action beyond routine rotation above.
2. **Caution** (below the safe floor): block NebulaOS's own maintenance-heavy operations (refuse to start a new factory-seed or update transaction) but do not delete anything beyond the routine rotation in §2.2; log a warning.
3. **Critical** (below a hard floor — **300MB, measured, see §4**): in addition to Caution's blocking, run the emergency shared-gcode cleanup (§2.4) and purge the pip cache (adapting SimpleAF's unconditional `.cache` purge into a Critical-only action here, since NebulaOS's `wheel`/`pip` tooling, Phase 2, is new and this cache did not previously exist).

**Documented platform limitation (final-seal mission, 2026-07-27) — the exact, consistent wording used everywhere this is described:**

> NebulaOS blocks its own factory-seeding, rollback, repair, cleanup, and other maintenance-heavy operations when free space is below the measured safety floor. Moonraker's native Update Manager does not provide a supported pre-download admission hook in the shipped integration, so NebulaOS cannot universally stop a user-triggered Moonraker-managed download before it begins. Low-space state is reported and cleanup protections remain active, but universal pre-download blocking is not claimed.

Confirmed against the same vendored `update_manager` source already cited for the same class of constraint in `docs/NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` §6.1. This is an accepted, documented limitation of the current integration, not an open implementation item - a Moonraker fork, plugin, UI-only button disable, or invasive interception mechanism was deliberately not built to close it.

```text
RETENTION_THRESHOLDS: COMPLETE
NEBULAOS_MAINTENANCE_ADMISSION_CONTROL: COMPLETE
MOONRAKER_NATIVE_PRE_DOWNLOAD_BLOCKING: NOT AVAILABLE IN CURRENT INTEGRATION
```

### 2.4 Emergency shared-gcode cleanup (special exception to the namespace rule)

Per the mission brief, the shared gcode directory (`/usr/data/printer_data/gcodes`, outside the `/usr/data/nebulaos` namespace) is a deliberate, explicit exception: under Critical disk pressure only, follow SimpleAF's verified pattern — delete `.gcode` files at `-maxdepth 1` (never recursing, so a USB-mounted subtree or an organized subfolder is never touched), oldest-`mtime`-first, stopping as soon as free space returns above the Critical floor rather than deleting everything eligible.

**Deliberate improvement over the SimpleAF reference** (§1's noted gap): before deleting any gcode file, NebulaOS's implementation must check:
- It is not the file backing the currently active print (via Moonraker's `print_stats`/`virtual_sdcard` state — an active or paused print's file is never eligible, full stop, regardless of age or disk pressure).
- It is not a partial/in-progress upload (match against Moonraker's upload-in-progress state, not just a naive "recently modified" heuristic, since a slow upload of an old-looking file could otherwise be misjudged as stale).
- It is not on a mounted USB device (already excluded by `-maxdepth 1` against the gcodes root, but re-checked explicitly here since this is the one path outside the namespace where a mistake would be highest-impact).

If a file's state is ambiguous for any reason, it is skipped, not deleted — matching the mission brief's explicit "never delete... files with ambiguous state."

### 2.5 Logging and dry-run

Every retention-manager run supports `--dry-run` (log intended deletions without performing them, matching SimpleAF's own `--dry-run`/`--client` convention) and logs every actual deletion with timestamp, path, size, and reason (rotation/staging-cleanup/emergency-gcode) to `/usr/data/nebulaos/maintenance/retention.log`, itself subject to the same 7-day rotation as any other log (§2.2).

### 2.6 RTC-before-NTP handling

Adapted directly from SimpleAF's own mechanism (§1): detect a start timestamp before a fixed reference date, wait for a large forward clock jump before performing any `mtime`-based comparison. NebulaOS's own implementation should use a reference date close to its own baseline (`functional-production-baseline-2026-07-23` or later) rather than SimpleAF's hardcoded 2025 date, and the same "wait for >20 minute jump" heuristic, adjusted only if real-device testing (Phase 12) shows this project's own NTP sync timing differs meaningfully from SimpleAF's board.

### 2.9 When it runs (G66, 2026-10-16)

- At boot from `S45nebulaos-cleanup` (waits for a real clock, up to 20 min).
- Every 30 minutes from `S99nebulaos-housekeeping` with `NEBULAOS_RETENTION_PERIODIC=1` and no clock wait: skipped entirely while a print runs or is paused; the §2.4 emergency print-file deletion is never done in this mode (boot only).
- One run at a time: a `mkdir` lock at `maintenance/retention.lock`, taken over when older than an hour.
- Files of the other system on the data drive are never touched by retention; removing them is the user's explicit "Clean up Creality files" (`nebulaos_osconfig/cleanup.py`, fixed list).

## 3. Open decisions (as originally drafted — resolved in §4/§5)

- Exact Caution/Critical free-space floors (proposed 800MB/300MB above) — need real-device validation, not just adapted from SimpleAF's single 1000MB number, since NebulaOS's own footprint (~150-250MB per the architecture doc's storage budget) differs from SimpleAF's.
- Whether Moonraker env versioning (Phase 7) actually produces multiple env directories needing rotation, or whether a single env is upgraded in place with a full backup/restore instead — affects whether the `envs/moonraker-*` row in §2.2 is real or moot.
- Retention manager invocation mechanism: a dedicated `S45cleanup`-numbered init script (matching SimpleAF's own numbering convention and this project's existing `S*` scheme) triggered at boot, versus a periodic cron-like mechanism — NebulaOS's BusyBox init has no native cron; likely a boot-time run plus an optional periodic re-invocation hook from Moonraker itself (a component or a timer), to be decided during implementation.

## 4. Closure mission (2026-07-27): real measurement, resolving the floor values

Measured directly on the physical device (partition `/dev/mmcblk0p10`, 6022MB total), steady state after all four closure-mission phases were live-tested:

```
apps/klipper        233.3M   (real upstream lib/ - bundled MCU toolchain sources for every
                               architecture Klipper supports, not NebulaOS-specific bloat)
apps/moonraker         6.9M
apps/mainsail         10.1M
envs/moonraker        25.5M   (--system-site-packages: only Moonraker's own few
                               venv-local packages, not a full duplicate of system site-packages)
backups/mainsail/last-known-good        10.1M   (mirrors the live app directory exactly)
backups/moonraker/last-known-good-env   25.5M   (mirrors the live venv exactly)
backups/klipper                          4.0K   (git history is the "backup" - no directory copy needed)
system/swapfile                       128.1M   (fixed, Memory Resilience Gate)
---------------------------------------------------------------------
total /usr/data/nebulaos                466.4M
partition free space at measurement    2580MB  (43% free, 6022MB total)
```

**Temporary peak during the heaviest single operation** (a Moonraker paired source+venv rollback - the only operation this mission found that duplicates a large directory): `atomic_directory_replace()`'s staging-then-swap sequence briefly holds the venv's `.staging` copy (25.5M) alongside the still-present original (25.5M) before the old copy is removed - a real, measured peak of **~55-80MB**, never sustained (torn down again within the same operation, typically under a minute per the live rollback timings observed in Phase D testing). Mainsail's own equivalent (backup snapshot + staging swap) peaks lower, around **~30MB**, since its steady-state footprint (10.1M) is smaller.

**Conclusion**: the originally *proposed* 800MB/300MB floors were not arbitrary guesses that needed correcting - real measurement confirms they already provide roughly 10x and 4x margin respectively over the heaviest actually-observed temporary peak (~80MB). **Kept unchanged, now backed by measured evidence instead of an adapted reference number.**

## 5. Two real bugs found live during the closure-mission measurement pass

1. **`delete()` silently failed on every directory-based backup.** BusyBox's `rm -f` refuses to remove a directory at all (`rm: 'x' is a directory`, exit 1) - confirmed live with a direct reproduction. Every one of this script's own log lines claiming `deleting (obsolete-version-<comp>): ...` against `backups/{klipper,moonraker,mainsail}` (all real directories) had been doing nothing for the entire mission; only the flat-file cases (rotated logs, config backups) were ever genuinely removed. Fixed: `delete()` now uses `rm -rf` for directory targets and verifies the target is actually gone afterward, logging a `FAILED to delete` line instead of a false `deleting` line if not.
2. **`clean_obsolete_versions()` didn't distinguish failure evidence from the active paired backup.** It sorted and rotated *everything* under `backups/$comp` together, including `last-known-good`/`last-known-good-env` - the single, continuously-refreshed backup the Phase C/D update-supervisor's own rollback mechanism depends on to restore from, not "an old version to prune." Confirmed live via the real retention log: this had been running automatically at every boot (`S45nebulaos-cleanup`) and genuinely attempted to delete the paired backup repeatedly across multiple boots throughout this mission - masked only by bug 1 above (the `rm -f` failure meant it never actually succeeded). Fixed: only `failed-*`-prefixed evidence directories are ever candidates now; the paired backup names are structurally excluded from the glob this function operates on, not just skipped by a name check that could regress.

Both fixes verified live: `sh /etc/nebulaos-retention.sh --dry-run` correctly identifies only the oldest `failed-*` entries beyond the newest 2 per component, and a direct `rm -rf` reproduction against a real populated test directory confirmed the corrected removal mechanism actually works this time.
