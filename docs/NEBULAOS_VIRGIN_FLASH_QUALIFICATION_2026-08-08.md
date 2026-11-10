# Virgin Flash + Verification mission (2026-08-08)

Running record for the Autonomous NebulaOS Virgin Flash + Verification
mission: deploying `build-work/deploy-packages/z-compensate-guppyscreen-
20260808T152643Z/` to the real device, proving first boot uses no previous
NebulaOS runtime state, live qualification, and the resulting canonical
baseline tag. Appended to as each phase completes.

## Phase 1: traceability correction

The package under deployment was built from a genuinely fresh clone at
firmware commit `91a190e` (`build: pin pellcorp/k1-bash-build by immutable
digest`). One further commit, `f939141` (`docs: record explicit load-cell
scope + exclude uncommitted safety fix`), landed on `main` afterward -
**independently re-verified here** via `git diff --stat 91a190e f939141`:
exactly one file changed, `docs/NEBULAOS_PRINTER_CFG_LOADCELL_GAP.md`, pure
Markdown, zero lines touched in any script, manifest, `klippy_extras/`
module, or `printer.cfg`. Confirmed documentation-only; no rebuild
performed, per this mission's own explicit instruction.

```
BUILT_FROM_FIRMWARE_SHA=91a190e4cd6b128de1cc071012e899cbd44b53a4
CURRENT_DOCUMENTATION_HEAD=f939141afa5dcbd30472f37e94bb233013e7d0c1
```

Full commit SHAs, for the record:

- `BUILT_FROM_FIRMWARE_SHA` = `91a190e4cd6b128de1cc071012e899cbd44b53a4`
  (matches this package's own `build-manifest.txt`'s `git_commit_main` and
  `/opt/nebulaos-version.json`'s `firmware_sha`, independently confirmed by
  direct `unsquashfs` inspection of the packaged `rootfs.squashfs` during
  the prior mission's own artifact-inspection step)
- `CURRENT_DOCUMENTATION_HEAD` = `f939141afa5dcbd30472f37e94bb233013e7d0c1`
  (current `origin/main` tip at the time this deployment mission began)

The canonical baseline tag this mission creates (Phase 11) is placed on
`91a190e` - the commit that actually produced the flashed bytes - not on
the later docs-only HEAD, so the tag always points at something a fresh
clone can rebuild byte-reproducibly-equivalent to what is actually running
on the device.

## Phase 2: final package gate

Re-verified fresh (not reused from memory): `sha256sum -c SHA256SUMS` all 7
files OK; `rootfs.squashfs` 119,410,688 bytes (~113.9 MiB, well under the
500MB rootfs2 budget); `build-manifest.txt` confirms
`git_commit_main=91a190e...`, `git_commit_klipper=462fd68...`,
`git_commit_v4l_utils=3b22ab0` (`_dirty=no`, confirming the deterministic
archive fetch produces a clean checkout); fresh `unsquashfs` extraction
directly confirmed `[nebulaos_version]`/`[prtouch_v2]`/`[z_compensate]`
present in the packaged `printer.cfg`, `bed_add_temp: 60`, all 7 required
Klipper modules present and non-empty, `S04nebulaos-factory-seed`/
`S04nebulaos-migrate` present, GuppyScreen a real stripped MIPS32 ELF
binary, `nebulaos-version.json` reporting `firmware_sha: 91a190e...`. Both
canonical repos (`NebulaOS-firmware`, `NebulaOS-klipper`) confirmed clean
with local HEAD == remote HEAD.

## Phase 3: pre-flash printer checks

Device located via `nmap -p 22 --open` scan (IP had drifted, as expected -
see project memory on DHCP lease churn): `192.168.1.242`, dropbear banner,
password `openke` accepted. Confirmed:

- `/proc/cmdline`: `root=/dev/mmcblk0p8 ... rootfstype=squashfs ro` - real
  board, currently booted on the **custom** slot (rootfs2). Partition
  table (`/dev/disk/by-partlabel/*`) matches this project's own documented
  layout exactly (kernel/kernel2/rootfs/rootfs2/rootfs_data/userdata/rtos/
  rtos2/sn_mac/ota) - confirms genuine device identity.
- OTA marker (`/dev/mmcblk0p1`): `ota:kernel2` - internally consistent
  with currently booted on custom.
- Moonraker `/printer/objects/query`: `print_stats.state: "standby"`,
  `idle_timeout.state: "Idle"`, `extruder.target: 0.0`,
  `heater_bed.target: 0.0` - idle, no active/paused print, heaters off.
- Moonraker `/server/info`: `klippy_connected: true`,
  `klippy_state: "ready"` - Klipper healthy, not halted (resolves the
  open question carried from before this mission chain: whatever earlier
  `bed_add_temp`-related halt existed is not present in the currently
  running, pre-this-deployment image).
- `moonraker_version: v0.10.0-31-gd5ee171` matches the pinned
  `MOONRAKER_PIN`.

**Real finding, not previously documented**: `/opt/klipper` is NOT
currently bind-mounted from `/usr/data/nebulaos/apps/klipper` on this
boot (`mount` output has no `klipper` entry, unlike `/opt/moonraker`,
`/opt/printer_data`, `/usr/share/mainsail`, `/root/klippy-env`, all of
which are correctly bound). Klipper is therefore currently running from
whatever `/opt/klipper` resolves to on the read-only squashfs itself
(content dated 2026-08-07, consistent with the prior "canonical-
baseline-2026-08-07" live deployment). The **persistent** checkout at
`/usr/data/nebulaos/apps/klipper` (HEAD `d839d0375a31327e57e0a35e99e70ba60814ec05`,
branch `nebulaos`) is unaffected by this and is what actually gets backed
up in Phase 4 below - this anomaly does not change this mission's plan
(a fresh flash + virgin provisioning replaces the whole picture
regardless) but is recorded here since it is real, observed device
state, not something to silently paper over.

No motion/homing/heating/extrusion/printing/calibration command was ever
issued - every check above is a read-only query.

Stock slot health / current custom image recoverability: not directly
probed from within custom (deferred to Phase 6, where booting into stock
as part of the flash sequence itself is the real, direct verification -
stronger evidence than any indirect check possible from custom).

## Phase 4: persistent-state backup

Real, active runtime paths identified precisely from the live device's
own `/etc/init.d/S05nebulaos-activate` (not inferred): every real bind
mount source is under `NEBULAOS_ROOT=/usr/data/nebulaos`, plus one
separate shared-gcodes source at `/usr/data/printer_data/gcodes`. The
device's `/usr/data` partition (99% full, only 67MB free) also carries
several GB of unrelated, non-bind-mounted historical debris from past,
unrelated missions (`creality/`, a dozen `*-stage/` directories, six
separate `nebulaos.*-backup-*/` snapshots, `staging/`, `deploy-staging/`,
etc.) - confirmed inert (not referenced by the live activation script) and
out of scope for this backup, which targets the real active state only.

Backed up (streamed directly over SSH to the build host - the device had
no free space to stage a local copy at all):

```
ssh root@192.168.1.242 "tar -cf - -C /usr/data nebulaos printer_data/gcodes" \
    > nebulaos-device-backup-20260808T165251Z/usr-data-backup.tar
```

- Path: `~/Documents/nebulaos-device-backup-20260808T165251Z/usr-data-backup.tar`
- Size: 373,587,968 bytes (~356 MiB), 12,665 entries
- SHA256: `be6f597b665d917a089aaaf3027a00ca5cbfa51b3ff8b746137995e6ab40c4d0`
- Two Unix-domain sockets (`nebulaos/printer_data/comms/moonraker.sock`,
  `.../klippy.sock`) were skipped by `tar` (expected, harmless - live
  runtime sockets, not data)
- Verified by extraction: `nebulaos/apps/klipper`'s checkout re-hashes to
  the exact same HEAD confirmed live (`d839d0375a...`), `printer_data/
  config/printer.cfg` present

This backup is complete, checksummed, and left untouched at an inert
location off the device, outside anything Phase 5's virgin-state reset or
Phase 6's flash can affect. Not deleted; not to be restored before
qualification (Phase 5's own explicit instruction).

## Phase 5: virgin-state reset

**User caught a real safety error before this ran**: my original plan was
to run the reset while still booted on custom, where Klipper/Moonraker
were actively running against the exact paths being deleted (`/opt/moonraker`,
`/opt/printer_data` etc. are bind-mounted from the same underlying
directories) - deleting the source out from under live processes could
have crashed them mid-write or corrupted an in-flight SQLite transaction.
Corrected: cycled to stock first (`write_ota_marker "ota:kernel"` +
reboot), confirmed genuinely booted on stock (`root=/dev/mmcblk0p7`,
stock's own dropbear version/password), confirmed stock's own separate
Klipper/Moonraker/GuppyScreen stack (different, unrelated top-level paths -
`/usr/share/klipper`, `/usr/data/moonraker`, `/usr/data/guppyscreen`) was
idle, and confirmed no live process anywhere had `/usr/data/nebulaos` as
its cwd. Reset then ran with zero risk:

```
rm -rf /usr/data/nebulaos/apps /usr/data/nebulaos/envs \
       /usr/data/nebulaos/system /usr/data/nebulaos/printer_data
```

Verified: all four gone, `/usr/data` free space rose from 67MB to 402.5MB.
Left untouched (not part of what influences first-boot provisioning):
`backups/`, `updates/`, `maintenance/`, `loadcell-test-backup-20260805/`,
`display-qualified.conf`, `wpa_supplicant.conf`.

## Phase 6: flash

Staged the package (`xImage`, `rootfs.squashfs`, `build-manifest.txt`,
`flash-spare-slot.sh`) to the device via `scp -O` while still on stock;
independently re-verified transfer integrity with `sha256sum` before
touching the flash script at all. `--check-only` preflight: `result:
SAFE TO FLASH` (active slot 1/stock, target slot 2/custom, confirmed
inactive). Real write: both images written and read-back-verified by the
script's own internal MD5 comparison; independently cross-checked those
exact MD5s against the local package files afterward - exact match. Stock
partitions (mmcblk0p5/p7) never touched - only mmcblk0p6/p8. OTA marker
flipped via the real on-device toggle mechanism (`ota_local_method.sh`'s
`local_set_next_boot_device`, read-verified before and after), synced,
then rebooted.

## Phase 7: proving a genuine virgin first boot

**First reboot attempt surfaced a real bug, in my own Phase 5 scope, not
in the shipped image**: after ~5 minutes uptime, `/usr/data/nebulaos/apps/klipper`
still had no `.git` - `S04nebulaos-factory-seed` had not populated it, yet
Klipper was already reporting `klippy_state: "ready"` (running from the
separate, immutable copy baked directly into the squashfs at `/opt/klipper`,
not the intended persistent bind-mounted path - `/opt/klipper` was not
bind-mounted at all on this boot). Root cause found directly: a **stale
lock file**, `/usr/data/nebulaos/updates/locks/klipper.lock`, dated
2026-08-07 - left over from the OLD image, outside Phase 5's reset scope
(which only covered `apps/envs/system/printer_data`) - permanently
satisfies `S04nebulaos-factory-seed`'s own `maintenance_gate_ok()` refusal
condition (`[ -d "$LOCKDIR" ] && [ -n "$(ls -A "$LOCKDIR")" ]`), silently
blocking real seeding on every boot. `S99confirm-good` does not check
whether persistent seeding actually succeeded, only Moonraker's own
`klippy_state` - so the system reported itself healthy and even flipped
the OTA marker forward, despite factory-seed never having run. Removed
the stale lock, rebooted again (marker was already `ota:kernel2`, so a
plain reboot correctly returned to custom) - this second boot is the
device's genuine, unblocked virgin first boot.

Verified directly on the resulting live system:

- `app-generation.json`: `migration_version: 32eb40a307874aa1`,
  `klipper_commit: 462fd689...` (exact `KLIPPER_PIN` match),
  `moonraker_commit: d5ee171...` (exact `MOONRAKER_PIN` match) - a
  genuinely new marker, did not exist before this deployment at all.
- `/usr/data/nebulaos/system/migration-backups/`: does not exist - no
  redundant reseed happened (the fresh-boot-ordering fix from the earlier
  mission is confirmed working on real hardware, not just offline tests).
- Klipper checkout: `HEAD 462fd689...`, branch `master`, origin the
  canonical fork URL, `git status --porcelain` (excluding the one
  allowlisted `c_helper.so` path) completely clean - no local
  modifications.
- `printer.cfg`: `[nebulaos_version]`/`[prtouch_v2]`/`[z_compensate]` all
  present, `bed_add_temp: 60` present - this section set did not exist in
  the pre-deployment backup at all, direct proof it came from the new
  factory seed, not carried over.
- `klippy/chelper/c_helper.so`: MD5 `616ac242...`, confirmed **different**
  from the old backup's own copy (MD5 `e0da43c2...`) - the old compiled
  helper was not reused.
- GuppyScreen (`/opt/guppyscreen/guppyscreen`): MD5 `3ec55f6d...`, an
  **exact match** against the same binary extracted directly from the
  verified package's own `rootfs.squashfs` - confirmed canonical, not a
  leftover.
- Explicit search for old-state evidence: the old Klipper HEAD
  (`d839d0375...`) and old branch (`nebulaos`) do not appear anywhere in
  the live checkout's refs.

## Phase 8: live non-motion qualification

All checks below are read-only queries or passive kernel/log inspection -
zero motion/homing/heating/extrusion/printing/calibration commands issued.

- **PREEMPT_RT**: `uname -a` → `6.6.18-rt23 #2 SMP PREEMPT_RT`,
  `/sys/kernel/realtime` = `1`.
- **ROAMOFF1**: `/sys/module/brcmfmac/parameters/roamoff` = `1`.
- **WiFi IRQ priority**: the real SDIO IRQ threads (`irq/44-mmc1`,
  `irq/44-s-mmc1`) - `SCHED_FIFO priority 60` via `chrt -p`.
- **WiFi power save**: `iw dev wlan0 get power_save` → `off`.
- **CID-derived MAC**: `link/ether 16:3b:5d:...` (locally-administered bit
  set) vs `permaddr 20:0b:74:...` (real hardware MAC) - differ as expected.
- **TCP_NODELAY**: `ustreamer` process command line includes
  `--tcp-nodelay`.
- **Camera idle controller + presets**: `S51nebulaos-camera-idle-controller`
  running; `SET_CAMERA_QUALITY_HIGH/LOW/MED` all registered
  (`/printer/gcode/help`).
- **DISPLAY-V1 / PWM**: dmesg - `ingenic-pwm ...: Probe of pwm success!`,
  `nebulaos_backlight_final ...: backlight final controller ready -
  boot-preserve...` (the documented deliberate boot-preserve design -
  zero hardware touched until an explicit command).
- **Backlight-only sleep / touch wake mechanisms present**:
  `S98nebulaos-display-sleep-wake-controller` running; not actively
  cycled (a real sleep/wake transition is a display-state change, out of
  scope for a non-motion pass - driver health + presence is the
  appropriate bar here, matching every other passive check in this list).
- **Polling touch**: `ns2009_ts` input device present
  (`/proc/bus/input/devices`).
- **Zero pinctrl warnings**: 3 pinctrl dmesg lines total, all
  "success"/"initialized" - 0 matching warn/error.
- **Klipper**: `klippy_state: "ready"`.
- **GuppyScreen**: process stable (pid unchanged across the Moonraker
  restart below).
- **S99confirm-good**: OTA marker is `ota:kernel2` - only ever written by
  a successful confirm-good pass.

**Real finding, resolved live**: `/server/info` initially showed
`failed_components: ["update_manager"]` with warning "Unparsed config
section [update_manager mainsail] detected." `moonraker.log` traced the
exact cause: `moonraker.confighelper.ConfigError: [klipper]: Invalid
virtualenv at path /usr` - the same class of bug already documented in
this project's own history (Moonraker's reserved-slot venv auto-discovery
reads Klippy's own identify handshake; on this genuinely fresh boot,
`update_manager` tried to load before Klippy had reported it) - a
first-boot startup race, not a regression. Resolved with a single
`/etc/init.d/S56moonraker restart` (a service restart, not a motion/
heating action): `failed_components: []`, `warnings: []` after.

`/machine/update/status`'s klipper entry, post-restart: `current_hash ==
remote_hash == 462fd689...` (exact canonical match - direct live
confirmation the Phase 1 branch-unification fix holds), `branch: master`,
`remote_url` correct. `is_dirty: true` / `is_valid: false`, but the
*only* reported difference is `klippy/chelper/c_helper.so` - the same
already-established, expected, harmless cross-compiled-binary difference
this whole project has documented repeatedly (Moonraker's own dirty-check
has no allowlist for it, unlike this project's own `nebulaos_version.py`,
which explicitly excludes it and correctly reports `klipper_dirty: false`
via both HTTP and WebSocket below - two tools, two different, both
correct, definitions of "dirty").

**z_compensate, both transports**: HTTP
(`/printer/objects/query?z_compensate`) and a real WebSocket JSON-RPC
call (`printer.objects.query` over `/websocket`, minimal stdlib-only
client - no third-party `websockets` package needed) both return
identical structured status: `calibration_id: 0, calibration_state:
"idle", calibration_z_offset: null, calibration_error: null` - the
expected untouched-baseline state.

**GuppyScreen calibration-ID gating**: `calibration_id` has never left
`0`; `klippy.log` contains zero occurrences of `Z_OFFSET_CALIBRATION` or
`CRTENSE_NOZZLE_CLEAR` - GuppyScreen has not issued any calibration
command, consistent with "does not calibrate before receiving the real
baseline ID."

## Phase 9: Moonraker update/recovery safety

Pre-condition (already established in Phase 8): remote correct, canonical
branch (`master`) correct, `current_hash == remote_hash ==
462fd689448fb1d1946a9b0dcf81a9d7b9112254`, live checkout clean (excluding
the one allowlisted `c_helper.so` path). The real remote's own content at
this exact commit was independently verified in an earlier mission
(`tests/recovery-safety-tests.sh`, a real shallow clone of the actual
remote, not a fixture).

Ran the real, non-motion soft Recovery test with the printer confirmed
idle immediately beforehand:

```
POST /machine/update/recover  {"name": "klipper", "hard": false}
→ {"result": "ok"}
```

After Recovery, confirmed all required post-conditions directly:

- Klipper checkout: `HEAD` still `462fd689...` (== canonical remote,
  unchanged - nothing to move, it was already correct).
- `git status --porcelain` (excluding `c_helper.so`): clean.
- `z_compensate.py`, `prtouch_v2.py`, `prtouch_probe.py`, `prtouch_mcu.py`,
  `prtouch_nozzle.py`: all present.
- `/server/info`: `klippy_state: "ready"`, `failed_components: []`,
  `warnings: []` - Moonraker fully reconnected and healthy, including
  `update_manager` itself.
- `z_compensate` structured status: identical over both HTTP and a real
  WebSocket JSON-RPC call, `calibration_id: 0` still (recovery did not
  disturb Klipper's own runtime state).
- GuppyScreen: same PID (752) as before Recovery - never disrupted.
- Printer: `print_stats.state: "standby"`, `idle_timeout.state: "Idle"` -
  remained idle throughout.

Recovery did not revert any accepted baseline content - confirmed
directly, not assumed.

## Phase 10: warm reboot + soak

Confirmed idle immediately before, then issued a plain `reboot` (custom
slot, no OTA marker change beforehand - the standard warm-reboot path).
`S00revert-safety` correctly reset the marker to `ota:kernel` on boot
start (its own unconditional default); `S99confirm-good` correctly
flipped it back to `ota:kernel2` once Klipper/Moonraker were confirmed
healthy. `root=/dev/mmcblk0p8` unchanged - custom slot remained selected
throughout. `update_manager` loaded cleanly on the first attempt this
time (no restart needed - the Phase 8 race was specific to the genuinely
first, cold provisioning boot).

Soak (~220s uptime at check time): all services still running (nginx,
webcam, ustreamer, Klipper, Moonraker, GuppyScreen), WiFi still connected
(`HomeWiFi`), printer still idle. `dmesg` grep for error/fail/oops/
panic/BUG/warn found four lines, all at boot timestamps 0.0-1.1s (long
before the soak's own observation window) - `ingenic-dma`/`ingenic-tcu`
IRQ-not-found probe-ordering messages and one `mmc1: Failed to initialize
a non-removable card` immediately followed (a few lines later in the same
early boot) by `mmc1: new high speed SDIO card at address 0001` succeeding -
a resolved-by-retry transient, not an ongoing fault; live WiFi
connectivity is the direct proof. One `EXT4-fs ... mounting unchecked fs`
notice (expected on a device without a clean shutdown before reboot,
already a known/benign message class in this project). Pinctrl: same
3-line, all-success sequence as every other boot checked this mission -
zero warnings.

## Phase 11: canonical baseline

Every required live check (Phases 3-10) passed. The canonical baseline
tag is placed on `91a190e4cd6b128de1cc071012e899cbd44b53a4` - the exact
commit that produced the flashed, verified, live-qualified package - not
on this document's own later HEAD (which only ever adds qualification
records, never anything build-affecting; see Phase 1's own independent
re-verification of that split).

| Component | SHA |
|---|---|
| Firmware source (tagged commit) | `91a190e4cd6b128de1cc071012e899cbd44b53a4` |
| Documentation HEAD (this record's own tip) | `bf5a0ab41eefddf58f0409e6605a395d77a04485` |
| Kernel | `295b7101d751fd888ae39e6f1746a4a940664a5f` |
| Klipper | `462fd689448fb1d1946a9b0dcf81a9d7b9112254` |
| Moonraker | `d5ee17128bb88434aacdab90c2e9e990e2b64e4a` |
| GuppyScreen | `be5d372c0d0c693adff3c23adf2655584bb2961e` |
| Buildroot | `74d020081096972857acdb9e76c6c5335455d430` |
| `pellcorp/k1-bash-build` image | `sha256:0b96d1d65175c5a2e3a83a64c3212d08dd774fef0900f991e0ebc570ba896c85` |
| WiFi firmware | `60dbb5b77b2c232e513322e0ff4350ab5dab5a9fcad0e26e80a2f089e652d720` |
| `xImage` | `03ff00fdf34d02e9f54183d5e44eef3be628456edc50c716bcd70a5b7d8a9a44` |
| `rootfs.squashfs` | `9d2ed16abf40d17171761135c8cfd962ad07657d00850d6fa444a892a7d9e7fd` |
| Persistent app generation | `32eb40a307874aa1` |

This is the first baseline in this project's history that is genuinely
virgin-flashed (persistent state archived off-device and reset, not
carried over) and live-qualified end to end on real hardware from that
exact virgin state - not merely built and deployed onto an
already-provisioned device.
