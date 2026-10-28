# How the A/B boot slots work

This is the raw partition layout and boot-selection mechanism the KE actually uses. It assumes
you're comfortable with SSH, root, and thinking about block devices — this isn't a consumer install
guide, it's the reference for anyone actually working on this stuff.

## Two models: fixed slots, and NebulaOS in either or both

**Original model (still the most common state).** Slot 1 holds Creality's stock system and slot 2
holds NebulaOS. A NebulaOS update overwrites slot 2. Writing slot 2 while running from it is
impossible, so the developer install boots Creality from slot 1 to do it. That is the Hardware
Agent's `PRESERVE_STOCK` path.

**Since 2026-10-14 (human decision): NebulaOS may occupy either or both slots.** An update writes
whichever slot is **not** running and then points the marker at it. After one such update a printer
can run NebulaOS from slot 1 with an older NebulaOS still in slot 2, or the reverse. If its owner
installed a Creality image, it can also hold Creality in either slot. In this model the way back
is the slot you are leaving, which must contain a bootable system (NebulaOS or Creality).

Both models use the same partitions, the same marker and the same bootloader. The only change is
what each slot is allowed to hold, so nothing may assume "slot 1 is stock". Tools decide from the
device:

- the running slot comes from `root=` in `/proc/cmdline` (p7 is slot 1, p8 is slot 2);
- the next slot comes from the marker bytes in p1;
- what a slot holds comes from that slot itself. The Hardware Agent mounts the other rootfs
  read-only on the printer and looks for NebulaOS's `/etc/ota_marker.sh` + `/opt/nebulaos` or
  Creality's `/etc/ota_bin`. It cross-checks against the kernel partition's uImage name (Linux 6.x
  is NebulaOS, 4.4 is Creality's KE firmware). Anything it cannot identify is `unknown`, and that
  is never assumed bootable or expendable. See `docs/HARDWARE_AGENT.md`, "NebulaOS in either or
  both slots".

## The layout

```
Slot 1 (factory: stock)     Slot 2 (factory: custom / NebulaOS)
  mmcblk0p5  kernel            mmcblk0p6  kernel2
  mmcblk0p7  rootfs             mmcblk0p8  rootfs2
  (8 MiB / 500 MB)              (8 MiB / 500 MB - real, fixed capacities)

              mmcblk0p1  ota marker (1 MB)
                 shared, not per-slot

              mmcblk0p9  rootfs_data (300 MB, ext4, /overlay)
              mmcblk0p10 userdata    (~6 GB, ext4, /usr/data)
                 shared, not duplicated per slot - see below
```

These are two fixed physical slot pairs. In the original model slot 1 is Creality's stock kernel
and rootfs, and slot 2 is NebulaOS's permanent home: every update overwrites slot 2 again. In the
both-slots model an update alternates between the two pairs, always writing the one that is not
running.

SPL loads a slot's RTOS together with its kernel and rootfs: rtos (p3) for slot 1, rtos2 (p4) for
slot 2. NebulaOS running from slot 1 therefore runs with p3, Creality's RTOS image, and the
NebulaOS boot logo (written to rtos2 only) does not show.

The important part: **we never overwrite the slot we're currently booted from.** That's not just a
convention, it's enforced in code (more on that below), in both models.

### `/overlay` and `/usr/data` are shared, not duplicated

`mmcblk0p9` (`/overlay`) and `mmcblk0p10` (`/usr/data`) are the same physical partitions no matter
which slot is active — they don't get a separate copy per OS. Stock and NebulaOS just use their own
subdirectories underneath, so switching slots doesn't expose one OS's files to the other, and
doesn't wipe either one out. `docs/DEVELOPER_RECOVERY.md` has the full breakdown of what actually
lives where and what survives a switch.

## What a normal flash actually touches

`scripts/flash-spare-slot.sh` writes exactly two devices, one slot's kernel and rootfs. By default
that is `/dev/mmcblk0p6` (kernel2) and `/dev/mmcblk0p8` (rootfs2). `--target-slot 1` writes
`/dev/mmcblk0p5`/`p7` instead. The Hardware Agent passes it only when NebulaOS runs from slot 2
and slot 1 holds NebulaOS or its owner released it (`INSTALL_OTHER_SLOT=expendable`). Whatever
the target, the script flatly refuses to run if the slot it's about to write is the one you're
currently booted from. It resolves that from `/proc/cmdline` twice, the second time immediately
before writing. That check happens in the script itself, not just in a warning somewhere — see
`run_preflight()` if you want to read it.

It never touches:

- the slot it is running from - there's no code path that writes the live slot
- `mmcblk0p1` (the OTA marker) — that's a separate, deliberate step, covered below
- `mmcblk0p9`/`p10` (the persistent data partitions) — not this script's job
- U-Boot, the partition table, or any factory-calibration data — nothing in this repo touches those

Worth knowing why this is so locked down: an earlier version of this script had a broken check for
"what am I currently booted from," and a write ended up landing on the live, running rootfs. That
went about as well as you'd expect — cascading segfaults, needed a manual power cycle to recover.
The current script was rewritten specifically to make that impossible: it reads the real `root=`
value out of `/proc/cmdline` instead of trusting an alias, and refuses outright if the resolved
target matches the resolved active slot. If you're ever modifying this script, know that the
safety check is there because we got burned once, not because it seemed like a good idea in the
abstract.

## The OTA marker

`/dev/mmcblk0p1` is a plain 1 MB partition. Its whole job is holding one of two strings:

```
ota:kernel      (boot slot 1 next - stock in the original model)
ota:kernel2     (boot slot 2 next - NebulaOS in the original model)
```

Two different tools write it, depending which OS you're currently on — and that's intentional, not
an inconsistency:

The marker names a **slot**, not an operating system. In the both-slots model `ota:kernel` can
select a NebulaOS in slot 1.

| From | Tool | Semantics |
|---|---|---|
| Custom (NebulaOS) | `/etc/ota_marker.sh`'s `write_ota_marker()` — NebulaOS's own helper, ships as part of the rootfs | **sets an exact state** — you name the slot |
| Stock (Creality) | `/etc/ota_bin/ota_local_method.sh`'s `local_set_next_boot_device()` — Creality's own pre-existing tool, already on stock | **toggles** — takes no argument, flips to whatever it currently is not |

That asymmetry matters. From stock you cannot ask for a particular slot, only
for "the other one", and the command succeeding tells you nothing about which
slot you ended up pointed at. Always read the marker back before rebooting —
`docs/DEVELOPER_RECOVERY.md` §2 has the exact command — and never reboot on a
marker whose value you could not read cleanly.

If you're switching over from stock for the first time, you use stock's own tool, since NebulaOS's
helper doesn't exist there yet. Once you're running NebulaOS, its own tool takes over. Both have
been used successfully on real hardware to flip the marker and switch slots.

The part that actually reads the marker at boot time lives in the bootloader, which is vendor code
outside this repo — so we can only describe what we've observed (writing the marker and rebooting
reliably switches the boot target), not the internals of how it's read.

## What happens on first boot

**Updated in Phase 1.8B (`phase1.8b/boot-safety`, commit 86a0c01) — the description below is the
CURRENT behavior. It replaces an earlier design (kept here for history) that automatically flipped
the marker back to stock on any Klipper/Moonraker failure.**

```
reboot
  |
S00revert-safety   -- Phase 1.8B: deliberate NO-OP. Logs that automatic stock
  |                   fallback is disabled and why. Does NOT touch the marker.
init sequence proceeds (S04 factory-seed/migrate, S5x services...)
  |
S99confirm-good    -- polls Moonraker's /server/info for klippy_state=="ready"
  |                   (up to 30 retries, 5s apart = 150s), purely for diagnostic
  |                   logging now
  |
  +-- success --> logs healthy, marker UNCHANGED
  |
  +-- timeout ----> logs a WARNING, marker UNCHANGED (stays on NebulaOS)
```

**Why this changed:** booting the stock Creality slot auto-flashes the GD32F303 MCU with old
Creality firmware, destroying whatever native MCU firmware was qualified and installed. The
original design's automatic stock-fallback-on-failure was worse than the problem it solved — a
transient Klipper/Moonraker failure inside NebulaOS could silently trigger an MCU-destroying
reboot into stock. Phase 1.8B removes every automatic path that can flip the marker: a NebulaOS
boot that crashes, hangs, has Klipper or Moonraker fail to start, or loses MCU connectivity now
simply **stays on NebulaOS** and preserves diagnostics — it does not fall back to stock on its own.
Manual recovery (SSH `write_ota_marker`, Creality's own tools, or USB mask-ROM recovery) is fully
preserved for the cases where a human genuinely needs to switch back — see
`docs/DEVELOPER_RECOVERY.md` and `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md`.

`S00revert-safety` and `S99confirm-good` are kept as named, ordered init.d scripts rather than
deleted outright: `S00`'s position (literal first script in boot order) is itself meaningful to
preserve, and `S99`'s health poll remains useful diagnostic signal independent of the marker. Both
carry extensive comments explaining why they're neutered, specifically so a future change doesn't
accidentally reintroduce automatic MCU-destroying fallback.

**One thing to be aware of:** this is all NebulaOS-side software behavior. If the kernel never gets
far enough to even start userspace — or the rootfs fails to mount before `/sbin/init` runs — none
of this repo's init scripts get a chance to run at all, and the marker just stays wherever it
already was. There is no bootloader-level (pre-init) automatic fallback mechanism in this project;
the marker is read by vendor bootloader code outside this repo, and no counter-driven revert
exists here. That gap is a known, currently-accepted limitation (see Phase 6/7 of the vNext
roadmap), not something Phase 1.8B attempts to close.

**Hardware watchdog (G117(b), Run 21; on by default since Run 22).** `S02nebulaos-watchdog` feeds
the SoC watchdog (BusyBox `watchdog -F -T 60 -t 10`, SCHED_OTHER nice -20, oom_score_adj -1000) so
a frozen system resets itself after ~60 s. It arms on every boot unless
`/usr/data/nebulaos/system/watchdog.disable` exists (the opt-out). Qualified on ke-dev 2026-10-28:
`watchdog-arm` (arms, stays fed, disarms cleanly) and `watchdog-fire` (a killed feeder -> the SoC
reset itself, normal boot). A watchdog reset is the same hardware reset as a software `reboot` (the
platform reboot is a WDT reset, `soc-x2000/reset.c`), so:

- a confirmed image boots the same slot again;
- during an unconfirmed image trial every start is counted (once per boot, in the TRIAL record,
  before the wait - G122). A reset before the verdict therefore uses up one attempt; the start
  after 3 unconfirmed ones goes back to the previous slot at once (LAST note "the new system
  restarted 3 times before it was confirmed"). A new image that reliably freezes early ends in a
  rollback after a few minutes, not in a loop;
- a clean `reboot`/`poweroff` runs rcK, which stops the feeder with SIGTERM (magic close), so
  it never fires; `halt -f` skips rcK and leaves it armed - the printer resets after ~60 s;
- Creality's stock rootfs never opens `/dev/watchdog`; a stock boot is unaffected.

## Related docs

- `docs/DEVELOPER_INSTALL_FROM_STOCK.md` — the full first-install walkthrough
- `docs/DEVELOPER_UPDATE.md` — updating an existing install
- `docs/DEVELOPER_RECOVERY.md` — what to do if something goes wrong, including the edge case above
- `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md` — the practical, day-to-day version of flipping slots
- `docs/NEBULAOS_OTA_FLOW.md` — the bigger picture this slot model fits into
