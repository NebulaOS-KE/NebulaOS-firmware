# Component update ownership

2026-08-07/08, Clean-Update + Virgin Baseline mission, Phase 2. One
explicit owner per component - no component may have two independent
paths that can each change what's actually running, since that's exactly
the class of bug Phase 1 found and fixed for Klipper.

## The Klipper stack (Klipper + the NebulaOS extension set)

**Owner: the qualified PAIR. Neither half has an independent owner.**

Updated 2026-08-17 by the Phase 1 no-fork migration. NebulaOS no longer
hosts a Klipper fork. Two components now make up what used to be one:

| | Source | Pin |
|---|---|---|
| Klipper | `Klipper3d/klipper`, `master` — **official upstream, unmodified, zero core patches** | `KLIPPER_PIN` |
| Extensions | `coreflake1/NebulaOS-klipper-extensions`, `main` — everything this project actually owns | `KLIPPER_EXTENSIONS_PIN` |

- **Build time:** both pins are fetched into their own factory-seed
  archives. Neither archive contains anything belonging to the other.
- **Boot time:** `S05nebulaos-activate` composes them — each managed module
  is symlinked from the extension checkout into
  `apps/klipper/klippy/extras/` and listed in that clone's own
  `.git/info/exclude`. Both checkouts stay content-pristine;
  `git status --porcelain` is empty in both, always, on a running device.
- **Run time:** Moonraker's reserved `[update_manager klipper]` slot and a
  separate `[update_manager nebulaos_klipper_extensions]` section can each
  update their own checkout. Both are pinned to the qualified pair, in a
  firmware-managed include (see below).
- **Validation:** `/etc/nebulaos-update-supervisor.sh` treats
  `(klipper_sha, extensions_sha)` as one transactional unit. It never
  records a known-good pair until *both* halves have passed, and any
  failure restores *both*.

### Why the pair, and not two components

Because the two ways they can drift apart are both total outages, not
degradations:

- **New Klipper, old extensions.** A Klipper update touching anything in
  `klippy/chelper/` makes the shipped cross-compiled `c_helper.so` older
  than a source. Klipper decides whether to rebuild by comparing *mtimes*,
  so it shells out to `gcc` — which this device does not have. Klippy does
  not start. API drift lands here too; mainline has already renamed
  `MCU.register_response()` once.
- **New extensions, old Klipper.** The extension set's own preflight
  correctly refuses to load against a Klipper it was not qualified
  against.

Both are caught *before* Klippy is restarted, not after: the supervisor
recomposes, re-runs the collision guard, and re-checks the `c_helper.so`
mtime invariant as part of the transaction, while the printer is still
running the old pair. Since G72 (2026-10-17) the first case is usually
repaired rather than refused: the supervisor installs the `c_helper.so`
built for the new sources from its cache or the NebulaOS package index, and
a rollback finds the old pair's library in the cache.

### Moving the qualified pin

**Phase 1.5 persistent-namespace mission (2026-08-18):** the pins moved from
`printer_data/config/nebulaos/klipper-pin.conf` (persistent, kept in sync by
`S04nebulaos-migrate` on every boot) to `/etc/nebulaos/moonraker/
klipper-pin.conf` — **SLOT/IMAGE OWNED**, on the read-only rootfs. This
closes a real gap the old location had: `/usr/data` is shared, not
duplicated, across the A/B boot slots, so a device rolled back to an older
slot would still read the newer slot's persistent copy of the pin. Living
on the rootfs means an A/B switch or rollback restores the matching pins
automatically, simply because the rootfs changed — no sync step, no
migration-direction dependency. See `NEBULAOS_PERSISTENT_NAMESPACE.md` for
the full reasoning.

`moonraker.conf` is USER OWNED and carries only a stable
`[include /etc/nebulaos/moonraker/klipper-pin.conf]` line (an ordinary
absolute-path include — confirmed against Moonraker's real pinned
`confighelper.py`, which treats a leading `/` as absolute by design), so
advancing a pin is an ordinary firmware update rather than a request that
every user hand-edit a config file. The full procedure for moving a pin —
compose, run the extension suite, re-verify `required_klipper_symbols`,
rebuild `c_helper.so`, **re-qualify on real hardware**, then move both pins
and the manifest together — is in
`NebulaOS-klipper-extensions/docs/COMPATIBILITY.md`.

**Known limitation:** a device provisioned before this exact include line
existed will not have it, because nothing may rewrite a user-owned file
except the one bounded, idempotent migration in
`NEBULAOS_PRINTER_CFG_MIGRATION.md`, which does cover this exact line
(recognizing the old relative-glob form and rewriting only that one line).
A device whose `moonraker.conf` predates even that old form keeps working
but ignores the managed pins until the line is added by hand.

### A firmware update overrides a separately-updated Klipper

Stated plainly because it will otherwise read as a bug. If you update
Klipper or the extensions yourself through Mainsail, and later flash a
firmware image whose `migration_version` differs, `S04nebulaos-migrate`
replaces both checkouts with the image's versions. This is the appliance
model and it is deliberate — it is how Klipper and Moonraker have always
been treated here. Your previous tree is **not** destroyed: it is moved
intact to `$SYSTEM/migration-backups/<timestamp>/`, and the migration is
all-or-nothing, so a partial failure advances no generation and retries on
the next boot.

A retry does **not** create a second backup directory. It reuses the one the
first failed attempt created, so a persistent failure cannot accumulate one
backup per boot. Your original pre-migration tree stays in that directory
untouched across every retry. If you changed the checkout yourself between the
failed attempt and the retry - a Mainsail update, or your own commit - that
tree is not silently discarded either: it is only removed when it is provably
identical to the incoming seed and clean, and otherwise it is preserved
alongside as `<component>.diverged-<timestamp>` with a warning in the boot log.

## GuppyScreen

**Owner: NebulaOS firmware/release only. No independent updater exists,
and none should be added without a deliberate future mission.**

- Canonical source: `coreflake1/NebulaOS-guppyscreen`, `main` branch,
  pinned via `GUPPYSCREEN_PIN`.
- Served from `/opt/guppyscreen` - **immutable, squashfs-resident**, not
  persistent-data-backed. A new image ships a new binary automatically;
  there is nothing for a live updater to manage.
- No `[update_manager guppyscreen]` section exists in `moonraker.conf`,
  confirmed deliberate (that file's own comment already states this).
  **This document formalizes it as a standing rule, not just a current
  fact**: do not add a live GuppyScreen updater unless a future mission
  explicitly decides GuppyScreen should become persistent-data-backed
  (mirroring Klipper's model) - doing so silently, without also changing
  where the binary is served from, would recreate exactly the
  two-owners problem this phase exists to prevent.
- Found during this audit, noted as inert cruft, **not currently a
  conflict**: `/usr/data/helper-script/files/guppy-screen/guppy-update.sh`
  and sibling paths (`/usr/data/guppyscreen/`, `/usr/data/guppy-webrtc-
  stage/`, `/usr/data/guppyify-backup/`) are leftovers from a pre-NebulaOS-
  namespace provisioning era (SimpleAF/Creality-installer-style helper
  scripts), outside `$NEBULAOS_ROOT` entirely. Nothing in the current
  tracked build overlay references them (confirmed by grep) - they are
  dormant, not wired into any init script/cron/supervisor entry. Not
  cleaned up this mission (out of scope: this phase is about *active*
  update paths, not general persistent-partition archaeology), but
  flagged here so a future reader doesn't mistake their presence for a
  live, competing update mechanism.

## Kernel / rootfs / NebulaOS itself

**Owner: the NebulaOS package updater only** (`scripts/flash-spare-
slot.sh` + the OTA-marker mechanism) - **never** an ordinary `git pull`
replacing the running OS.

- This was already true before this mission - `flash-spare-slot.sh`'s
  entire design (fixed target slot, mandatory preflight, byte-verified
  write, separate deliberate marker-flip step) exists specifically to be
  the *only* way the running kernel/rootfs changes. There is no git
  checkout of kernel or Buildroot source anywhere on the live device -
  `vendor/x2000_kernel_6.6` and `vendor/buildroot-x2000` are build-host-
  only, gitignored, never shipped to the printer.
- Formalized here as a standing rule for the same reason as GuppyScreen's
  entry above: any future convenience script that tries to "quick-patch"
  the running kernel/rootfs via anything other than this flow would
  recreate the two-owners problem.

## Mainsail

**Owner: intentionally dual, by ecosystem convention - not a bug, but
documented as a deliberate exception to the "one owner" rule.**

See `docs/NEBULAOS_UPDATER_AUDIT.md`'s own Mainsail section for the full
detail. Unlike the three components above, Mainsail is a third-party web
UI, not NebulaOS-owned application code - letting Moonraker's own web-
updater track upstream `beta` releases independently of the build's pin is
standard practice across the whole Klipper-firmware ecosystem, and Mainsail
drifting to a newer release cannot silently lose an *accepted NebulaOS
feature* the way Klipper branch drift could (there is no NebulaOS-authored
code in Mainsail to lose). Left as-is.
