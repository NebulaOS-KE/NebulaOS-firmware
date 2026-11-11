# The black box: why the printer restarted

Added for 1.0.2 after two failures that left nothing behind. Read against `NebulaOS-firmware`
at `b95b156`; where 1.0.2 (`3bdf3ff`) differs, the page says so.

The kernel half - the watchdog pre-timeout dump, the lockup detectors, the ramoops reservation
and the `nebulaos_sdio_idle` parameter - is in
[NebulaOS-kernel's wiki](https://github.com/NebulaOS-KE/NebulaOS-kernel/wiki/Freeze-Diagnosis).

Added after two failures that left nothing behind - a partial hang on 2026-11-06 and a
mid-print freeze on 2026-11-08, where the system stopped dead, the hardware watchdog reset the
board about 60 s later, and the last minute of every log never reached the eMMC.

The fix is to stop depending on the eMMC. The kernel reserves 1 MB of RAM that survives a
watchdog or panic reset (pstore/ramoops, `halley5_v30.dts` in the kernel repository) and keeps
three things in it: its own log (`console-ramoops-0`), any panic or oops dump
(`dmesg-ramoops-N`), and a userspace heartbeat (`pmsg-ramoops-0`).

`usr/libexec/nebulaos-blackbox`, started by `S03nebulaos-blackbox`, has three modes:

| Mode | When | What it does |
|---|---|---|
| `collect` | once at boot | reads pstore and the SoC reset status, decides why the last boot ended, keeps the evidence under `logs/`, empties the dump zones, and leaves a notice after a freeze or crash |
| `heartbeat` | continuously | one line every 10 s into `/dev/pmsg0` - load, memory and the processes that used the most CPU since the last line. RAM only, so no eMMC wear |
| `shutdown` | `rcK` | one `shutdown clean` line into `/dev/pmsg0`, a synchronous RAM write, so the next boot knows the restart was orderly |

**The heartbeat runs at `SCHED_OTHER` nice 19**, the lowest priority there is. That is
deliberate twice over: it never takes CPU from Klippy, and it still runs beside a runaway
real-time task thanks to RT throttling - so its lines can name the task that is eating the
printer. In a true kernel stall nothing runs at all, and then **the timestamp of the last line
is the evidence**.

### The verdict, and where to read it

`collect` writes `REASON=` into `/run/nebulaos/last-reset` and appends a line to
`logs/reset-history.log` (100 lines kept). The reasons are checked in this order:

| `REASON` | Established from |
|---|---|
| `FREEZE` | a panic dump from the kernel's watchdog pre-timeout handler (`nebulaos-freeze:`, 1.0.2) - the printer froze and the kernel dumped its state 40 s later |
| `CRASH` | any other kernel panic or oops dump in pstore |
| `RESTART` | the heartbeat log ends in `shutdown clean`, or the SoC scratch word holds the kernel's reboot signature `0x3535`, or the kernel log ends in `reboot: Restarting system` |
| `POWER_OFF` | the kernel log ends in `reboot: Power down` or `System halted` |
| `UNKNOWN` | no reset status from the kernel (an image without the black box), or no evidence either way |
| `FREEZE` | a previous kernel log in pstore, none of the above, and the SoC says watchdog reset |
| `POWER_ON` | nothing in pstore and a power-on reset: switched on, or a power cut |

`FREEZE` appears twice on purpose. The first is a kernel that dumped its own state before the
reset; the last is the inference from a watchdog reset with no dump. **The difference is
visible in the state file:** `PSTORE_DUMP=freeze` means the pre-timeout handler fired,
`PSTORE_DUMP=yes` an ordinary panic dump, `PSTORE_DUMP=no` neither.

**That third value is newer than the release.** On 1.0.2 (`3bdf3ff`) the same situation reports
`PSTORE_DUMP=no` even though the dump exists and `REASON=FREEZE` is already correct;
`dc4d9d6` on `main` is what distinguishes the two. Read a 1.0.2 printer's `last-reset`
accordingly - the reason is trustworthy, that one field is not.

A `FREEZE`, `CRASH` or `UNKNOWN` boot copies every pstore file to
`logs/crash/<stamp>-<reason>-<file>.txt`, newest five kept. The previous boot's kernel log and
heartbeat are kept in full every boot (`previous-boot-kernel.log`,
`previous-boot-heartbeat.log`), whatever the reason - that is what catches a partial hang the
user ended with a restart from the screen, which produces no `FREEZE` and no crash copy.

After a `FREEZE` or `CRASH` it writes a plain-language notice to
`system/notices/printer-restarted.txt`, telling the owner the printer restarted by itself, to
check whether the screen offers to resume the print, and how to send the logs in. **The black
box never fails the boot:** every step is best effort.

### The two overlay files that go with it

Neither is an executable, so neither appears in [Runtime helpers](Runtime-Helpers), and
both change behaviour:

- **`etc/sysctl.d/91-nebulaos-freeze.conf`** makes every stall the kernel can see end in a
  panic, because a panic is what writes the kernel log into pstore past a console lock a stuck
  CPU may hold: `kernel.panic_on_rcu_stall = 1`, plus all-CPU backtraces for soft and hard
  lockups. The watchdog would have reset the printer anyway; this only makes the reset leave a
  reason behind.
- **`etc/udev/rules.d/60-nebulaos-no-sleep.rules`** turns off two low-level sleep paths
  suspected in the freeze: USB runtime suspend for every device and hub (`power/control` =
  `on`, so the dwc2 controller never clock-gates), and the Wi-Fi SDIO bus sleep
  (`nebulaos_sdio_idle` = `0`, needs kernel `95d0321e` or newer). It costs a few tens of
  milliwatts. Note what this means for a bug report: on 1.0.2 the SDIO idle sleep is **off**,
  whatever the kernel's own default says.

The kernel half of all this is documented in the kernel repository's wiki:
[Freeze diagnosis](https://github.com/NebulaOS-KE/NebulaOS-kernel/wiki/Freeze-Diagnosis) and
[What NebulaOS changes](https://github.com/NebulaOS-KE/NebulaOS-kernel/wiki/What-NebulaOS-Changes).

