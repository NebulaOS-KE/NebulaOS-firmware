# Updating an existing NebulaOS install

> **Superseded (2026-10):** NebulaScreen now updates through Moonraker too, and system images install from the screen (USB, upload or online). Current guide: the wiki's [Updating NebulaOS](https://github.com/NebulaOS-KE/NebulaOS-nebulascreen/wiki/Updating-NebulaOS). Kept as history.

This assumes NebulaOS is already installed and booted. If it isn't yet, start with
`docs/DEVELOPER_INSTALL_FROM_STOCK.md`.

There are two different kinds of updates here, and it's easy to mix them up if you haven't worked
on this project before. There's also a third thing — a planned future update mechanism — that
doesn't exist yet. Let's go through all three.

## Klipper and Moonraker updates — this works today

Klipper and Moonraker (the checkouts under `/usr/data/nebulaos/apps/{klipper,moonraker}`) update
through Moonraker's own update manager — the same "Update" button you'd normally see in Mainsail.
Nothing special here; it's the standard Klipper/Moonraker update flow. Neither one is pinned to a
specific commit, so they just track their branch tip.

This does **not** touch the kernel, the rootfs, or GuppyScreen. GuppyScreen in particular has no
update-manager entry at all — it ships baked into the squashfs image and only changes when you
flash a whole new build (see below). It also never touches your actual `printer.cfg`, macros, or
`moonraker.conf` — those live in a completely separate spot that this update path doesn't go near.

**If an update goes wrong**, there's a small background service (`nebulaos-update-supervisor.sh`)
that watches for it. It polls every 20 seconds, and if it sees a commit change, it runs a health
check — first that the files are actually there and importable, then that the whole printer stack
(Moonraker, Klipper, the MCU) actually comes up healthy. If that fails, it resets back to the last
known-good commit and restarts the service directly, rather than going through Moonraker's own API
(since a bad Moonraker update might have broken Moonraker itself). If even *that* fails, it falls
back to the untouched factory copy baked into the squashfs, and leaves things locked there until a
person clears it — it won't keep flip-flopping on its own.

We found two real bugs testing this on actual hardware: a false-positive rollback that fired too
soon after a restart (fixed with a small grace period), and some stale bookkeeping that could hide
a factory-fallback event from the next check (also fixed). It's been retested clean since.

One thing this doesn't handle yet: Moonraker's Python virtualenv isn't independently versioned or
rolled back. If a bad update's `requirements.txt` change ran a `pip install` before things broke,
resetting the source code with `git reset --hard` won't undo that. Still an open item.

## Updating the whole OS image — works, but it's manual

This replaces the kernel and rootfs — same mechanism as a first install, just run again on a device
that's already got NebulaOS on it:

```
build/download new xImage + rootfs.squashfs + build-manifest.txt
        |
scp to the device
        |
independent sha256sum check
        |
flash-spare-slot.sh --check-only   (confirms target slot 2 is inactive -
        |                            the OTHER slot from whatever's running now)
flash-spare-slot.sh                (writes + MD5 read-back verification)
        |
flip the marker, reboot
        |
same first-boot sequence as install (S00/S04/S5x/S99 - see A_B_SLOT_MODEL.md)
```

Worth saying plainly: **there's no "check GitHub, download a new build, and install it"
button yet.** Every step above is something a developer runs by hand. If you see this described as
automatic somewhere else, that's stale — this is the real current state.

## Where this is eventually headed

There's a design doc (`docs/NEBULAOS_OTA_FLOW.md`) sketching out a more automated flow down the
road — discover a release, download it, verify it, flash the inactive slot, reboot, confirm it's
healthy, mostly hands-off. That's a plan, not something that exists yet. The manual sequence above
is what actually happens today, so if an older doc anywhere describes automated OTA as already
working, don't trust it — this page is the current state.

## Related docs

- `docs/A_B_SLOT_MODEL.md` — the slot/marker mechanics behind the whole-image update path
- `docs/NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` — the full engineering writeup and test record for the component-update path
- `docs/NEBULAOS_UPDATE_OWNERSHIP.md` — which component owns which update path, and why GuppyScreen doesn't have one
- `docs/DEVELOPER_RECOVERY.md` — what to do if an update leaves the device unhealthy
