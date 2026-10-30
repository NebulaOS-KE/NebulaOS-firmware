# The canonical NebulaOS OTA flow

> **Superseded (2026-10):** releases are built by the NebulaOS repository's GitHub release workflow (`scripts/release/` here) and published as `.img` + `.ingenic`; see [RELEASE_ARTIFACTS.md](RELEASE_ARTIFACTS.md) and [README.md](README.md). Kept as history.

Clean-Update + Virgin Baseline mission, Phase 7 (2026-08-08). Every real
mechanism referenced here already exists (built across this and earlier
missions) - this document is the first place that states the full,
end-to-end flow in one place and names the one script/init-script
responsible for each step. **The one hard rule this flow exists to
enforce: a raw `git pull` (or any other ad hoc update mechanism) must
never be how a device's software actually changes.** Every real update
path goes through this flow, all the way to a device.

```
git main/tag
     |  (git tag -a, human-reviewed, see "who creates a tag" below)
     v
reproducible build            scripts/build/build-qualified-baseline.sh
     |  (fresh clone only - see Phase 8/build.sh --containerized)
     v
versioned release package     scripts/build/package-deployment.sh
     |  (images, configs, decompiled DTB)
     v
manifest + SHA256              build-manifest.txt + SHA256SUMS
     |  (in the same package directory)
     v
GitHub Release                 scripts/release.sh <tag>
     |  (tag-verified: refuses to publish unless the tag is pushed and
     |   matches origin exactly - see that script's own checks)
     v
verified download              gh release download / manual curl + sha256sum -c
     |  (operator or a future automated updater - not yet built, see
     |  "not yet automated" below)
     v
inactive slot write             scripts/flash-spare-slot.sh
     |  (hardcoded to slot2 only; refuses if slot2 is currently active;
     |  full safety preconditions - idle, no active print, heaters off)
     v
read-back verification          scripts/flash-spare-slot.sh's own post-write
     |  (byte-for-byte compare against the source image, not just a
     |  "write succeeded" return code)
     v
reboot                          operator-triggered (see FIRMWARE.md sec 21/22
     |                          for why this project never automates reboot)
     v
persistent migration            S04nebulaos-factory-seed + S04nebulaos-migrate
     |  (compares installed migration_version against this image's own -
     |  see docs/NEBULAOS_PERSISTENT_LIFECYCLE.md for the full mechanics)
     v
confirm-good                    S99confirm-good
     |  (polls Moonraker's own /server/info klippy_state - only flips the
     |  OTA marker forward once the real app stack is actually healthy,
     |  not just "init reached this point")
     v
rollback-on-failure             REMOVED as of Phase 1.8B - see below.
```

## Automatic rollback-to-stock was removed in Phase 1.8B (`phase1.8b/boot-safety`, 86a0c01)

**This section previously described `S00revert-safety` unconditionally arming an automatic
rollback to stock on every boot. That mechanism no longer exists — the description below is
historical, kept so the reasoning for the change is visible, not a description of current
behavior.**

Booting the stock Creality slot auto-flashes the GD32F303 MCU with old Creality firmware,
destroying whatever native MCU firmware is currently qualified and installed. The old design meant
any transient Klipper/Moonraker failure inside NebulaOS — not just a genuinely broken image — could
silently trigger exactly that MCU-destroying fallback on the next reboot. That risk outweighed the
convenience of automatic recovery.

As of Phase 1.8B: `S00revert-safety` is a deliberate no-op (it logs that automatic fallback is
disabled and why, and does not touch the marker). `S99confirm-good` still polls Moonraker's
`klippy_state` and logs the result, but no longer writes the marker on either the success or the
timeout path. **A NebulaOS boot that crashes, hangs, or never reaches a healthy Klipper/Moonraker
state now simply stays on NebulaOS** — there is no cable-free, button-free automatic path back to
stock any more. Manual recovery (SSH `write_ota_marker`, Creality's own tools, or USB mask-ROM
recovery) remains fully available — see `docs/DEVELOPER_RECOVERY.md` and
`docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md`. `docs/A_B_SLOT_MODEL.md` has the full current-state
description of what each script does now.

An update that lands on a genuinely broken image therefore now requires a human to notice and
manually recover, rather than self-healing on the next reboot — a deliberate trade of convenience
for hardware safety. This is tracked as a known limitation of the current A/B model (see the vNext
roadmap's Phase 6/7 discussion of pre-init rollback), not something Phase 1.8B claims to solve.

## Persistent migration is what makes a slot-flash-only update actually work

A `flash-spare-slot.sh` write only ever touches the squashfs
(kernel2/rootfs2) - never `/usr/data`. Before Phase 3/4 of this mission,
that meant a Klipper/Moonraker source update baked into a new image never
actually reached an already-provisioned device's persistent checkout (the
exact bug `docs/NEBULAOS_CANONICAL_DEPLOYMENT_QUALIFICATION.md` found
live). `S04nebulaos-migrate` closes that gap on every boot after a
successful flash+reboot, comparing the new image's `migration_version`
against what is actually installed and re-seeding only what changed - see
`docs/NEBULAOS_PERSISTENT_LIFECYCLE.md` for the complete mechanics.

## Who creates a tag

A canonical baseline tag is a deliberate, human-reviewed act - never
something a script creates as a side effect of building or packaging.
`scripts/release.sh` enforces this structurally: it refuses to publish a
release unless a tag *already exists* both locally and on `origin`, with
the two matching exactly. It cannot tag anything itself.

## Verified download

`SHA256SUMS` inside every release package covers every file in it. The
one supported verification is `sha256sum -c SHA256SUMS` run against the
downloaded files before they are ever passed to `flash-spare-slot.sh` -
that script does not re-verify hashes of its own accord, so skipping this
step means flashing unverified content.

## Not yet automated (real, honest gap)

There is currently no automated agent on a NebulaOS device that itself
performs "check for a new release, download it, verify it, flash it" -
every device-side step (download, `flash-spare-slot.sh`, reboot) is
currently operator-driven. This is intentional for now given this
project's own repeated finding that reboot and flash actions need a real
human confirming real device state immediately beforehand (see this
mission's own Phase 9/10 safety-check requirements) - a background
updater silently flashing an inactive slot while a print might be starting
is a real risk this flow does not yet take on. Building a supervised
on-device updater (one that still requires an explicit human trigger, but
automates the download/verify/flash sequence once triggered) is real,
separate, future work, not part of this mission.

## Scripts referenced by this flow

| Step | Script |
|---|---|
| Reproducible build | `scripts/build/build-qualified-baseline.sh`, `build.sh --containerized` |
| Package + manifest + SHA256 | `scripts/build/package-deployment.sh` |
| GitHub Release publish | `scripts/release.sh` |
| Inactive-slot flash + read-back | `scripts/flash-spare-slot.sh` |
| Boot-start no-op (Phase 1.8B: automatic rollback removed) | `scripts/build/overlay/etc/init.d/S00revert-safety` |
| Health diagnostic (Phase 1.8B: no longer writes the marker) | `scripts/build/overlay/etc/init.d/S99confirm-good` |
| Persistent migration | `scripts/build/overlay/etc/init.d/S04nebulaos-factory-seed`, `S04nebulaos-migrate` |
| Runtime version truth | `klippy_extras/nebulaos_version.py` (`[nebulaos_version]`) |
