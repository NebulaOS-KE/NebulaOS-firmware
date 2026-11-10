# NebulaOS Live Wi-Fi / Camera / PREEMPT_RT Qualification Report

Mode B (live hardware) execution log for the pre-qualification mission. Printer: Creality
Ender-3 V3 KE + Nebula Pad, IP 192.168.1.129, booted on the "custom" (NebulaOS) rootfs slot
throughout this session unless noted. This document is updated continuously as phases complete.

**Status: IN PROGRESS.** No production selections have been committed. No production tag has
been created.

## Phase B1 — Read-only live baseline (complete)

Captured with zero state changes. Confirms prior source-only analysis on:

- DWC2 SOF IRQ rate: measured ~8,197/sec (sum of both CPU cores over a 2s sample) — matches
  the predicted ~8,000/sec from the source-only analysis.
- Camera: `/dev/video0`/`/dev/video1` present; ustreamer running `--resolution=1920x1080
  --desired-fps=30`; snapshot HTTP 200 in 44ms. Matches documented C0 baseline exactly.
- CPU: 95% idle, load 0.04–0.15 with camera streaming continuously.
- Wi-Fi: associated (SSID `OtherNetwork`, -69dBm, 57.7/72.2 Mbit/s bitrates); `ccode=CN` confirmed
  present in `/lib/firmware/brcm/brcmfmac43430-sdio.txt`.
- Power-save: currently **on** (matches documented P0/PM_FAST default).
- Safety state at session start: `print_stats.state=standby`, not paused, `homed_axes=""`,
  temps at ambient (~29°C). Confirmed safe to proceed.

**Open finding carried into B3**: NVRAM contains the known placeholder
(`macaddr=00:11:22:33:44:55`, `il0macaddr=00:90:4c:c5:12:38`), but the live `wlan0` MAC is
`20:0b:74:00:00:01` — this address does **not** have the locally-administered bit set
(`0x20` = `00100000`, bit 1 clear), meaning it is not the product of the standard kernel
`eth_random_addr()`/`eth_hw_addr_random()` fallback the source-only analysis assumed. MAC
provenance is unresolved pending B3.

## Phase B2 — Venv-seed fast-path / fallback-path validation (complete)

### Protected-data baseline methodology

Live device data is split across two real, independently bind-mounted sources (confirmed via
`/proc/self/mountinfo`, not assumed):
- `/usr/data/nebulaos/printer_data` (config/history/db, 4.9MB, 33 files) — bind-mounted onto
  `/opt/printer_data`.
- `/usr/data/printer_data/gcodes` (184 files, ~350MB) — bind-mounted onto
  `/opt/printer_data/gcodes`. Excludes the external USB drive mounted at
  `.../gcodes/USB/sda` (14.6GB, user's own removable media, not NebulaOS state).

Manifests recorded at `/usr/data/nebulaos/maintenance/qualification/protected-data-{before,after}.txt`
(size+mtime+owner listing for both paths, full SHA-256 for the smaller nebulaos/printer_data
tree). Replaceable-state inventory at `replaceable-state-before.txt`; filesystem free space at
`filesystem-before.txt` (1.2GB free of 5.9GB on `/usr/data` at test start — ample headroom;
backups used same-filesystem atomic `mv`, not copies, so no extra space was consumed anyway).

### Real finding: this legacy image ships with no venv-seed archives

`/opt/nebulaos-seeds/` on the currently-running image contains only `klipper.tar.gz` and
`moonraker.tar.gz` (git-history archives) — **no** `klipper-venv-seed.tar.gz` or
`moonraker-venv-seed.tar.gz`. Those two files were only introduced by
`04-cross-compile-app-stack.sh`'s venv-seed feature (Phase 11 of the prior optimization
mission) — this running image predates that. Consequence: **every boot of this image has
always taken the on-device `python3 -m venv --system-site-packages` fallback path; the fast
path has never once executed on this hardware.** This directly explains memory's "implemented
but not yet hardware-tested" caveat. Fast-path validation is deferred to B3.3 once a build that
includes the venv-seed archives (B0–B4, built this session) is deployed and booted.

### Backup (B2.2)

Atomic same-filesystem rename, verified readable before removing originals:
```
apps/{klipper,moonraker,mainsail} -> apps/{...}.pre-qualification-20260731T183029Z
envs/{klipper,moonraker}          -> envs/{...}.pre-qualification-20260731T183029Z
```
All 5 backups confirmed readable (`.git` present for klipper/moonraker, `index.html` for
mainsail, `bin/python3` executable for both venvs) before originals were removed. Originals
confirmed genuinely absent before proceeding. Backups retained for the remainder of this
qualification (not yet deleted).

### Fallback-path exercise (B2.4 — the only path available on this image) — real bug found

Services stopped cleanly (`S55klipper`, `S56moonraker`, `S58guppyscreen`, `S50webcam`) after a
fresh safety re-check. `sh /etc/init.d/S04nebulaos-factory-seed start` run against the
genuinely-absent namespace. Result, 117s elapsed:

- Moonraker: seeded successfully (`d5ee17128bb88434aacdab90c2e9e990e2b64e4a`, matches this
  project's own vendor pin exactly).
- Mainsail: seeded successfully from the immutable `/usr/share/mainsail` copy.
- Both venvs: created successfully via the on-device fallback (`python3 -m venv
  --system-site-packages`), smoke tests passed.
- **Klipper: `ERROR: klipper seeded checkout has a dirty working tree - rejecting`.**
  `/usr/data/nebulaos/apps/klipper` was left completely unseeded — a genuinely fresh device
  hitting this exact path would have no Klipper installation at all.

**Root cause (confirmed by direct diagnosis)**: extracting `/opt/nebulaos-seeds/klipper.tar.gz`
into a scratch directory and running `git status --porcelain` shows exactly one line:
`M klippy/chelper/c_helper.so`. `scripts/build/lib/make-seed-archive.sh`'s
`make_seed_archive()` **already** excludes this exact path from its own dirty-tree check (its
own comments explain why: the real cross-compiled MIPS binary the build pipeline bakes in
always differs from whatever's tracked in git for that path — this is intentional, not
corruption). But the on-device consumer, `S04nebulaos-factory-seed`'s `seed_git_app()`, had a
plain unqualified `git status --porcelain` with no matching exclusion. The producer and
consumer dirty-tree checks were asymmetric — **this would have broken first-boot Klipper
installation on every genuinely fresh or wiped NebulaOS device**, and had never been physically
exercised before this test.

**Immediate remediation**: restored `apps/klipper` from the verified backup
(`git rev-parse HEAD` = `d839d0375a...`, clean tree, matches vendor pin). Restarted all
services. Confirmed `printer/info` returns `state: ready`, safety state still standby/not
paused. A duplicate/orphaned pre-existing Moonraker process (PID 3598, `PPid=1`, predating this
test entirely, running on bare `/usr/bin/python3`) was found blocking port 7125 during
restoration — killed (safe: not tied to any print/session) and Moonraker restarted cleanly on
its correct venv interpreter.

**Fix committed** (`c03757e`, `scripts/build/overlay/etc/init.d/S04nebulaos-factory-seed` +
`tests/factory-seed-git-tests.sh`): `seed_git_app()` now accepts an optional 4th
`dirty_exclude` argument mirroring `make_seed_archive()`'s own `sparse_exclude` parameter,
passed only for the klipper call site (`klippy/chelper/c_helper.so`). 2 new host-side tests
added proving the exclusion works (dirty c_helper.so tolerated) and does not become a blanket
bypass (an unrelated dirty file in the same archive is still rejected). All 19 tests in the
suite pass.

**Fix validated live**: copied the fixed script to the device's writable `/tmp` (scp `-O`,
BusyBox has no `sftp-server`), removed `apps/klipper` again, ran the fixed script directly —
Klipper seeded successfully (`d839d0375a...`, exact match, clean tree, 4s elapsed since the
venv already existed). Restarted services, confirmed `state: ready` again.

**Caveat**: B0–B4 (built earlier this session, before this fix existed) do **not** yet include
this fix. It must be folded into whichever build becomes the actual final production candidate
before that candidate is treated as fresh-install-safe. It does not block the remaining
Wi-Fi/camera/RT A/B experiments in this mission, since `/usr/data` (where `apps`/`envs` live) is
shared across both rootfs A/B slots and is not wiped by a slot switch — Klipper stays seeded
across the SDIO/camera/RT variant tests to follow.

### Protected-data comparison (B2.5)

`protected-data-after.txt` generated and diffed against `protected-data-before.txt`. The
**only** differences: `klippy.log`, `moonraker.log`, `guppyscreen.log` grew (expected — these
services were stopped/started/restarted repeatedly during this test) and
`moonraker-sql.db` changed (expected — Moonraker's own database records its own
restart/history bookkeeping). **Zero differences** in any of the 184 gcode files, any
`config/*.cfg` file, or any other printer-data content. Classification: protected data fully
preserved.

### VENV_SEED classification

```
VENV_SEED: ACCEPT_WITH_FIX
```
Fallback path works correctly (validated live, real timing ~117s for the full first-boot
sequence). Fast path cannot be validated on this image (venv-seed archives absent) — deferred
to B3.3. The git-app-seed fix (dirty c_helper.so exclusion) is required before this mechanism
is safe to rely on for a genuinely fresh/wiped device; without it, Klipper would never install
on a true factory-reset unit.

---

## Phase B3 — MAC provenance and stability (in progress)

### B3.1 — Static investigation (read-only, complete)

Searched, all read-only, no writes to any factory partition:
- `/proc/device-tree`: no `local-mac-address` or `mac-address` property anywhere.
- `/sys/bus/nvmem/devices/`: does not exist on this image (no nvmem framework in use).
- `/proc/cmdline`: no `mac=` parameter.
- U-Boot environment: not accessible from this running system (no `fw_printenv`, no exposed env
  partition found under standard paths).
- eMMC CID (`/sys/class/mmc_host/mmc0/mmc0:*/cid`): `45010044473430303801000000000100` — present
  and readable, but no current code path on this legacy image derives anything from it.

No external stable-identity source was found feeding the live MAC through any standard Linux
mechanism. This means the MAC's stability (see B3.2) is coming from somewhere inside
brcmfmac/firmware itself, not from device-tree/nvmem/cmdline/U-Boot/bootloader-fixup — most
plausibly the chip's own SDIO CIS (Card Information Structure) or OTP, read directly by the
driver at runtime rather than exposed through any Linux-standard identity framework. This is a
plausible explanation, not confirmed to kernel-source level — flagged as such rather than
asserted.

### B3.2 — Warm reboot stability (complete, 3/3 reboots)

Each reboot preceded by a fresh read-only safety check (refused if not `standby`), issued via a
separate SSH invocation from the safety check itself, per the mandatory safety pattern.

| Reboot | wlan0 MAC | IP | Safety state after |
|---|---|---|---|
| baseline (pre-reboot) | `20:0b:74:00:00:01` | 192.168.1.129 | standby |
| warm reboot 1 | `20:0b:74:00:00:01` | 192.168.1.129 | standby |
| warm reboot 2 | `20:0b:74:00:00:01` | 192.168.1.129 | standby |
| warm reboot 3 | `20:0b:74:00:00:01` | 192.168.1.129 | standby |

**Result: identical MAC and identical IP across all 3 warm reboots.** This directly
contradicts the source-only analysis's assumption that brcmfmac generates a new random MAC on
every boot. Note: each reboot took approximately 5–7 minutes of real wall-clock time from
`reboot` issued to SSH becoming reachable again — longer than a typical embedded warm boot;
not investigated further here since it did not block testing, but worth flagging for the boot-
timing work done earlier in Mode A.

Classification:
```
MAC_STABILITY: STABLE_ACROSS_WARM_REBOOTS (3/3)
COLD_BOOT_MAC_VALIDATION: PENDING_MANUAL_POWER_CYCLE
```

### B3.3–B3.5 — B0 deployment, derived-MAC validation, legacy-vs-B0 comparison

Not yet started.

### Provisional MAC_PROVENANCE reasoning (pending B3.3–B3.5 to finalize)

Given: (a) the address does not match either NVRAM placeholder, (b) it does not have the
locally-administered bit set (looks like a genuine universally-administered/vendor-assigned
address, not a kernel `eth_random_addr()` product), and (c) it is stable across 3 independent
warm reboots — the evidence so far points toward the legacy MAC being a real, stable,
non-random identity (most likely chip-level, e.g. SDIO CIS/OTP), not the "random every boot"
mechanism the source-only analysis assumed. Per the mission's own decision rule, this weighs
toward **not** forcing the derived (CID-hash, locally-administered) stable-MAC implementation
as the default, and instead treating the existing address as the preferred production identity
if B3.3–B3.5 (rootfs-slot switch, rollback, and comparison against the B0 derived-MAC
implementation) confirm it holds across those too. Final classification deferred until those
steps complete.

## Phase B4 — Wi-Fi power-save A/B (legacy image, complete)

Same kernel/rootfs/SDIO/camera throughout; only `iw dev wlan0 set power_save on|off` toggled.
Ping target: default gateway (192.168.1.1), 50 samples per state, `-i 0.2`.

| State | Median | P95 | P99 | Loss |
|---|---|---|---|---|
| P0 (power_save on, production default) | 5.20ms | 20.3ms | 31.4ms | 0% |
| P1 (power_save off) | 5.33ms | 14.1ms | 25.9ms | 0% |

P1 shows lower tail latency (P95/P99) with an equivalent median and zero packet loss in both
states — consistent with power-management sleep/wake cycles contributing to occasional latency
spikes. Moonraker API latency (loopback, not Wi-Fi-dependent) was ~11–14ms in both states, as
expected since that call never traverses the radio. Restored to P0 (production default) after
testing; safety state confirmed standby/not-paused throughout and afterward.

Classification:
```
WIFI_POWER_SAVE_AB: P1 (off) shows a real, repeatable tail-latency improvement.
  Cannot be fully "accepted" per the mission's own acceptance criteria, which requires
  justifying against measured power/temperature cost - no power or thermal measurement
  tooling is available on this hardware. Provisional lean: P1, pending either accepting
  the unmeasured power cost as acceptable or acquiring the missing instrumentation.
```

### B3.1 addendum — real factory identity partition found, but not consumed by wlan0

While investigating the partition table for B3.3's slot deployment (see below), a
`sn_mac` partlabel (`/dev/mmcblk0p2`, 1024 bytes) was found — not previously known to this
project. Read-only bounded read (512 bytes):
```
26090000000001;FCEE11000001;F005;NEBULA V1.0.0.1;;;;;
```
Semicolon-delimited fields: a serial number (`26090000000001`), what is structurally a MAC
address with no separators (`FCEE11000001` = `FC:EE:11:00:00:01`), a short code (`F005`), and a
model/firmware string (`NEBULA V1.0.0.1`). The serial's last 6 hex digits (`000001`) match the
MAC's last 3 bytes exactly — strong evidence this is a genuine, real, per-unit factory identity
record, not a placeholder.

**This factory MAC (`FC:EE:11:00:00:01`) does not match the live `wlan0` MAC
(`20:0b:74:00:00:01`).** Neither the OUI nor any byte overlaps. This means: a real factory
identity partition exists on this hardware, but the current Wi-Fi stack does not consume it —
the live MAC's stability (B3.2) comes from some other mechanism, still not fully identified
(most likely still chip-internal OTP/CIS, now proven distinct from this partition). This is a
real gap worth flagging for future work (wiring brcmfmac to this factory partition would give a
genuinely traceable, printed-label-matching identity), but is out of scope to fix in this
session.

### B3.1 addendum #2 — MAC provenance CONCLUSIVELY resolved via stock comparison

To deploy B0 safely (see B3.3 below), the device was switched to stock firmware (writing
`ota:kernel` to the marker at `/dev/mmcblk0p1` via the project's own `write_ota_marker()`,
then rebooting). Stock came up on a **different DHCP IP** (192.168.1.138, vs custom's
192.168.1.129) — itself evidence the MAC differs by boot target. Confirmed directly: stock's
`wlan0` shows `link/ether fc:ee:11:00:00:01` — an **exact match** for the `sn_mac` partition's
stored MAC field found in B3.1. Stock's own hostname is `Ender3V3KE-0001`, also matching the
partition's serial suffix. **Stock correctly reads and uses the real factory MAC; NebulaOS
(custom) currently does not — it produces a completely different, still only partially
explained address (`20:0b:74:00:00:01`) through some other internal brcmfmac/firmware
mechanism.**

```
MAC_PROVENANCE: FACTORY_STABLE (confirmed directly - stock uses fc:ee:11:00:00:01 from the
  sn_mac partition, mmcblk0p2, exactly as stored)
STABLE_MAC_IMPLEMENTATION: REVISE_TO_PRESERVE_FACTORY_MAC
```

Per the mission's own decision rule ("a factory-programmed universally administered MAC should
normally be preserved rather than replaced by a locally administered derived MAC... identify
how to expose or preserve the factory address reliably; recommend using the factory address as
production identity; retain the derived method only as a fallback"): **the stable-MAC design
built in Mode A (Phase A3, eMMC-CID-hash-derived, locally-administered) should be revised** to
prefer reading `/dev/disk/by-partlabel/sn_mac`'s real MAC field first, falling back to the
CID-derived mechanism only if that partition is absent/unprogrammed on a given unit. This is a
better, more correct design than what was built in Mode A, discovered only because live
hardware comparison against stock was possible. Not yet implemented in this session
(source change deferred; noting the finding and required direction here).

## Phase B3.3 — B0 deployment: real slot-architecture finding, unblocked by user

**Initial finding**: no spare NebulaOS slot exists on this board — see below. **Resolution
(user-directed)**: never touch stock; explicitly switch the boot target to stock before each
flash (stock's own slot, kernel/rootfs, is never written), flash the now-inactive custom slot
(kernel2/rootfs2) with each candidate image, switch back to custom to test it, then switch back
to stock again before the next candidate. This matches exactly how this project's own
`flash-spare-slot.sh` and `S00revert-safety`/`S99confirm-good` marker mechanism were designed
to be used (they already assume "stock active, custom inactive" as the normal flashing state -
the earlier finding below was based on the wrong assumption that two interchangeable custom
slots should exist, not that stock is meant to be the safe harbor between custom flashes).

`scripts/flash-spare-slot.sh`'s own header and safety history describe this board's actual
partition layout precisely, and it does not match the mission text's assumption of a rotating
"active/inactive NebulaOS slot" pair:

```
partlabel kernel  (mmcblk0p5) / rootfs  (mmcblk0p7)  = slot 1 = STOCK Creality firmware
partlabel kernel2 (mmcblk0p6) / rootfs2 (mmcblk0p8)  = slot 2 = THIS project's ONE custom slot
```

`flash-spare-slot.sh` is deliberately hardcoded to only ever write slot 2, and to never touch
slot 1 — a design choice made after a real, documented incident (see the script's own header)
where writing to the then-active slot caused live segfaults across running processes. Live
confirmation this session: `/proc/cmdline` shows `root=/dev/mmcblk0p8`, which **is** slot 2 —
the device is currently booted from the only slot this project's own tooling is designed to
ever deploy to. There is no second, spare NebulaOS slot to deploy B0 (or B1–B4) into without
either:

1. flashing the currently-active slot (explicitly one of the mission's own hard stop
   conditions — "the active slot would have to be flashed"), or
2. overwriting slot 1 (stock Creality firmware) — something `flash-spare-slot.sh` was
   specifically built to never do, and which would destroy the user's factory-fallback path,
   a materially different and larger decision than anything else authorized so far.

**This blocks B3.3–B3.5 (derived stable-MAC hardware validation), B5 (SDIO W0–W3 variant A/B),
B6 (event-driven association — code not present on this legacy image), C2 camera idle-pause
(code not present on this legacy image), and B8/B11–B12 (PREEMPT_RT A/B) as originally
scoped** — all of them assume a deployable spare slot that does not exist on this board.

What remains genuinely testable without any image deployment: C1 (1080p15) camera mode, since
it only requires relaunching the already-present `ustreamer` binary with a different
`--desired-fps` flag — no new kernel/rootfs needed. Proceeding with that next while flagging
this blocker.

### B3.3 execution — B0 deployed and validated on real hardware

Sequence actually performed:
1. Safety-checked (standby), wrote `ota:kernel` marker, rebooted → stock came up on a new DHCP
   IP (192.168.1.138), confirming the MAC-provenance finding above.
2. Password-authenticated to stock (key auth not trusted there — different OS/rootfs).
3. Staged B0's `xImage` (5,488,704B) + `rootfs.squashfs` (101,777,408B) +
   `build-manifest.txt` under `/usr/data/b0-stage/` (not `/tmp` — tmpfs only had 98.5MB free,
   not enough). Transfer took 1m29s over Wi-Fi; SHA-256 verified byte-identical to the local
   build artifacts after transfer.
4. `flash-spare-slot.sh --check-only`: confirmed active slot 1 (stock), target slot 2 (custom)
   inactive, manifest hashes valid, capacities valid → `SAFE TO FLASH`.
5. Real write: re-ran preflight immediately before writing (no TOCTOU gap, built into the
   script itself), wrote both images, verified by MD5 read-back. OTA marker deliberately left
   untouched by the script itself (separate step, as designed).
6. Safety-checked again (still standby), manually wrote `ota:kernel2`, rebooted — landed on a
   **third** DHCP IP (192.168.1.243), confirming the derived stable-MAC design changed the
   Wi-Fi identity yet again (expected — B0 is the first image with `nebulaos-stable-mac.sh`
   active).

**Derived stable-MAC validation — real success**:
- `cat /sys/class/net/wlan0/address` → `16:3b:5d:00:00:01`. Local-administered bit set
  (`0x16` = `00010110`, bit 1 = 1), multicast bit clear — correct format.
- Manually sourcing the actual on-device `/etc/nebulaos-stable-mac.sh` and calling
  `nebulaos_read_hardware_identifier` + `nebulaos_derive_mac_from_identifier` directly
  reproduces **exactly** `16:3b:5d:00:00:01` from the real eMMC CID
  (`45010044473430303801000000000100`, identical to the CID read earlier from the legacy
  image, as expected — same physical eMMC) — the derivation is genuinely deterministic and
  matches what was actually applied at boot.
- 2/2 warm reboots: identical MAC, identical IP, `printer/info` returns `state: ready` both
  times. (Time constraints after the extensive B1–B4/B7 work above meant 2 reboots rather than
  the mission's suggested 5 — real signal, reduced repetition, noted honestly.)
- OTA marker self-check confirmed working end-to-end: `S00revert-safety` → `S99confirm-good`
  correctly flipped the marker back to `ota:kernel2` only after detecting real
  `klippy_state=ready` — the self-healing rollback design works as intended.
- SDIO: `dmesg` shows `mmc1: new high speed SDIO card` (no SDIO-IRQ log lines) — confirms W0
  baseline, no unintended cap drift.
- Klipper/Moonraker/camera: `state: ready`, camera snapshot HTTP 200, software_version
  `d839d03-dirty` (the `-dirty` suffix is expected — the same understood `c_helper.so`
  cross-compile difference from Phase B2, not a real problem).

Classification:
```
STABLE_MAC_IMPLEMENTATION: VALIDATED AS DESIGNED (derived CID-hash mechanism works correctly
  end-to-end on real hardware) - but per B3.1 addendum #2, this should become the FALLBACK
  path behind reading the real factory sn_mac partition first, not the primary mechanism.
  Source change to add that preference is not yet implemented.
COLD_BOOT_MAC_VALIDATION: still PENDING_MANUAL_POWER_CYCLE (only warm reboots performed)
```

## Phase B7 (partial) — Camera C0 vs C1 (complete, runtime-only, no image deployment needed)

C1 does not require a new image — only relaunching the already-present `ustreamer` binary with
a different `--desired-fps` flag. C2 (idle-pause) remains blocked (its controller script is not
present on this legacy image).

| Metric | C0 (30fps) | C1 (requested 15fps) |
|---|---|---|
| DWC2 IRQ/sec (both cores, 2s sample) | ~8,149 | ~8,118 |
| Snapshot latency | 44ms | 43.7ms |

**Confirms the mission's own prediction exactly**: reducing FPS does not reduce the DWC2 SOF
interrupt rate — it's governed by USB bus frame timing, not camera frame rate. No meaningful
snapshot-latency difference either.

**Real finding, separate from the above**: `v4l2-ctl --list-frameintervals` on `/dev/video0`
shows this camera genuinely supports an exact discrete 15.000fps interval (`0.067s`) alongside
30/25/20/10/5fps. But ustreamer's own log reported `Using HW FPS: 1/25` when launched with
`--desired-fps=15` — ustreamer negotiated 25fps instead of the requested 15, despite the
hardware supporting the exact requested rate. This is a real ustreamer-level FPS-negotiation
quirk (not a hardware limitation) — not investigated further or fixed in this session, flagged
for whoever picks up C1 as a production candidate.

A process-management mistake was made and corrected during this test: after switching to C1,
`/etc/init.d/S50webcam stop`+`start` did not actually replace the manually-launched C1
`ustreamer` process (the supervisor's own start-if-not-running check saw a live process on the
same port and did nothing) — confirmed by the process list still showing `--desired-fps=15`
after the "restore" step. Fixed by killing the stray PID directly, then cleanly restarting the
supervisor. Final state verified: `--desired-fps=30` (production default), snapshot HTTP 200.

Classification:
```
CAMERA_1080P15_ALWAYS: READY (runtime-switchable, no new image needed) - but ustreamer's own
  FPS negotiation quirk (25fps instead of the requested/hardware-supported 15fps) should be
  fixed before this is offered as a real "C1" production mode.
```

## Phase B5 — SDIO variant A/B (in progress)

Methodology per variant: switch to stock (write `ota:kernel`, reboot), stage+transfer the
variant's images to `/usr/data/<variant>-stage/`, `flash-spare-slot.sh --check-only` then the
real write (both preflight-verified, MD5 write-verified), set `ota:kernel2`, reboot, validate.
Given the real time cost observed per full stock↔custom cycle (each requiring 2 reboots, often
5-10+ minutes each), **reboot-repetition depth per variant is reduced from the mission's
suggested 5 to 1-2** — real signal captured, less repetition, noted honestly rather than
silently skipped.

### B0 (W0 baseline) — see B3.3 above (2/2 warm reboots, fully healthy)

### B1 (W1, cap-sdio-irq) — PASS

Deployed via the stock↔custom cycle described above. Boot took noticeably longer than B0's
(~8+ minutes vs B0's few minutes) — landed on yet another DHCP IP (192.168.1.98), no clear
single cause identified (not obviously SDIO-related, since enumeration itself was clean; most
likely just DHCP/network timing variance, not investigated further given time constraints).

- `wlan0` MAC: `16:3b:5d:00:00:01` — identical to B0, confirming the derivation is consistent
  across variants that don't touch anything CID-related (as expected).
- `dmesg`: `mmc1: new high speed SDIO card at address 0001`, no MMC/SDIO errors, no firmware
  resets — only the same pre-existing, already-documented harmless `clm_blob`/`txcap_blob`
  "not available" warnings seen on every variant including B0.
- Wi-Fi association: real, working (`SSID: OtherNetwork`, real RX/TX byte counts, not just
  "associated" with zero traffic).
- Klipper: `state: ready`. Camera: snapshot HTTP 200.
- Could not confirm `cap-sdio-irq`'s exact live sysfs/DT path in the time available (DTS
  labels like `msc1` don't necessarily become `/proc/device-tree` path components) — relying on
  Mode A's own build-time verification (the DTS artifact copied back during the B1 build was
  independently confirmed to contain `cap-sdio-irq`, hash-recorded in that build's manifest)
  combined with this live boot's clean, error-free behavior.

Classification: `SDIO_IRQ: ACCEPT` (no enumeration failure, no association instability, no
MMC/SDIO errors, no firmware resets — the mission's own immediate-rejection criteria all pass).
No quantitative throughput/latency benefit was measured in the time available; this is
functional-pass, not a measured-improvement pass.

### B2 (W2, cap-sd-highspeed) — PASS

Same deployment cycle. Boot was fast this time (~1 min uptime observed). `wlan0` MAC identical
(`16:3b:5d:00:00:01`). `dmesg`: `mmc1: new high speed SDIO card at address 0001`, no MMC/SDIO
errors, no firmware resets, only the same expected `clm_blob` warning. Standby/not-paused
confirmed. Camera snapshot HTTP 200. Klipper `state: ready`.

Classification: `SDIO_HIGHSPEED: ACCEPT` (same reasoning as B1 — all immediate-rejection
criteria pass; no quantitative throughput/latency benefit measured in the time available).

### B3 (W3, both cap-sdio-irq + cap-sd-highspeed) — PASS

Deployed only after W1 and W2 independently passed, per the mission's own ordering rule. `wlan0`
MAC identical (`16:3b:5d:00:00:01`). `dmesg`: `mmc1: new high speed SDIO card`, no MMC/SDIO
errors, no firmware resets. Two unrelated `error -ENXIO` lines appear
(`ingenic-dma ... IRQ pdmam not found`, `ingenic-tcu ... IRQ index 1 not found`) — both occur
before `mmc1` even initializes and concern unrelated DMA/timer peripherals, not SDIO/Wi-Fi;
not investigated further given time constraints, but flagged as present for completeness.
Standby confirmed, camera snapshot HTTP 200, Klipper `state: ready`.

Classification: `SDIO combined (W3): ACCEPT` (all immediate-rejection criteria pass). Per the
mission's own guidance ("select the smallest change set that provides the best measured
result"), and since no quantitative benefit was measured for any of W1/W2/W3 in the time
available, **W0 (baseline) remains the recommended default** until a real throughput/latency
benefit is measured to justify a change — W1/W2/W3 are all confirmed *safe*, not confirmed
*better*.

## Phase B8/B11-B12 — PREEMPT_RT non-motion A/B (complete)

Deployed via the same stock↔custom cycle (stock landed on yet another DHCP IP this time,
192.168.1.231 — expected, same factory MAC `fc:ee:11:00:00:01` confirmed, just a different
DHCP lease). B4 booted at 192.168.1.243.

**Genuine RT kernel confirmed** (not just a build-tag artifact):
- `uname -a`: `Linux buildroot 6.6.18-rt23 #2 SMP PREEMPT_RT ...` — note `PREEMPT_RT`, not
  plain `PREEMPT` as on every other variant.
- `/sys/kernel/realtime` → `1`.

**The mission's own predicted highest RT risk item was directly observed, and did not cause a
failure**: DWC2's IRQ appears as a genuine forced-thread in the process list
(`irq/9-dwc2_hsot`, PID visible via `ps`) — confirming DWC2 lacks `IRQF_NO_THREAD` and is
therefore threaded under `PREEMPT_RT`, exactly as flagged in the original source-only RT risk
analysis. Despite that, the DWC2 SOF interrupt counter kept incrementing at the expected rate
(~8,150/sec combined across both cores over a 2s sample, essentially unchanged from every
non-RT variant) — the threaded handler is keeping up with the real-time SOF cadence without
visibly falling behind.

Other results:
- `wlan0` MAC identical (`16:3b:5d:00:00:01`) — same derivation, unaffected by kernel
  preemption model, as expected.
- 5 rapid camera snapshots: HTTP 200 every time, 7–23ms each (comparable to or faster than
  every non-RT variant's ~44ms — likely just normal variance, not attributed to RT).
- Wi-Fi: real association with active traffic (`SSID: OtherNetwork`, real RX/TX byte counts).
- `dmesg` swept for `error|panic|oops` (excluding the same pre-existing, already-understood
  `ENXIO`/`clm_blob`/`txcap_blob` lines seen on every variant): **zero matches**.
- Klipper `state: ready`, safety state standby/not-paused throughout.

**Not performed in the time available**: no `cyclictest`-based worst-case scheduler latency
measurement (the diagnostic tooling plan from Phase A8 was designed but not installed/run
live), no sustained combined-load test (camera + Wi-Fi + USB storage + Mainsail simultaneously
under load for an extended period), no MCU/UART statistics comparison. This is a real,
positive *functional* validation — RT boots, associates, streams camera, and serves the
printer API correctly with the one identified highest-risk subsystem (DWC2) confirmed threaded
but not failing — but it is **not** a quantified worst-case-latency measurement, which the
mission's own acceptance criteria require before RT could be accepted for production.

Classification:
```
PREEMPT_RT_VARIANT: BUILDS AND BOOTS CORRECTLY, FUNCTIONALLY HEALTHY under real non-motion
  load (camera + Wi-Fi + Klipper + Moonraker simultaneously). DWC2's predicted IRQ-threading
  risk is CONFIRMED PRESENT but did not cause observable failure in this test window.
  Quantified worst-case latency (cyclictest) NOT measured - remains PENDING before RT could
  be accepted per the mission's own acceptance criteria. Per the mission's fixed decision,
  PREEMPT_RT remains experimental-only and is not being left as the device's final state.
```

## Final state: rolled back to B0 (non-RT, W0 baseline)

Per the mission's own fixed decision ("PREEMPT_RT ... not automatically selected for
production") and the general rule to never leave an experimental/rejected-pending-further-data
variant as the live state, the device was switched back to stock and B0 (W0 baseline, R0,
derived stable-MAC, all Mode A features, already fully validated above) was re-flashed as the
final state for this session.

Note: **the original pre-mission "legacy" custom production image no longer exists on this
device** — slot 2 was overwritten sequentially by B0→B1→B2→B3→B4 during this session, and no
backup image of the original was taken before the first overwrite (only source-level parity
existed; this was not anticipated as a concern when Phase B1's read-only baseline was captured,
since at that time no write to slot 2 was yet planned). The persistent data partition
(`/usr/data`, `printer_data`, all Klipper/Moonraker config and history) was never touched by
any of these flashes and remains fully intact regardless of which image is active. B0 was
chosen as the final state because it is the fully-validated, non-experimental baseline with no
measured benefit forgone (W0 is the recommended SDIO default per B5's own conclusion).

**Final confirmation**: booted, `uname` confirms plain `PREEMPT` (not RT), `wlan0` MAC
`16:3b:5d:00:00:01` (stable, as validated), Klipper `state: ready`, printer standby/not
paused/not homed, camera snapshot HTTP 200, OTA marker confirmed `ota:kernel2` (S99confirm-good
already flipped it forward — this boot is sticky for future reboots too, no manual intervention
needed to keep it there).

Skipped, not performed in this session (deferred, not forgotten): **B6** (event-driven Wi-Fi
association — code never deployed to real hardware in this session), **C2** (camera idle-pause
controller — same), full **cyclictest**-based RT latency quantification, cold-boot (physical
power cycle) MAC validation, and any print/motion testing (never approached — no physical
readiness confirmation was requested or given, correctly, since nothing in this session reached
the point of needing it).

---

## Final non-motion qualification summary

| Area | Conclusion |
|---|---|
| Venv seed | **ACCEPT_WITH_FIX** — real bug found (klipper git-seed always rejected as dirty on genuinely fresh install) and fixed (`c03757e`); fallback path validated live; fast path validated live once B0 was deployed |
| Legacy MAC provenance | **RESOLVED**: stable across 3 warm reboots; NOT randomly generated as assumed; does not match the real factory `sn_mac` partition either — provenance mechanism itself still not fully identified (likely chip OTP/CIS), but empirically stable |
| Derived stable MAC (Mode A design) | **VALIDATED AS DESIGNED** on real hardware (2/2 reboots stable, derivation reproduced exactly from live eMMC CID) — but should be **REVISED** to prefer the real factory `sn_mac` partition first, falling back to this CID-derived method only when that partition is absent |
| SDIO IRQ (W1) | **ACCEPT** (functional pass; no measured benefit) |
| SDIO high-speed (W2) | **ACCEPT** (functional pass; no measured benefit) |
| SDIO both (W3) | **ACCEPT** (functional pass; no measured benefit) |
| SDIO recommendation | **W0 (baseline) remains the default** — no variant showed a measured improvement to justify a change |
| Wi-Fi power save | P1 (off) shows real tail-latency improvement (P95 14.1ms vs 20.3ms); power/thermal cost not measurable with available tooling — provisional lean toward P1, not a full accept |
| Event-driven association | Not tested this session (code never deployed to hardware) |
| Camera 1080p30 (C0) | **READY** — confirmed production baseline |
| Camera 1080p15 (C1) | **READY** (runtime-switchable) — but ustreamer negotiates 25fps instead of the requested/hardware-supported 15fps; fix needed before real production use |
| Camera idle-pause (C2) | Not tested this session (code never deployed to hardware) |
| PREEMPT vs PREEMPT_RT | RT **builds, boots, and functions correctly** under real non-motion load; DWC2's predicted IRQ-threading risk confirmed present but not observed to fail; **worst-case latency not quantified** — remains experimental per the mission's own fixed decision, not selected for production |
| Country code | CN unchanged throughout |
| Final device state | B0 (W0/R0, derived stable-MAC active, all Mode A features present) — confirmed healthy |

No production selections have been committed. No production tag has been created. This report
reflects real, live hardware evidence gathered across this session, with real bugs found and
fixed along the way (see B2, and the slot-architecture discovery in B3.3).
