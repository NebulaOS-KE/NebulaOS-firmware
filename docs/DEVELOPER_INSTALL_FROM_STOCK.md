# Installing a developer build from stock

> **Superseded (2026-10):** users install with Creality's own updater ([INSTALL_FROM_STOCK.md](INSTALL_FROM_STOCK.md)); developers use the Hardware Agent ([HARDWARE_AGENT.md](HARDWARE_AGENT.md)). Kept as history.

NebulaOS uses the KE's existing stock/custom A/B layout, which is genuinely convenient here: we
don't need to touch or overwrite the stock system to get a NebulaOS build onto the printer.
NebulaOS just goes into the second, custom slot that's normally sitting empty.

Read `docs/A_B_SLOT_MODEL.md` first if you haven't already — this doc assumes you already know how
the two slots and the OTA marker work.

This also assumes you already have root/SSH access on the printer's stock firmware. Getting that in
the first place is out of scope here — every Creality K1/KE mod project makes the same assumption,
and if you're reading this, you probably already have it sorted.

## The install, step by step

```
stock printer, root/SSH already available
        |
1. build or obtain: xImage, rootfs.squashfs, build-manifest.txt
   (from `./build.sh` - see docs/BUILD_FROM_SOURCE.md)
        |
2. scp xImage rootfs.squashfs build-manifest.txt scripts/flash-spare-slot.sh
   root@<printer-ip>:/usr/data/<some-staging-dir>/
        |
3. sha256sum the four transferred files, independently, before touching
   the flash script - confirm they match what you scp'd
        |
4. sh flash-spare-slot.sh --check-only xImage rootfs.squashfs build-manifest.txt
        |
5. sh flash-spare-slot.sh xImage rootfs.squashfs build-manifest.txt
        |
6. flip the marker to custom (see docs/A_B_SLOT_MODEL.md for why this
   is stock's own tool, not NebulaOS's):
   . /etc/ota_bin/ota_local_method.sh; local_set_next_boot_device
        |
7. reboot
        |
8. S00revert-safety / S04 factory-seed+migrate / S5x services / S99confirm-good
   (see docs/A_B_SLOT_MODEL.md - this is the same sequence every boot goes through)
```

A couple of things worth knowing before you start:

**Stage things in `/usr/data`, not `/tmp`.** `/tmp` on this board is a small `tmpfs`, and
`rootfs.squashfs` alone is well over 100 MB — it's easy to run out of space mid-transfer.
`/usr/data` is the real, ~6 GB persistent partition, so use that instead.

**Run `--check-only` first.** It doesn't write anything. It figures out which slot you're actually
booted from, checks the partition mapping and sizes, verifies the build manifest if you gave it
one, and refuses to continue if the target would overwrite the slot you're currently running. The
real flash (step 5) runs that exact same check again immediately before it writes anything — so an
earlier check-only pass is never treated as a stale green light.

What the checks actually cover:

1. **Slot mapping** — makes sure `/dev/disk/by-partlabel/{kernel,kernel2,rootfs,rootfs2}` all
   resolve to the device nodes we expect, so an unexpected partition table gets caught early.
2. **Active slot** — reads the real, live boot device straight out of `/proc/cmdline`'s `root=`
   value, not `/proc/mounts`, since the latter can't actually tell the two slots apart.
3. **Target slot** — always slot 2. You can't pick a different target; that's the point.
4. **Live-target collision** — refuses if the target and the active slot turn out to be the same
   device. This check exists because of a real incident — an earlier version of the script got this
   wrong once, and it wasn't fun to recover from.
5. **Image sizes** — checked against the partitions' real, fixed capacities.
6. **Manifest/hash verification** — if you pass `build-manifest.txt`, it checks both files' sizes
   and SHA-256 against what the manifest recorded. It's optional, but every real install we've done
   has used it.

Once both checks pass, the actual write happens — `dd` to the target device, then a read-back of
exactly the bytes that were written (not the whole partition, so a smaller new image can't
accidentally get compared against leftover data from a bigger old one), and an MD5 check against
the source file.

**The flash script doesn't flip the boot marker for you.** That's step 6, on purpose — writing a
new image to the spare slot and actually deciding to boot it are two separate steps, and keeping
them separate means a bad flash never gets booted by accident.

## What this touches, and what it never touches

Only `mmcblk0p6` (kernel2) and `mmcblk0p8` (rootfs2) get written. Stock's own `mmcblk0p5`/`p7` are
never touched — that's enforced by the script, not just something we're careful about. `/usr/data`,
the shared persistent partition, isn't touched by any of this either.

## One honest caveat

We've exercised this exact flashing path on real hardware, including resetting all the persistent
state to simulate a first boot. What we haven't specifically tested is a printer whose custom slot
has *literally* never been written before — every real run on record had already had something
flashed to slot 2 at some point earlier. There's no code path that treats "first write ever"
differently from "overwrite," so there's no real reason to expect different behavior, but it hasn't
been directly verified end to end from a truly virgin slot. Worth knowing if you're the one doing
that for the first time.

## Related docs

- `docs/A_B_SLOT_MODEL.md` — the partition layout and marker mechanics behind all of this
- `docs/DEVELOPER_UPDATE.md` — updating a printer that's already running NebulaOS
- `docs/DEVELOPER_RECOVERY.md` — what to do if this doesn't boot right
- `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md` — the day-to-day switching guide once both slots have something on them
