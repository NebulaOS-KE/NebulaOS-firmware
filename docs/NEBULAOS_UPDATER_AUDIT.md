# Moonraker updater + canonical branch audit

2026-08-07/08, Clean-Update + Virgin Baseline mission, Phase 1. Full audit
of every Moonraker-managed component: path, remote, tracked branch,
local/remote HEAD, dirty state, update method, recovery method. Real bug
found and fixed as part of this audit (see "Klipper branch divergence"
below) - this document exists specifically because that class of bug
(two branches, only one actually tracked, silently diverging) is exactly
what this audit is designed to catch before it recurs.

## Klipper

| Field | Value |
|---|---|
| Path (device) | `/opt/klipper`, bind-mounted from `$NEBULAOS_ROOT/apps/klipper` (`/usr/data/nebulaos/apps/klipper`, `mmcblk0p10`) by `S05nebulaos-activate` |
| Remote | `https://github.com/coreflake1/NebulaOS-klipper.git` (real fork, not upstream `pellcorp/klipper` directly - see `manifests/dependencies.conf`'s own comment) |
| Update manager | `[update_manager klipper]` - one of Moonraker's two **reserved** slots (confirmed against `vendor/moonraker`'s own `update_manager/common.py`: `type`/`origin`/`path` are hardcoded internally and auto-discovered live from Klippy's identify handshake, not read from config). Only `channel`/`pinned_commit`/`refresh_interval`/`report_anomalies` are real config options here. |
| Tracked branch | **Whatever branch the live checkout is currently on** - this is the crux of the bug below. Not a fixed setting; auto-discovered. |
| Recovery method | Moonraker's built-in git recovery (soft: fetch + reset to the tracked remote ref; hard: full re-clone) - resets to whichever branch the checkout is *currently* on, same auto-discovery as above |

### Klipper branch divergence - found and fixed

**The bug**: the live device's persistent checkout had three local branches -
`jun2025` (386fde4, unrelated old work), `master` (d839d03, tracked by
`origin/master`), and `nebulaos` (also d839d03 locally, but
`origin/nebulaos` had moved to `0e5785d` - the commit that actually
carries the accepted `z_compensate` structured-status contract and
prtouch fixes). The checkout was sitting on `master`, at the *old* commit.
Moonraker's reserved-slot auto-discovery therefore reported `master`
(`d839d03`) as Klipper's real version - not because anything was
misconfigured, but because the accepted code had only ever been pushed to
a side branch nobody made canonical.

**Verification before fixing**: confirmed via `git merge-base
--is-ancestor` that `master`'s old tip (`d839d03`) is a direct ancestor of
`nebulaos`'s tip (`0e5785d`) - a single commit, pure linear history, zero
divergent content. Fast-forwarding is unconditionally safe here; no merge,
no rebase, no force-push needed.

**The fix**:
1. `git push nebulaos-remote 0e5785d:refs/heads/master` - fast-forwarded
   `master` on `coreflake1/NebulaOS-klipper` to include the accepted
   commit. `nebulaos` branch left untouched (not deleted, not rewritten) -
   it now just points at the same commit `master` does.
2. `manifests/dependencies.conf`'s `KLIPPER_BRANCH` switched from
   `nebulaos` to `master` - the build now pins/fetches from the same
   branch Moonraker's factory-seed has always assumed is canonical
   (`S04nebulaos-factory-seed`'s own doc comment already said "master
   branch" - it just wasn't true until this fix).
3. On the live device (see the prior session's own live fix, done ahead
   of this formal audit): the persistent checkout's `git status` showed
   only the one already-expected/allowlisted difference
   (`klippy/chelper/c_helper.so`, a locally-compiled binary that
   naturally differs from git's tracked bytes on every device) - zero
   real source drift.

**Result**: one canonical branch (`master`), containing all accepted
code, tracked by both the build manifest and Moonraker's live
auto-discovery. No accepted feature exists only as local dirt anymore.

## Moonraker

| Field | Value |
|---|---|
| Path (device) | `/opt/moonraker` area, `$NEBULAOS_ROOT/apps/moonraker`, running from `$NEBULAOS_ROOT/envs/moonraker` venv |
| Remote | `https://github.com/Arksine/moonraker.git` - official upstream, not forked |
| Update manager | `[update_manager moonraker]` - the other reserved slot, same auto-discovery rules as Klipper |
| Tracked branch | `master` (upstream's own default) |
| Local/remote HEAD | `d5ee171` (`paneldue: parse fix`) == `origin/master` - confirmed via a fresh clone during this mission's own build, zero divergence |
| Dirty state | Clean |
| Recovery method | Same Moonraker built-in git recovery as Klipper |

No divergence found - official upstream, single branch, pin matches tip
exactly. No fix needed.

## Mainsail

| Field | Value |
|---|---|
| Path (device) | Two copies exist: `/usr/share/mainsail` (immutable, baked into the read-only squashfs from the build's pinned `MAINSAIL_TAG`) and `$NEBULAOS_ROOT/apps/mainsail` (persistent, `/usr/data`) - `S05nebulaos-activate` bind-mounts the **persistent** copy over the immutable one, so what's actually served is the persistent copy, not necessarily the build-pinned one |
| Update manager | `[update_manager mainsail]`, `type: web`, `channel: beta`, `repo: mainsail-crew/mainsail` - a real, independent Moonraker web-app updater, not a git checkout |
| Build pin | `manifests/dependencies.conf`'s `MAINSAIL_TAG=v2.18.2` (exact release archive, sha256-verified at fetch time) |
| Runtime tracking | Moonraker's own `beta` channel from `mainsail-crew/mainsail` directly, independent of the build pin |

**A real, lower-severity duplicate-source-of-truth, noted but not fixed
this mission**: the build pins one exact Mainsail version; the live,
served copy can independently update itself to a newer upstream `beta`
release via Moonraker at any time, with no relationship back to the
manifest pin once that happens. Unlike Klipper, this is standard,
widely-expected behavior across the whole Klipper-firmware ecosystem
(most users deliberately let their web UI self-update this way), and
Mainsail is a third-party web app, not this project's own accepted-
baseline-critical code - drift here doesn't silently lose an accepted
NebulaOS feature the way Klipper branch drift did. Left as a known,
intentional design point (see Phase 2's ownership decision below), not
something requiring the same fast-forward treatment.

## NebulaScreen (current state, Run 19, 2026-10-24)

The "GuppyScreen" table below is the Phase 2 snapshot and no longer
describes the image. Current state (from source):

| Field | Value |
|---|---|
| Path (device) | image copy `/opt/nebulascreen` (squashfs); downloaded releases in `/usr/data/nebulaos/apps/nebulascreen`, bound over the image copy only after the update supervisor approved them |
| Remote | `https://github.com/NebulaOS-KE/NebulaOS-nebulascreen.git` (renamed from `NebulaOS-guppyscreen`; the old URL redirects) |
| Update manager | `[update_manager nebulascreen]`, type `zip`, channel `stable`, in the image-owned `/etc/nebulaos/moonraker/nebulascreen-update.conf`, **active** (included from `nebulaos.conf`) since Run 19 |
| Image pin | `NEBULASCREEN_PIN` / `NEBULASCREEN_VERSION` in `manifests/dependencies.conf` |

See `NEBULAOS_UPDATE_OWNERSHIP.md`, "NebulaScreen".

## GuppyScreen

| Field | Value |
|---|---|
| Path (device) | `/opt/guppyscreen` - immutable, squashfs-resident binary, **not** persistent-data-backed |
| Remote | `https://github.com/coreflake1/NebulaOS-guppyscreen.git` |
| Update manager | **None** - no `[update_manager guppyscreen]` section exists in `moonraker.conf`, by deliberate design (see that file's own comment: "GuppyScreen stays served from its immutable /opt/guppyscreen copy this mission, updating it is explicitly a separate, future mission") |
| Tracked branch | `main` |
| Local/remote HEAD | `be5d372` == `origin/main`, confirmed clean |
| Dirty state | Clean (the two submodule differences (`libhv`, `spdlog`) already documented/allowlisted in `06-verify.sh` are build-time-only, in the vendor checkout, not the deployed device) |

No divergence, no conflicting update path already exists here - this is
the target end state Phase 2 asks for, already true for GuppyScreen
specifically. Confirmed, not changed.
