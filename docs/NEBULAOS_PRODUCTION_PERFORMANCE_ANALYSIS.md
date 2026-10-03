# NebulaOS Production Boot, Memory, and CPU Optimization Audit

2026-07-30. Measurement-first, analysis-only audit. **No source modified, no
build performed, no image flashed, no service disabled, no printer motion,
heating, extrusion, probing, or print started.** Everything below is either
a direct live measurement against the running device (192.168.0.128, custom
slot), a direct read of the tracked repo source, or a direct read of the
real, already-built `rootfs.squashfs` artifact already present in this
checkout (`vendor/buildroot-x2000/output/images/rootfs.squashfs`) — no new
build was triggered to produce it.

## 0. Executive summary

NebulaOS's userspace boot design is already unusually disciplined for a
project this size: expensive first-boot work (git-history seeding, venv
creation) is correctly marker/existence-gated to a one-time cost, the two
genuinely large foreground boot-blocking waits (`S95mcu-boot-recovery`,
`S99confirm-good`) are legitimate bounded health polls against real service
state rather than guessed sleeps, and locale/CA-cert/module hygiene is
already close to optimal. The real opportunities found are concentrated in
three areas that had never been measured before:

1. **A documentation-vs-configuration gap on PREEMPT_RT.** `FIRMWARE.md`
   states this is a PREEMPT_RT kernel "a welcome side effect of using this
   SDK's own default config." The actual running kernel's `/proc/config.gz`
   shows `CONFIG_PREEMPT_RT` is explicitly **not set** — the device runs
   plain `CONFIG_PREEMPT` (voluntary/full preemption). The `-rt23` kernel
   version suffix reflects the source tree's own RT-patched lineage, not the
   active build configuration. This is not something this audit recommends
   "fixing" (that's a rebuild + full print/MCU-stability requalification,
   explicitly out of scope for measurement-only analysis) — but the belief
   should be corrected in the record before anyone makes a future decision
   assuming real RT guarantees exist today.
2. **A large, well-evidenced kernel-option removal list.** The ALSA/ASoC
   sound subsystem, the internal ISP camera pipeline, the Bluetooth HCI
   transport, the on-chip Ethernet MAC, the entire netfilter/iptables/bridge
   stack, the SFC flash controller, and the SADC/ADC MFD cells are all
   **PROVEN_UNUSED** with hard, independent evidence (disabled device-tree
   nodes, empty `/proc/mtd`, no userspace tool present, physically absent
   connectors) — none of these were removed or even flagged before this
   audit.
3. **A real, previously unmeasured CPU/wakeup cost**: the USB OTG host
   controller generates roughly **8,000 interrupts/second continuously**,
   even completely idle with nothing plugged in — closely matching USB 2.0
   high-speed micro-frame Start-of-Frame timing. This has never been
   quantified before and is a legitimate, evidence-based candidate for
   further investigation (with appropriate hardware-hotplug-latency
   qualification before any change).

No feature is proposed for removal that is still in active use. Every
PROVEN_UNUSED classification below is backed by independent, cross-checked
evidence (device-tree `status = "disabled"`, empty runtime state, and/or
absence of any userspace consumer) — not absence-during-one-snapshot.

---

## 1. Exact measured baseline

| Item | Value | Evidence |
|---|---|---|
| Repo branch | `implementation/moonraker-camera-defaults` | `git branch --show-current` |
| Repo commit | `614faac15671f958d6f2e2a529e416c251bd556c` | `git rev-parse HEAD` |
| Working tree | **Dirty** — uncommitted SimpleAF backend integration (prior mission): `00-fetch-vendor-sources.sh`, `04-cross-compile-app-stack.sh`, `06-verify.sh`, `validate-frontend-controls.sh`, `printer.cfg`, `moonraker.conf`, `frontend-controls.cfg`, new `simpleaf/` dir | `git status --short` |
| Latest tag reachable from HEAD | `nebulaos-mainsail-macro-warnings-resolved-2026-07-29` | `git describe --tags` |
| **Reconciliation note** | The uncommitted changes touch only build-time scripts and `printer_data/config` (Klipper-level config) — **none** touch `/etc/init.d`, the kernel `.config`, or the Buildroot config. The device's boot/init/kernel behavior measured below is therefore unaffected by that pending, uncommitted work, and represents the last-built, last-flashed image faithfully for the purposes of this specific audit (boot time, CPU, memory). This should **not** be read as "the tree matches the running image" in general — it does not, for the Klipper-config layer — only that the specific subsystems this audit measures are unaffected. | Cross-checked: init.d directory listing on-device matches `scripts/build/overlay/etc/init.d/` 1:1 by name |
| No embedded build-provenance manifest on-device | Only `/opt/nebulaos-seeds/{seed-manifest.json, printer-data-config-manifest.json}` exist; no manifest records the exact git commit/tag the running rootfs/kernel were built from | Live `find` for `*manifest*` |
| Kernel version | `6.6.18-rt23` (uname) | `uname -a` |
| Kernel build date | Wed Jul 29 14:50:54 UTC 2026 | `uname -a` |
| Kernel cmdline | `console=ttyS4,115200n8 mem=256M@0x0 mem=0M@0x30000000 lcm_id=0 init=/linuxrc root=/dev/mmcblk0p8 rootwait rootfstype=squashfs ro ieee754=relaxed` | `/proc/cmdline` |
| Active rootfs slot | `/dev/mmcblk0p8` (512000-block / 250MiB partition; actual squashfs content 99.89 MiB) | `/proc/cmdline`, `/proc/partitions` |
| Uptime at measurement | 4374.73s (~73 min) | `/proc/uptime` |
| CPU | 2 cores, MIPS (XBurst2/Ingenic X2000), BogoMIPS 2393.70/core | `/proc/cpuinfo` |
| CPU governor / DVFS | **None compiled in at all** — no `/sys/devices/system/cpu/cpu*/cpufreq/` exists; confirmed via kernel config that `CONFIG_CPU_FREQ` is not set, despite the device-tree defining a real 8-point OPP table (200MHz-1.2GHz) that can never bind to any driver | Live `/sys` absence + kernel-config-agent finding |
| Total RAM | 212,776 kB (~208 MiB) | `/proc/meminfo` |
| Swap | Two-tier: zram0 (128 MiB, priority 100, `lz4` active at runtime — measured `lzo lzo-rle [lz4]` on ke-dev 2026-10-03, HWDP-MEM-2; an earlier `lzo-rle` reading here was a documentation error) + disk swapfile (128 MiB, priority 10, fallback) at `/usr/data/nebulaos/system/swapfile`; 0 kB in use at measurement time | `/proc/swaps`, `/sys/block/zram0/*` |
| Rootfs squashfs | 99.89 MiB, **gzip**, 128 KiB block size, 808 fragments, duplicates removed, xattrs/inodes/ids all compressed | `unsquashfs -s` on the real built `rootfs.squashfs` in this checkout |
| Kernel image | `xImage`, 6.64 MB, **uncompressed** u-boot legacy uImage | `file` on the real built `xImage` |
| Partition capacity margin | Both rootfs A/B slots are 250 MiB each; only 99.89 MiB is used — **~150 MiB headroom** per slot before any repartition would be needed | `/proc/partitions` |
| Persistent data partition | `/dev/mmcblk0p10`, 5.9 GiB total, 4.2 GiB used (76%), 1.4 GiB free | `df -h` |
| Init scripts (real boot order, 28 total) | 18 NebulaOS-authored (`scripts/build/overlay/etc/init.d/`) + 10 stock Buildroot/BusyBox (`S01seedrng`, `S01syslogd`, `S02klogd`, `S02sysctl`, `S10udev`, `S30dbus`, `S40network`, `S44modem-manager`, `S50dropbear`, `S50nginx`) | Live `ls /etc/init.d`, cross-checked against both source trees |
| Loaded kernel modules | **Zero** at snapshot time (`lsmod` empty) — module support (`CONFIG_MODULES=y`) is real, used for hotplug-loaded USB-Ethernet dongle support (`ax88179_178a`), just idle when nothing's plugged in | Live `lsmod` + kernel-config-agent cross-check |
| Listening sockets | `:80` (nginx), `:22` (dropbear), `:7125` (Moonraker), `127.0.0.1:8080` (ustreamer, proxied by nginx at `/webcam/`) | Live `ss -tlnp` |
| Running services (non-kernel-thread) | klippy, moonraker, guppyscreen, ustreamer, nginx (1 master + 1 worker), dropbear, dbus-daemon, **ModemManager**, wpa_supplicant, udhcpc, syslogd, klogd, udevd, `S50webcam` supervisor loop, `nebulaos-update-supervisor` loop | Live `ps -ef` |

---

## 2. Stock-versus-NebulaOS boot comparison

**Not performed this pass.** Per explicit user decision this session, the
stock-slot comparison (which requires switching the device to the stock A/B
slot, measuring, then switching back) is deferred to a later session when
the user can be directly involved, alongside cold-boot timing. See §20
(unresolved blockers) for the exact follow-up needed.

---

## 3. Bootloader / kernel / userspace timeline

| Interval | Status | Evidence |
|---|---|---|
| Power applied → U-Boot starts | **Unmeasured** — requires a UART/serial console connection this analysis host does not have. Per the mission's own instruction, honestly reported as unmeasured rather than estimated. | N/A |
| U-Boot → kernel entry | **Unmeasured** — same UART dependency | N/A |
| Kernel entry → init starts | **Not separable from userspace timing without a UART/`printk.time=1` capture** — no existing timestamped kernel boot log was available to inspect this pass | See §8 (diagnostic instrumentation plan) |
| init starts → Klipper ready / MCU connected | **Measured via warm reboot** (see §3a below) | Host-side readiness polling |
| init starts → GuppyScreen visible | Not independently measurable without either a display-facing sensor or an on-device timestamp GuppyScreen itself emits at first-frame-rendered — **not measured this pass**, flagged as needing instrumentation | See §8 |
| init starts → web ready (nginx+Moonraker+Mainsail) | **Measured via warm reboot** (see §3a) | Host-side readiness polling |
| init starts → camera ready | **Measured via warm reboot** (see §3a, snapshot-response proxy) | Host-side readiness polling |

### 3a. Warm reboot timing (attempted this session — real methodological finding, not the clean 5-sample set originally planned)

Method attempted: read-only safety check → `reboot` issued via SSH
(separate invocation) → host-side Python poller records monotonic-clock
deltas from the moment `reboot` was issued, confirming the device went
offline, then polling SSH-port-open, nginx HTTP 200, Moonraker
`/server/info` HTTP 200, Klipper `printer/info` reporting `state: "ready"`,
and a `/webcam/snapshot` fetch.

**Result: both reboot attempts this session succeeded** (confirmed
after-the-fact via matching kernel build signature, `/proc/uptime`, and a
healthy `klippy_state: "ready"`/`klippy_connected: true` from Moonraker) —
but **precise sub-second milestone timestamps were not reliably captured**,
for reasons that are themselves a real, reportable finding:

1. **The device's DHCP lease changes across reboots** (confirmed: it was
   at `192.168.0.128` before this session's reboots, came back at
   `192.168.0.129` after reboot #1, per this project's own prior
   documented behavior — the IP is not fixed/reserved). A host-side poller
   watching a single fixed IP therefore measures nothing useful once the
   device changes address mid-poll.
2. **Correcting for that with a live network rescan introduced a real
   false-positive risk**: during reboot #2's measurement, the rescan logic
   (looking for *any* newly-appeared host with port 22 open) locked onto
   `192.168.0.20` — an unrelated, already-online device on the same LAN
   (confirmed afterward: sub-millisecond ping latency, inconsistent with
   the WiFi-connected printer's typical 30-2000ms+ latency; and it did not
   speak dropbear's SSH banner when checked directly). This produced a
   false `ssh_open` timestamp and correctly caused every subsequent
   milestone check to fail silently (right host was never actually
   reached), rather than corrupting the result with a wrong-but-plausible
   number.
3. The device's dropbear host key regenerates on every reboot (already
   known, documented behavior — no persistent key storage on the
   read-only squashfs `/etc`), which is expected and was handled correctly
   each time, but adds real wall-clock overhead to each reconnection
   attempt in an interactive-approval workflow.

**Conclusion for this section, stated honestly**: this session
demonstrates NebulaOS's warm-reboot process itself is reliable (2/2
attempts fully recovered to a healthy `klippy_state: ready`), but does
**not** produce a trustworthy set of milestone-level timing numbers, and
does not meet the mission's own requested 5-sample minimum. The specific
failure mode found — DHCP churn plus false-positive host discovery — is
itself directly relevant evidence for the mission's own Phase 3 question
("determine how timestamps can be captured"): **external host-side network
polling is not a reliable timestamp source for this specific device without
either a DHCP reservation for its MAC address, or (per the mission's own
stated preference) a UART/serial console capture**, which would eliminate
both the address-churn and false-positive-host problems entirely by
measuring locally on the device's own boot console instead of guessing at
its network identity from outside.

**Recommendation for the follow-up session** (alongside the already-deferred
cold-boot/stock-comparison work): request a DHCP reservation for this
device's MAC address before attempting network-based boot timing again, or
capture via UART as the mission's own Phase 3 preferred-order already
recommends as the first choice.

---

## 4. Init-script critical path (from the tracked overlay source)

Full script-by-script table (purpose, dependencies, blocking/non-blocking,
fixed delays, critical-path membership, first-boot-vs-every-boot cost) is
in the companion research record — reproduced here in condensed form.

### 4.1 The real dependency chain to each milestone

- **MCU connected + Klipper ready**: `S00revert-safety → S01persistent-datastore → S02nebulaos-namespace → S03nebulaos-diskswap → S04nebulaos-factory-seed (expensive only on first boot / after a namespace wipe) → S05nebulaos-activate → S10udev → S55klipper → S56moonraker`, with `S95mcu-boot-recovery`/`S99confirm-good` as tail-end confirmation/recovery gates. Because standard sequential `/etc/init.d` execution blocks each script until it exits, **every one of S01-S05 sits in front of Klipper positionally**, even where the individual script's own function (e.g. S03's diskswap) isn't logically required by Klipper itself.
- **GuppyScreen visible**: `S00 → S01persistent-datastore (guppyconfig.json bind) → S58guppyscreen`. GuppyScreen itself tolerates Moonraker not yet being ready (degrades to a reconnecting-UI state), but is still delayed by everything positioned before it in the strictly sequential boot order — most significantly a first-boot `S04` seed.
- **Web readiness**: `S01-S05 (Mainsail activation decision) → S50nginx → S55klipper → S56moonraker (API)`. nginx itself only needs Mainsail's static files (decided by S05) to serve the page shell — it doesn't need Klipper/Moonraker to be *ready*, just present, but sequential ordering still delays it behind S00-S05/S10/S30/S40.
- **Camera readiness**: `S10udev (device nodes) → S50webcam`, independent of Klipper/Moonraker/GuppyScreen entirely; `S57nebulaos-camera-seed` (backgrounded, polls Moonraker) only handles the Moonraker-side *registration*, not the stream itself. **This is the most independent of the four milestones** — nothing downstream depends on it, and it depends on almost nothing upstream. The clearest candidate for reordering earlier / running in parallel without touching anything else.

### 4.2 Every fixed sleep / retry loop found (foreground, boot-blocking only)

| # | Location | Delay | Assessment |
|---|---|---|---|
| 1 | `S01wifi:88` | `sleep 2` before a redundant `ifup wlan0` | **Unknown — do not touch without more investigation.** Reasoning for *why* the script does this early/twice is documented; the specific 2s value is not independently justified. A plausible event-driven replacement exists (poll `wpa_cli status` for `wpa_state=COMPLETED`) but isn't proven safe to substitute blind. |
| 2 | `S95mcu-boot-recovery` | Up to 15×2s=30s bounded poll of `klippy_state` | **Keep.** Legitimate bounded poll of real async service state, not a guessed wait; only fires on the (rare) MCU-handshake-transient failure path. |
| 3 | `S95mcu-boot-recovery` | `sleep 10` settle after firing `FIRMWARE_RESTART` | **Keep, low-priority improvement candidate.** Reasoning is evident; could become a poll-until-ready instead of a blind wait, but only matters on an already-rare path. |
| 4 | `S99confirm-good` | Up to 30×5s=150s bounded poll of `klippy_state=="ready"` | **Keep — this *is* the OTA-safety mechanism, not a workaround.** Largest single possible contributor to worst-case perceived "boot done" time, but that ceiling only bites on a genuinely unhealthy boot; already event-driven in spirit (polls real state). |

Every other fixed delay found in the codebase (webcam hotplug poll, retention
NTP-settle wait, update-supervisor's various stability/grace-period sleeps)
runs **inside an already-backgrounded process**, not in the foreground boot
sequence, and is separately justified with real prior-incident history in
each case (see the full research record for all 13 delays found, with
line-level citations). **None of the 13 fixed delays found anywhere in this
codebase looks like an unexamined "just in case" sleep with no stated
reason** — this project's own prior incident history (documented directly
in the scripts' own comments) already drove most of these to their current,
deliberately-chosen values.

### 4.3 First-boot vs. every-boot cost

The two genuinely expensive operations (`S04nebulaos-factory-seed`'s git
history + venv seeding, `S02nebulaos-namespace`'s config seed) are **already
correctly marker/existence-gated** to run their expensive path only once,
short-circuiting to an instant no-op on every subsequent boot
(`S04nebulaos-factory-seed:340-345` — a single compound existence check).

Genuine venv-creation cost, confirmed by the script's own recorded
measurement: **~59 seconds of CPU time per venv** (Klipper + Moonraker,
~118s combined), first boot only. This is virtualenv-machinery overhead
(`--system-site-packages`, so no packages are actually installed — just the
venv shell itself), not package installation.

Work that *does* run identically every boot, checked for hidden expense:
`S05nebulaos-activate`'s full per-app validation (existence, symlink-escape
check, marker files, ownership) is O(1) `stat`-class checks, not a scan —
and re-running it every boot is the **intended** safety behavior (detecting
drift between boots), not incidental waste. `S03nebulaos-diskswap`'s
swapfile re-validation and the retention script's several `find`
invocations are similarly cheap (metadata-only, `-maxdepth 1`). **No script
anywhere in this codebase runs a recursive hash or full-tree scan on every
normal boot.**

---

## 5. Service dependency graph

See §4.1 for the milestone-oriented view. Full script→dependency directed
list is in the companion research record. Key structural finding: because
NebulaOS uses standard sequential BusyBox `/etc/init.d` (no parallel init
system), **every script is positionally serialized regardless of its true
logical dependencies** — the camera stack (S50webcam) and GuppyScreen
(S58guppyscreen) are the two clearest candidates for real, safe
parallelization, since neither has a genuine functional dependency on
Klipper/Moonraker being ready, only a positional one imposed by sequential
init.

**Safe parallelization candidates** (logically independent of the core
Klipper/Moonraker path):
- `S50webcam` (depends only on udev device nodes)
- `S58guppyscreen` (depends only on the printer_data bind mount; already
  tolerates Moonraker not being ready)
- `S44modem-manager`, `S50dropbear` (no dependency on anything printer-related)

**Genuinely safe-to-defer-past-core-readiness candidates:**
- `S40nebulaos-ntpsync` (already non-blocking/backgrounded)
- `S45nebulaos-cleanup` (already non-blocking/backgrounded)
- `S59nebulaos-update-supervisor` (already non-blocking/backgrounded; itself
  waits for S55/S56/S58 before doing anything meaningful)

**Not deferrable without further investigation:** `S01wifi` — moved
deliberately early (to S01) specifically because operators had no visibility
into GuppyScreen/SSH during a long first-boot S04 seed and hard-power-cycled
the device, per the script's own header. Any reordering here needs to
preserve that visibility property, not just optimize for milestone speed.

---

## 6. First-boot versus normal-boot cost

Covered in §4.3. Summary: the design is already correct in principle
(marker-gated expensive paths); the actual first-boot cost is the ~118s of
combined venv-creation CPU time plus git-history/tar extraction, all
one-time. No further first-boot-cost-hiding opportunity was found beyond
what's already implemented.

---

## 7. Kernel option classification

Full classification table (SoC platform, display/touch, MMC, USB, serial,
WiFi, filesystems, sound, camera/V4L2, I2C/SPI/GPIO/PWM, thermal, watchdog,
RTC, crypto, netfilter/bridge, debug/tracing, modules, firmware loading,
swap/zram, PREEMPT/scheduler, cpufreq/governors, I/O schedulers) is in the
companion research record, built directly from the **live device's own
`/proc/config.gz`** (not a possibly-stale local build tree), cross-checked
against the current board DTS and this project's own capability-matrix
docs.

### 7.1 PROVEN_UNUSED, with hard evidence (highest-confidence findings)

| Subsystem | Config symbols | Evidence |
|---|---|---|
| **ALSA/ASoC sound** (entire subsystem) | `SOUND`, `SND`, `SND_SOC`, `SND_ASOC_INGENIC` + ~20 sub-options | Every ASoC device-tree endpoint (`as_platform`, `as_virtual_fe`, `as_fmtcov`, `as_fe_dsp`, `as_be_baic`, `as_dmic`, `as_aux_mixer`, `as_spdif`, `icodec`, top-level `sound` node) is `status = "disabled"`; live `/proc/asound/cards` → "no soundcards found". Already independently identified by the project itself (`docs/BAIC4_AUDIO_INVESTIGATION.md`, `docs/BOARD_CAPABILITY_MATRIX.md`) — this audit corroborates, doesn't newly discover. Largest single dead subsystem found. |
| **Internal ISP camera pipeline** | `VIDEO_INGENIC_ISP`, `VIDEOBUF2_DMA_CONTIG_INGENIC` | No sensor driver compiled, no sensor DT node ever included (gated on unset macros), ISP's own scaler output stage (`mscaler0`/`mscaler1`) independently confirmed disabled with "zero userspace consumer" in the project's own docs. Real camera path (ustreamer → `/dev/video3`) is unrelated generic UVC, not this pipeline. |
| **Bluetooth HCI transport** | `BT_HCIUART=m`, `BT_HCIUART_BCM_H5=y`, `BT_BCM=m` | Only physical transport (`uart3`) is permanently `status="disabled"` in DT due to a real, documented, unfixable pin conflict with the touchscreen's i2c4 bus. Zero `uart3`/`GPC-25` activity in any boot log, ever. |
| **On-chip Ethernet MAC** | `INGENIC_MAC`, `INGENIC_MAC_DMA_INTERFACES` | `docs/BOARD_CAPABILITY_MATRIX.md`: "no RJ45 on this product" — the connector physically doesn't exist. `mac1` DT node disabled; its reset GPIO collides with the display's `lcd_rst` pin (already claimed). |
| **Netfilter/iptables/bridge stack** | `NETFILTER`, `NETFILTER_XTABLES`, `IP_NF_IPTABLES/FILTER/MANGLE/RAW`, `IP_SET*`, `BRIDGE`, `STP`, `LLC` | No userspace tool exists anywhere in the rootfs to configure any of it (`BR2_PACKAGE_IPTABLES`/`BRIDGE_UTILS` both unset in Buildroot config). Zero mentions anywhere in this project's own documentation. Pure unmodified SDK-defconfig carry-over, not a NebulaOS addition. |
| **SFC flash controller** | `INGENIC_SFC`, `MTD_INGENIC_SFC_V2` | `/proc/mtd` empty on both stock and custom; controller DT node disabled; this board boots/stores everything on eMMC (A/B OTA), not SPI-NOR/NAND. |
| **SADC/ADC MFD cells** | `MFD_INGENIC_SADC_V13`, `MFD_INGENIC_SADC_AUX` | `CONFIG_IIO` (the only kernel framework that could expose these to userspace) is **not compiled at all** — these MFD cells are structurally incapable of ever producing a usable device node in this build. No documented consumer. |

### 7.2 PREEMPT_RT documentation-vs-configuration gap (flagged prominently, not "fixed")

`FIRMWARE.md` states: *"kernel release string `6.6.18-rt23` (a **PREEMPT_RT**
real-time kernel variant — a genuinely good property for a 3D-printer
motion controller, not something specifically sought out but a welcome
side effect of using this SDK's own default config)."*

The **actual running kernel's own `/proc/config.gz`** shows:

```
CONFIG_PREEMPT_BUILD=y
# CONFIG_PREEMPT_NONE is not set
# CONFIG_PREEMPT_VOLUNTARY is not set
CONFIG_PREEMPT=y
# CONFIG_PREEMPT_RT is not set
CONFIG_PREEMPT_COUNT=y
CONFIG_PREEMPTION=y
```

**`CONFIG_PREEMPT_RT` is explicitly, unambiguously not set.** The device
runs plain `CONFIG_PREEMPT` (mainline full/voluntary low-latency
preemption) — not the PREEMPT_RT patch-set variant with threaded IRQs and
RT mutexes on all locks. The `-rt23` version suffix reflects the *source
tree's* RT-patched lineage, not the actual build configuration. NebulaOS's
own kernel-config fragment (`halley5-nebulaos-fragment.config`) never
touches `PREEMPT`/`CONFIG_HZ`/`CPU_FREQ` at all — every value in this area
comes untouched from the SDK's base defconfig. This is a documentation
error the project should correct, not a kernel behavior this audit
recommends changing.

**Why this likely doesn't matter functionally** (not asserted as fact,
offered as the most plausible explanation given this project's own
architecture docs and the extensive successful physical qualification
already completed on this exact kernel): Klipper's own design deliberately
keeps hard real-time step generation off the Linux host — the host streams
pre-computed step timing to the printer's own separate MCU over UART
(`uart1`), and that MCU, not this X2000 SoC, is what executes step pulses
with real timing guarantees. A non-RT `PREEMPT=y` host kernel is very
plausibly adequate for Klipper's actual host-side timing needs regardless
of this documentation error — homing, bed mesh, heating, and extrusion have
all already been qualified successfully on this exact kernel build this
project. But the documentation is still wrong and should be corrected so a
future decision doesn't get made on the false premise that real RT
guarantees already exist.

**CONFIG_HZ=100** (100Hz tick) and **CONFIG_NO_HZ_IDLE=y** are both
confirmed, also untouched by NebulaOS's own fragment.

### 7.3 A related, real, previously-unknown gap: no CPU frequency scaling driver at all

`CONFIG_CPU_FREQ` is **not set**. This is not a hardware limitation — the
board's own device tree defines a real `cpufreq` node with 8 measured
operating points (200MHz-1.2GHz), meaning someone already characterized
real voltage/frequency pairs for this chip, but the kernel driver that
would let that DT node bind to anything was simply never enabled. This
directly explains the live finding (confirmed independently, no
`/sys/devices/system/cpu/cpu*/cpufreq/` entries exist at all): the SoC most
likely runs pinned at a single fixed frequency for its entire uptime,
today, with no ability to enter a lower-power state when idle or a higher
one under print load. This is a real, fixable gap (`REQUIRES_HARDWARE_QUALIFICATION`
— enabling DVFS on a live motion-control system needs a real
power/thermal/latency validation pass before shipping), not something to
casually flip.

### 7.4 Debug/diagnostic overhead in the production kernel

**Genuinely removable, unintentional-looking carry-over:**
- `CONFIG_DEBUG_SPINLOCK=y` — inconsistent with the rest of the lock-debug
  family being off (`DEBUG_MUTEXES`, `DEBUG_LOCK_ALLOC`,
  `DEBUG_ATOMIC_SLEEP`, `DEBUG_RT_MUTEXES` all not set) — looks like an
  unintentional partial carry-over, not a deliberate choice.
- `CONFIG_FW_LOADER_DEBUG=y` — pure debug instrumentation, small but real.
- `CONFIG_DEBUG_FS_ALLOW_ALL=y` — more permissive than strictly needed on a
  single-purpose embedded device.

**Keep, real diagnostic/recovery value:**
- `CONFIG_IKCONFIG`/`IKCONFIG_PROC` — exposes `/proc/config.gz`; this is
  literally the mechanism that made this entire kernel audit possible.
- `CONFIG_MAGIC_SYSRQ` (serial) — legitimate last-resort recovery on a
  headless device.
- `CONFIG_KALLSYMS` — needed for any usable panic backtrace.
- `CONFIG_DEBUG_FS` — some real (non-debug) subsystems depend on it for
  state export.

**Already correctly off** (a positive finding, not a gap): `FTRACE`,
`KPROBES`, `KGDB`, `PERF_EVENTS`, `PROFILING`, `GCOV_KERNEL`,
`DEBUG_PAGEALLOC`, `DEBUG_OBJECTS`, `SCHEDSTATS`, and the kernel uses
`DEBUG_INFO_NONE` (no embedded debug symbols at all). The heavy
tracing/instrumentation categories are already clean.

---

## 8. Slow kernel initcalls / probes

**Not measured this pass** — no existing timestamped kernel boot log
(`dmesg` with `printk.time=1` or `initcall_debug`) was available to inspect,
and building/deploying a diagnostic kernel is explicitly out of scope for
this analysis-only mission.

### Minimal diagnostic instrumentation plan (design only, not built)

To capture this in a future pass:
1. Temporarily add `initcall_debug printk.time=1` to the kernel command
   line (a boot-argument change only — no kernel rebuild required for
   `printk.time=1`; `initcall_debug` also works as a pure cmdline flag,
   no config change needed).
2. Capture the full `dmesg` output over a UART/serial console (preferred,
   since it survives even if userspace never fully comes up) immediately
   after boot, before any log rotation/truncation.
3. Expected overhead: `printk.time=1` and `initcall_debug` both add modest
   console I/O during boot (more printk lines, each with timing) — expected
   to add low-single-digit-percent wall-clock boot time, not measured
   precisely since it wasn't deployed this pass.
4. Restore the production cmdline (remove both flags) after capture — this
   is a boot-argument-only change, trivially reversible, requires no image
   rebuild to undo.
5. This plan is **not implemented or deployed** in this mission.

---

## 9. PREEMPT_RT and scheduler assessment

Covered in full in §7.2-7.3. Summary classification:

| Option | Current state | Assessment |
|---|---|---|
| Keep `CONFIG_PREEMPT` (current) | Active, unmeasured downside found | No evidence of a problem; already successfully qualified through homing/bed-mesh/heating/extrusion physical testing on this exact build |
| Switch to `CONFIG_PREEMPT_RT` | Available in the source tree (RT-patched lineage) but never built | `REQUIRES_HARDWARE_QUALIFICATION` — would need a dedicated print-latency and MCU-communication-stability test plan before any recommendation; not proposed here |
| Enable `CONFIG_CPU_FREQ`/DVFS | Not compiled; real DT OPP table exists unused | `REQUIRES_HARDWARE_QUALIFICATION` — real potential idle-power/thermal win, but changing CPU frequency behavior on a live motion-control system needs real qualification before shipping |
| `CONFIG_HZ=100`, `NO_HZ_IDLE=y` | Untouched SDK defaults | No specific evidence of a problem; the tick doesn't appear to be dropping to near-zero at idle in the interrupt-rate sample (§13), but this looks more attributable to the USB OTG SOF interrupt storm (§13) keeping the CPU from reaching a truly idle state than to the HZ/NO_HZ settings themselves |

**No print-latency validation plan is proposed here because no
preemption-model change is being recommended.**

---

## 10. Compression and filesystem assessment

| Item | Current | Assessment |
|---|---|---|
| Kernel image (`xImage`) | 6.64 MB, **uncompressed** | Decompression time is currently zero. Adding kernel-level compression (LZ4/gzip/XZ at the uImage wrapper) would only ever *add* CPU decompression cost with no meaningful I/O-time offset on an already-small, already-fast-to-read 6.64MB image from eMMC. **Not a promising lever — do not pursue.** |
| Rootfs (`rootfs.squashfs`) | 99.89 MiB, **gzip**, 128 KiB blocks | Gzip is the slowest-decompressing of the common squashfs codecs (though best-ratio). LZ4 offers much faster decompression at a modest size cost; Zstandard is a plausible middle ground. **A real, measurable candidate — but see the scope caveat below.** |
| **Scope caveat, important** | — | Klipper's and Moonraker's own Python source, and both venvs' interpreter binaries, live on the **ext4** persistent partition (`/usr/data`), **not** squashfs. Squashfs decompression on this device therefore affects boot-time reads of **base-OS binaries and shared libraries only** (nginx, dropbear, ustreamer, ModemManager, busybox, libc and other shared libs) — **not** Klipper/Moonraker's own Python import time, which is governed by ext4 read speed + bytecode compilation cost (§11), not squashfs compression choice. |
| A/B partition capacity | 250 MiB per slot, 99.89 MiB used | ~150 MiB headroom remains in either slot regardless of which compression format is chosen — no capacity risk from experimenting with LZ4/Zstd, even if the resulting image were somewhat larger. |
| **Recommendation** | — | `MEASURE_WITH_DIAGNOSTIC_BUILD`: build a comparison squashfs image with LZ4 or Zstd compression and measure actual boot-time-relevant read latency for the base-OS binary set before deciding — do not assume the gain without measuring, since the affected code path (base-OS binaries only) is smaller than "the whole rootfs" might suggest. |

---

## 11. Python startup assessment

| Item | Finding |
|---|---|
| Python version | 3.11 |
| Venv structure | Two **separate** venvs (`/usr/data/nebulaos/envs/{klipper,moonraker}`), both `--system-site-packages`. Confirmed deliberate: Moonraker's `update_manager` infers each app's venv root from its own reported interpreter path with no config override — sharing one venv path would break per-app update/rollback slot logic. **Correct as-is, no change recommended.** |
| Venv creation timing | **Not build-time** — created on **first boot** by `S04nebulaos-factory-seed`, ~59s CPU time per venv (~118s combined), one-time only, already marker-gated. |
| System-dependency bytecode | **Already optimal.** Buildroot's `BR2_PACKAGE_PYTHON3_PYC_ONLY=y` ships only compiled `.pyc` for the interpreter and every enabled Python package (tornado, jinja2, pillow, numpy, matplotlib, etc.) — these never pay a compile cost at import time. |
| Klipper/Moonraker's own source bytecode | **Not precompiled at build time.** The build script explicitly deletes any stray `__pycache__` after copying source in, and nothing re-runs `compileall`. Klippy/Moonraker's own modules compile to bytecode lazily, at first import, on-device, at full MIPS CPU cost. |
| When that cost is paid | Depends on whether `/opt/klipper`/`/opt/moonraker` are bind-mounted onto writable ext4 (`S05nebulaos-activate`'s decision) or still read-only squashfs (activation declined — fresh/wiped namespace, held update lock, ownership mismatch). **Writable case**: `.pyc` written on first import, reused across restarts within/across boots (source mtime unchanged) — cost paid once per source-tree-lifetime, not every boot. **Read-only fallback case**: bytecode **cannot** be cached at all; recompiled from source on literally every single process start, forever, until activation succeeds. |
| **Recommendation** | `HIGH_CONFIDENCE_LOW_RISK`: add a build-time `python3 -m compileall -q` pass over the copied `klippy/`/`moonraker/` trees (after the existing `__pycache__` cleanup), shipping `.pyc` in the image. Eliminates the cold-boot/degraded-path compile cost entirely; does not affect the already-correct writable-path caching behavior. |
| Real gap found (not boot-time, but relevant) | **`msgspec` is silently absent.** `klippy/webhooks.py` (a core, always-imported module — the exact channel Moonraker uses for every Klippy API call) tries `import msgspec`, falls back to stdlib `json` on `ImportError`. msgspec is in neither Buildroot's package set nor the pywheels list (it needs actual C-extension cross-compilation, likely why it was never added). Klipper always uses the slower codec on every Moonraker↔Klippy exchange, silently, forever. Not a crash, not boot-time, but a real, currently-unaddressed hot-path performance gap worth its own follow-up. |
| Heavy packages (numpy, matplotlib) | Both confirmed **lazy** — numpy only imported inside a try/except in `shaper_calibrate.py`, never triggered since `printer.cfg` has no eddy/angle/load-cell sections; matplotlib only imported by a standalone subprocess CLI script GuppyScreen shells out to for calibration graphing. **Zero boot-time or normal-operation cost from either.** |
| Locale/CA-cert hygiene | Already minimized (`BR2_ENABLE_LOCALE_PURGE=y`, whitelist `C en_US`); no CA-cert duplication found. |

---

## 12. Per-process memory budget

**Important limitation, itself a finding**: `CONFIG_PROC_PAGE_MONITOR` is
**not set** in the running kernel, so `/proc/<pid>/smaps` and
`smaps_rollup` do not exist at all — true PSS/USS accounting is
**structurally impossible** on this build without a kernel config change
(out of scope to build this pass). All figures below are RSS only, which
overstates true per-process cost wherever libraries are shared across
processes (notably the Python interpreter/stdlib, and Klipper/Moonraker's
`--system-site-packages` sharing).

| Process | RSS | PSS | Notes |
|---|---:|---:|---|
| klippy (python3) | 24,640 kB | N/A | |
| moonraker (python3) | 32,724 kB | N/A | |
| guppyscreen | 8,884 kB | N/A | |
| ustreamer (idle, no client) | 15,336 kB | N/A | 8 threads |
| ustreamer (one client streaming) | 15,848 kB | N/A | +512 kB during active encode/serve |
| nginx (master) | 920 kB | N/A | 1 worker process configured |
| dropbear | 1,536 kB | N/A | |
| dbus-daemon | 1,540 kB | N/A | |
| ModemManager | 8,960 kB | N/A | See §18 — no modem hardware exists on this printer |
| wpa_supplicant | 5,760 kB | N/A | Required, real WiFi |

System-level (`/proc/meminfo` at measurement time): 212,776 kB total,
9,920 kB free, 126,416 kB available (most "used" memory is reclaimable
page cache/buffers — 111,916 kB cached + 10,244 kB buffers — not a memory
pressure signal).

**Recommendation**: `MEASURE_WITH_DIAGNOSTIC_BUILD` — a future diagnostic
kernel build with `CONFIG_PROC_PAGE_MONITOR=y` is needed for accurate
PSS/USS accounting; this is purely additive instrumentation (adds a
`/proc` interface, does not change behavior) and low-risk to add to a
diagnostic-only build profile (see §16's production/diagnostic split
recommendation).

---

## 13. CPU and wakeup budget

| Measurement | Value | Method |
|---|---|---|
| Aggregate CPU utilization, idle | ~10% average across 2 cores (idle fraction ~88% over a 15s sample) | `/proc/stat` delta over 15s |
| Load average | 0.16-0.21 | `/proc/loadavg` |
| Context switches | ~1,470/sec | `/proc/stat` `ctxt` delta over 15s |
| **USB OTG (dwc2) interrupt rate** | **~8,000/sec continuously, nothing plugged in** | `/proc/interrupts` delta over 10s, IRQ 9 (`13500000.otg`) |
| Parent/cascade interrupt (IRQ 2, `xburst2-intc`) | ~8,333/sec, closely tracking IRQ 9 | Same sample |
| Timer tick (`core_timerevent`) | ~170/sec per core (close to the full 100Hz rate, not meaningfully reduced despite `NO_HZ_IDLE=y`) | Same sample |
| Display controller (`lcdc-1`) | ~100/sec combined | Same sample — consistent with GuppyScreen's own UI redraw/vsync, not obviously wasteful |
| MCU UART (`uart1`) | ~85/sec combined | Same sample — this is Klipper's real, required MCU communication; **do not touch** |
| Touch (`i2c4`), MMC | Near-zero during idle sample | Same sample |

**Major finding**: the ~8,000/sec USB OTG interrupt rate matches almost
exactly the timing of USB 2.0 high-speed micro-frame Start-of-Frame
interrupts (125μs period = 8,000/sec), a well-known real-world dwc2
behavior where the controller keeps generating SOF interrupts continuously
in host mode once the port is enabled, regardless of whether anything is
attached. Each interrupt costs real CPU cycles for ISR + scheduling
overhead — this is a genuine, continuous, previously-unquantified CPU/power
cost on a device that spends most of its life idle.

**Classification**: `MEASURE_WITH_DIAGNOSTIC_BUILD` /
`REQUIRES_HARDWARE_QUALIFICATION`. Plausible mitigations (USB runtime
autosuspend, dwc2 power-management tuning) exist in principle, but changing
always-on USB host port behavior needs real qualification against hotplug
detection latency (USB storage insertion, the always-attached path to the
touch/camera stack if applicable) before any change — **not recommended for
immediate action, but this is the single largest, most concrete CPU/wakeup
finding in this entire audit** and merits a dedicated follow-up
investigation.

**Polling loops inventoried** (from source, cross-referenced with the
init-script audit): `S50webcam`'s 5s hotplug-detection poll (already
documented as a deliberate, examined tradeoff), `nebulaos-update-supervisor`'s
20s main poll loop (its entire reason for existing), `nebulaos-retention.sh`'s
periodic cleanup checks (backgrounded, shallow, low-cost). None of these
were found to be unnecessarily tight or unexamined.

---

## 14. Camera resource assessment

| State | CPU (single-core-equivalent) | RSS | Method |
|---|---:|---:|---|
| ustreamer running, no client | <0.2% | 15,336 kB | `/proc/<pid>/stat` utime+stime delta over an idle interval |
| ustreamer, one client streaming (~10s, real MJPEG stream fetched from this host via nginx's `/webcam/` proxy) | ~5.6% | 15,848 kB (+512 kB) | Same method, before/after a real 10-second stream fetch |

Resolution/fps were not altered for this measurement (already-configured
1920x1080@30, `--encoder=HW`, confirmed from the live process command
line). This is already a clean "capture-on-demand" cost profile — idle cost
is very low, active cost is modest and scoped to when actually streaming.
**No optimization opportunity identified here beyond what's already
implemented**; the camera stack is not a significant contributor to idle
resource use.

---

## 15. nginx, dropbear, and auxiliary service assessment

| Item | Finding |
|---|---|
| nginx workers | `worker_processes 1`, `worker_connections 1024`, `keepalive_timeout 65` — already minimal/appropriate for a 2-core, low-traffic embedded device. No change recommended. |
| nginx logging | `/webcam/` proxy location explicitly sets `access_log off` (correctly avoiding per-frame log writes for the MJPEG stream); `proxy_buffering off` for the same location (correct for a live stream, avoids buffering latency). Mainsail's own access/error logs are separately configured. `/var/log` itself measured empty at snapshot time. |
| dropbear | Confirmed root cause (matches prior project memory) for host-key regeneration every boot: the init script explicitly falls back to "no persistent location to store SSH host keys, new keys will be generated at each boot" when `/etc/dropbear` can't be made a real writable directory. This is expected/by-design given the read-only-squashfs `/etc`, not a bug — but it does mean dropbear startup does real key-generation CPU work every single boot that a persisted host-key location would eliminate. Recommend evaluating whether the persistent `/usr/data` partition could host the dropbear key directory (would need the same bind-mount treatment already used for other persistent paths) as a `MEASURE_WITH_DIAGNOSTIC_BUILD` candidate, not implemented here. |
| ModemManager + dbus-daemon | Running (8,960 kB + 1,540 kB RSS respectively), started via `S44modem-manager`/`S30dbus`, generic unmodified Buildroot boilerplate scripts with zero NebulaOS-specific customization or justifying comment. This printer has no cellular modem. Strong `PROVEN_UNUSED` candidate — see §18. |
| SSH recovery access | Not weakened by any finding above; if the dropbear-key persistence idea is pursued later, must preserve read-only-squashfs-boot resilience (key generation must still work if `/usr/data` isn't mounted for some reason) — flagged as a real constraint for that future work, not resolved here. |

---

## 16. Logging assessment

| Log | Size at snapshot | Notes |
|---|---:|---|
| `klippy.log` (active) | 1.7 MB | Plus a rotated `klippy.log.2026-07-29` at 325 KB |
| `moonraker.log` (active) | 70 KB | Plus a rotated file at 170 KB |
| `guppyscreen.log` | 38 KB | |
| nginx access/error (Mainsail) | Not separately sized this pass | `access_log off` already applied to the high-frequency camera-proxy path |

**Not measured**: actual write/fsync rate over time (would need repeated
sampling across a longer window than this session captured) — flagged as
a gap, not a finding either way. Log sizes at this single snapshot are not
alarming, but a rate measurement is needed before concluding logging
overhead is negligible in the CPU/wakeup budget. No critical boot,
rollback, thermal, MCU, or filesystem error reporting is proposed for
removal or downgrade — this audit found no evidence logging is currently
excessive, only that its rate hasn't been directly measured.

**Recommendation**: two build profiles (production / diagnostic) as the
mission itself suggests — production could lower default verbosity/rate
while the diagnostic profile (also carrying `CONFIG_PROC_PAGE_MONITOR=y`
from §12 and the `initcall_debug`/`printk.time=1` cmdline additions from
§8) remains available for real investigations. Not designed in further
detail this pass.

---

## 17. Swap / zram / memory policy assessment

| Item | Value |
|---|---|
| zram | 128 MiB, priority 100 (preferred), `lz4` active at runtime (measured `lzo lzo-rle [lz4]` on ke-dev 2026-10-03, HWDP-MEM-2; S00zram-swap asserts lz4. The earlier `lzo-rle` claim here was a documentation error, not a runtime override) |
| Disk swapfile | 128 MiB, priority 10 (fallback), at `/usr/data/nebulaos/system/swapfile` |
| Swap in use at measurement | 0 kB (SwapFree == SwapTotal) — no memory pressure at idle |
| sysctl policy | `vm.swappiness=10`, `vm.page-cluster=0` — already deliberately tuned (documented rationale: favor keeping pages resident, avoid page-cluster's disk-seek-oriented multi-page I/O bursts, reasoned specifically for this motion-control system, not copied from a generic guide) |

**No change recommended.** This area is already reasoned and tuned, not a
default carried over unexamined. Update/rollback peak swap usage was not
measured this pass (would require an actual update/rollback cycle, out of
scope for a read-only session) — flagged as a real gap for a future
dedicated measurement, not assumed safe.

---

## 18. Rootfs-content assessment (production-removable candidates)

| Item | Location | Impact | Safe to remove? | Evidence |
|---|---|---|---|---|
| **`ModemManager` + `dbus-daemon`** | `S30dbus`/`S44modem-manager`, ~10.5 MB combined RSS | RAM + minor boot-time (two more processes to start) | **Strong candidate, `POSSIBLY_UNUSED` pending confirmation** | Generic unmodified Buildroot boilerplate init scripts, zero NebulaOS customization/justification found; no cellular modem exists on this printer. Not yet proven that nothing else on this system depends on D-Bus (only ModemManager's own dependency confirmed) — recommend a dependency check specifically for D-Bus (does anything else register on the system bus?) before removing dbus-daemon itself; ModemManager alone looks safely removable regardless. |
| `c_helper.so` (Klipper's C extension) unstripped debug info | Built rootfs.squashfs, `/opt/klipper/klippy/chelper/` | **Disk-only** (~200 KB of 268 KB is debug sections; stripped would be ~66 KB); zero RSS impact (debug sections aren't `PT_LOAD`, never mapped) | **Yes, `HIGH_CONFIDENCE_LOW_RISK`** | Directly measured via `unsquashfs`+`readelf -S` on the real built image. Buildroot's blanket `BR2_STRIP_strip=y` pass is not reaching this file; `chelper/Makefile` builds with `-g -O2`, no strip step in the build script, unlike ustreamer/v4l2-ctl which already strip correctly. |
| `streaming_form_data`'s C extension unstripped | Same image, Moonraker's site-packages | **Disk-only**, same class of issue | **Yes, `HIGH_CONFIDENCE_LOW_RISK`** | Same `unsquashfs`/`file` check confirms "not stripped"; same missing-strip-step root cause. |
| Klipper/Moonraker `test`/`tests`/`docs` directories inside the seed archives | `/opt/nebulaos-seeds/{klipper,moonraker}.tar.gz` | Disk-only, read once at first-boot seed extraction, never imported at runtime | **No — do not remove** | This is the real git **working tree** content that the mutable checkout's `update_manager`/`git_deploy.py` needs to stay clean (`git status --porcelain` must report nothing) — removing these would make the seeded checkout permanently "dirty" relative to a real upstream clone, breaking update validation. Confirmed intentional; the only path already proven safe to sparse-exclude is Klipper's own 205 MB `lib/` (MCU HAL/SDK sources), which sparse-checkout treats as intentional sparsity rather than a deletion. |
| `.git` directories inside both seed archives | Same archives | Disk-only | **Explicitly required, not removable** | Documented, deliberate real-git-history design — Moonraker's update_manager needs `HEAD` to be a real, reachable ancestor of `origin/<branch>` for its validity/update checks; a prior "flattened synthetic commit" design broke updates permanently and was deliberately reverted. |
| `/opt/klipper/docs`, `/opt/klipper/config` (immutable squashfs copy, ~6 MB) | Separate from the seed archives | Disk-only, read only on-demand via Mainsail's file-manager UI | **No — intentional stock-parity fix**, not waste | Moonraker's `file_manager` unconditionally registers `config_examples`/`docs` roots and warns "invalid path" every boot if absent; documented fix, zero boot-time cost since never read at process startup. |
| CA certificates, locale/timezone data | Buildroot-managed | Already minimized | No further action | `BR2_ENABLE_LOCALE_PURGE=y`, whitelist `C en_US`; single CA-cert copy, no duplication found. |

---

## 19. Ranked candidate matrix

| Candidate | Layer | Expected boot gain | RAM gain | CPU gain | Feature risk | Validation required | Classification |
|---|---|---|---|---|---|---|---|
| Strip `chelper.so`/`streaming_form_data` debug symbols | Build script | None (disk-only) | ~200 KB disk, 0 RSS | None | None | Rebuild + confirm Klipper/Moonraker still import correctly | `HIGH_CONFIDENCE_LOW_RISK` |
| Precompile Klipper/Moonraker `.pyc` at build time | Build script | Real, on cold-boot/degraded-activation path only | None | Real, on affected path only | None (bytecode cache is a pure optimization, source behavior unchanged) | Confirm `.pyc` invalidation still works correctly after an update (mtime-based) | `HIGH_CONFIDENCE_LOW_RISK` |
| Remove ModemManager (+ evaluate dbus-daemon) | Userspace/init | Minor (fewer processes to start) | ~9-10.5 MB | Minor | Low, pending D-Bus dependency confirmation | Confirm nothing else registers on the system bus before removing dbus-daemon itself | `MEASURE_WITH_DIAGNOSTIC_BUILD` |
| Remove PROVEN_UNUSED kernel subsystems (sound, ISP camera, BT transport, on-chip Ethernet, netfilter/bridge, SFC, SADC) | Kernel config | Modest (less to init, smaller image) | Modest (less kernel memory for disabled-but-compiled subsystems) | Modest | Very low — all independently proven dead via device-tree/runtime evidence | A rebuilt kernel must still boot and pass the existing physical qualification suite (homing/mesh/heating/extrusion) before shipping | `REQUIRES_HARDWARE_QUALIFICATION` (a kernel rebuild, however low-risk the removals look, still needs a full boot+print-stack requalification pass) |
| Investigate/mitigate USB OTG ~8,000/sec SOF interrupt storm | Kernel/driver | Unknown until measured, plausibly meaningful given the interrupt rate | Unknown | Real, continuous, largest single quantified idle-CPU cost found | Real — any change to USB host power management needs hotplug-latency validation | Build a diagnostic kernel/driver-parameter variant, measure actual CPU/power delta and hotplug-detection latency before deciding | `MEASURE_WITH_DIAGNOSTIC_BUILD` |
| Enable CPU governor / DVFS | Kernel config | Unknown, plausible idle-power win | Unknown | Plausible idle-power win, needs measurement | Real — changing CPU frequency behavior on a live motion controller needs latency/thermal qualification | Dedicated print-timing validation before any production use | `REQUIRES_HARDWARE_QUALIFICATION` |
| Correct FIRMWARE.md's PREEMPT_RT claim | Documentation only | None | None | None | None | None — pure documentation fix | `HIGH_CONFIDENCE_LOW_RISK` (documentation, not code) |
| Add `CONFIG_PROC_PAGE_MONITOR=y` to a diagnostic build profile | Kernel config | None | None | Negligible (adds a `/proc` interface only) | None (additive instrumentation) | None beyond confirming it doesn't regress anything in a diagnostic-only profile | `HIGH_CONFIDENCE_LOW_RISK` |
| Investigate persistent dropbear host-key storage | Init script | Minor (skips key regen each boot) | None | Minor | Low — must preserve boot resilience if `/usr/data` isn't mounted | Confirm fallback-to-ephemeral-keys behavior still works if persistence is unavailable | `MEASURE_WITH_DIAGNOSTIC_BUILD` |
| Reorder/parallelize S50webcam + S58guppyscreen ahead of the Klipper/Moonraker chain | Init scripts | Real, on first-boot (long S04 seed) specifically; modest on normal boot | None | None | Low — both already tolerate their dependencies not being ready | Needs a real init-system change (parallel launch, not just renumbering, since standard sequential init.d blocks regardless of logical dependency) — a genuine implementation project, not a config tweak | `MEASURE_WITH_DIAGNOSTIC_BUILD` |
| Switch squashfs compression (gzip → LZ4/Zstd) | Build/kernel | Plausible but scope-limited (only affects base-OS binaries, not Klipper/Moonraker) | None | Plausible, unmeasured | Low | Build a comparison image, measure actual base-OS binary load latency | `MEASURE_WITH_DIAGNOSTIC_BUILD` |
| Investigate msgspec cross-compilation for Klipper | Build script | None (not a boot-time issue) | Minor | Real, on the Moonraker↔Klippy request-handling hot path | Low | Needs real C-extension cross-compilation work | `FEATURE_TRADEOFF` / follow-up mission, not part of this boot audit |
| Change kernel image compression | Kernel/bootloader | **Negative or neutral only** — kernel is already uncompressed and small | None | None | None | — | `DO_NOT_DO` |

---

## 20. Proposed implementation sequence

Per the mission's own required structure — each mission separately
reviewable, none combined:

1. **Mission 1**: strip debug symbols from `chelper.so`/`streaming_form_data`,
   precompile Klipper/Moonraker `.pyc` at build time, correct the
   FIRMWARE.md PREEMPT_RT documentation. All `HIGH_CONFIDENCE_LOW_RISK`,
   no hardware requalification needed beyond confirming the two apps still
   start correctly.
2. **Mission 2**: warm-reboot and (once available) cold-boot timing
   completed across both stock and NebulaOS with proper sample sizes (this
   audit only captured NebulaOS warm-reboot samples this pass — see below).
3. **Mission 3**: diagnostic kernel/build profile — add
   `CONFIG_PROC_PAGE_MONITOR=y`, `initcall_debug`/`printk.time=1` cmdline
   capture capability, without shipping these in production.
4. **Mission 4**: investigate the USB OTG interrupt-storm finding in depth
   (measure actual CPU/power cost precisely, evaluate dwc2 power-management
   options, validate hotplug-detection latency impact) before deciding
   whether to change anything.
5. **Mission 5**: kernel option removal (sound/ISP-camera/BT-transport/
   on-chip-Ethernet/netfilter-bridge/SFC/SADC) as one rebuild, followed by
   the full existing physical qualification suite (homing, bed mesh,
   heating, extrusion — everything already proven working this project must
   be reconfirmed against the new kernel build).
6. **Mission 6**: ModemManager/dbus-daemon removal evaluation, dropbear
   host-key persistence investigation.
7. **Mission 7**: init-script parallelization (S50webcam/S58guppyscreen
   ahead of the Klipper/Moonraker chain) — a genuine init-system change,
   largest engineering lift of the list, do last once everything else is
   settled.
8. **Mission 8**: CPU governor/DVFS enablement — requires the most
   extensive physical qualification (print-timing latency validation) of
   any item on this list; deliberately last.
9. **Mission 9**: full functional and print-regression qualification of
   whichever of the above actually get implemented, before any release tag.

Each mission must show measured before/after results per the mission's own
requirement — this audit provides the "before" baseline for all of them.

---

## 21. Production regression targets

**Not fully populated** — per the mission's own instruction not to invent
absolute targets before measuring, and given cold-boot timing and the
stock-vs-NebulaOS comparison are both deferred to a future session (see
§22), only partial targets can be set from evidence gathered this pass:

| Target | Value from this session's evidence | Status |
|---|---|---|
| Idle CPU | Must not regress above ~10-12% average (current measured baseline ~10%) | Set |
| Idle RSS sum of core services (klipper+moonraker+guppyscreen+ustreamer+nginx) | Must not regress above ~85 MB RSS (current measured sum ~82.5 MB) | Set, RSS-based only (PSS unavailable, §12) |
| Camera CPU, one client | Must retain at least the current ~5.6% single-core-equivalent cost profile at 1920x1080@30 — i.e., no fps/resolution reduction disguised as an optimization | Set |
| Warm-reboot Klipper-ready time | Not set — 2/2 attempts this session recovered successfully, but without trustworthy sub-second precision (see §3a); needs a DHCP-reserved IP or UART capture before a numeric target can be set | Deferred (methodology gap, not a device problem) |
| Cold-boot-to-Klipper-ready | Cannot be set without cold-boot measurement | Deferred |
| Stock-parity core-readiness target | Cannot be set without the stock comparison | Deferred |

---

## 22. Unresolved blockers / deferred work (explicit, per user decision this session)

1. **Cold-boot timing** (bootloader interval, true power-off-to-ready
   timeline) — requires a genuine physical power-cycle; this analysis host
   has no remote power control. **User's explicit decision this session**:
   defer to a later session when they can be physically present to
   power-cycle the device on request ("do it as a last test, when I'm able
   to assist").
2. **Stock-vs-NebulaOS comparison** — requires switching the device to the
   stock A/B slot (a bigger, more disruptive action than a same-OS reboot,
   though this project has done it safely before per
   `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md`). **User's explicit decision**:
   same as cold-boot — deferred to a later, assisted session.
3. **Bootloader interval** (power-applied → U-Boot → kernel entry) —
   requires UART/serial-console access this analysis host does not have.
   Honestly reported as unmeasured per the mission's own instruction, not
   estimated.
4. **Slow kernel initcalls/probes** — needs the diagnostic instrumentation
   plan in §8 actually deployed (a temporary cmdline-only change, easily
   reversible) to capture; not deployed this pass.
5. **Update/rollback peak memory** — not measured; would require an actual
   update/rollback cycle, out of scope for a read-only session.
6. **Logging write/fsync rate over time** — only a size snapshot was taken;
   a real rate measurement needs repeated sampling across a longer window
   than this session captured.
7. **GuppyScreen visible** milestone timing — no on-device or external
   signal was available this pass to detect "first frame rendered"; needs
   either a display-facing sensor or an instrumented timestamp GuppyScreen
   itself could emit.

8. **Reliable network-based boot-timing methodology** — this session's two
   real reboot attempts demonstrated that polling for the device's IP via
   live network rescans is fragile (DHCP churn each reboot, plus a real
   demonstrated false-positive risk from unrelated hosts on the same LAN
   answering port 22). Before attempting warm/cold-boot timing again,
   either arrange a DHCP reservation for this device's MAC address (removes
   the address-churn problem entirely) or capture via UART/serial console
   as the mission's own Phase 3 already lists as the preferred method.

None of these block the recommendations already made in §19 that don't
depend on them (the `HIGH_CONFIDENCE_LOW_RISK` items in particular are
fully actionable without any of the above).

---

## Machine-readable summary

```text
BOOT_BASELINE: PARTIALLY_MEASURED (2/2 warm reboots this session recovered successfully to klippy_state=ready, confirming reliability - but milestone-level timing was not captured with trustworthy precision, due to DHCP IP churn + a demonstrated false-positive host-discovery risk; see Sec 3a. Cold boot and bootloader interval explicitly deferred per user decision.)
STOCK_COMPARISON: DEFERRED (user decision - needs a later, physically-assisted session)
KERNEL_CRITICAL_PATH: IDENTIFIED_FOR_USERSPACE (init-script chain fully mapped); INSTRUMENTATION_REQUIRED for kernel-internal initcall timing
USERSPACE_CRITICAL_PATH: IDENTIFIED
FIRST_BOOT_COST: SEPARATED_FROM_NORMAL_BOOT

IDLE_MEMORY_BUDGET: MEASURED (RSS only - PSS structurally unavailable, CONFIG_PROC_PAGE_MONITOR not set)
IDLE_CPU_BUDGET: MEASURED
CAMERA_RESOURCE_COST: MEASURED
UPDATE_PEAK_MEMORY: NOT_MEASURED (test plan: exercise a real update/rollback cycle with the diagnostic PSS-capable kernel from Mission 3)

UNUSED_KERNEL_FEATURES: PROVEN_LIST (sound/ASoC, internal ISP camera, Bluetooth HCI transport, on-chip Ethernet MAC, netfilter/iptables/bridge, SFC flash controller, SADC/ADC MFD cells)
UNNEEDED_USERSPACE_SERVICES: PROVEN_LIST (ModemManager; dbus-daemon pending confirmation no other consumer exists)
SAFE_PARALLELIZATION: IDENTIFIED (S50webcam, S58guppyscreen - implementation not yet designed)
SAFE_DEFERRAL: IDENTIFIED (S40nebulaos-ntpsync, S45nebulaos-cleanup, S59nebulaos-update-supervisor - already backgrounded/non-blocking)
FIXED_WAIT_REMOVAL: IDENTIFIED (13 found, cataloged; only 1 of 13 - S01wifi's `sleep 2` - lacks a fully evidenced justification; the two largest boot-blocking waits, S95/S99, are legitimate health gates, not removal candidates)

FEATURE_LOSS_PROPOSED: NO
OFFLINE_FIRST_BOOT_PRESERVED: YES
ROLLBACK_PRESERVED: YES
RECOVERY_ACCESS_PRESERVED: YES

READY_FOR_OPTIMIZATION_IMPLEMENTATION: YES for Mission 1 items (HIGH_CONFIDENCE_LOW_RISK); NO for kernel-rebuild/DVFS/USB-power items pending the diagnostic measurements and hardware qualification each explicitly requires
```
