# NebulaOS Display Live Read-Only Investigation Report

Companion to [NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md](NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md).
First powered-on phase of the display investigation mission (2026-08-01) - strictly read-only
(SSH reads, procfs/sysfs/debugfs reads, kernel logs, live device-tree reads; no writes, no
flashing, no reboots, no register writes, no ioctls). Raw captured output is preserved at
`build-work/display-live-investigation/{identity-check,capture-192.168.1.243}/` (gitignored
scratch, matching this project's established convention).

## Discovery and identity confirmation

Printer found at `192.168.1.243` (unchanged from last known - verified independently, not
assumed). A full `/24` scan surfaced two other SSH-open hosts (`192.168.1.20`, `192.168.1.235`);
neither gave the expected `SSH-2.0-dropbear_2022.83` banner on repeated attempts, ruling them out
before any credentials were used.

Identity confirmed via 5 independent signals, 4 of which line up and one real discrepancy:

| Signal | Result | Verdict |
|---|---|---|
| wlan0 MAC | `16:3b:5d:00:00:01` | Exact match to the expected CID-derived MAC |
| Moonraker `/printer/info` | NebulaOS-specific paths (`/usr/data/nebulaos/envs/klipper/...`, `/opt/printer_data/config/printer.cfg`) | Matches this repo's overlay tree |
| Root slot | `root=/dev/mmcblk0p8` -> `rootfs2` partlabel | Booted from the custom slot, not stock |
| `/etc/ota_marker*` content | Contains this project's own `write_ota_marker()` shell function, citing `S00revert-safety`/`S99confirm-good`, `FIRMWARE.md sec 21/23` | Matches internal build documentation almost verbatim |
| hostname | `buildroot` | Does NOT match the expected `ender3v3ke-<hex>` pattern - a real, flagged discrepancy, not disqualifying given the other 4 signals |

`identity-manifest`: neither expected manifest path exists on this image (`NO_MANIFEST_FOUND`) -
a real gap, not a command failure.

**IDENTITY_CONFIRMED: YES**, on the strength of the exact MAC match plus 3 corroborating
signals. The generic `buildroot` hostname is a genuine, real anomaly worth a future fix (out of
this mission's scope) - this image was apparently never given the expected custom hostname.

## Safety checks (all clear before the full sweep)

- `print_stats.state`: `standby` (not printing/paused)
- `extruder`/`heater_bed` targets: `0.0` (idle)
- `/sys/kernel/realtime`: `1` (PREEMPT_RT active on this boot)

## Findings by group

**RT/kernel**: `Linux 6.6.18-rt23 #2 SMP PREEMPT_RT`, built 2026-07-31 21:52:40 UTC.
`/sys/kernel/realtime=1`, `CONFIG_PREEMPT_RT=y`, `CONFIG_HZ=100` (tickless,
`CONFIG_HZ_PERIODIC` unset) all confirmed live via `/proc/config.gz`. **This is the
NEBULAOS-ALPHA-MAX-RT experimental image, still the currently-running deployment** - consistent
with the pre-qualification mission's own record that this image was left running after that
mission concluded.

**Root slot / partitions**: `/` is `squashfs ro` on `/dev/root`. `mmcblk0p10` (ext4, rw) provides
`/usr/data` and is bind/overlay-mounted at `/opt/printer_data`, `/opt/klipper`,
`/opt/moonraker`, `/root/klippy-env`, `/usr/share/mainsail`,
`/opt/guppyscreen/guppyconfig.json`. Partition table: p1=ota marker, p2=sn_mac,
p3/p4=rtos/rtos2, p5/p6=kernel/kernel2, p7/p8=rootfs/rootfs2 (booted p8), p9=rootfs_data,
p10=userdata.

**Live device tree**: DPU node `/sys/firmware/devicetree/base/ahb0/dpu@13050000`
(`compatible="ingenic,dpu"`, `status="okay"`, `interrupts=<0x1f 0x0a>` = hwirq 31). Panel node
`openke_panel` present. **Backlight DT node: zero matches anywhere** (empty result, not a
command failure) - PROVEN_FROM_LIVE_READ_ONLY confirmation of the offline finding. Touch node
`ns2009@48` on i2c4. PWM controller node exposes all 16 channels' pinmux groups in the DT (static
wiring only, not evidence of use).

**Framebuffer**: `fb0`="ingenicfb", 480x272 @ 32bpp, stride 1920, `virtual_size=480,816`
(816=272x3 -> **triple-buffered, confirmed live**, matching the offline analysis exactly).
`fbset` not installed on this image (tool gap, not a data gap - the same info was obtained
directly from sysfs).

**DPU IRQ identity and rate**: IRQ 39 ("lcdc-1", hwirq 31 on XBurst2-irqchip). 10-second live
sample: 603 counts -> **~60.3Hz measured**, closely matching the offline-derived ~59.98Hz
baseline (well within normal measurement noise). Kernel boot log independently confirms
`mode->refresh: 60, mode->pixclock: 92962, rate: 10756800` - PROVEN_FROM_LIVE_READ_ONLY
confirmation of panel-timing-comparison.txt's numbers.

**Clocks/GPIO/pinctrl/PWM debugfs**: **all absent on this running kernel** - no
`/sys/kernel/debug/clk`, no `/sys/kernel/debug/gpio`, no `/sys/kernel/debug/pinctrl`, no
`/sys/kernel/debug/pwm`. This is a genuine kernel-config gap (these debugfs interfaces are
simply not compiled into this build), not a failed read - it means GPIO79's exact live
direction/pull/level and GPC-0/GPC-22's raw pin state could **not** be directly inspected this
session. Classification: UNKNOWN_UNTIL_HARDWARE remains for the exact electrical state of these
specific pins - see the live qualification plan's HT-01 (still open, would need either a debugfs-
enabled kernel rebuild or a bounded, source-address-proven `devmem` read to close).

**PWM controller/channel state**: `pwmchip0` exists (`npwm=16`), but **zero channels currently
exported/active**. Unambiguous, clean result: no PWM is driving anything right now - consistent
with (but not fully proving the electrical behavior of) the offline finding that no software
backlight control exists.

**Backlight class devices**: `/sys/class/backlight/` exists and is **empty**. Direct,
unambiguous PROVEN_FROM_LIVE_READ_ONLY confirmation of the offline finding.

**Touch input**: `ns2009_ts` registered at `i2c-4/4-0048` (`EV=b`, `KEY=400`=BTN_TOUCH,
`ABS=3`=X/Y) - a standard polled-touchscreen signature. **The full system-wide `/proc/interrupts`
table contains zero touch/GPIO79-related lines anywhere** - this is the authoritative,
kernel-wide check (not limited by the debugfs-GPIO gap above) and it directly confirms the
offline finding that touch has no dedicated GPIO IRQ registered anywhere in the system today.
i2c4 interrupt counts are very low (19/9), consistent with occasional I2C polling traffic rather
than an IRQ-driven device.

**Kernel logs** (real, quoted): `input: ns2009_ts as .../input/input0`; **`openke_panel: invalid
gpio vdd_en: -2`** (ENOENT - the panel driver's own probe path attempted to resolve a `vdd_en`
GPIO and found none, independently corroborating the deliberate DT omission documented in
device-tree-display.txt from an entirely different angle - the boot log, not just static DTS
inspection); `ingenic-fb 13050000.dpu: mode->refresh: 60, mode->pixclock: 92962, rate:
10756800`; `vidmem @ (ptr) size 1566720` (= 3 x 480x272x4 = 1,566,720 bytes, exactly matching
framebuffer-memory-analysis.txt's triple-buffer calculation).

**Boot timing**: no `/var/log/nebulaos-boot-timing*` file exists on this image - genuine
negative result.

**Boot handoff (Phase 13)**: not performed - requires physical UART setup and a natural
(not agent-triggered) cold boot, out of scope for a remote read-only session.

## Confirmation summary against prior offline findings

| Prior offline finding | Live result |
|---|---|
| No backlight DT node / class device | **CONFIRMED** - empty DT search, empty `/sys/class/backlight/`, independently corroborated by the `vdd_en: -2` boot-log error |
| Touch is polling-only, no IRQ on GPIO79 | **CONFIRMED** via full `/proc/interrupts` (zero touch/GPIO79 lines anywhere); direct debugfs GPIO79 pin-state read was unavailable (debugfs GPIO interface absent on this kernel) - a real, disclosed limitation, not a contradiction |
| DPU vsync/frame IRQ rate ~59.98Hz | **CONFIRMED** - measured ~60.3Hz over a live 10s sample |
| PREEMPT_RT live state | **ACTIVE** - `/sys/kernel/realtime=1`, confirmed live on the currently-booted kernel (this is the NEBULAOS-ALPHA-MAX-RT image, still running) |

## What remains open (real, disclosed gaps)

- GPC-0/GPC-22 (backlight PWM/enable pins) raw electrical state was NOT directly read this
  session - the debugfs interfaces needed to do so safely (gpio/pinctrl) are absent from this
  kernel build. HT-01 in the live qualification plan remains open; closing it needs either a
  debugfs-enabled kernel or a carefully bounded, source-address-proven `devmem` read.
- GPIO79's exact live pinmux/trigger-capability was not directly confirmed (same debugfs gap) -
  TOUCH-I1's own design is inherently tolerant of this unknown (see the implementation plan):
  `gpiod_to_irq()` fails safely and falls back to poll-only if the pin can't support an
  interrupt, so this gap does not block preparing/testing the prototype, only limits how
  confidently its success can be predicted in advance.
- No manifest file exists on this running image, and its hostname (`buildroot`) does not match
  the project's expected naming convention - both flagged for a future, separately-scoped fix,
  neither affects any display/touch/backlight finding above.
