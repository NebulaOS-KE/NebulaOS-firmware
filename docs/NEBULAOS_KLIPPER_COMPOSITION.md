# Klipper composition — running official Klipper without a fork

2026-08-17, Phase 1 no-fork migration. NebulaOS runs **official, unmodified
`Klipper3d/klipper`** and activates its own modules alongside it. Zero core
Klipper patches, zero Moonraker patches, zero kernel changes.

This document is the runtime half: how the two checkouts become one working
Klipper, what is checked, and what happens when a check fails. The
feasibility analysis behind it is
`_project/missions/2026-08-phase1-klipper-no-fork-analysis.md`; the
compatibility contract is
`NebulaOS-klipper-extensions/docs/COMPATIBILITY.md`.

## The constraint that decides the design

Klipper's module loader is a **filesystem gate, not an import path**.
`Printer.load_object()` does

```python
py_name = os.path.join(os.path.dirname(__file__), 'extras', module_name + '.py')
if not os.path.exists(py_name) and not os.path.exists(py_dirname):
    raise self.config_error("Unable to load module '%s'" % (section,))
mod = importlib.import_module('extras.' + module_name)
```

That check runs **before** `importlib` is ever reached. `PYTHONPATH`, a
`.pth` file, a namespace package, appending to `extras.__path__`, a wrapper
launcher that fixes `sys.path` — every one of them is defeated by it. A file
has to physically resolve at `<klipper>/klippy/extras/<name>.py`.

But `os.path.exists()` follows symlinks, and git can be told to ignore a
path per-clone. That is the whole mechanism.

## What actually happens at boot

```
/usr/data/nebulaos/apps/klipper/                     official Klipper3d/klipper
/usr/data/nebulaos/apps/nebulaos-klipper-extensions/ the NebulaOS extension set

apps/klipper/klippy/extras/<module>.py  ->  symlink into the extension repo
apps/klipper/.git/info/exclude          <-  one line per managed name
apps/klipper/.nebulaos-composed             generation marker (itself excluded)
apps/klipper/.nebulaos-chelper-verdict.json chelper preflight result (excluded)

/opt/klipper                            bind mount of apps/klipper, as always
```

`.git/info/exclude` lives inside `.git/`, is never part of any working tree,
and is never reported by any git status command. The result is that **both
checkouts stay content-pristine**: `git status --porcelain` empty in both,
`git describe --dirty` with no `-dirty`, and Moonraker reporting
`pristine: true`, `is_valid: true`, zero anomalies.

Composition runs in the **S05 slot** — after `S04nebulaos-migrate`, before
`S55klipper`. That ordering is load-bearing: migration replaces the whole
`apps/klipper` tree on a generation bump, which destroys the symlinks living
inside it, and Klipper must not start before they are back.

Implementation: `/etc/nebulaos-klipper-compose.sh`. The module list comes
from the extension repo's `nebulaos-extensions.json`, never from a hardcoded
list in the firmware.

## The one real hazard

If upstream Klipper ever ships a regular file at a path this project also
manages, **git silently replaces the symlink with upstream's file** — exit
code 0, no warning, nothing in any status output. The extension is then
shadowed: Klippy runs upstream's code while every version report still says
NebulaOS.

The names most exposed are the vendored community ones —
`gcode_shell_command` and `virtual_pins` are exactly the kind of module
mainline could adopt.

So a regular file at a managed destination is a **hard error**. It is never
overwritten, never worked around, never logged-and-continued. Verification
runs on *every* invocation, including the ones that skip the rebuild,
because the whole point is catching a change that produced no error.

Three layers enforce it:

| Layer | When | Catches |
|---|---|---|
| `/etc/nebulaos-klipper-compose.sh` | boot activation, and inside every update transaction | the authoritative check — refuses to activate |
| `/etc/nebulaos-update-supervisor.sh` | after any change to either half, **before** Klippy restarts | a Klipper update that introduces a collision |
| `extras/nebulaos_compat.py` | Klippy config load, first NebulaOS section | deployments the platform never saw — hand-updated checkouts, restored backups, developer installs |

## `c_helper.so` — a timestamp that decides whether the printer boots

Klipper decides whether to rebuild its C library by comparing **mtimes**,
not hashes. If any `.c`/`.h`/`__init__.py` in `klippy/chelper/` is newer than
`c_helper.so`, mainline shells out to `gcc`. This device has no toolchain, so
`do_build_code()` raises and **Klippy does not start**.

This is why NebulaOS needs no patch to `klippy/chelper/__init__.py`, and it
is why the invariant is enforced in two places rather than assumed in one:

- **Build time** (`04-cross-compile-app-stack.sh`, `make-seed-archive.sh`):
  the `.so`'s mtime is pushed forward as the *last* step over every staged
  copy, then verified as a hard gate. This is not belt-and-braces. `cp -r`
  does not preserve mtimes, and `git checkout` / `git read-tree -mu` rewrite
  them — so without an explicit step, whether the library ends up newer than
  its sources is decided by directory-walk order. On a bad roll the image
  simply does not boot.
- **Boot time** (`S05nebulaos-activate` via
  `/etc/nebulaos-chelper-preflight.sh`): re-checked against the tree that is
  actually about to run, because packaging correctness does not survive a
  later `git pull` or a rollback. The verdict is published where
  `nebulaos_compat.py` reads it, so a stale library surfaces as a named
  preflight refusal rather than a gcc crash part-way through boot.
- **After a Klipper update** (G72, 2026-10-17): the library no longer comes
  only from the image. Before the verdict, a library matching the tree's
  chelper source hash is installed from the local cache (S05 and the
  supervisor) or the NebulaOS package index (supervisor only) - see
  `NEBULAOS_PLATFORM_APP_BOUNDARY.md`. Never a blind touch: only a library
  built from exactly these sources.

## Failure behaviour

Every failure above leaves `/opt/klipper` on the **immutable squashfs copy**
and does not activate the persistent one. That is this system's existing
"doing nothing at all is always safe" default, not a new failure mode.

The immutable copy carries the extension modules as **real files**, not
symlinks — the pristine-git requirement applies to the persistent checkouts
where Moonraker looks and where updates happen, not to the emergency
fallback, and a fallback missing every module the shipped `printer.cfg`
references would be no fallback at all.

### Identity in factory-fallback — decided: ACCEPTED

`nebulaos_compat.py` identifies the running Klipper with
`git -C <checkout> rev-parse HEAD`. The immutable copy is not a git checkout
and never will be — carrying Klipper's history in the squashfs is not worth
it — so in `factory_fallback()` that check cannot pass, and Klippy refuses to
start with that module's own precise message.

**Decision (2026-08-17, Phase K): accept it as shipped for hardware
qualification.** The reasoning, from what `factory_fallback()` actually is
rather than from the policy statement:

- It is not a recovery path the device takes on its own. Every call site
  (`stack_roll_back()` and the three per-component equivalents) is reached
  only after an update has *already* failed validation **and** one of: no
  known-good pair exists yet, the known-good pair could not be restored and
  recomposed, or the restored known-good pair *also* failed validation. The
  persistent stack is unusable by the time this runs.
- It is terminal by construction. It holds `$LOCKDIR/klipper-stack.lock`, and
  `poll_klipper_stack_once()` returns immediately for as long as that lock
  and the `factory-fallback` state coexist. A human has to clear it. The
  printer is not autonomously recovered in either design.
- So what is actually lost is narrow: the case where both persistent
  checkouts are unusable but the squashfs copy would have printed — which
  requires the failure to be localised to `/usr/data` (corruption, a torn
  extraction, a bad object store) rather than to the config or the hardware.
- In exchange, the operator gets a named, specific stop instead of a start.
  The alternative is worse than it sounds: the pre-Phase-1 behaviour was to
  start an emergency Klipper whose extension pairing nothing had verified,
  and then drive a load-cell probe into a bed with it. "Stopped, and said
  exactly which checkout it could not identify" is the safer half of that
  trade on a machine that can push a nozzle into glass.
- It cannot cause motion. It prevents motion. It is not a new hardware risk,
  and it does not gate hardware qualification.

**Follow-up (not a blocker, not done here):** the clean fix is already
modelled by something that exists. The build bakes
`.nebulaos-chelper-verdict.json` into `/opt/klipper` precisely because that
tree is read-only at boot; an identity file baked the same way, named by a
new manifest key alongside `chelper.platform_result_file`, would let
`check_klipper_commit()` fall back to a platform-signed answer when the tree
has no `.git`. That restores the pre-Phase-1 capability without weakening any
check. It costs one manifest key and a small change in both repositories, and
it should be done deliberately rather than folded into a qualification night.

**For tomorrow's hardware test:** the deliberate bad-update rollback case is
expected to end in `rolled-back` with the known-good pair re-validated, not
in factory-fallback. If it *does* reach factory-fallback, Klippy refusing to
start is the expected, documented behaviour described here — not a new fault
to debug at the printer.

## The persistent "58bd67d-dirty" symptom (RC2 overnight closure, 2026-09-06)

Every hardware boot from Phase 1.8B candidate-001 (2026-08-28) through RC1
(2026-09-05) has reported Klipper's own runtime version as
`58bd67d-dirty` — contradicting the "both checkouts stay content-pristine"
claim above and this project's zero-core-patches architecture.

Root cause, found by reading `compose_ensure()` directly rather than
guessing: `compose_verify_pristine()` — the function that actually runs
`git status --porcelain` on both checkouts — was only ever called from
inside `compose_build()` (an actual rebuild). The common "fast path" (marker
signature unchanged, i.e. every ordinary reboot once a device has composed
successfully once) called `compose_verify()` (symlink-resolution
correctness) but never `compose_verify_pristine()`. So whatever was making
Klipper's own `git describe --dirty` (`klippy/util.py:get_git_version()`,
unmodified upstream) see a difference has been silently unchecked on every
normal boot since the very first one.

`TRACKED_UPSTREAM_KLIPPER_MODIFICATIONS=0` still holds architecturally (no
host-Klipper patch mechanism exists anywhere in this project), and the
leading, most plausible explanation is not a real modification at all:
`git describe --dirty` is sensitive to file **mode** changes with zero
content difference, and this project's own packaging pipeline (`cp -r` /
tar extraction into the rootfs image, the same class of "doesn't preserve
what a host git checkout recorded" issue the `c_helper.so` mtime section
above already documents for a different property) does not guarantee mode
bits survive identically.

Two changes, both offline-verifiable and neither hiding any real
modification:

1. **`compose_disable_filemode_tracking()`** sets `core.fileMode false` on
   both checkouts, unconditionally, every time `compose_ensure()` runs. This
   makes git ignore mode-only differences — it does **not** suppress
   detection of any actual content change, which `compose_verify_pristine()`
   still reports in full.
2. **The fast path now also calls `compose_verify_pristine()`**, and logs a
   named `WARNING:` line if the checkout is not pristine. This is
   deliberately **not** wired to fail activation the way a symlink-verify
   failure is: composing again cannot fix a real tracked-file change (a
   rebuild only ever touches symlinks and the exclude file), and refusing to
   activate Klipper over an unconfirmed hypothesis — with no real hardware
   available overnight to prove which explanation is correct — risks the
   OTA safety net falling back to the stock slot on every boot, which is a
   far worse outcome than a misreported version string. See
   `tests/klipper-composition-tests.sh` section 15.

**Not claimed fixed.** Fix (1) removes the single most plausible false-
positive source without changing any detection behavior; fix (2) makes the
symptom visible in boot logs for the first time instead of silently
unchecked. Neither was validated against real hardware (printer powered off
for this mission) — `docs/qualification/rc2-morning-hardware-acceptance.md`
adds a step to capture `git -C <checkout> status --porcelain` directly from
the booted device and confirm the WARNING line is now absent (or, if still
present, to finally capture the exact dirty path that (1) didn't cover).

## Recovery and crash safety

Rebuilds always start from a **full teardown** rather than reconciling in
place, because a half-completed prior run is a state this device really
reaches — power loss, OOM kill, a reboot mid-boot. The generation marker is
an optimisation for skipping work, never the safety property; it is written
last and atomically, so a partial one cannot exist, and verification runs
independently of it.

Exclude entries are written **before** the symlinks they cover, so the
checkout is not dirty even transiently mid-compose. Exclude writes are
grep-before-append, so repeated boots cannot accumulate duplicate lines.

## Tests

| File | Covers |
|---|---|
| `tests/klipper-composition-tests.sh` | composition, idempotency, teardown/rebuild, the collision guard, path traversal, improper link targets, five half-completed-run recovery cases, both chelper directions |
| `tests/klipper-stack-lifecycle-tests.sh` | seeding with real origins, pair atomicity, migration of both halves, composition auto-rebuild after migration, the shared stack lock |
| `tests/klipper-stack-update-tests.sh` | the six update-ordering and failure scenarios, driven through the real supervisor |
| `tests/moonraker-klipper-stack-config-tests.py` | the shipped Moonraker config, checked against Moonraker's real source at the pinned commit |
| `tests/klipper-config-load-smoke-tests.py` | **real Klipper loading the real shipped `printer.cfg`** on a really-composed pinned pair — every include, every module's `load_config()`, Klipper's own `check_unused_options()`, the GD32 sensor type resolving, and three refusal cases |
| `tests/klipper-git-survival-tests.sh` | fetch / ff-only pull / `reset --hard` / branch + detached checkout / `clean -d -f` / `gc` / `stash` against a real remote, plus `clean -x` destruction-and-recovery, the silent upstream-collision hazard, and hard-reclone recovery |
| `tests/recovery-safety-tests.sh` | that Moonraker's Recovery cannot revert an accepted feature under the new two-checkout architecture |

Only `recovery-safety-tests.sh` and the two suites' source lookups touch the
network, and only to read public/pinned git remotes. None of them touch a
device or a printer.

`klipper-config-load-smoke-tests.py` stops exactly where Klipper itself stops
offline. Everything downstream of `klippy:mcu_identify` — MCU pin-name
validation, command lookup, PRTouch's proprietary message formats — needs the
mainboard's GD32 data dictionary, which exists only on the printer and only
arrives over serial. Those are hardware tests, not something a host suite can
honestly claim.

## What is still unproven

Everything above is static and host-side. It says nothing about whether a
load-cell probe behaves correctly against mainline's independently
refactored `probe.py`, `toolhead.py`, `mcu.py` and `motion_queuing` — 588
commits of it. That is hardware qualification's job, and no amount of green
tests substitutes for it.
