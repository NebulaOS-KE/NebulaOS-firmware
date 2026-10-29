# Phase 1 Final Candidate — Frozen for Hardware Qualification

Produced by the Phase 1 overnight closure mission and finalized by the
Phase 1 final candidate cleanup mission. This document records the exact,
frozen identity of the candidate that tomorrow's hardware sessions must
test. **Nothing in this document may be silently changed** — if a real
architectural contradiction is found tomorrow requiring a source change, a
new candidate must be built and this document (or a successor) updated
explicitly, in its own reviewed commit.

## Status

```
SOURCE_VERIFIED=YES
BUILD_VERIFIED=YES
HARDWARE_QUALIFIED=NO
PHASE_1_OFFLINE_WORK_COMPLETE=YES
FINAL_CANDIDATE_FROZEN=YES
PHASE_1_PRINTER_COMPLETE=NO  (requires tomorrow's real hardware qualification)
```

## Branches (both pushed)

| Repo | Branch | Tip commit |
|---|---|---|
| NebulaOS-firmware | `phase1.9b/plr` | `db6870b` |
| NebulaOS-klipper-extensions | `phase1.9b/plr` | `b6ae35e` |

Neither branch has been merged to `main`. Per this mission's own hard
rule, nothing here is promoted or labeled hardware-qualified — that
requires tomorrow's real tests to pass first.

## Exact pinned identities (`manifests/dependencies.conf`, NebulaOS-firmware @ `db6870b`)

| Component | Identity |
|---|---|
| Kernel source (NebulaOS-kernel, `openke`) | `295b7101d751fd888ae39e6f1746a4a940664a5f` |
| Buildroot fork | `74d020081096972857acdb9e76c6c5335455d430` |
| Klipper (official, unforked) | `58bd67db3ce1be1951c3e4a6d1156a79903d4edc` |
| NebulaOS-klipper-extensions | `b6ae35ef735ffad540a6ade8505085a8e97e8f42` |
| Moonraker | `d5ee17128bb88434aacdab90c2e9e990e2b64e4a` |
| k1-ustreamer | `18e30bb313d54b1b01dd995bd31ce5a3d5adffd6` |
| v4l-utils | `3b22ab02b960e4d1e90618e9fce9b7c8a80d814a` |
| NebulaOS-guppyscreen (**unchanged this mission**) | `5f1911ac938451bb00439e8c55c87ef60b4a1566` |
| Build container | `ghcr.io/nebulaos-ke/nebulaos-build@sha256:a6ba57c69fa1ea630b037a1d1f55cf0c044a7f5a403bde9b155ea54bca1cceba` |
| GD32 MCU candidate | native candidate-001, `candidate-001.bin` SHA256 `c2db4f34586c5df88b0d8d40e1d2d1c0f3bea90ab879c7c3a1ccc3a64f91db0c` (Phase 1.7/1.8B, **unchanged this mission** — see `docs/MCU_LIFECYCLE_GUARD.md`) |

None of these pins besides `KLIPPER_EXTENSIONS_PIN` were touched by either
the overnight closure or final-candidate-cleanup missions.

## Build artifact hashes

From this exact candidate's own genuinely clean build (empty `vendor/`,
fresh network fetch, `built_at=2026-08-30T11:57:07Z`):

```
built_at=2026-08-30T11:57:07Z
git_commit_main=db6870bb74ca2973dc8eafd4278f6f4b6d0c10ba
xImage_sha256=e480c12db8877e5ac81b0bac6ba45cefd05522c070de8095254243b0666df445
xImage_size=5509184
rootfs_squashfs_sha256=e6c85f824a5d59c606fd99175b9757d19e09393b6b01d29566ecd50db7d7feb3
rootfs_squashfs_size=98570240
device_tree_sha256=e2c22548bbabea584a835d5c09a0884e0945291093a95b887333bc0d0377df93
kernel_config_sha256=542da7402a5c3997ac6d28ba79d954d384cfe4d78830568254a1ec03e2634e2e
buildroot_config_sha256=fe95305b3643077e80f0396d00142c27f362de20a7b6b8f2b028047fd00c40b8
guppyscreen_sha256=3d0ac0155ce2d456c83138b9c85b1eb7939a5baf84fb2a60b52838fb376fd181
```

`device_tree_sha256`/`kernel_config_sha256`/`buildroot_config_sha256` are
identical to every other build this session produced from this same
source (proving the kernel/DTS/Kconfig *content* is stable and
reproducible). `xImage_sha256` and `guppyscreen_sha256` differ from
build to build **despite identical pinned source** in every build run
this session (three different GuppyScreen hashes, two different xImage
hashes, across three separate builds, all from the same
`git_commit_guppyscreen`/kernel pins) - this is expected, build-
environment-dependent nondeterminism (most likely an embedded build
timestamp in each binary's own version-reporting/banner), not a real
source or behavioral change. `GD32_CHANGED`/`GUPPYSCREEN_CHANGED` are
therefore verified by **source pin identity**
(`git_commit_guppyscreen=5f1911ac938451bb00439e8c55c87ef60b4a1566`,
unchanged - confirmed unmodified by this mission), not by binary hash
matching, which is not a meaningful comparison for either artifact given
this nondeterminism.

> **CORRECTION (2026-09-24, final release closure mission).** The paragraph
> above is a dated record and is kept as written, but two of its claims have
> since been measured and one of them is wrong. It must not be relied on.
>
> - **The guppyscreen half is now false as stated.** `guppyscreen` reproduced
>   byte-for-byte across three separate builds, from three different firmware
>   commits, in three freshly cloned workspaces, under one fixed
>   `GUPPYSCREEN_PIN` and one fixed build-container digest. That refutes
>   "differs from build to build despite identical pinned source". It is not
>   the same as establishing full byte-reproducibility under varying hosts,
>   toolchain images or pins, which has NOT been demonstrated - see
>   `scripts/build/05-final-build.sh`, which deliberately says so.
>   The cause of the variation observed above was specific, not "build-
>   environment-dependent nondeterminism": libhv expands the compiler
>   `__DATE__`/`__TIME__` macros (`libhv/base/htime.c` `hv_compile_datetime`),
>   and libhv links into `guppyscreen` but not into `guppybeep`. Stage 04 now
>   pins `SOURCE_DATE_EPOCH` to the GuppyScreen commit date and verifies the
>   expected date is embedded. Two independent builds, of two different
>   firmware commits, in two freshly cloned workspaces, produced an identical
>   `guppyscreen` (`1b34e7b7…`) and an identical `guppybeep` (`fe2a7d3b…`).
>
> - **The `xImage` half is still true, and has been measured.** `xImage`
>   remains non-reproducible from identical inputs: the uImage header embeds
>   wall-clock build time (bytes 8-11), and beyond the 64-byte header
>   1,454,891 of ~5.5 MB still differ, so the compressed payload is itself
>   non-deterministic. That is a real open defect with its own scope, recorded
>   in `docs/REPRODUCIBILITY.md`.
>
> - **The reasoning pattern is the thing to avoid**, not just the fact. The
>   original text attributed an observation to a guessed cause ("most likely an
>   embedded build timestamp"), promoted that guess to "expected", and then
>   used it to justify not checking binary hashes at all. Verifying
>   `GUPPYSCREEN_CHANGED` by source pin identity remains reasonable; declaring
>   hash comparison "not a meaningful comparison" on the strength of an
>   unverified cause was not.

## What changed to reach this candidate

- **Overnight closure mission (Missions A–L)**: checkpoint execution
  semantics fixed (candidate/promotion pipeline gated on real motion
  completion via `mcu.estimated_print_time()`), physical-recovery analysis
  (`SAFE_AUTOMATIC_POSITION_RECOVERY=NO`, honestly concluded), the formal
  `PLR_SUPPORTED_CONTRACT`, an adversarial storage-transaction review (no
  new gap), an EEPROM endurance calculation (no concern), the
  `candidate-post-build` SOURCE/BUILD/HARDWARE-QUALIFIED distinction, the
  hardware qualification harness, and the regression matrix. Full detail:
  [`_project/missions/phase1-overnight-closure-final-report.md`](../../_project/missions/phase1-overnight-closure-final-report.md).
- **Final candidate cleanup mission**: fixed the one remaining
  `06-verify.sh` MISS (`[nebulaos_version]` — a stale check that grepped
  `printer.cfg`'s own text instead of following its `[include
  platform.cfg]`, where the section actually lives and always has). Fixed
  the one remaining pre-existing test failure (`test_nebulaos_compat`'s
  manifest-completeness check — `test_z_offset_probe_down_min_z.py`
  existed but was never declared in `nebulaos-extensions.json`, a
  trivial, zero-behavior-change manifest fix). Also found and fixed a
  genuine, previously-mischaracterized bug: `vendor/v4l-utils` appearing
  dirty was never reused-checkout staleness — it's a deterministic side
  effect of `04-cross-compile-app-stack.sh`'s own `autoreconf`/`autopoint`
  workaround for that vendor's build, present on every build including a
  genuinely fresh one, and `06-verify.sh`'s allowlist had simply never
  been updated for it.

## Build verification

```
sh scripts/build/assert-baseline-config.sh pre-build            # SOURCE_VERIFIED
sh scripts/build/assert-baseline-config.sh candidate-post-build # BUILD_VERIFIED
sh scripts/build/06-verify.sh                                    # rootfs/DTB/config content
```

All three were run against this exact candidate's own genuinely clean
build (fresh `vendor/`, no reused state, canonical `build.sh` /
pinned container). Result: **215 OK / 0 MISS** from `06-verify.sh`,
`BUILD_VERIFIED` from `candidate-post-build`, zero failures across the
full 398-test offline suite (336 Python `unittest` + 62 shell-test-suite
assertions across `host-mcu-tests.sh`/`recovery-safety-tests.sh`/
`plr-tombstone-tests.sh`/`candidate-vs-qualified-baseline-tests.sh`). See
the Phase 1 final candidate cleanup report for the exact per-suite
accounting.

`VENDOR_DRIFT=0` — every pinned component (kernel, buildroot, klipper,
moonraker, k1-ustreamer, v4l-utils, guppyscreen, pellcorp-creality)
verified clean, from a genuinely fresh, network-only fetch, no allowlist
gaps remaining.

## Explicit non-promotions

- `manifests/dependencies.conf`'s `QUALIFIED_BASELINE_TAG` is **unchanged**
  — still `nebulaos-canonical-baseline-2026-08-14-prtouch-qualified`.
  Promoting it to a new tag covering this candidate is a separate,
  deliberate action to take only after tomorrow's hardware qualification
  passes.
- Neither branch is merged to `main`.
- Nothing in this candidate is described anywhere as "hardware-qualified".

**Tomorrow, qualify only these exact artifacts. Do not rebuild before
hardware testing.**
