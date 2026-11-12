# Phase 9 deployment checklist

Clean-Update + Virgin Baseline mission. This is the explicit overnight
stopping point: Phases 1-8 are repository/build-only and complete without
touching the device; Phases 10-14 need the printer reachable and are
deliberately NOT started until that is confirmed. This document is what
carries the handoff between those two halves.

## Repository state (Phases 1-8)

| Phase | Status | Commit(s) |
|---|---|---|
| 1. Audit + fix Klipper branch divergence | Done | manifest + fork fast-forward |
| 2. One update owner per component | Done | `docs/NEBULAOS_UPDATE_OWNERSHIP.md` |
| 3. Versioned persistent `/usr/data` migration | Done | `S04nebulaos-migrate`, `docs/NEBULAOS_PERSISTENT_LIFECYCLE.md` |
| 4. Factory-clean provisioning mode | Done | `factory-clean-provision.sh` |
| 5. Offline recovery-safety assertions | Done | `tests/recovery-safety-tests.sh` |
| 6. Runtime version-truth exposure | Done | `klippy_extras/nebulaos_version.py` |
| 7. Canonical OTA flow + release automation | Done | `docs/NEBULAOS_OTA_FLOW.md`, `scripts/release.sh` |
| 8. Virgin candidate build | **PASSED** | fresh clone, `./build.sh` |

All canonical branches (`NebulaOS-firmware` main, `NebulaOS-klipper` master)
are pushed and match what a fresh clone actually gets - verified directly
by `tests/recovery-safety-tests.sh` and by Phase 8's own from-scratch clone.

**Phase 8 build result: PASSED.** `git clone https://github.com/coreflake1/
NebulaOS-firmware.git` into a throwaway directory (`NebulaOS-firmware-
virgin-build`, HEAD `f254c41`), then `./build.sh` with zero reuse of any
`vendor/`/`build-work/`/`artifacts/` state. One transient failure along the
way, self-diagnosed and resolved without touching any of this repo's own
logic: `git.linuxtv.org` (v4l-utils, an unrelated third-party upstream)
returned a 504 mid-clone; re-running `build.sh` resumed correctly (every
already-verified pin skipped its re-clone, confirmed by the log) and
completed cleanly on retry. Result:

- `06-verify.sh`: zero `MISS` lines.
- Post-build assertions (`assert-baseline-config.sh post-build`): all PASSED
  (PREEMPT_RT, HZ=100, backlight/PWM/touch qualification, DISPLAY-V1,
  W3 SD/SDIO capabilities, ROAMOFF1, kernel.config/DTS/buildroot.config
  byte-identical to the pinned `nebulaos-display-baseline-vsync-pwm-sleep-
  2026-08-03` tag).
- `baseline-difference-gate.sh`: PASSED - only allowed differences from the
  prior baseline (klipper commit now `cfa3e1c` per Phase 1/6's own fixes,
  guppyscreen commit now tracked as a new manifest field, rootfs grows
  ~18.6MB from a broader `linux-firmware` set - traced, not a loss, still
  well under the 500MB rootfs2 budget - and the usual non-reproducible
  `xImage`/`rootfs.squashfs` hashes from embedded build timestamps).
  (CORRECTION 2026-09-24, dated record kept as written: the non-reproducibility
  is real, but "from embedded build timestamps" was a guess and is measured to
  be insufficient - 1,454,891 bytes differ beyond the uImage header. Cause not
  established. See `docs/REPRODUCIBILITY.md`.)
  (UPDATE 2026-11-12: the causes have since been measured and fixed; a rebuild
  of the same commit now reproduces both artifacts byte for byte. See
  `docs/REPRODUCIBILITY.md`.)
- `scripts/build/package-deployment.sh`: package produced at
  `build-work/deploy-packages/z-compensate-guppyscreen-20260807T224746Z/`
  (local to the throwaway clone - not committed; canonical per
  `docs/NEBULAOS_OTA_FLOW.md`, a package is published via `scripts/
  release.sh` only once a real tag exists, which Phase 14 creates).
  `sha256sum -c SHA256SUMS`: all 7 files OK.
- One real, load-bearing bug found and fixed by this attempt itself:
  `00-fetch-vendor-sources.sh`'s WiFi firmware fetch used plain
  unauthenticated `curl` against this repo's own (still-PRIVATE) release
  assets, which 404s regardless of the URL's shape. Fixed with a `gh
  release download` fallback - see that commit for detail. Without this
  fix, Phase 8 could not have completed at all.

A virgin build that did not pass would have needed to be fixed and
re-run before Phase 10 begins; that did not end up being necessary once
the above fix landed.

## Known, documented gaps (not blockers to Phase 10, but must not be forgotten)

1. **`docs/NEBULAOS_PRINTER_CFG_LOADCELL_GAP.md`** - the canonical
   `printer.cfg` does not yet wire in `[z_compensate]`/`[prtouch_v2]`,
   even though that config was live-tested successfully on the real
   device (2026-08-05). A virgin install will currently NOT include
   load-cell probing. If Phase 11's "prove truly clean" pass is checked
   against load-cell functionality specifically, it will legitimately
   fail on this one point until the real config values are pulled from
   the device (Phase 10 territory) and committed back.
2. **Klipper HALTED state, unresolved from before this mission started**:
   during the prior session's live diagnostic work (fixing the
   `d839d03-dirty` version-string issue), restarting Klipper surfaced a
   pre-existing, unrelated config/code mismatch - `printer.cfg`'s
   `[z_compensate]` section has `bed_add_temp: 60`, but
   `z_compensate.py` validates `maxval=20`. This was deliberately NOT
   guessed at (neither reverting the value nor loosening the code bound)
   since the correct value depends on real printer calibration this
   session has no way to know. **The live device's Klipper may still be
   in this halted state.** This must be checked and resolved (with the
   user's input on the correct `bed_add_temp` value) as part of Phase 10's
   safety re-checks, before any qualification work proceeds - a halted
   Klipper is not a safe starting point for any of Phase 10-13's
   verification work.

## Phase 10 entry: re-run every device safety check from scratch

Per the mission's own explicit instruction: printer unreachability during
Phases 1-9 is not an error and was not treated as one. The moment the
printer becomes reachable, do not assume any previously-known state still
holds - re-verify from scratch:

1. SSH reachable, board identity confirmed (`cat /proc/cmdline`).
2. Printer idle: no active/paused print (`print_stats.state`), heater
   targets at zero.
3. Check Klipper's actual live state first (see gap #2 above) - do not
   proceed with any motion/heating-adjacent work if Klipper is halted;
   resolve that with the user before anything else.
4. Currently active boot slot (`root=` in `/proc/cmdline`), so the correct,
   non-active slot is targeted by any flash.
5. Only then proceed to Phase 10's actual work: archive-only (never
   destroy) the current NebulaOS-owned persistent state via
   `factory-clean-provision.sh --archive-and-reset`, flash the virgin
   candidate to the inactive slot via `flash-spare-slot.sh`, read-back
   verify, and only then request a reboot from the user (this project's
   own tooling cannot issue `reboot` itself - confirmed persistently
   blocked - a human must physically/remotely trigger it).

## Phases 11-14 (unchanged from the mission's own specification)

11. Prove the installation is truly clean: canonical HEAD == remote SHA
    exactly, no dirty/local patches (query `[nebulaos_version]` - Phase 6's
    own `klipper_dirty` field is exactly the tool for this), z_compensate/
    GuppyScreen from canonical source, no old compiled helper/migration
    marker/stale app tree survived. Any accepted runtime code explainable
    only by an old persistent file is a FAIL - given gap #1 above, treat
    load-cell probing as explicitly OUT of the "accepted feature" set for
    this pass unless it was fixed in Phase 10.
12. Live qualification (same checklist as the prior canonical-baseline
    deployment - PREEMPT_RT, ROAMOFF1, WiFi IRQ priority, CID MAC,
    TCP_NODELAY, camera presets, DISPLAY-V1/PWM/backlight, polling touch,
    zero pinctrl errors, all services healthy, z_compensate HTTP/WebSocket
    structured status if wired) plus a safe Moonraker Recovery test while
    idle - `tests/recovery-safety-tests.sh`'s own assertions predict this
    will land back on canonical HEAD cleanly; confirm that prediction
    against the real device. One warm reboot + soak after.
13. Controlled persistent-app-generation migration test (no motion/
    heating): verify detection/backup/update/preserve/verify/generation-
    advance/restart-succeeds via `S04nebulaos-migrate`, and verify the
    failure/rollback path does not destroy user state - both already
    proven offline by `tests/app-migration-tests.sh`; this is the
    on-device confirmation of the same properties.
14. Only after everything above passes: commit final docs, push all
    canonical branches, verify all repos clean, create the new canonical
    baseline tag, publish the exact deployment package + hashes via
    `scripts/release.sh`.

## Do not proceed past Phase 9 without explicit confirmation

Phases 10-14 require the user to confirm the printer is back online and
reachable. Nothing in this checklist authorizes starting them
automatically.
