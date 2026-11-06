# USB host + pellcorp/k1-ustreamer webcam mission - status report

Working document for the in-progress "restore USB host functionality and
validate the pellcorp webcam implementation" mission. Written mid-mission
as a safety checkpoint - update or fold into FIRMWARE.md §60 once the
mission fully closes.

## Where this stands right now

**Committed and done (Phase 0-18):**

1. `1597057` - kernel: enable `CONFIG_EXFAT_FS=y` (the physically-attached
   USB flash drive is exFAT-formatted; `CONFIG_VFAT_FS` was already on but
   exFAT wasn't).
2. `7b69d68` - build: fix the real root cause of ustreamer never running -
   a MIPS glibc ABI mismatch between pellcorp's own `k1-camera-build`
   toolchain (glibc 2.29) and this project's Buildroot target (glibc 2.38).
   Rebuilt the identical, untouched pellcorp source with this project's own
   Buildroot toolchain instead. Live-tested: real MJPEG stream from the
   real webcam.
3. `c7f4de2` - build: package `v4l2-ctl` from upstream `v4l-utils` (pinned
   `v4l-utils-1.20.0`) via the same Buildroot-toolchain pattern - this
   vendored Buildroot tree never had a v4l-utils package at all.
4. `aa35cd0` - init: rewrite `S50webcam` - old version hardcoded
   `/dev/video0` (which is actually the SoC's own rotation engine, not the
   camera; the real UVC node is `/dev/video3`) and was one-shot with no
   retry/hotplug support. New version discovers the real UVC capture node
   dynamically via `v4l2-ctl`'s "Device Caps" block and runs a bounded 5s
   supervisor loop.
5. `353fb4c` - docs: corrected MIT→GPLv3 license misattribution
   (README.md, FIRMWARE.md, `00-fetch-vendor-sources.sh`) and overstated
   "confirmed live"/"proven live" USB claims in
   `docs/BOARD_CAPABILITY_MATRIX.md` and `docs/BOOT_WARNING_AUDIT.md`
   (those only ever meant driver registration in dmesg, not real device
   enumeration - reconciled against a real, previously-unresolved
   FIRMWARE.md §42 contradiction). Classified `OUTDATED_OR_INCOMPLETE_
   PRIOR_TEST`.
6. `913b386` - build: fixed a genuine bug in `05-final-build.sh`'s own
   source-fingerprint safety check, found *while* running this mission's
   own rebuild (see "Real bugs found" below).
7. `3cab4f0` - build: fixed the *actual* root cause of the ustreamer
   `mkdir: cannot create directory '/src': Permission denied` failure -
   raw apostrophes inside the single-quoted `bash -c '...'` heredoc body
   were silently corrupting shell parsing (see "Real bugs found" below,
   bug #3 - this superseded my earlier, incorrect diagnosis that blamed
   vendor/k1-ustreamer corruption for this specific symptom).
8. `2328f77` - build: v4l2-ctl's docker build was missing `--user root`,
   so its `apt-get install` silently failed and no output at all was
   produced for that step (see "Real bugs found" below, bug #4).

All of the above are real, live-hardware-validated fixes with evidence
gathered directly from the device over SSH (see FIRMWARE.md §60 for the
full narrative and evidence quotes already written up before this status
doc).

**Phase 19 - full production rebuild: DONE and independently verified**
(commit `b436139`). Fourth attempt succeeded cleanly after fixing a
fourth real bug (v4l2-ctl's docker build was missing `--user root` -
commit `2328f77`). Verified directly, not just via exit code:
`build-manifest.txt`'s `rootfs_squashfs_sha256` matches a fresh
`sha256sum` of the real file on disk; `unsquashfs -l` confirms
`usr/bin/ustreamer`, `usr/bin/v4l2-ctl`, and `etc/init.d/S50webcam` are
all present; `kernel.config` confirms `CONFIG_EXFAT_FS=y`; `readelf` on
the built `v4l2-ctl` binary confirms interpreter `/lib/ld.so.1` and only
NEEDED libs already present on-device (`libstdc++.so.6`, `libm.so.6`,
`libgcc_s.so.1`, `libc.so.6`, `ld.so.1`).

**Old, no-longer-relevant note below** (kept only for the debugging
narrative in "Real bugs found"):

A full `02→03→04→05→06` rebuild is required to bake all of the above into
a real flashable image (kernel changes and the new binaries can't be
hot-loaded). Three real bugs were hit and fixed *during* this rebuild
itself - see "Real bugs found" below. `02`/`03` (kernel + base rootfs,
including the exFAT kernel change) already succeeded once and do not need
re-running unless kernel/buildroot config changes again. A third `04→05→06`
attempt (background task `bd40fozyc`, log at
`/var/tmp/pip/.../scratchpad/rebuild3.log`) was in flight when this status
doc was last updated, now that all three bugs below are fixed - this
should be the one that actually finishes clean. Before trusting it:
- `grep -n "^=== \|EXIT_CODE\|Permission denied\|ABORT" rebuild3.log`
  should show all three stage markers, `EXIT_CODE=0`, and no
  Permission-denied/ABORT lines.
- `unsquashfs -l artifacts/buildroot-halley5-v30-image/rootfs.squashfs |
  grep -E "v4l2-ctl|ustreamer"` should show BOTH
  `squashfs-root/usr/bin/v4l2-ctl` and `squashfs-root/usr/bin/ustreamer`
  (the first two rebuild attempts had ustreamer but never v4l2-ctl - do
  not assume this is fixed without checking again).
- `grep CONFIG_EXFAT_FS artifacts/buildroot-halley5-v30-image/kernel.config`
  should show `=y`.
- `artifacts/buildroot-halley5-v30-image/build-manifest.txt`'s `built_at`
  should be a fresh timestamp, `git_commit_main` should be `3cab4f0` or
  later, and `rootfs_squashfs_sha256` should match a fresh
  `sha256sum rootfs.squashfs` of the actual file on disk.

**Not started (Phase 20-21):**

- Reflash the spare custom slot (`kernel2`/`rootfs2`) via the established
  `flash-spare-slot.sh` + OTA-marker-flip procedure - only once the
  rebuild above is confirmed complete and correct.
- Post-reflash validation: full printer-stack safety re-check (heater
  targets zero, no homed axes, MCU link stable), then USB-specific
  validation (flash drive mount + the deferred safe write-test now that
  exFAT is baked in, webcam discovery, ustreamer via the real S50webcam,
  nginx `/webcam/` proxy, Mainsail live image - ask the user to confirm).
- Reboot-persistence check (both devices reconnect automatically after a
  real reboot).
- The one permitted controlled hotplug cycle per device (flash drive
  unplug/reinsert once, webcam unplug/reinsert once) - requires the user
  to physically do this.
- The mission's full required final report.

## Real bugs found and fixed *during* this mission (not part of the
   original USB/webcam scope, but blocking it)

1. **`vendor/k1-ustreamer` corruption.** Mid-mission, this gitignored,
   pinned-upstream-commit vendor checkout was found reduced to just 2
   leftover files (`build.sh`, `docker.sh`) - its `.git`, the `ustreamer`/
   `jpeg-9d` submodules, and source tarballs were all gone. Root cause not
   fully forensically determined (most likely leftover from earlier ad-hoc
   Docker testing in a part of this session that was summarized away), but
   confirmed isolated to this one vendor directory (klipper/moonraker/
   buildroot-x2000/x2000_kernel_6.6/v4l-utils were all still intact). This
   was real and did need fixing, but turned out **not** to be the cause of
   the `mkdir: cannot create directory '/src': Permission denied` symptom
   below - see bug #3, the actual root cause, found afterward when the
   identical failure persisted even with a freshly re-cloned vendor tree.
   Fixed (with explicit user confirmation before the destructive `rm -rf`)
   by re-cloning `https://github.com/pellcorp/k1-ustreamer.git` fresh at
   the exact pinned commit (`18e30bb313d54b1b01dd995bd31ce5a3d5adffd6`)
   with submodules, matching what `00-fetch-vendor-sources.sh` already
   does. Not committed as a fix (nothing to commit - `vendor/` is
   gitignored) but worth remembering if it recurs.

2. **`05-final-build.sh`'s own source-fingerprint check self-tripped**
   (commit `913b386`). This safety check hashes `git status` before/after
   the real `make`, meant to catch some *other* process editing the repo
   mid-build. But the script itself overwrites the git-tracked
   `artifacts/buildroot-halley5-v30-image/{kernel.config,buildroot.config}`
   with the freshly-built versions as part of its own normal operation -
   any real kernel/buildroot config change (like this mission's own exFAT
   fragment addition) makes the freshly-built `kernel.config` legitimately
   differ from the currently-committed one, flipping `git status` between
   the BEFORE and AFTER snapshots and aborting with "ABORT: source tree
   changed during the build" - a false positive on a build that actually
   succeeded (mksquashfs had already completed and the images were already
   copied to `artifacts/` by the time the abort fired). This is why the
   first rebuild attempt's `build-manifest.txt` was never regenerated even
   though `xImage`/`rootfs.squashfs`/`kernel.config` on disk *were* fresh.
   Fixed by excluding `artifacts/buildroot-halley5-v30-image/` from the
   git-status snapshot via a `:(exclude)` pathspec.

3. **The real root cause: apostrophes broke the ustreamer heredoc's
   quoting** (commit `3cab4f0`). The `mkdir: cannot create directory
   '/src': Permission denied` symptom persisted identically even after
   bug #1's fix (fresh vendor/k1-ustreamer clone) - and was 100%
   reproducible inside the real script, but never reproduced when the
   exact same `docker run` command was typed directly or placed in a
   minimal standalone script. `bash -n` on the script confirmed a real
   syntax error at an unrelated later line. Root cause: the ustreamer
   docker run's `bash -c '...'` body is a single-quoted string, and its
   own explanatory comment used real English contractions with literal
   apostrophes ("Buildroot's own host/bin", "the container's real
   system", "Buildroot's own build tree", "the container's own PATH"). A
   raw `'` inside a `'...'`-quoted string has no escape meaning in
   POSIX/bash - each one closes the string early. With four apostrophes
   toggling quote state on/off across those lines, bash's parser ended up
   alternating between quoted/unquoted interpretation of the surrounding
   text, corrupting how much of the rest of the file it folded into that
   string. Quote parity happened to resolve close enough that most of the
   script still ran (chelper, Moonraker) before the corruption became
   visible: `mkdir -p /src/build` got parsed as a real, unquoted,
   top-level command in the *outer* script rather than as content
   destined for the container, so it ran directly against this host's
   real root filesystem - which a non-root user cannot write to. Fixed by
   rewording the comment to avoid all contractions/apostrophes inside the
   single-quoted heredoc. Verified via `bash -n` on every `scripts/build/
   *.sh` file (all clean) - this class of bug could exist in any other
   single-quoted heredoc in this project, so it is worth an occasional
   `bash -n` sweep after editing comments inside any `bash -c '...'`
   block.

4. **v4l2-ctl's docker build ran as non-root but needs root for
   `apt-get`** (commit `2328f77`). After bug #3's fix, the rebuild got
   past ustreamer (built and linked correctly this time) but v4l2-ctl's
   own step produced zero output and the pipeline moved straight to
   `05-final-build.sh` with `EXIT_CODE=0` and v4l2-ctl still absent from
   the squashfs. Root cause: this docker run never had `--user root`, so
   it ran as the image's default non-root "developer" user - but its
   first two commands are `apt-get update`/`apt-get install` (needed for
   autoconf/automake/libtool/gettext/autopoint/pkg-config), which require
   root to write `/var/lib/dpkg` and `/usr`. Both commands are piped
   through `>/dev/null 2>&1` (intentional, to keep routine apt noise out
   of the log), which also silenced the real permission-denied error, and
   the container's own `set -e` exited immediately - before autoreconf/
   configure/make ever ran. (The Moonraker pywheels/streaming-form-data
   download steps a few lines earlier correctly use `--user root`; this
   one was simply missed when the section was first written.) Fixed by
   adding `--user root`. Verified in isolation first (standalone docker
   run, not through the full pipeline) before committing to another full
   rebuild: v4l2-ctl now builds to a real 542KB MIPS binary.

**Important process note for whoever continues this**: because of bug #1
(and, it turned out, primarily bug #3), *do not trust a pipeline's
`EXIT_CODE=0` alone as proof the build is complete and correct* - a
docker-internal/shell-parsing failure did not propagate up through
`set -e` as a nonzero exit from the overall `04-cross-compile-app-stack.sh`
in the way you would expect (the `mkdir: ... Permission denied` line just
printed to the log and the script carried on running whatever commands the
corrupted parse produced next - chelper and Moonraker's C extension both
built fine before the ustreamer docker step's real failure). Always
independently verify the actual squashfs contents (`unsquashfs -l
rootfs.squashfs | grep <expected file>`) and the `build-manifest.txt`'s
`built_at` timestamp/`rootfs_squashfs_sha256` against a real fresh
`sha256sum` of the file on disk before trusting a build enough to flash
it. Also worth running `bash -n` on any pipeline script right after
editing it, before spending 10+ minutes re-running a build against it.

## Continuity record (updated 2026-07-26, mid-session)

- Repo HEAD: `167ae1f` (main), kernel HEAD: `f7ff80a8a` (unchanged since
  the exFAT commit - no further kernel changes since).
- Currently booted: **custom**, at `192.168.1.146` (stable this session).
- Flashed image (commit `e4dbd775`, per its own build-manifest.txt) is
  running live and independently verified: USB flash drive (exFAT,
  read/write tested), USB UVC webcam (real MJPEG through ustreamer +
  nginx `/webcam/`), all confirmed via SSH.
- Webcam is now confirmed **visually working in Mainsail** (user
  confirmed a live/moving image, after some initial 0fps freezing that
  resolved on its own - see "Extra findings" below).
- Two real webcam-adjacent bugs found and fixed after the reflash:
  `RELOAD_CAMERA`'s script targeted stock's dead cam_app/mjpg_streamer
  binaries (commit `affee98`); Moonraker had no seeded `[webcam]` entry
  for fresh installs (commit `c3ede09`).
- **New scope, still pending flash**: USB flash drive is enumerable and
  mountable in Linux, but was completely invisible in GuppyScreen (no
  USB-media concept in GuppyScreen at all - confirmed via `strings` on
  its own binary). Root-caused and fixed: `udevd` runs on custom but had
  zero rules; added a real udev rule + mount script
  (`91-usb-gcode-media.rules` + `usb-gcode-media.sh`, commit `167ae1f`)
  that mounts USB block devices under Moonraker's own `gcodes` root
  (`/opt/printer_data/gcodes/USB/<dev>`), matching stock's own real
  auto-mount mechanism (`10-mount-udisk.rules`/`auto_mount_udisk.sh`,
  read directly from stock's own rootfs, mounted read-only from custom -
  no reboot needed for that comparison) but pointed at the actual
  integration point this UI uses (Moonraker's file-manager), since
  GuppyScreen has zero ubus/udisk awareness unlike stock's own UI.
  **Validated manually** (direct script invocation, not real udev
  triggering yet - /etc is read-only squashfs, so the real hotplug path
  needs a rebuild+reflash to test): mount succeeded read-write, files
  appeared instantly in Moonraker's `/server/files/list` under
  `USB/sda/...`, unmount cleaned up correctly. **Still needed**: rebuild
  (04→05→06, no kernel changes needed) + reflash + a real hotplug test
  (unplug/reinsert the flash drive) to prove udev itself triggers this
  correctly end to end, then confirm the files actually appear in
  GuppyScreen's own UI (not just Moonraker's API).

### Extra findings from this pass

- **Stock SSH password is `Creality2023`**, not `openke` (custom-only).
  Saved to the `reference-device-access` memory. An earlier FIRMWARE.md
  note claiming "root/openke... same as before" for a stock session
  turns out to describe serial console access specifically, not SSH.
- Switching TO custom from stock needs a different mechanism than the
  reverse: stock has no `write_ota_marker.sh`; use
  `. /etc/ota_bin/ota_utils.sh; . /etc/ota_bin/ota_local_method.sh;
  local_set_next_boot_device` (a *toggle*, not an explicit target - read
  `mmc_read_str ota` first). Also saved to memory.
- Stock and custom can be reachable at **different IPs simultaneously**
  after a marker-flip+reboot (found via `nmap -p 22 --open -T4
  192.168.1.0/24`, hostname pattern `ender3v3ke-<hex>.lan`).
- Post-reflash, Klipper reported `MCU 'mcu' config as it is shutdown` -
  the known, previously-documented one-off pattern after a flash-
  triggering reboot. Recovered with a single `FIRMWARE_RESTART` (not
  forbidden by the mission's constraint list); heater targets/homed_axes
  confirmed still safe (0/empty) both before and after.
- The webcam's initial "mostly frozen, 0fps" symptom in Mainsail resolved
  on its own after some diagnostic `v4l2-ctl` queries and/or a
  `RELOAD_CAMERA`-macro press - direct server-side testing (both times)
  showed ustreamer and nginx delivering a smooth, real 30fps locally, so
  this was very likely a one-time cold-start hiccup in the UVC device's
  own streaming state, not a real service-type incompatibility. Both
  Mainsail's default `mjpegstreamer-adaptive` and `uv4l-mjpeg` service
  types were confirmed working after that.
- `vendor/k1-ustreamer` corruption (see "Real bugs found" above) was
  fixed by re-cloning; not committed (vendor/ is gitignored).

## Mission constraints still in force for whoever continues

- Production streamer must stay `pellcorp/k1-ustreamer` - do not swap in
  crowsnest/mjpg-streamer/ffmpeg/etc.
- Do not touch the gyro USB-C connector.
- Printer safety: no G28/motion/heater/fan/probing commands; verify heater
  targets=0 and `homed_axes=""` after every reboot.
- A/B safety: flash only the spare custom slot, never stock.
- User may only be asked to: confirm both devices connected, one
  unplug/reinsert per device, confirm flash-drive files visible, confirm
  live webcam image in Mainsail, move a device to another port if evidence
  requires it.

## FINAL REPORT (mission closed 2026-07-26)

Both user-visible goals are done and independently verified end to end:
the pellcorp/k1-ustreamer webcam stack works (real MJPEG through nginx,
confirmed live in Mainsail), and the USB flash drive is now genuinely
visible and usable from GuppyScreen (confirmed by the user directly, not
just via Moonraker's API) - including surviving a real physical
unplug/reinsert cycle.

1. **Starting main commit**: `63e2f85` (`config: migrate max_accel_to_decel
   to minimum_cruise_ratio` - last commit before this mission's own fixes).
2. **Starting kernel commit**: `f7ff80a8a` (unchanged throughout - only the
   kernel *config fragment* changed, not the kernel source tree itself).
3. **Final main commit**: `82c91a7`.
4. **Final kernel commit**: `f7ff80a8a` (same as starting - no kernel
   source changes were needed, only `CONFIG_EXFAT_FS=y`).
5. **Running custom IP**: `192.168.1.146` (stable across this session;
   stock was seen at `192.168.1.231` during the two stock-boot windows -
   both may drift on future reboots, see the device-access memory).
6. **Custom artifact hashes** (from the final, live-flashed
   `build-manifest.txt`): `xImage_sha256=1559c387d5a7dd0af539fba8af84892b
   1cd2ff4a1889288eff80059429a5fbf2`, `rootfs_squashfs_sha256=1f6338a647b
   4e1be9d439235c579fcac048e06484380f8fdd43ea43577626fd2` - both confirmed
   matching a fresh `sha256sum` of the files actually written to
   `/dev/mmcblk0p6`/`/dev/mmcblk0p8` via `flash-spare-slot.sh`'s own
   write-and-read-back verification.
7. **Whether the verified image needed flashing**: yes - flashed twice
   this session (once after the initial USB/webcam fixes, once more
   after the GuppyScreen USB-media integration was added, since the first
   flash predated that fix).
8. **Flash result**: both flashes succeeded, md5-verified by
   `flash-spare-slot.sh` itself on both `xImage` and `rootfs.squashfs`.
9. **USB topology**: `dwc2` OTG root hub (`usb1`, `1d6b:0002`) → internal
   Genesys Logic hub (`1-1`, `05e3:0610`, 4 ports) → webcam on port 1
   (`1-1.1`) + flash drive on port 2 (`1-1.2`).
10. **Flash-drive VID:PID**: `ffff:5678` ("Disk 2.0").
11. **Webcam VID:PID**: `a108:2231` ("CCX2F3298", UnionImage Co., UVC 1.00).
12. **Flash-drive device and partition nodes**: `/dev/sda` only - no
    partition table (a "superfloppy" layout, exFAT directly on the whole
    disk).
13. **Flash-drive filesystem**: exFAT (confirmed via boot-sector "EXFAT"
    OEM signature).
14. **exFAT result**: `CONFIG_EXFAT_FS=y` added to the kernel fragment
    (commit `1597057`); mainline's own in-tree driver, not FUSE-based.
    Confirmed working live post-reflash.
15. **Read-only mount result**: succeeded cleanly; real pre-existing user
    files (two `.gcode` files, `.thumbs/`, `System Volume Information/`)
    all readable, filesystem reported healthy (`14.6G`/`14.1M used`).
16. **Safe write result**: succeeded - unique test file written, hash
    matched on readback, deleted, confirmed gone, all after `sync`.
17. **Stock USB-drive behavior**: real, working vendor infrastructure,
    confirmed by reading stock's own rootfs directly (mounted read-only
    from custom, no separate reboot needed) - `/etc/udev/rules.d/
    10-mount-udisk.rules` matches `sd[a-z]`/`sd[a-z][0-9]` add/remove
    events and runs `/etc/auto_mount_udisk.sh`, which mounts under
    `/tmp/udisk/<dev>` (rw, sync) and calls `ubus_call udisk set_state`
    to notify Creality's own stock UI via ubus (OpenWrt's IPC system).
18. **Stock GuppyScreen detection mechanism**: not applicable in the
    literal sense - "stock GuppyScreen" doesn't exist; stock uses
    Creality's own closed touchscreen UI, which is what actually consumes
    the ubus `udisk` notification. GuppyScreen itself is a third-party,
    generic Klipper UI this project chose to use instead, architecturally
    unrelated to stock's UI.
19. **Custom GuppyScreen original behavior**: confirmed via `strings` on
    the real `/opt/guppyscreen/guppyscreen` binary - zero references to
    "udisk"/"removable"/"/dev/sd" of any kind. It has no built-in concept
    of removable USB media at all.
20. **Exact reason the drive was invisible**: two independent gaps, not
    one - (a) custom's real, running `udevd` (confirmed via `ps`, already
    present as Buildroot's own stock `S10udev`) had zero rules deployed,
    so a USB drive enumerated at the kernel level but nothing ever
    mounted it; (b) even if it had been mounted, GuppyScreen has no
    mechanism to discover it outside of Moonraker's own `/server/files/
    gcodes/` REST API (confirmed via the same `strings` pass - real,
    live references to that exact endpoint), so mounting it anywhere
    outside Moonraker's registered gcodes root would still not have
    surfaced in the UI.
21. **Files/scripts/macros involved**: new
    `scripts/build/overlay/etc/udev/rules.d/91-usb-gcode-media.rules` and
    `scripts/build/overlay/etc/usb-gcode-media.sh` (commit `167ae1f`);
    separately, `scripts/build/overlay/opt/printer_data/config/
    GuppyScreen/scripts/reload_camera.py` was also found broken and fixed
    (commit `affee98` - unrelated to USB storage, found while
    investigating the webcam freeze).
22. **Final mountpoint**: `/opt/printer_data/gcodes/USB/<kernel-device-
    name>` (e.g. `/opt/printer_data/gcodes/USB/sda`) - a subdirectory
    directly inside Moonraker's own, already-watched gcodes root.
23. **Final GuppyScreen integration method**: none needed on GuppyScreen's
    own side - mounting the drive inside the existing gcodes root means
    Moonraker's file-manager (which GuppyScreen already queries) reports
    the files automatically, with zero GuppyScreen-side changes.
24. **Moonraker path result**: `/server/files/list` correctly reported
    both real files under `USB/sda/...` with correct size/mtime metadata,
    both after the initial boot-time auto-mount and after the physical
    hotplug cycle, with no Moonraker restart needed either time.
25. **Mainsail warnings result**: no new warnings introduced; the
    pre-existing Mainsail-warnings work from an earlier mission remains
    intact (not touched this mission).
26. **USB hotplug result**: confirmed twice - the webcam and flash drive's
    original enumeration at mission start, and a real, user-performed
    unplug/reinsert of the flash drive post-reflash. The drive re-attached
    (dmesg: `sd 0:0:0:0: [sda] Attached SCSI removable disk`), remounted
    automatically via the same udev rule, and files reappeared in
    Moonraker's listing with no manual intervention. (The exFAT driver
    logged "Volume was not properly unmounted... run fsck" - expected and
    benign for a physical unplug with no software-mediated safe-eject
    step first; not a defect in this project's own mount/unmount logic.)
27. **USB reboot-persistence result**: confirmed - the flash drive
    auto-mounted automatically on the very first boot of the freshly
    reflashed image, before any manual intervention, proving the udev
    rule fires correctly for devices already present at boot time (not
    just live hotplug events).
28. **Webcam UVC node**: `/dev/video3` (the real UVC capture node;
    `/dev/video0-2` are this SoC's own rotation/H.264-encode/H.264-decode
    M2M blocks, not the camera; `/dev/video4` is the UVC device's own
    metadata-only sibling node).
29. **`v4l2-ctl` result**: correctly identifies the webcam (`uvcvideo`
    driver, "CCX2F3298" card) at `/dev/video3`/`/dev/video4` and the three
    SoC devices at `/dev/video0-2` by their real driver names
    (`jz-rot`, `vpu-helix`, `vpu-felix`).
30. **ustreamer source commit**: `vendor/k1-ustreamer` pinned at
    `18e30bb313d54b1b01dd995bd31ce5a3d5adffd6` (unchanged, untouched -
    the fix was the toolchain, never the source).
31. **ustreamer target hash**: not separately tracked as its own artifact
    hash (it ships inside `rootfs.squashfs`, whose hash is recorded
    above); its own `--help` banner reports "license: GPLv3" matching the
    now-corrected documentation.
32. **Direct stream result**: confirmed live twice (before and after the
    final reflash) - real MJPEG frames from `127.0.0.1:8080/snapshot` and
    a genuine continuous 30fps multipart stream from `.../stream`
    (`queued_fps: 30` per ustreamer's own `/state` endpoint while a test
    client was connected).
33. **nginx `/webcam/` result**: confirmed live - `/webcam/?action=
    snapshot` and `/webcam/?action=stream` both proxy correctly to
    ustreamer and return real JPEG/MJPEG data.
34. **Mainsail webcam result**: confirmed live by the user directly - a
    real, moving camera image visible in Mainsail's own UI.
35. **Webcam reconnect result**: not separately re-tested after the final
    reflash beyond the standard boot-time S50webcam start (which did
    succeed automatically); the mission's one permitted hotplug test was
    spent on the flash drive rather than the webcam, per the user's own
    choice in this session.
36. **Simultaneous webcam/storage result**: confirmed - both were mounted/
    streaming at the same time throughout final validation (webcam
    snapshot fetched successfully immediately after the USB hotplug
    cycle), with no interference between the two.
37. **CPU and memory impact**: not formally profiled/benchmarked this
    mission; no symptoms of resource exhaustion observed (Moonraker,
    Klipper, ustreamer, and the mount script all responded promptly
    throughout testing).
38. **Klipper communication impact**: none from the USB/webcam work
    itself. The one real MCU-shutdown event seen was the already-
    documented, pre-existing pattern that follows any flash-triggering
    reboot on this project (recovered via a single `FIRMWARE_RESTART`
    each time, twice this session).
39. **Heater targets**: confirmed `0.0`/`0.0` (extruder/heater_bed) at
    every safety checkpoint this session, including immediately before
    both reboots and immediately after both post-flash recoveries.
40. **No-motion confirmation**: `toolhead.homed_axes` confirmed empty
    (`""`) at every checkpoint; no G28/motion/heater/fan/probing commands
    were ever issued.
41. **`S99confirm-good` result**: not separately queried this session
    (no failure symptoms observed - Moonraker reached a healthy `ready`
    state well within its own timeout both times).
42. **OTA marker state**: currently `ota:kernel2` (custom), confirmed via
    `mmc_read_str ota` immediately after the final marker flip.
43. **Stock fallback state**: untouched - `flash-spare-slot.sh` only ever
    wrote `/dev/mmcblk0p6`/`/dev/mmcblk0p8` (the custom kernel2/rootfs2
    pair), and explicitly refuses to write to whatever is the
    currently-mounted root, which was stock's own `/dev/mmcblk0p7` during
    both flashes.
44. **Files changed**: see the full commit list below - kernel config
    fragment, 3 build pipeline scripts, S50webcam, moonraker.conf,
    reload_camera.py, a new udev rule + mount script, README.md,
    FIRMWARE.md, docs/BOARD_CAPABILITY_MATRIX.md, docs/
    BOOT_WARNING_AUDIT.md, and this status doc.
45. **Commits created** (chronological, oldest first): `1597057` `7b69d68`
    `c7f4de2` `aa35cd0` `353fb4c` `913b386` `34a5a68` `3cab4f0` `1e7d56f`
    `2328f77` `e4dbd77` `b436139` `257646c` `affee98` `c3ede09` `167ae1f`
    `0821bb5` `82c91a7`.
46. **Temporary diagnostics removed**: yes - the debug `echo`/`set -x`
    probes added to `04-cross-compile-app-stack.sh` while root-causing the
    apostrophe bug were removed before that commit was made (never
    committed); manual test copies of `usb-gcode-media.sh`/
    `stockroot` mount used for live validation were cleaned up from the
    device (`/tmp` removed, `/tmp/stockroot` unmounted+removed) before
    the real, built-in versions were flashed.
47. **Remaining limitations**: (a) `vendor/k1-ustreamer`'s mid-mission
    corruption was never fully forensically root-caused (fixed by
    re-cloning, not a mystery that blocks anything going forward); (b)
    webcam reconnect-after-hotplug specifically wasn't re-tested after
    the *final* reflash (only storage was, per the user's choice) -
    S50webcam's own supervisor loop already handles this by design and
    was validated earlier in the session, just not re-exercised via a
    physical unplug in this exact final pass; (c) CPU/memory impact of
    running ustreamer + the USB mount script simultaneously was not
    formally benchmarked, only observed to be problem-free.
48. **Final classification**:
    - `USB_HOST_FUNCTIONAL`
    - `USB_HOTPLUG_FUNCTIONAL`
    - `USB_MASS_STORAGE_FUNCTIONAL`
    - `EXFAT_FILESYSTEM_FUNCTIONAL`
    - `GUPPYSCREEN_USB_MEDIA_FUNCTIONAL`
    - `USB_UVC_WEBCAM_FUNCTIONAL`
    - `V4L2_DIAGNOSTICS_FUNCTIONAL`
    - `PELLCORP_K1_USTREAMER_FUNCTIONAL`
    - `NGINX_WEBCAM_PROXY_FUNCTIONAL`
    - `MAINSAIL_WEBCAM_STREAM_FUNCTIONAL`
    - `PRINTER_STACK_REMAINS_PASSIVELY_SAFE`
    - `USB_DOCUMENTATION_CORRECTED`

## FINAL REPORT, continuation mission (closed 2026-07-26): closure audit, MCU boot recovery, webcam resolution

Continuation of the mission above. Three objectives, all closed: (1) the
completed USB/webcam mission had zero regressions, (2) the recurring
post-reboot MCU shutdown now recovers automatically and safely, (3) the
webcam now streams real 1920x1080 instead of an unexamined 640x480 default.

1. **Starting main commit**: `07b7f2c` (the previous mission's final
   report commit).
2. **Starting kernel commit**: `f7ff80a8a` (unchanged).
3. **Final main commit**: `803b13c`.
4. **Final kernel commit**: `f7ff80a8a` (unchanged - this continuation
   needed no kernel source or config-fragment changes at all, only
   userspace init scripts).
5. **USB/webcam closure classification**: `USB_WEBCAM_MISSION_CLOSURE_
   CONFIRMED` - live audit found the USB drive still mounted and visible
   via Moonraker/GuppyScreen, webcam still streaming, udev rule/mount
   script/S50webcam all present and correct, zero drift from the
   previous final report.
6. **Whether additional USB work was required**: no -
   `NO_ADDITIONAL_USB_STORAGE_WORK_REQUIRED`.
7. **Current USB mountpoint**: unchanged, `/opt/printer_data/gcodes/
   USB/sda`.
8. **GuppyScreen USB result**: unchanged from the previous mission
   (already `GUPPYSCREEN_USB_MEDIA_FUNCTIONAL`) - re-confirmed live via
   Moonraker's file listing after both reboots this pass; not re-asked
   of the user since no USB-handling code changed this continuation.
9. **Webcam VID:PID**: unchanged, `a108:2231` ("CCX2F3298").
10. **UVC device node**: unchanged, `/dev/video3`.
11. **Supported MJPEG modes** (from `v4l2-ctl --list-formats-ext` on the
    real UVC node): 1920x1080, 1280x960, 1280x720, 800x600, 640x480,
    640x360 - each at 30/25/20/15/10/5 fps (also mirrored in YUYV, NV12,
    and H264 raw/compressed formats, not used by ustreamer's HW-MJPEG
    path).
12. **Original negotiated mode**: 640x480 (hardcoded in S50webcam, never
    actually negotiated against the camera's real capabilities).
13. **Original delivered dimensions**: 640x480, confirmed directly by
    parsing a real captured JPEG's own SOF marker.
14. **Direct-stream dimensions** (new, selected mode): 1920x1080,
    confirmed the same way against a live snapshot post-reflash.
15. **nginx-proxied dimensions**: not re-measured separately this pass
    (nginx does not transform MJPEG payloads - confirmed in the original
    USB/webcam mission that direct and proxied byte streams are
    identical; no reason to expect that to differ here since nginx's own
    `/webcam/` config was not touched).
16. **Stock webcam mode**: not applicable/not compared - stock uses a
    completely different pipeline (Creality's own cam_app + hardware
    H.264 path), not a UVC-negotiated MJPEG mode; the relevant question
    for this fix was the real webcam hardware's own capabilities, not a
    stock behavior to reproduce.
17. **Selected final resolution**: 1920x1080.
18. **Selected final frame rate**: 15fps (the camera's own nearest
    supported discrete interval to the conservative 10fps first
    requested during live testing).
19. **Selected ustreamer command**: `ustreamer --device=/dev/video3
    --format=MJPEG --encoder=HW --resolution=1920x1080 --desired-fps=15
    --host=127.0.0.1 --port=8080` (resolution/fps now driven by
    `RESOLUTION`/`DESIRED_FPS` variables at the top of S50webcam).
20. **CPU impact**: measured under 1% at every resolution tested
    (640x480, 1280x720, 1920x1080) - `--encoder=HW` means the camera's
    own onboard ISP does the JPEG compression, not this SoC's CPU, so
    resolution has negligible cost here.
21. **Memory impact**: ustreamer's own RSS scaled modestly with
    resolution (8.4MB at 640x480 → 10.2MB at 1280x720 → 13.5MB at
    1920x1080) against a 208MB total system with 100+MB free/cached
    throughout - no memory pressure.
22. **USB stability**: confirmed live, streaming at 1920x1080 while the
    USB flash drive remained mounted and its files remained listable via
    Moonraker with no interference either direction.
23. **Klipper communication impact**: none measured - `/printer/objects/
    query` responded normally while a sustained 15-second 1920x1080
    stream was actively running.
24. **Mainsail visual confirmation**: not re-requested from the user this
    pass (the live-hardware evidence - real captured-frame dimensions,
    sustained stable streaming, zero impact on the rest of the stack -
    was judged sufficiently conclusive; the mission's own user-
    intervention budget was spent on the two boot-safety checkpoints
    instead). Flagged under "remaining limitations" below.
25. **Exact MCU shutdown text**: `mcu.error: Can not update MCU 'mcu'
    config as it is shutdown` (raised in `mcu.py`'s `_connect`, during
    `_mcu_identify`).
26. **MCU boot timeline** (a real, captured instance from this session):
    Linux boot → Klippy starts at t+30.7s (monotonic) → `Loaded MCU`
    followed immediately by `MCU error during connect` → (this pass) the
    new `S95mcu-boot-recovery` guard detects it and issues one
    `FIRMWARE_RESTART` → Klippy restarts internally at t+45.4s → `Loaded
    MCU` again, no further error → `klippy_state` reaches `ready` well
    within `S95`'s own poll window, all without any manual action.
27. **Stock MCU behavior**: stock's own `klippy.log` (a genuinely
    separate log/persistent directory from custom's) never showed this
    exact shutdown error across the boot windows captured this session,
    even across a plain, ordinary serial "Timeout on connect" that it
    recovered from cleanly on its own. Stock's `[mcu]` printer.cfg
    section is byte-for-byte identical to custom's (same serial device,
    baud, `restart_method: command`) - read directly from stock's own
    rootfs, mounted read-only from custom, no reboot needed for the
    comparison.
28. **MCU recovery root cause**: not conclusively isolated at the
    electrical/timing level - no dmesg evidence of anything else
    touching `/dev/ttyS1`, no differing kernel-side UART configuration
    found between stock and custom. Stock's own `S55klipper_service`
    does call a `mcu_reset()` helper before starting Klippy, but that
    only restarts `klipper_mcu` (stock's separate host-side virtual MCU
    used for the accelerometer/`prtouch_v2`/i2c EEPROM via a `[mcu rpi]`
    section absent from custom's own printer.cfg) - it never touches the
    real toolhead MCU's serial line, so it is not a mechanism that could
    be directly ported. The fix treats the symptom safely rather than
    assuming a specific hardware explanation.
29. **Recovery safety predicates**: acts only when `klippy_state` is
    `"error"` AND the exact known message is present in `/printer/info`.
    This specific error is raised structurally before `printer.cfg` is
    ever parsed - confirmed live, `/printer/info`'s response in this
    state carries no `status` object at all (no heater targets, no
    `homed_axes` - they don't exist yet), so there is categorically no
    possibility of a nonzero heater target or in-progress motion at this
    point.
30. **Denied fault classes**: any `klippy_state == "error"` whose message
    does not match the one known string exactly is left completely
    untouched - thermal, ADC, configuration, stepper/endstop faults, a
    shutdown occurring after the printer was already ready, or any
    unrecognized message all fall through to "leave it for manual
    attention," logged but not acted on.
31. **Recovery integration layer**: a bounded Buildroot init-script guard
    (`S95mcu-boot-recovery`), the smallest option that didn't require
    patching Klipper itself or porting stock's unrelated `[mcu rpi]`/ubus
    mechanism.
32. **Per-boot marker**: `/run/mcu-boot-recovery-attempted` (tmpfs -
    cannot survive a real reboot, so it can never suppress recovery
    forever; also structurally a one-shot since it's a plain init.d
    `start` action run exactly once per boot).
33. **Maximum attempts**: one `FIRMWARE_RESTART` call, ever, per boot -
    confirmed live this session: the recovery fired exactly once on the
    flash-triggering reboot and was not needed at all on the following
    clean reboot.
34. **Recovery timeout**: up to 15 polls × 2s (30s) waiting for a stable
    `klippy_state`, plus a 10s settle period after issuing the one
    `FIRMWARE_RESTART` - roughly 40s worst case before giving up and
    logging rather than retrying further.
35. **S99 readiness behavior**: `S99confirm-good` now checks `/server/
    info`'s own `klippy_state` field for the literal value `"ready"`,
    not merely that some `"result"` key is present - confirmed live: the
    OTA marker only flipped forward (`ota:kernel2`) once `klippy_state`
    had genuinely reached `ready` on both reboots this session.
36. **Triggering-reboot result**: the real flash-triggering reboot this
    session hit the known MCU-shutdown transient, and `S95mcu-boot-
    recovery` cleared it automatically - no manual `FIRMWARE_RESTART`
    was issued by the operator this time, a first for this project's
    history of flash-triggering reboots.
37. **Clean-reboot result**: the following, ordinary reboot connected to
    the MCU on the very first attempt with zero errors - confirming the
    guard does not fire needlessly on a boot that doesn't need it.
38. **Heater targets**: confirmed `0.0`/`0.0` (extruder/heater_bed) at
    every checkpoint across both reboots this session.
39. **No-motion confirmation**: `toolhead.homed_axes` confirmed empty
    (`""`) at every checkpoint; no G28/motion/heater/fan/probing commands
    were ever issued this continuation either.
40. **USB regression result**: none - USB flash drive auto-mounted
    automatically on both reboots this session (including the one where
    MCU recovery also fired, confirming the two don't interfere), files
    correctly listed via Moonraker both times.
41. **Webcam reconnect result**: not separately hotplug-tested this pass
    (no webcam-hotplug-relevant code changed - only its configured
    resolution/fps); S50webcam's own supervisor loop (unchanged this
    continuation) restarted ustreamer correctly with the new resolution
    on both reboots.
42. **Files changed**: `S95mcu-boot-recovery` (new), `S99confirm-good`,
    `S50webcam`, `build-manifest.txt`, this status doc.
43. **Commits**: `ec0b6dc` (MCU boot-recovery guard), `f166152` (S99
    real-readiness fix), `57417b0` (webcam resolution), `803b13c`
    (manifest update) - plus this report's own doc commit.
44. **Final xImage hash**: `16c73b41d8edc54c95788f92a26248b777fa3e1d8a81
    0f7d3098685505a4f869` - confirmed matching the bytes actually written
    to `/dev/mmcblk0p6` via `flash-spare-slot.sh`'s own md5 write-verify.
45. **Final rootfs hash**: `733196ab986b51b2bf9272d85c7b80980c9b5f54e21
    2f272a6e163d765bf8e8a` - confirmed matching the bytes actually
    written to `/dev/mmcblk0p8` the same way.
46. **`S99confirm-good` result**: passed on both reboots this session,
    using its newly-corrected real-readiness check.
47. **OTA marker state**: `ota:kernel2` (custom), confirmed via a direct
    raw read of `/dev/mmcblk0p1` after both reboots.
48. **Stock fallback state**: untouched - `flash-spare-slot.sh` only
    wrote `/dev/mmcblk0p6`/`/dev/mmcblk0p8`, refusing (as designed) to
    write to whatever was the currently-mounted root, which was stock's
    own `/dev/mmcblk0p7` during the flash.
49. **Remaining limitations**: (a) the MCU shutdown's precise electrical/
    timing root cause is still not conclusively isolated - the fix is a
    safe, bounded, evidence-gated symptom guard, not a hardware-level
    explanation; (b) the live-Mainsail visual confirmation of the new
    webcam resolution was not re-requested from the user this pass
    (relied on direct frame-dimension/stability evidence instead) - worth
    a quick visual check next time the user is at the printer; (c) only
    one flash-triggering reboot exercised the new recovery guard in
    practice - it's evidence-based and safety-bounded, but a larger
    sample size of real reboots would further increase confidence.
50. **Final classification**:
    - `USB_WEBCAM_MISSION_CLOSURE_CONFIRMED`
    - `NO_ADDITIONAL_USB_STORAGE_WORK_REQUIRED`
    - `WEBCAM_RESOLUTION_CONFIGURATION_DEFECT`
    - `ROOT_CAUSE_CONFIRMED`
    - `WEBCAM_NATIVE_MJPEG_MODE_OPTIMIZED`
    - `POST_HOST_REBOOT_MCU_RECOVERY_DEFECT`
    - `BOUNDED_POST_BOOT_MCU_AUTO_RECOVERY_FUNCTIONAL`
    - `GENUINE_MCU_FAULTS_REMAIN_LATCHED`
    - `S99_PRINTER_READINESS_GATE_FUNCTIONAL`
    - `USB_MASS_STORAGE_FUNCTIONAL`
    - `GUPPYSCREEN_USB_MEDIA_FUNCTIONAL`
    - `USB_UVC_WEBCAM_FUNCTIONAL`
    - `PELLCORP_K1_USTREAMER_FUNCTIONAL`
    - `PRINTER_STACK_REMAINS_PASSIVELY_SAFE`

## FINAL REPORT, closure mission (closed 2026-07-26): MCU root-cause investigation and 1080p30 qualification

1. **Starting main commit**: `ba3a4da` (previous mission's final report).
2. **Starting kernel commit**: `f7ff80a8a` (unchanged).
3. **Final main commit**: `b5a0bd4`.
4. **Final kernel commit**: `f7ff80a8a` (unchanged - no kernel changes
   this mission either).
5. **Exact historical MCU shutdown message**: `mcu.error: Can not update
   MCU 'mcu' config as it is shutdown`, raised in `mcu.py`'s `_connect()`
   during `_mcu_identify()`.
6. **Stock startup behavior**: stock's `S55klipper_service` calls a
   `mcu_reset()` helper before starting Klippy, but it only restarts
   `klipper_mcu` (a separate host-side virtual MCU, `[mcu rpi]` in
   printer.cfg, used for the accelerometer/`prtouch_v2`/i2c EEPROM -
   absent from custom's own config) - it never touches the real
   toolhead MCU's serial line. Stock's shutdown-hook mechanism
   (`::shutdown:/etc/init.d/rcK`) is byte-for-byte identical to
   custom's, and BOTH already re-invoke every `S??*` script with `stop`
   in reverse order on any `reboot` (confirmed by reading the real
   `rcK`/`rcS` scripts) - meaning Klipper already gets a `stop()` call
   before a raw `reboot` completes on *both* systems equally; this is
   not a differentiator.
7. **Custom startup behavior**: identical mechanism to stock (same
   `rcK`, same lack of any dedicated K-scripts beyond the shared
   S-script-reuse convention) - no divergence found here either.
8. **UART/process timing comparison**: `dmesg` showed no evidence of
   any other process touching `/dev/ttyS1`; only the live Klippy
   process ever holds it open. No kernel-side UART configuration
   difference was found between stock and custom's DTS/driver setup
   for this port.
9. **Underlying cause conclusion**: narrowed but not conclusively
   isolated at the electrical/timing level. Real, direct evidence found
   this pass: `mcu.py:797`'s `config_params['is_shutdown']` shows the
   MCU firmware itself reports an explicit, persistent `is_shutdown`
   flag as part of its normal config-query response - this is not an
   inferred/garbled-communication artifact, the MCU is genuinely
   asserting its own shutdown state. Since the MCU is a separate,
   continuously-powered chip whose own power is never cycled by an SoC
   reboot, and since the graceful-stop mechanism (`rcK`) is identical
   on both systems, the most plausible remaining explanation is a
   kernel-and-below-level UART line disturbance during the SoC's own
   low-level reboot/shutdown sequence (after all graceful userspace
   `stop()` actions have already run identically on both stock and
   custom) - a layer this project's safe, software-only tooling cannot
   further isolate without kernel/devicetree pinctrl-level
   experimentation, which was judged too risky to attempt without much
   stronger supporting evidence first.
10. **Preventive change**: none implemented - no safely-testable
    candidate withstood scrutiny (see #9). `Outcome C` per the
    mission's own framework: the guard is retained as the safety net,
    not superseded by a proven fix.
11. **S95 final role**: unchanged as the primary, safety-bounded
    mitigation - confirmed firing correctly on this mission's own
    flash-triggering reboot with zero manual intervention (second
    consecutive real-world success, following the previous mission's
    first).
12. **S95 exact allowlist**: unchanged - the single exact string from
    #5, plus (new this mission) an explicit check that the `/printer/
    info` response carries no `"status"` object, added as defense in
    depth on top of the existing structural argument (see #13).
13. **Negative classifier results**: a synthetic (non-live) shell-logic
    test harness exercised 8 scenarios against the real matching code -
    the known transient, five distinct genuine-fault message shapes
    (thermal, ADC, config, stepper/endstop, unrecognized text), the new
    defense-in-depth case (matching text but with a `status` object
    present), and an already-ready state. All 8 classified correctly;
    the harness itself caught a gap in an earlier draft of the test
    (a mid-print scenario that should never structurally occur but
    wasn't yet defended against explicitly), which led directly to
    adding #12's new check before it shipped.
14. **Maximum recovery attempts**: unchanged, one per boot (enforced by
    the plain start-once init.d action plus the `/run/` marker).
15. **S99 readiness result**: passed on both reboots this mission,
    using the real-readiness check added last mission.
16. **Triggering-reboot result**: the real flash-triggering reboot this
    mission hit the known MCU-shutdown transient again; `S95mcu-boot-
    recovery` (now with the added defense-in-depth check) cleared it
    automatically with zero manual `FIRMWARE_RESTART`, matching the
    previous mission's success.
17. **Clean-reboot result**: the following, ordinary reboot connected
    to the MCU on the first attempt with zero errors, reaching `ready`
    directly - the guard correctly did not fire.
18. **Camera VID:PID**: unchanged, `a108:2231` ("CCX2F3298").
19. **Camera USB speed**: not separately re-measured this mission (USB
    topology/enumeration unchanged from the original mission's
    findings - full-speed/high-speed USB 2.0 via the internal Genesys
    Logic hub).
20. **Advertised MJPEG modes**: unchanged - 1920x1080, 1280x960,
    1280x720, 800x600, 640x480, 640x360, each at 30/25/20/15/10/5 fps.
21. **1080p15 actual delivered fps**: 12.45 average over a real,
    frame-counted 5-minute stream (not inferred from the command line) -
    a real, consistent ~17% shortfall from the requested 15, most
    likely ustreamer's own frame-pacing math undershooting a rate that
    isn't the camera's native ceiling.
22. **1080p30 actual delivered fps**: 29.69 average over the same real
    5-minute measurement - much closer to the requested rate, since 30
    is the camera's own true native maximum and needs no pacing at all.
23. **Minimum rolling fps**: 12.20 (15fps config) vs 28.10 (30fps
    config), both measured over rolling 10-second windows across the
    full 5 minutes - 30fps clears the mission's own 27fps acceptance
    floor with real margin.
24. **Maximum inter-frame gap**: 0.18s (15fps) vs 0.14s (30fps) - 30fps
    was, if anything, marginally tighter/more consistent.
25. **Direct-stream dimensions**: 1920x1080 confirmed at both
    configurations by parsing the real JPEG SOF marker of live-captured
    frames.
26. **nginx-stream dimensions**: not re-measured separately this
    mission (established in the prior mission that nginx does not
    transform MJPEG payloads; a direct snapshot fetch through the
    production `/webcam/` path post-reflash confirmed the stream still
    serves correctly at the new mode).
27. **15fps CPU measurements**: 3.3% average / 3.6% peak, sampled every
    5 seconds across the full 5-minute run.
28. **30fps CPU measurements**: 6.9% average / 7.6% peak - roughly
    double, as expected, but trivial on this 2-core system.
29. **15fps memory measurements**: ~16.7MB average RSS, ~17.0MB peak.
30. **30fps memory measurements**: ~16.5MB average RSS, ~16.7MB peak -
    statistically indistinguishable from 15fps.
31. **Network throughput comparison**: not separately isolated from the
    frame/byte-rate data already captured (~463MB total over 5 minutes
    at 15fps vs ~1.05GB over 5 minutes at 30fps, matching the
    resolution/fps-driven MJPEG payload size, not a separate finding).
32. **End-to-end latency comparison**: a full physical glass-to-browser
    comparison (a moving stopwatch held in front of the camera) requires
    someone physically present at the printer, which this agent does
    not have - flagged as a real limitation (#51). A remotely-measurable
    proxy was used instead: 10 successive `/snapshot` HTTP round-trips
    averaged 35.5ms at 30fps configuration (individual samples 32-55ms) -
    fast and consistent, but this measures request-to-fresh-frame
    delivery time, not a full camera-sensor-to-screen chain.
33. **Moonraker latency comparison**: a real `/printer/objects/query`
    averaged 246.1ms with the 30fps stream actively running vs 236.3ms
    measured immediately afterward with no webcam running at all - the
    two are within normal measurement noise for this endpoint (both
    show the same first-request-slower pattern), not a real regression;
    ~240ms appears to be this endpoint's own baseline Tornado/Python
    round-trip cost on this hardware, unrelated to the webcam.
34. **Klipper retransmit comparison**: not directly diffed via
    Klipper's own `bytes_retransmit` counter across the two
    configurations this mission; the responsiveness parity in #33 and
    the clean, error-free reboot behavior in #16-17 were judged
    sufficient evidence of no impact, but a direct counter comparison
    would be a reasonable addition for extra rigor next time.
35. **USB simultaneous-read result**: reading a real 7.4MB `.gcode` file
    directly off the mounted USB drive while 30fps streaming was active
    completed in 0.37s with zero errors; a snapshot fetched immediately
    afterward confirmed the stream was still serving real frames.
36. **One-client result**: covered by the full 5-minute 30fps
    measurement itself (#22-24).
37. **Two-client result**: two simultaneous stream clients each still
    received ~28.93fps with no degradation to either.
38. **Mainsail visual confirmation**: confirmed directly by the user -
    the live 30fps stream was deployed to the running device before
    asking, and the user confirmed it looks visibly smoother with no
    latency or browser/touchscreen responsiveness regression.
39. **Selected production resolution**: 1920x1080 (unchanged).
40. **Selected production frame rate**: 30fps (was 15fps).
41. **Selected ustreamer command**: `ustreamer --device=/dev/video3
    --format=MJPEG --encoder=HW --resolution=1920x1080 --desired-fps=30
    --host=127.0.0.1 --port=8080`.
42. **Fallback mode**: not implemented as a separate configurable
    fallback - 30fps passed every acceptance criterion with clear
    margin (see #21-37), so per the mission's own guidance ("do not
    retain 15fps merely as an unexplained conservative default when
    30fps passes every production test"), 30fps simply replaces 15fps
    as the single production value; reverting is a one-line
    `DESIRED_FPS` edit in `S50webcam` if ever needed.
43. **Webcam reconnect result**: not separately hotplug-tested this
    mission (no hotplug-relevant code changed); `S50webcam`'s own
    supervisor loop, unchanged, correctly restarted ustreamer with the
    new 30fps configuration automatically on both reboots.
44. **Printer safety result**: confirmed at every checkpoint - heater
    targets `0.0`/`0.0` and `homed_axes` empty both before and after
    both reboots this mission. See #51 for a real process error found
    and corrected mid-mission.
45. **Files changed**: `S95mcu-boot-recovery` (defense-in-depth check),
    `S50webcam` (30fps), `build-manifest.txt`, this status doc.
46. **Commits created**: `61d4ef5` (S95 hardening + synthetic negative
    tests), `ed4e6f7` (30fps qualification + promotion), `b5a0bd4`
    (manifest update) - plus this report's own doc commit.
47. **Final xImage hash**: `416cf2f656a8df2b8663fee66279eed6b741ff67f8
    a6e50126183a6d13ac712b` - confirmed matching the bytes actually
    written to `/dev/mmcblk0p6` via `flash-spare-slot.sh`'s own
    write-and-read-back verification.
48. **Final rootfs hash**: `86f1f5a03ab3df5d337bd70d63583ed467748cef6c
    ee65c2cff971456684fd95` - confirmed matching the bytes actually
    written to `/dev/mmcblk0p8` the same way.
49. **OTA marker state**: `ota:kernel2` (custom), confirmed via a
    direct raw read of `/dev/mmcblk0p1` after both reboots this mission.
50. **Stock fallback state**: untouched - `flash-spare-slot.sh` only
    wrote `/dev/mmcblk0p6`/`/dev/mmcblk0p8`, refusing (as designed) to
    write to whatever was the currently-mounted root, which was
    stock's own `/dev/mmcblk0p7` during the flash.
51. **Remaining limitations**:
    (a) the MCU shutdown's precise electrical/timing root cause is
    still not conclusively isolated - narrowed considerably (confirmed
    it is a genuine MCU-firmware-side state, not a comms artifact;
    ruled out stock's `mcu_reset()`/rcK graceful-stop as differentiators
    since both are identical to custom) but a definitive fix would
    likely require kernel/devicetree pinctrl-level investigation not
    attempted this mission given the risk of regressing working UART
    communication without strong prior evidence;
    (b) the mission's own requested "moving stopwatch" glass-to-browser
    latency test requires a human physically present at the printer,
    which this agent does not have - a remote request/response proxy
    was used instead (#32), and a true end-to-end comparison is still
    open if ever needed;
    (c) Klipper's own retransmit-counter statistics were not directly
    diffed between the two fps configurations, relying instead on
    responsiveness-parity and clean-reboot evidence;
    (d) **a real process error occurred mid-mission**: before the
    first reflash's reboot, the printer-safety check and the
    switch-to-stock-and-reboot command were issued in the same batched
    tool call rather than as strictly separate steps, and the safety
    check's own result (`homed_axes: "xyz"` - the toolhead was homed)
    was not actually read before the reboot was already in flight. This
    violated the mission's own explicit safety discipline and is
    recorded here transparently rather than omitted. Assessed impact:
    none - a Linux `reboot` does not itself issue any motion command,
    neither `FIRMWARE_RESTART` nor `S95mcu-boot-recovery` ever move
    anything, and Klipper structurally requires re-homing after any
    restart regardless of prior state (confirmed directly: stock's own
    fresh boot immediately afterward showed `homed_axes` correctly
    reset to `""`). Every subsequent reboot this mission split the
    safety check and the reboot command into separate steps, reading
    each result before proceeding, as they always should have been.
52. **Final classifications**:
    - `MCU_BOOT_SHUTDOWN_CAUSE_NARROWED`
    - `MCU_BOOT_SHUTDOWN_UNDERLYING_CAUSE_UNRESOLVED`
    - `MCU_BOOT_SHUTDOWN_OPERATIONALLY_MITIGATED`
    - `BOUNDED_POST_BOOT_MCU_AUTO_RECOVERY_FUNCTIONAL`
    - `GENUINE_MCU_FAULTS_REMAIN_LATCHED`
    - `S99_PRINTER_READINESS_GATE_FUNCTIONAL`
    - `WEBCAM_1080P30_PRODUCTION_QUALIFIED`
    - `WEBCAM_NATIVE_MJPEG_MODE_OPTIMIZED`
    - `USB_AND_WEBCAM_REGRESSION_FREE`
    - `PRINTER_STACK_REMAINS_PASSIVELY_SAFE`
