# Image install and the trial

How a whole system image gets onto a printer, what bounds the trial that follows, and how the
component checkouts (Klipper, Moonraker) update separately from the image. Written against
`NebulaOS-firmware` at `b95b156`; the shipping release is 1.0.2, firmware `3bdf3ff`.

Read [Architecture](Architecture) first - the two slots and the boot marker are what makes any
of this safe.

## Installing a system image

A system image is written into the slot that is **not** running, so the running system is never
touched. Then the printer restarts into it.

The API path is `machine.nebulaos.image.*` - `list`, `status`, `check`, `install`, `ack` - and
the work happens in `nebulaos_osconfig/image.py`. Images can come from a USB stick, a Mainsail
upload, or an online download (`machine.nebulaos.ota.*`).

### The trial, and why it is bounded two ways

After an install from the screen, the new slot starts **on trial**. From
`nebulaos_osconfig/image.py`:

- `TRIAL_SECONDS = 300` - five minutes to come up.
- `TRIAL_ATTEMPTS = 3` - three starts that never confirm.

Either bound exhausting switches back to the previous slot, once, automatically.

Two bounds rather than one, because there are two distinct failure shapes. A system that hangs
needs a timeout. A system that crashes and reboots cleanly would reset a timeout forever, so it
needs an attempt count instead. One without the other leaves a gap.

A screen shed by the memory guard counts as a successful start, and a power cut during the trial
makes the trial run again on the next boot.

**This trial applies only to installs from the screen.** An install through Creality's own
updater has no trial at all, which is worth knowing when comparing the two routes.

Note how this coexists with [Architecture](Architecture)'s MCU section: there is no automatic
fallback to *stock*, but there *is* an automatic fallback between two NebulaOS slots. The
difference is that switching between NebulaOS slots does not touch the MCU.


## The other kind of update: the component checkouts

A system image carries the kernel, the root filesystem and NebulaScreen. Klipper, the NebulaOS
Klipper extensions and Moonraker live in writable checkouts under
`/usr/data/nebulaos/apps/` and update through Moonraker's own update manager - the Update button
in Mainsail. That path never touches the kernel, the root filesystem or NebulaScreen.

`etc/nebulaos-update-supervisor.sh`, started by `S59nebulaos-update-supervisor` after Klipper,
Moonraker and NebulaScreen, watches that path. It is an independent poller rather than a
Moonraker plugin, on purpose: this Moonraker version's update manager has **no pre- or
post-update hook at all**, and a poller keeps working when a bad update breaks Moonraker
itself. What the script establishes, read from its own source at `3bdf3ff`:

- **Detection is git's own `HEAD`**, polled every `POLL_INTERVAL` seconds (default **20**). A
  commit that differs from the last recorded value means an update happened - through Moonraker
  or by hand; the supervisor does not care which.
- **The rollback unit for Klipper is the pair `(klipper_sha, extensions_sha)`**, not Klipper
  alone, because Moonraker can update either half independently with no ordering between them.
  New Klipper against old extensions makes Klipper's own mtime check try to rebuild
  `c_helper.so` with a compiler the printer does not have, and Klippy does not start.
- **Moonraker's source and its virtualenv roll back together.** Moonraker installs new
  requirements into the existing venv in place, so `git reset --hard` on the source alone would
  leave the venv changed. The supervisor keeps one paired backup, refreshed whenever a
  (source, venv) pairing validates healthy, and restores both halves in the same step.
- **Nothing is restarted under a print.** The shared busy check (`etc/nebulaos-busy.sh`) runs
  before every restart, reset, unmount or recompose step, and a busy printer *defers* the step
  to a later poll as a recorded state rather than waiting on it. A Moonraker-only rollback is
  the exception: it never touches Klipper, and the screen needs Moonraker.
- **If both the new and the previous version fail validation**, `factory_fallback()` restores
  the untouched copy baked into the image and leaves the component locked in state
  `factory-fallback`, so it cannot flip-flop on its own.

The design record is `docs/NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md`; the supervisor's own header
is the honest version of it, and five test suites in `tests/update-supervisor-*.sh` cover the
deferral, settle and marker behaviour.
