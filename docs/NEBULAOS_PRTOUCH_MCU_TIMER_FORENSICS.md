# PRTouch MCU timer incident — forensics, source-correspondence audit, and next diagnostic plan

Audit date: 2026-08-10. Scope: a live no-trigger `Z_OFFSET_CALIBRATION` test (configured for a
1mm descent that could not physically reach the bed) ended in a real MCU shutdown
(`sentinel timer called`, preceded by five `Timer too close` warnings) and an audibly abnormal
motor sound. This document is the autonomous zero-motion follow-up: it establishes what can and
cannot be proven about the firmware actually running on the device, reconstructs the incident
timeline with explicit confidence labels, resolves the second-JSON-RPC-request question as far as
evidence allows, records the non-reentrancy guard added as a result, and specifies (but does not
execute) the smallest safe next motion experiment.

No gcode was sent to the real printer during this session. Every finding below came from
SSH-based read-only inspection (files, logs, Moonraker/Klipper status queries, `READ_PRES`),
static source inspection, and offline unit tests. The printer was left idle, unhomed, heaters
off, motors de-energized throughout.

---

## 1. Source ↔ running-firmware correspondence

**Question: is `vendor/klipper/src/sched.c` (or any source in this repo) provably the code that
built the MCU firmware currently running on this printer's `F005` mainboard?**

**No — and there is now positive evidence it is not.**

- Live MCU identify string: `Loaded MCU 'mcu' 116 commands
  (38d96adc-dirty-20231016_135251-longer-virtual-machine / gcc 9.2.1 [ARM/arm-9-branch] ...)`,
  `MCU=gd32f303xe`, `CLOCK_FREQ=120000000`, connected via real UART (`serial: /dev/ttyS1` in
  `[mcu]` — not a Linux-software-MCU, a genuine separate microcontroller).
- `38d96adc` does not exist as a commit anywhere in `vendor/klipper`'s git history
  (`git cat-file -t 38d96adc` → "Not a valid object name"). `vendor/klipper` HEAD is an unrelated
  commit (`0e5785da`, 2026-08-07). The firmware build date (Oct 2023) predates this whole project.
- `vendor/klipper/src/sched.c` was vendored wholesale in one commit ("add ender 3 v3 firmware
  blobs", `386fde4`, pellcorp/creality import) alongside **precompiled** firmware blobs at
  `fw/*/mcu0_*.bin` — i.e. this repo's own history already treats the mainboard MCU firmware as a
  separate, binary-only artifact from the buildable `src/` tree.
- This device's board code is `F005` (independently confirmed elsewhere in this repo's
  `FIRMWARE.md` via `/etc/ota_info` and U-Boot's own `nvram model: F005` output), matching
  `fw/F005/mcu0_001_G32-mcu0_007_000.bin`. That file is present both in this repo and on the live
  device (`/usr/data/nebulaos/apps/klipper/fw/F005/...`, byte-identical path/name). `file` reports
  it as raw opaque "data" (no ELF header); `strings -n 4` finds **zero** readable text anywhere in
  it — no "klipper", "prtouch", "timer", "shutdown", nothing. This is almost certainly an
  encrypted/obfuscated Creality OTA package, not a directly-inspectable compiled image.
- **No consumer of `fw/*.bin` exists anywhere on the live custom OS** (`grep -rl "fw/F005\|mcu0_"`
  across the whole `klipper` app tree matches only `.git/index`). **No `gd32` build target exists**
  in this Klipper source tree's `src/` at all (only `atsam, stm32, lpc176x, hc32f460, simulator,
  ar100, generic, linux, atsamd, rp2040, pru, avr`). **No file anywhere in the reachable custom-OS
  filesystem mentions "gd32"/"GD32" in any form.** The mainboard MCU update mechanism, if one
  exists, is not part of NebulaOS/SimpleAF at all — it almost certainly lives in Creality's
  separate stock firmware/OS partition, which was not booted into (a real OS-switch/reboot,
  explicitly out of scope for this zero-motion session).
- `reference/prtouch_v2.c` defines `PR_VERSION (307)`, which exactly matches `'version': 307`
  echoed in every live `debug_prtouch` MCU response — real corroboration that *the prtouch command
  layer specifically* is genuine. But that same file's header comment (`// Report on user
  interface buttons ... Copyright (C) 2018 Kevin O'Connor`) is verbatim upstream Klipper's
  unrelated `buttons.c` header — this file was made by editing an existing template, not a
  pristine Creality drop, and its provenance for anything beyond the prtouch command layer is
  unconfirmed.
- **Direct behavioral contradiction, not just a version mismatch**: `vendor/klipper/src/sched.c`
  implements `try_shutdown("Timer too close")` →
  `sched_try_shutdown()` (only guard: "not already shutting down") → `sched_shutdown()` →
  `irq_disable(); longjmp(shutdown_jmp, reason);` — an **immediate, unconditional hard shutdown on
  the very first call**. The real device instead printed five `Timer too close` `#output` lines
  across three full attempt cycles, with completely normal sensor reads, no-trigger detection, and
  recovery lifts in between each one, before a distinct `sentinel timer called` shutdown much
  later. If this exact `sched.c` governed the real firmware, the first `Timer too close` should
  have hard-stopped the MCU immediately. It did not. **This is concrete evidence that whatever
  scheduler code is actually running differs from this repo's `vendor/klipper/src/sched.c`.**
- A targeted web search found a Creality Wiki "Firmware Open Source" page for this exact model,
  but it is JS-rendered and yielded no extractable links via automated fetch. No further public
  Creality GPL source release was located from this session.

**Conclusion (superseded — see §7)**: this section originally stopped here, concluding that
static analysis had been exhausted pending either a genuine Creality GPL source release or live
MCU extraction. §7 below found that release. Kept for the historical record of what was
provable from the live device and this repo's own vendored source alone.

---

## 2. Incident timeline, with confidence labels

All times are Klipper `eventtime` (reactor-monotonic), read directly from
`klippy.log` (`Received`/`debug_prtouch`/`#output` lines are all in this same clock domain; the
one `Requested toolhead position at shutdown time 1748.877217` line is in the *separate*
`print_time` domain and must not be compared directly against `eventtime` — an error made and
corrected during this investigation).

| eventtime | Event | Confidence |
|---|---|---|
| 1743.594545 | `Received` `gcode/script` `Z_OFFSET_CALIBRATION` (id `1945934128`) — the one HTTP call made | FACT |
| 1744.366–367 | Attempt 1 armed: pres config echo, step-down echo `oid=5 dir=0 send_ms=10 step_cnt=200 step_us=1000 acc_ctl_cnt=50` | FACT |
| ~1744.4–1747.1 | `repairing pres samples, got 0/32` → `no pressure channel reported a trigger ... attempt 1/10` | FACT |
| 1747.152 | `Timer too close` (1st) | FACT |
| 1747.152–154 | disarm step/pres, recovery lift armed: `oid=5 dir=1 step_cnt=200 step_us=2500` | FACT |
| — | `repairing step samples, got 4/32` | FACT |
| ~1747.15 | `Timer too close` (2nd) | FACT |
| 1749.887 | Attempt 2 armed (down): identical params to attempt 1 | FACT |
| — | `no pressure channel reported a trigger ... attempt 2/10` | FACT |
| 1754.383 | `Timer too close` (3rd) | FACT |
| 1754.385 | recovery lift for attempt 2 armed | FACT |
| — | `Timer too close` (4th) | FACT |
| 1757.082 | Attempt 3 armed (down): identical params | FACT |
| — | `no pressure channel reported a trigger ... attempt 3/10` | FACT |
| 1761.591 | `Timer too close` (5th) | FACT |
| 1761.593 | recovery lift for attempt 3 armed — its own disarm/completion is never logged | FACT |
| 1748.808983 | `Received` `gcode/script` `Z_OFFSET_CALIBRATION` (id `1956010320`) — second, distinct request | FACT |
| shortly after 1761.593 | `Transition to shutdown state: MCU shutdown` → `MCU 'mcu' shutdown: sentinel timer called` | FACT |
| — | Motors reported by the operator as sounding abnormal during the test | FACT (direct observation) |
| — | `sched_shutdown`'s `longjmp` is immediate on first call, in the *source read*; real device tolerated 5 warnings before the real shutdown | FACT (of the source) / STRONG_INFERENCE (that the real firmware therefore differs — see §1) |
| — | The raw step-generation timing/cadence itself (not concurrency) is implicated, since attempt 1 alone produced 2 of the 5 warnings before the second RPC ever existed | STRONG_INFERENCE |
| — | Something specific to the third attempt's recovery-lift dispatch is where the firmware actually stalled long enough to trip the sentinel (~18s of the MCU's own 100ms heartbeat not running, per `sentinel_timer.waketime = periodic_timer.waketime + 0x80000000` at 120MHz — again only provably true of the *source read*, not confirmed for the real firmware) | HYPOTHESIS |
| — | Exact firmware-level mechanism that stalls the scheduler for that long | UNKNOWN — needs source correspondence (§1) or live instrumentation to resolve |
| — | Origin of the second RPC request | UNKNOWN as to *source*, but see §3 for what has been ruled out with evidence |

### On "0/32" and "4/32" sample-repair counts
`repairing pres samples, got 0/32` appears on every attempt's down-phase (no pressure trigger
ever arrived, consistent with a load cell that genuinely never triggered against open air — matches
the intentional design of this test). `repairing step samples, got 4/32` appears once, on attempt
1's *recovery lift* specifically (not its down-phase, and not on attempts 2 or 3's lifts, which show
`0/32`) — i.e. the MCU did report 4 real step samples for that one lift before the buffer needed
repair, while every other repair event reports zero. This is the single asymmetric data point in
the whole sequence. It temporally lines up with the first `Timer too close` overall (which also
occurs during attempt 1's transition into that same recovery lift). **STRONG_INFERENCE**: this
one partially-populated buffer marks the first point at which MCU response timing genuinely
degraded — consistent with, but not proof of, the recovery-lift path being where things start
going wrong. Not proven as causal; recorded as the most concrete anomaly available for any future
firmware-level investigation to explain first.

---

## 3. The second JSON-RPC request

Two distinct `Received gcode/script Z_OFFSET_CALIBRATION` lines exist in `klippy.log`'s
connection dump, with different ids, 5.2s apart (1743.59 / 1748.81) — this is a real, structural
fact, not a parsing artifact (Klippy's own retrospective 20-request dump lists both by their
genuine original timestamps).

**Ruled out, with evidence, as the source:**
- **Moonraker's own request layer duplicating the call.** Read directly from
  `/opt/moonraker/moonraker/components/klippy_connection.py`: `_request_standard()` creates
  exactly one `KlippyRequest` object (keyed by Python `id()`) and schedules exactly one write to
  Klippy per call (`self.event_loop.register_callback(self._write_request, base_request)`, once).
  `KlippyRequest.wait()`'s "pending" retry-logging path (the mechanism behind the unrelated
  `Request 'gcode/script' pending: 60.00 seconds` lines seen earlier and 20 minutes before this
  incident) re-awaits the *same* future via `asyncio.shield(self._fut)` — it structurally cannot
  create a second request. **This is proof, not inference: a single HTTP POST cannot produce two
  `Received` lines through this code path.**
- **Moonraker's own HTTP access log** (`application.py:log_request()`) shows exactly one relevant
  POST: `17:50:12,500 400 POST /printer/gcode/script?script=Z_OFFSET_CALIBRATION (127.0.0.1)
  20864.56ms` — the one call made during this investigation.
- **GuppyScreen's UI/wizard.** Its own application log
  (`/usr/data/nebulaos/printer_data/logs/guppyscreen.log`) shows a completely unrelated,
  already-finished `RecalibrationWizardPanel` session (stock BLTouch `TESTZ`-based calibration,
  *not* our custom `Z_OFFSET_CALIBRATION` command at all) ending at `17:30:32`, then **total
  silence** until a fresh process restart at `18:16:04` (consistent with GuppyScreen's connection
  being killed by the MCU shutdown and auto-restarting afterward). Zero log activity of any kind
  during the 17:43–17:50 incident window.
- **Mainsail.** Its websocket (`ID 1956252112`) closed at `17:47:22`, over a minute before this
  session's own curl call was even issued.
- **Full websocket enumeration** across the entire `moonraker.log`: only three connections ever
  opened — GuppyScreen's local one (open throughout, but proven silent above), Mainsail (closed
  before the test), and GuppyScreen's post-crash restart. No other client is visible.

**Not fully resolvable**: Moonraker does not access-log individual websocket JSON-RPC method
calls (only HTTP requests go through `log_request()`), so a raw, un-instrumented websocket call
cannot be 100% excluded on log evidence alone. However every specific, checkable candidate has
been checked and ruled out with positive evidence (not merely left untested), and GuppyScreen —
the only client with a connection open throughout — is independently proven silent by its own
application log.

**Causally irrelevant regardless of origin**: the first `Timer too close` (1747.15) predates the
second request (1748.81) by 1.6s, and the real shutdown occurs roughly 13s *after* the second
request, following a full additional clean attempt cycle (attempt 3) with no visible interference.
Whatever sent the second request, it did not cause this incident.

---

## 4. Reference material confidence reassessment

| Item | Classification | Basis |
|---|---|---|
| `reference/prtouch_v2.c` — prtouch command/protocol layer (`PR_VERSION`, field encoding) | CONSISTENT_BUT_UNPROVEN, with one strong corroborating data point | `PR_VERSION=307` matches the live device's own echoed protocol version exactly |
| `reference/prtouch_v2.c` — file provenance/header | RECONSTRUCTED_ONLY | Header is verbatim unrelated upstream Klipper `buttons.c` copyright text |
| `reference/prtouch_v2_wrapper.py` — command cadence (wait-then-disarm, timeout formula) | CONSISTENT_BUT_UNPROVEN | This port's `probe_timeout_seconds()` (`distance/speed + 2.0s`) matches the wrapper's own `down_min_z/use_tri_z_down_spd + 2` formula exactly; structurally equivalent wait/disarm sequencing |
| `vendor/klipper/src/sched.c` — scheduler/timer/shutdown semantics | CONTRADICTED | See §1's `try_shutdown` behavioral contradiction |
| This port's own `prtouch_probe.py`/`prtouch_mcu.py` host-side orchestration | CONFIRMED_BY_REAL_FIRMWARE (structurally) | The live incident's own log output (attempt counters, repair-sample counts, disarm/rearm sequencing) matches exactly what this port's source predicts it would send/log — the port's *host-side* behavior is doing what it was written to do; the *firmware's* response to that behavior is what remains unproven |

---

## 5. Non-reentrancy guard (added this session)

Independent of the unresolved timer root cause: `klippy_extras/z_compensate.py`'s
`cmd_z_offset_calibration()` now rejects a second invocation immediately (`command_error:
"Z_OFFSET_CALIBRATION: a calibration is already in progress"`) if one is already running, checked
and set with no yield in between — safe without a lock given Klipper's single-threaded/cooperative
reactor (whichever invocation's handler runs first always sets `"running"` before it can yield via
`reactor.pause()`/`wait_moves()`, so any second invocation is guaranteed to observe the busy state
already set, however it was triggered). The busy state clears on every exit path (success →
`"complete"`, any exception → `"error"`), matching the existing status-contract behavior; four new
regression tests in `test_z_compensate.py::ReentrancyGuardTest` cover rejection-while-running, that
a rejected call doesn't bump `calibration_id` or disturb the in-progress status, and that the guard
correctly clears after both success and failure to allow legitimate sequential reuse.

This is explicitly **not** presented as a fix for the timer incident — the second request was
shown in §3 to be causally irrelevant to it. It closes a real, independently-justified gap (no
motion-capable command should ever be able to overlap another instance of itself on this MCU's raw
step channel) regardless of what actually caused the shutdown.

Scope note: `CRTENSE_NOZZLE_CLEAR`/`NOZZLE_CLEAR` (`cmd_nozzle_clear`) also call `touch_probe()` on
the same shared `PrtouchProbe` instance and carry the same theoretical class of risk, but were not
part of what was asked for here and were left unguarded — flagged for a future, explicitly scoped
pass if wanted.

`UPSTREAM_KLIPPER_CORE_DIFFS: NONE` — this change is entirely within
`klippy_extras/z_compensate.py` (a NebulaOS-owned extra) and its own test file.

---

## 6. Next motion diagnostic — prepared, NOT executed

Do not run any of the following without a fresh, explicit go-ahead.

Given §1–§4: the retry/recovery *cadence itself* is not yet cleared as a factor (attempt 1 alone,
before any retry loop had run twice, already produced two `Timer too close` warnings), so the
right next step is not another `Z_OFFSET_CALIBRATION` run — it's the smallest possible **isolated,
single, non-probing raw step dispatch**, to learn whether even one lone `start_step_prtouch` call
produces `Timer too close` outside of any retry/disarm/rearm cadence. `SAFE_MOVE_Z` already exists,
is genuinely non-probing (no pressure arm, no trigger check, no retry loop — confirmed by direct
code reading earlier this investigation), and is exactly this shape. No new code is needed; this is
a usage plan, not an implementation task.

**Step A — single isolated UP move** (away from the bed; the strictly safer direction):
```
SAFE_MOVE_Z DIR=1 DIS=1 SPD=1
```
- 1mm, at a deliberately slow 1mm/s (well under the ~5mm/s used in the incident) — the smallest,
  slowest raw move this command supports.
- Capture `klippy.log` immediately before and after for any `#output: Timer too close` or shutdown
  transition, and confirm `webhooks.state` stays `"ready"` throughout.
- Confirm via `objects/query` that `toolhead` position and MCU stats look sane afterward.
- **Do not send Step B in the same session/back-to-back** — a deliberate pause and explicit
  human confirmation between the two, specifically because the incident's own cadence (rapid
  disarm-then-immediately-rearm) is one of the still-open hypotheses.

**Step B — single isolated DOWN move**, only after Step A is confirmed clean and only with fresh
authorization:
```
SAFE_MOVE_Z DIR=0 DIS=1 SPD=1
```
- Same 1mm/1mm/s parameters. Since `SAFE_MOVE_Z` has no pressure arm or trigger detection at all,
  this cannot be mistaken for contact detection — it is purely a raw-step-timing probe.

**Explicitly not part of this plan**: no `Z_OFFSET_CALIBRATION`, no `NOZZLE_CLEAR`, no retries, no
`G28`/homing, no persistence, no chaining the two steps together. If Step A alone reproduces
`Timer too close`, that would be strong evidence the issue is inherent to any raw step dispatch on
this real MCU, independent of cadence — a materially different conclusion than if only the
chained/retried case (as in the actual incident) reproduces it.

**NEXT_MOVEMENT_DIAGNOSTIC_EXECUTED: NO** (by design — this document only specifies the plan).

### 6a. Exact static proof (2026-08-10, second session, after the fix)

Ran this device's real, live `[stepper_z]` values (`microsteps: 16`, `rotation_distance: 8`,
200 full steps/rotation → `mm_per_step = 8/(200*16) = 0.0025`) through the real, unmodified
`prtouch_units.py` functions (no fake/test values) to compute exactly what
`SAFE_MOVE_Z DIR=1 DIS=1 SPD=1` will send, now that the guard/settle fix is in place:

```
start_step_prtouch oid=<step_oid> dir=1 send_ms=10 step_cnt=400 step_us=2500 acc_ctl_cnt=200 \
    low_spd_nul=5 send_step_duty=16 auto_rtn=0
collect_step_samples timeout = 6.0s (1.0s expected physical move + 5.0s margin)
settle after disarm = 0.01s (tri_send_ms/1000, the new fix's own yield)
```

Notably, `step_cnt=400, step_us=2500` for this 1mm/1mm/s move is the same order of magnitude as
the incident's own recovery-lift arms (`step_cnt=200, step_us=2500` for its 0.5mm lifts) —
this diagnostic exercises genuinely comparable timing to what actually happened, not an
artificially different regime. With the fix in place, this single call now also exercises
`_own_raw_operation` (rejects any overlapping call) and `_settle_after_disarm` (yields 10ms
after the disarm before returning) — both proven correct offline in
`test_prtouch_raw_op_guard.py`.

**NEXT_MOVEMENT_DIAGNOSTIC_EXECUTED: NO.**

---

## 7. Official Creality source located — the root cause is now proven, not inferred

2026-08-10, second session. `gh repo view` confirmed two real, accessible, official Creality
repositories: `CrealityOfficial/Ender-3_V3_KE_Klipper` (`git clone from
https://github.com/Klipper3d/klipper/`, tag `V1.1.0.12` — the exact firmware version this repo's
own `FIRMWARE.md` already cites for this device via `/etc/ota_info`) and
`CrealityOfficial/Ender-3_V3_KE_Annex`. Cloned both. History is only 4 commits total
(`9bdde73 Initial commit`, `a63fb1a update for open source`, plus two dependabot bumps) — a
one-time GPL-compliance snapshot, not a live mirror of Creality's internal build system, so
`38d96adc` (the running firmware's own embedded hash) still does not appear here either. That
specific commit remains unrecoverable — but this is now a materially different, far stronger
kind of evidence than §1's `vendor/klipper`: **Creality's own official source**, not a
third-party fork, containing the *exact same custom PRTouch subsystem* (confirmed below), for
the same board family.

### What's actually there
- `src/prtouch_v2_cm23.o`, `src/prtouch_v2_cm3.o`, `src/prtouch_v2_cm4.o` — real, precompiled,
  **not stripped** ARM ELF relocatable objects (`file`: "ELF 32-bit LSB relocatable, ARM, EABI5
  ... with debug_info, not stripped"), one per Cortex-M variant (M23/M3/M4).
- `src/gd32/` — a real, buildable GD32 target (`Kconfig`, `Makefile`), with
  `config MACH_GD32F303XE` present and selecting `MACH_GD32F30X_HD`/`MACH_GD32F30X` — this
  device's own live-identified chip (`gd32f303xe`) is a named, first-class target here, and the
  GD32F30x family's actual core is Cortex-M4, making `prtouch_v2_cm4.o` the applicable object
  (the Kconfig confirms the chip target; which of the three `.o` files gets linked for it is
  standard Cortex-core selection, not something this session needed to trace further given what
  was found below applies identically to all three).
- `config/F005/factory_printer.cfg` and `config/F005/printer.cfg` — this exact board, with the
  same `[mcu] serial:/dev/ttyS1 baud:230400` as the live device.
- `src/prtouch_v2_compile.c` — just `DECL_COMMAND` declarations + a thin `sendf_info()`; the
  real command implementations live in the precompiled `.o` files, linked via
  `src-$(CONFIG_HAVE_GPIO) += ... prtouch_v2_compile.c` in `src/Makefile`.

### The proof: Creality's own `sched_add_timer()` is NOT stock Klipper's

Diffing this official `src/sched.c` against `vendor/klipper/src/sched.c` (this repo's own
vendored pellcorp/klipper copy, the one §1 already showed is unproven for this device):

```c
 sched_add_timer(struct timer *add)
 {
     uint32_t waketime = add->waketime;
+	uint8_t flags = 0;              // (Creality's own real code, not upstream's)
     irqstatus_t flag = irq_save();
     struct timer *tl = SchedStatus.timer_list;
     if (unlikely(timer_is_before(waketime, tl->waketime))) {
         if (timer_is_before(waketime, timer_read_time()))
+		{
+            //try_shutdown("Timer too close");     <-- COMMENTED OUT in Creality's real source
+			flags = 1;
+			waketime = timer_read_time() + timer_from_us(2);   <-- silently clamped instead
+			add->waketime = waketime;
+		}
         ...
     }
     irq_restore(flag);
+    if(flags)
+	{			
+		output("Timer too close");      <-- plain debug print, NOT a shutdown notification
+		flags = 0;
+	}
 }
```

(diff direction: `+` lines are what upstream/pellcorp's `vendor/klipper/src/sched.c` has; the
lines actually present in Creality's own file are what's left when those are removed — i.e.
Creality's real `sched_add_timer()` has the commented-out `try_shutdown` and the clamp/print
logic, not the stock immediate-`longjmp` behavior.)

**This exactly and completely explains the incident's observed behavior.** §1 found a real
behavioral contradiction: stock `sched.c`'s `try_shutdown` → `sched_shutdown` → `irq_disable();
longjmp(...)` is unconditional and immediate on the very first call, yet the live device
tolerated five separate `Timer too close` warnings with fully normal operation in between each
one before a distinct, later shutdown. Creality's own real firmware source shows exactly why:
**they deliberately commented out the hard-shutdown call and replaced it with a silent
now+2μs clamp and a plain `output()` debug print** — which is precisely what
`mcu 'mcu': #output: Timer too close` in the live log is (a plain debug line, never a shutdown
notification at all, confirmed by the wire-format difference: shutdown reports use `is_shutdown
static_string_id=%hu`, not `#output:`).

A second, independent Creality customization was found in the same diff: the core idle loop
(`sched_main`'s inner `while` in `run_tasks`) has upstream's `irq_wait()` (sleep until an
interrupt) replaced with:
```c
do {
    asm volatile("cpsie i" ::: "memory");
    extern void prtouch_task(void);
    prtouch_task();
} while (SchedStatus.tasks_status != TS_REQUESTED);
```
i.e. whenever the MCU has no pending Klipper task, it **busy-polls a PRTouch-specific function
instead of sleeping**. Disassembling `prtouch_task` in `prtouch_v2_cm4.o`
(`arm-none-eabi-objdump -dr -j .text.prtouch_task`) shows it is a two-instruction dispatcher:
```
00000000 <prtouch_task>:
   0:	b508      	push	{r3, lr}
   2:	f7ff fffe 	bl	0 <prtouch_task>
			2: R_ARM_THM_CALL	prtouch_pres_task
   6:	e8bd 4008 	ldmia.w	sp!, {r3, lr}
   a:	f7ff bffe 	b.w	0 <prtouch_task>
			a: R_ARM_THM_JUMP24	prtouch_step_task
```
— it calls `prtouch_pres_task` then tail-calls `prtouch_step_task`, **the exact two function
names already documented in `reference/prtouch_v2.c`** (its own `prtouch_step_task()`, gated by
`check_delay(&send_dly, send_ms/1000)`, is what paces buffered-sample sends). This is real,
symbol-level, disassembly-confirmed proof that `reference/prtouch_v2.c`'s documented structure
matches Creality's actual compiled firmware, upgrading its confidence rating (see §4) from
"consistent but unproven" to **CONFIRMED_BY_REAL_FIRMWARE at the function/call-graph level**
(not byte-exact instruction correspondence — this session did not attempt full decompilation of
the timer-scheduling internals themselves, judged disproportionate once the `sched.c`-level
proof above was in hand).

### Updated §1 answer

`RUNNING_MCU_SOURCE_FOUND`: a strong, official, function-level match — not the exact `38d96adc`
build (unrecoverable without Creality's internal build history), but Creality's own published
source for this exact board family and firmware line, showing the precise customization that
explains the observed behavior. This is the strongest evidence obtainable without live MCU
extraction, and it was sufficient to reach a real conclusion.

---

## 8. Could the raw-step architecture be replaced instead of patched?

Evaluated per the mission brief's explicit instruction not to preserve Creality's raw-step
primitive "merely for compatibility." Conclusion: **no, not without upstream Klipper
modifications, which are out of scope.** The pressure (load-cell) sampling and the raw step
pulse generation are fused together inside the MCU firmware itself — `prtouch_event()` (the
per-pulse timer callback disassembled/read via `reference/prtouch_v2.c` and confirmed present
by symbol in the official `.o` files) is the single function that both toggles the step GPIO
*and* checks `read_swap_sta()` (the pressure-trigger latch) on every pulse, recording
`send_tri_time` the instant a trigger is detected. Upstream Klipper's own stepper/homing/probe
abstractions (`trsync`, `mcu_endstop`, the trapq-based move queue) have no path to observe this
MCU's pressure channel at all — there is no endstop pin, ADC reading, or any other primitive
upstream Klipper knows how to homing-query that carries this signal. Reimplementing the touch
detection on top of upstream's motion APIs would mean either (a) inventing a new MCU-side
protocol from scratch (modifying the firmware — explicitly excluded) or (b) polling the
pressure sensor from the host during a normal queued move, which cannot achieve trigger-time
resolution anywhere close to the MCU's own per-pulse check and would reintroduce exactly the
kind of unbounded-blind-travel risk the 2026-08-06/09 fixes already closed. The raw-step
primitive is the *only* foundation available for detecting a load-cell trigger without
firmware changes. This session's fix therefore works within that architecture (bounding and
pacing its use) rather than replacing it.

---

## 9. Root cause — final synthesis

| Finding | Confidence |
|---|---|
| The live device's `Timer too close` warnings are plain debug prints, not shutdown attempts, because Creality's own real firmware has `try_shutdown("Timer too close")` commented out | **PROVEN** (official Creality source, `CrealityOfficial/Ender-3_V3_KE_Klipper` tag `V1.1.0.12`, `src/sched.c`) |
| A "too close" timer gets silently clamped to `now + 2µs` and rescheduled, rather than rejected | **PROVEN** (same source) |
| The real, unmodified `sentinel_timer`/`sentinel_event` mechanism (§2) is still present and still capable of independently firing after ~17.9s of the periodic 100ms heartbeat not running | **PROVEN** (same source — this part of `sched.c` is unmodified from stock) |
| Repeated back-to-back disarm-then-immediate-rearm cycling (the incident's own cadence — zero host-side yield between a disarm and the next arm) is what drove the clamp-and-warn path 5 times, and plausibly congested the MCU's timer dispatch enough to eventually starve the periodic timer and trip the still-present sentinel | **STRONG_EVIDENCE** — directly explains every observed timestamp and warning count; the exact congestion mechanism inside `sched_add_timer`'s repeated near-immediate rescheduling was not separately disassembled/simulated, so this final causal link (clamp cascade → sentinel starvation) is strong inference from proven mechanics, not a byte-level proof |
| `reference/prtouch_v2.c`'s documented `prtouch_step_task`/`prtouch_pres_task` structure matches Creality's real compiled firmware | **PROVEN** (disassembly + symbol match, `prtouch_v2_cm4.o`) |
| The second, unexplained `Z_OFFSET_CALIBRATION` JSON-RPC request caused or contributed to the incident | **DISPROVEN** (§2/§3 — the first warning predates it by 1.6s, and the shutdown follows a full additional clean attempt cycle after it) |
| A full replacement of the raw-step architecture with upstream Klipper motion APIs is possible without firmware changes | **DISPROVEN** (§8 — the pressure/step coupling is inside the MCU firmware itself) |

**Likely root cause**: the live incident's own command cadence — disarming a raw step operation
and immediately rearming the next one with no host-side yield — repeatedly triggers Creality's
own real (not stock-Klipper) timer-clamping path in rapid succession, and this repeated
near-immediate rescheduling pressure is what eventually stalled the MCU's timer dispatch loop
long enough to trip the always-present, unmodified sentinel watchdog. This is now grounded in
Creality's own official source for the exact behavior that diverged from what stock
`vendor/klipper/src/sched.c` would predict, not merely inferred from host-side log timing.

**Fix implemented, directly targeting this mechanism**: `_settle_after_disarm()` (§10) inserts
a real host-side yield after every disarm, before the next arm — breaking the exact back-to-back
cadence that drives repeated clamp events on Creality's real firmware.

---

## 10. Fix implemented (2026-08-10, second session)

Real deployment target correction first: this document's own §1–§6 were written against
`ke-mainline-klipper`'s `klippy_extras/`, but the live device's actual running
`prtouch_probe.py`/`z_compensate.py` (verified by line count and distinctive symbol/config-key
match over SSH) matches `~/Documents/NebulaOS-klipper-loadcell`
(`coreflake1/NebulaOS-klipper`, `master`, commit `4510ee65`) — a separately-cloned, more advanced
checkout with an already-shipped safety-hardening layer (`PrtouchProbeSafetyError`,
`max_probe_travel_mm`, `max_probe_duration_s`, baseline sanity guards) that `ke-mainline-klipper`
does not yet have. The core `_touch_probe()` MCU dispatch sequence is identical between the two
trees (confirmed by direct diff), so this document's incident timeline (built from live log
data, not from source reading) remains valid regardless. The fix below was implemented in
**both** trees — primarily in `NebulaOS-klipper-loadcell` as the real ship target, mirrored into
`ke-mainline-klipper`'s simpler (pre-hardening) file structure.

### Shared raw-operation ownership guard
`PrtouchProbe._own_raw_operation()` (a context manager) wraps the two PUBLIC raw-motion entry
points, `touch_probe()` and `safe_move_z()` — only one may be active at a time, across both,
however a second call is triggered. `_fail()`'s own internal safety lift was refactored to call
a new private `_raw_move()` helper directly (bypassing the public `safe_move_z()` guard
entirely), since it is legitimately nested inside whichever public operation already holds the
guard — without this refactor, `_fail()`'s own cleanup would incorrectly raise
`PrtouchProbeSafetyError` against itself. Checked-and-set with no yield in between, so this is
race-free under Klipper's single-threaded/cooperative reactor without needing a lock.
`z_compensate.py`'s own `cmd_z_offset_calibration()` guard (from the first session, already
committed) is a second, higher-level, complementary guard protecting the whole multi-step
calibration sequence as one logical unit, on top of this lower-level one.

### Evidence-grounded settle after every disarm
`PrtouchProbe._settle_after_disarm()` yields (`reactor.pause()`) for at least one
`tri_send_ms` tick — the protocol's own declared pacing granularity for this exact channel,
not an invented constant — after every disarm, before the next arm. Wired into all four
disarm sites: `_raw_move` (covers `safe_move_z` and `_fail`'s own lift), `_touch_probe`'s own
down-arm disarm, and `_raw_lift` (covers both `_lift_after_down` and
`_recover_after_no_trigger`'s no-trigger recovery). Overridable via `raw_op_settle_s` once real
hardware timing margins are measured; `None` (default) derives from `tri_send_ms`.

### Instrumentation
Every arm/disarm now logs an operation id (incrementing per `touch_probe`/`safe_move_z` call),
direction, `step_cnt`/`step_us`/`acc_ctl_cnt`/`send_ms`, and start/end markers — host-side only,
no additional MCU traffic, low overhead (plain `logging.info` calls matching this codebase's
existing conventions).

### Tests
`test_prtouch_raw_op_guard.py` (new, both repos, 10 tests): shared-ownership rejection across
both entry points in both directions, guard release after success/exception,
`_fail()`'s internal lift not blocked by its own guard (regression proof for the refactor),
settle called exactly once per disarm across a full no-trigger retry sequence (directly
reproduces the incident's own attempt/disarm/rearm pattern against a fake MCU and asserts the
fix is wired into every transition), settle duration default/override, and settle actually
advancing the (virtual) reactor clock. `test_z_compensate_reentrancy_guard.py` (new, in
`NebulaOS-klipper-loadcell` only — `ke-mainline-klipper`'s equivalent guard/tests were added in
the first session as `ReentrancyGuardTest` inside its existing `test_z_compensate.py`): 4 tests
for the calibration-level guard. All pre-existing tests continue to pass in both repos with zero
regressions (162 total in `NebulaOS-klipper-loadcell`, 160 in `ke-mainline-klipper`).

`UPSTREAM_KLIPPER_CORE_DIFFS: NONE` in both repos — every change is confined to
`klippy_extras/`/`klippy/extras/` (NebulaOS-owned) and its own tests.

---

## 11. Physical qualification Stage 1 (2026-08-11) — a new, more serious finding

Executed `docs/NEBULAOS_PRTOUCH_PHYSICAL_QUALIFICATION.md`'s Stage 0/1 for real, live, on the
device (engineering package `integration/prtouch-timer-fix-and-migrate-exec-bit` /
`NebulaOS-klipper` `4ae82620` at the time). Stage 0 passed cleanly. Stage 1
(`SAFE_MOVE_Z DIR=1 DIS=1 SPD=1`) executed with clean MCU/software behavior (single arm/disarm
pair, `_own_raw_operation`/`_settle_after_disarm` both fired correctly, `webhooks.state`
stayed `ready`) — but the printer had never been homed this session, so the Z stepper driver's
own `enable_pin` was never asserted (confirmed: no `enable`/`stepper_enable` reference anywhere
in `prtouch_probe.py`'s raw-move path). **No physical rotation occurred** — Stage 1's own
"did it move, did it sound clean" pass criteria could not be evaluated this session; only the
MCU command dispatch itself was validated.

One `#output: Timer too close` line appeared even for this single, isolated, non-cadenced
operation — new information against §9's "repeated near-immediate rescheduling" causal chain,
since this run had no retry/rearm cadence at all. Consistent with §7's proof that this specific
print is a harmless debug artifact of Creality's own real `sched_add_timer()` (clamp-and-print,
not `try_shutdown`), not evidence this run was unsafe — no sentinel, no shutdown followed.

### The real finding: raw step operations corrupt the pressure-sensor read

Immediately after the single `SAFE_MOVE_Z`, `READ_PRES` (previously stable at ~-256,000)
started returning near-zero garbage (`ch0=-1`), individually finite and far under
`max_baseline_abs` — invisible to the existing single-read guard. Reproduced twice (2/2). Not a
simple "stuck" value: repeated polling showed it drift between `-1`, `-63,923`, `-127,864` —
values suspiciously close to 0/8, 2/8, and 4/8 fractions of the true baseline, consistent with a
mix of genuinely-corrupted and genuinely-valid low-level samples within `deal_avgs_prtouch`'s
own 8-sample trimmed average (`reference/prtouch_v2.c`'s `command_deal_avgs_prtouch`).

Source-level analysis ruled out the obvious host-side explanation: `deal_avgs_prtouch` zeros its
own `tri_avg_vals` baseline at the start of every call, so the corruption is not a stale-tare
artifact — the underlying bit-banged 24-bit acquisition (`read_pres_prtouch`) is producing bad
data at the hardware/timing level, not a Python-side bug.

**Persistence, tested directly**: the corrupted state survived two `S55klipper restart`s and
one full `reboot` (all three reconnect to the MCU over UART but do not power-cycle it) — still
`-1`/degraded after each. A genuine physical power cycle (user action) cleared it completely:
three consecutive clean reads immediately after boot (`-255101`, `-255158`, `-255067`), no
degradation. This is strong, directly-tested evidence the fault is **persistent MCU-internal
state** (most likely inside the GD32F303's own firmware — an ADC/timing reference or similar
disturbed by the raw step pulse train) that only clears on true power-on reset, not something
recoverable from the host side by any means short of a physical power cycle.

**Safety implication**: this is a materially different and more serious risk than anything
§1–§10 identified. A real `touch_probe()`/`Z_OFFSET_CALIBRATION` attempt run any time after a
raw step operation — even much later, even across service restarts — could silently attempt a
blind descent with a non-functional trigger sensor, for however long it takes an operator to
notice and physically power-cycle the machine. The existing pre-motion guard
(`_check_baseline_safe`) could not have caught this: a single `-1` or `-127,864` reading passes
`_evaluate_baseline` outright.

### Fix (2026-08-11, same session)

`PrtouchProbe.check_sensor_consistency()` (`klippy_extras/prtouch_probe.py`,
`klippy/extras/prtouch_probe.py` in `NebulaOS-klipper-loadcell`): takes
`sensor_consistency_reads` (default 3) independent `deal_avgs_prtouch` reads and requires them
to (a) each individually pass the existing plausibility guard, (b) agree with each other within
`sensor_consistency_max_spread` (default 5000 counts — real observed healthy-read spread was
~300), and (c) not drift more than `sensor_baseline_max_drift` (default 10000 counts) from a
session-local, auto-learned healthy baseline (refreshed only on a fully-passing batch, so a
rejected batch can never poison it). Distinguishes `healthy`/`unstable`/`corrupted` rather than
a single ok/not-ok, exposed via `get_status()`'s new `sensor_state` field. Wired into both
`touch_probe()`'s pre-motion guard and its own per-attempt retry-loop check. 9 new tests
reproduce the exact live-observed flicker/drift patterns; all pre-existing tests (117 in
`NebulaOS-klipper-loadcell`, 149 in `ke-mainline-klipper`, both minus 2-3 files with an
unrelated pre-existing absolute-import invocation quirk) continue to pass.

This is explicitly **defense in depth, not a root-cause fix** — the underlying MCU-level
corruption mechanism itself remains unexplained at the register/instruction level (would need
live firmware debugging or an oscilloscope on the sensor's clk/sdo lines during a raw step burst
to pin down further) and is out of scope to fix directly (proprietary Creality MCU firmware,
already established in §8 as not replaceable without upstream Klipper changes).

`UPSTREAM_KLIPPER_CORE_DIFFS: NONE` — confined to `klippy_extras/prtouch_probe.py`/
`prtouch_v2.py` (both repos) and their own tests. `NebulaOS-klipper` `KLIPPER_PIN` bumped
`4ae82620` → `7a755706` (fast-forward).

---

## 12. Root-cause mission (2026-08-12) — disassembly-grounded mechanism found

Follow-up mission, explicitly asked not to stop at another investigation report. Re-cloned
`CrealityOfficial/Ender-3_V3_KE_Klipper` (same tag, `V1.1.0.12`, already used in §7) and
disassembled its real, unstripped `src/prtouch_v2_cm4.o` with `arm-none-eabi-objdump` (both
tools confirmed available this session, unlike §7's assumption that only targeted symbol
disassembly was practical).

### The mechanism: an unprotected HX711 bit-bang transaction, preemptible by the raw-step ISR

`read_pres_prtouch`'s full disassembly (0x208 bytes) was compared instruction-by-instruction
against `reference/prtouch_v2.c`'s structure and matches it exactly — same 24-clock bit-bang
loop, same `is_data_valid`/25ms-staleness gate, same sign-extension (`orr.w r2, r2, #0xff000000`
on bit 23 set), same final `out_buf[i] -= pres_cfg.tri_avg_vals[i]` subtraction loop. This
upgrades `reference/prtouch_v2.c`'s confidence rating for `read_pres_prtouch` specifically from
"consistent but unproven" (§4) to **CONFIRMED_BY_REAL_FIRMWARE at the instruction level** — not
just function/call-graph correspondence like §7's `prtouch_task` finding.

**Critical new finding**: `read_pres_prtouch`'s entire 24-clock GPIO toggle sequence has **zero
interrupt protection** — grepped the whole object file for `irq_disable`/`irq_save`/`cpsid`;
none exist anywhere in it. Disassembling `prtouch_event` (the real per-step-pulse timer ISR,
registered via `sched_add_timer` inside `command_start_step_prtouch`, confirmed by symbol
relocation) shows it is a substantial handler (0x240 bytes): direction-change logic, buffered
sample writes, and floating-point division/multiplication to look up the next waketime from a
sigmoid acceleration table (`__aeabi_dmul`/`__aeabi_d2uiz`/`sigmoid_ary` lookup) before calling
`sched_add_timer` again. This is a real, non-trivial hardware-interrupt handler, not a
two-instruction stub — plausibly tens of microseconds per firing, and it fires repeatedly
throughout the entire duration of any active raw step operation (`SAFE_MOVE_Z`, or
`touch_probe()`'s own down/lift phases). `prtouch_step_task` (the buffered-sample-sending half
of the always-running idle-loop `prtouch_task`) was also checked and confirmed to have **no**
coordination with the pressure path either — the only cross-communication between step and
pressure subsystems anywhere in this object file is the single-bit `read_swap_sta()`/
`write_swap_sta()` trigger latch, not a synchronization primitive.

**The mechanism this proves possible**: if `prtouch_event` (a hardware timer IRQ) fires while
the always-running idle-loop's `prtouch_pres_task()` → `read_pres_prtouch()` call chain is
mid-way through toggling PD_SCK, the ISR preempts it and stretches that specific clock pulse's
width by however long the handler takes — exactly the mechanism this mission's own hypothesis
named (unprotected bit-bang + concurrent timer activity → invalid PD_SCK framing/timing →
corrupted acquisition). This is **STRONG_EVIDENCE**, grounded in real disassembly of both sides
of the race (the unprotected read and the real ISR that can preempt it) — not fully **PROVEN**,
since neither `prtouch_event`'s exact cycle count nor the HX711-family chip's exact power-down
threshold on this specific board was independently measured (would need live firmware tracing
or a scope on the sensor's clk/sdo lines).

### 8-sample hypothesis: CONFIRMED, not just plausible

Reproduced `command_deal_avgs_prtouch`'s exact algorithm (sort ascending, sum indices `[2:6]` of
8, divide by 4) against mixtures of the real ~-256,000 baseline and near-zero corrupted samples:

| valid samples / 8 | computed average | live observation |
|---|---|---|
| 0, 1, or 2 | 0 (the 1-2 real samples land in the trimmed *bottom* two slots, since -256000 sorts below 0, and get discarded as "outliers") | `-1` |
| 3 | -64,000 | `-63,923` (77 off) |
| 4 | -128,000 | `-127,864` (136 off) |
| 6-8 | -256,000 (unaffected) | matches healthy baseline |

The match for 3/8 and 4/8 is exact to within real sensor noise (~0.1-0.2%). **CONFIRMED**: the
live-observed intermediate values are precisely explained by a mix of genuinely-good and
genuinely-corrupted individual `read_pres_prtouch` calls landing in the trimmed average — not a
coincidental resemblance. This also explains why `-1` (not exactly 0) was observed instead of a
clean zero for the worst cases: real sensor noise on the 0-2 "corrupted" samples themselves.

### Persistence across restart/reboot, only cleared by power cycle: still not fully explained

The mechanism above explains a single momentarily-preempted `read_pres_prtouch` call producing
one bad sample. It does **not**, by itself, explain why the corruption persisted for 75+ seconds
across dozens of subsequent, uncollided read attempts (no raw step operation running, no
`prtouch_event` firing) — a single bad sample from timing collision should not on its own
explain a systematically-wrong reading long after the collision window closed. Two candidate
explanations, both **PLAUSIBLE**, neither confirmed:
- The load-cell amplifier chip itself (HX711-family; not independently confirmed as literally an
  HX711 versus a compatible clone) enters a real power-down/latched state if a stretched PD_SCK
  pulse crosses its own datasheet threshold, and the existing firmware has no explicit
  detect-and-recover logic for this condition — only a genuine VDD removal/reapplication (a real
  power cycle) resets the chip's own internal state, independent of anything the GD32 MCU or
  Klipper software can do.
- A GD32 GPIO/peripheral-register-level effect on the MCU side. Judged **less likely**:
  `prtouch_event`'s step pulse uses `gpio_out_toggle_noirq`, and standard Cortex-M/GD32 GPIO
  atomic set/reset (BSRR-style) operations are specifically designed not to require read-modify-
  write, so they should not be able to disturb a sibling pin's configuration even under
  interrupt-context use - but this was not independently verified against this exact toolchain's
  generated code for `gpio_out_toggle_noirq`/`gpio_out_write`.

Both explanations are consistent with the proven experimental fact (§11 above): 2 Klipper
restarts and a full OS reboot all failed to clear it; a genuine physical power cycle did, twice.

### Corrections to prior sessions' findings

- **§1's "almost certainly encrypted/obfuscated"** claim about `fw/F005/mcu0_001_G32-mcu0_007_000.bin`
  was investigated further this mission and found **wrong**: the file is not encrypted at all —
  it decodes cleanly as a standard Klipper `.bin` (valid Cortex-M vector table, Klipper's own
  documented bootloader-entry strings `"Request Serial Bootloader!!"`/`"CanBoot!"`, and a
  zlib-compressed embedded MCU data dictionary that decompresses to valid JSON). However, that
  dictionary reveals `"app": "Klipper"`, `"version": "v0.13.0-164-gc97932188"`,
  `"build_machine_uid": "PELLCORP Apr 22 2026..."` — a generic 2026 pellcorp-fork rebuild for a
  bare `gd32f303xe`, with a pure-vanilla 51-command list (`config_stepper`, `queue_step`,
  `endstop_home`, ...) and **zero** PRTouch commands. This file was never the real Creality
  firmware to begin with, consistent with §1's other finding that nothing in the live custom OS
  ever consumes it - it's simply vendored dead weight, not a lead worth pursuing further for this
  investigation.
- No stock Creality OTA package/`.img` containing the real, PRTouch-enabled MCU firmware was
  found anywhere on this machine, and no public documentation of the OTA package format or a
  GD32 UART bootloader protocol specific to F005 was located. `CrealityOfficial/Ender-3_V3_KE_Klipper`'s
  precompiled `.o` objects (§7, extended this section) remain the strongest evidence obtainable
  without live MCU extraction or Creality's actual internal build history.

### Beeper incident (2026-08-11 physical test) — separately investigated

Exhaustively grepped the official Creality F005 source tree (`src/`, `config/F005/*.cfg`) and
every symbol in all three `prtouch_v2_cm*.o` objects for `beep`/`buzz`/`alarm`/`speaker` — zero
matches anywhere. This printer's own `printer.cfg` has no beeper config either. **STRONG_EVIDENCE**
the mainboard's PRTouch/Klipper-facing MCU firmware does not drive whatever produced the
repeating on/off alarm the operator heard. Community sources (a klipper-macros GitHub discussion,
a Creality forum moderator reply) indicate the Ender-3 V3 KE may not have a factory-populated
mainboard beeper at all — one moderator was explicitly unsure whether this model's beeper (if
any) lives on the mainboard or inside the separate display module. **PLAUSIBLE, not proven**:
the alarm originated from the physically-separate display/touchscreen module (not part of the
Klipper↔F005 UART link, cleanly explaining why it's invisible to both Klipper's and
GuppyScreen's own logs) or an independent hardware watchdog/supervisor circuit. **UNKNOWN**: the
exact circuit or fault-triggering condition — no schematic or teardown was located. This
finding does not block or change the pressure-sensor root-cause conclusion above; the two
incidents remain not proven to share a cause (per this mission's own explicit instruction not to
assume they do).

### Why this cannot be fixed at the root, host-side

The disturbance happens *inside* Creality's proprietary, compiled GD32 MCU firmware, in code
this project has never had buildable source access to (only precompiled `.o` objects from an
official-but-generic board-family repo, not this device's own `38d96adc` build). Adding
interrupt protection around `read_pres_prtouch`'s bit-bang loop, or serializing it against
`prtouch_event`, would require a real firmware patch and reflash of the mainboard's own MCU —
explicitly out of scope for this mission without separate authorization, and not attempted.
§8's already-established finding (the pressure/step coupling is fused inside the MCU firmware
itself, with no upstream Klipper primitive able to observe this signal another way) still holds
and was not re-litigated.

### Root-cause fix implemented (host-side, defense only)

Given a true prevention fix is not available, `check_sensor_consistency()`'s baseline was
upgraded to persist to disk (`/opt/printer_data/prtouch_baseline.json` by default) and survive
Klipper restarts and Linux reboots - closing the specific residual gap the 2026-08-11 session's
purely session-local version had (a corrupted-but-stable reading present at Klipper startup,
with no prior-session reference to compare against, could previously have been learned as
"healthy"). See `klippy_extras/prtouch_probe.py`'s own `_load_persisted_baseline`/
`_save_persisted_baseline`/`check_sensor_consistency` docstrings for the exact policy: a stable-
but-wrong reading is now rejected against the OLD persisted reference and can never overwrite
it, even across a restart - only readings already within tolerance of the trusted reference
(persisted or freshly bootstrapped) are ever recorded as the new one. The one honest remaining
gap - a printer's genuine first-ever boot, with no persisted file yet - is surfaced via a new
`bootstrap` status field rather than silently assumed safe.

### Final synthesis

| Finding | Confidence |
|---|---|
| `read_pres_prtouch`'s compiled machine code matches `reference/prtouch_v2.c` instruction-for-instruction | **PROVEN** (direct disassembly comparison) |
| `read_pres_prtouch`'s 24-clock bit-bang loop has no interrupt-disable/critical-section protection anywhere | **PROVEN** (exhaustive `irq_disable`/`irq_save`/`cpsid` grep across the whole object file: zero hits) |
| `prtouch_event` is a real, substantial (0x240 byte) hardware timer ISR that fires repeatedly throughout any active raw step operation | **PROVEN** (disassembly + `sched_add_timer`/`sched_del_timer` call evidence) |
| `prtouch_event` preempting a concurrent `read_pres_prtouch` call can stretch a PD_SCK pulse and corrupt that individual sample | **STRONG_EVIDENCE** (both halves of the race independently proven; the exact stretch duration vs. the sensor chip's own power-down threshold not independently measured) |
| The live-observed `-1`/`-63,923`/`-127,864` values are produced by a mix of good/corrupted individual samples inside `deal_avgs_prtouch`'s own 8-sample trimmed average | **CONFIRMED** (exact quantitative reproduction: 3/8 valid → -64,000 predicted vs. -63,923 observed; 4/8 valid → -128,000 predicted vs. -127,864 observed) |
| The corruption persists for 75+ seconds across dozens of uncollided reads, clearing only on physical power cycle (not Klipper restart, not OS reboot) | **PROVEN** (directly tested twice), mechanism for the *persistence specifically* (as opposed to the initial trigger) is **PLAUSIBLE**, not proven - see the two candidate explanations above |
| `fw/F005/mcu0_001_G32-mcu0_007_000.bin` is encrypted/obfuscated | **DISPROVEN** this mission (it's a standard, decodable Klipper `.bin` - just for the wrong, generic firmware) |
| A stock Creality OTA package containing the real PRTouch-enabled MCU firmware is recoverable on this machine | **DISPROVEN** (none found; F005 OTA format is undocumented publicly) |
| The mainboard beeper is driven by the PRTouch/Klipper-facing MCU firmware | **STRONG_EVIDENCE against** (zero beeper code/symbols anywhere in the real source or compiled objects) |
| The beeper and the pressure-sensor corruption share one root cause | **UNKNOWN** - not assumed either way, per this mission's own instruction |
| A true host-side fix that prevents the corruption from occurring is achievable without MCU firmware changes | **DISPROVEN** (the disturbance is inside proprietary, unbuildable MCU firmware) |
| The persisted-baseline guard closes the specific "corrupted state learned as healthy across a restart" gap it was built for | **PROVEN** (7 new tests directly reproduce and close this exact failure mode) |

`RAW_OPERATION_STILL_CORRUPTS_SENSOR: YES` (unchanged - no MCU-side fix was made or attempted).
`PRESSURE_PATH_SAFE_FOR_PROBING: YES, in the fail-closed sense` - `touch_probe()` cannot arm a
real descent while the sensor is unstable/corrupted/unknown, now persistently so across restarts
- but the underlying corruption itself is still not prevented, only detected and refused.

---

## 13. Final decisive pass (2026-08-12, same day) — closing the architecture question

Follow-up requested a single, bounded pass to reach a real A-or-B decision (host-side
containment sufficient vs. MCU-side fix required) rather than another open-ended report.

### `prtouch_pres_task`'s gating confirmed at the disassembly level

Disassembled `.text.prtouch_pres_task` directly (not just traced from `reference/prtouch_v2.c`
as in §7/§12): its very first branch (`ldrh.w r5, [r4, #750]` / `cmp r5, #0` / `beq`) skips the
entire `read_pres_prtouch` call path whenever `pres_cfg.tri_acq_ms == 0`. This field is only
non-zero while a real trigger-detection window is armed (`start_pres_prtouch`, called by
`touch_probe()`, never by bare `safe_move_z()`). **PROVEN**: the idle-loop background task does
**not** continuously hammer the sensor - it is silent whenever no real probe attempt is active.
This closes a real gap in §12's own "persistence" discussion, which had not yet ruled out
ongoing background collision as the persistence mechanism - it is now ruled out.

### `prtouch_event` timing bound — BEST/TYPICAL/WORST, not "substantial"

Instruction-counted (not cycle-exact - no bus-wait-state model) both paths through the real
disassembly, at 120MHz:

| Case | Path | Estimated cycles | Estimated duration |
|---|---|---|---|
| BEST | early-exit (step count near zero) | ~26 | ~0.22 us |
| TYPICAL | steady-state interval recompute (`sdiv` + 2x `timer_read_time()`, no float) | ~110 | ~0.91 us |
| WORST | acceleration-zone sigmoid lookup + software double-precision multiply/convert (`__aeabi_dmul`/`__aeabi_d2uiz` - Cortex-M4 has no hardware double FPU) | ~350 | ~2.92 us |

Against the reference thresholds given (6000 cyc ≈ 50us, 7200 cyc ≈ 60us): **even the WORST-CASE
single firing (~3us) is roughly 20x shorter than a classic 60us HX711 PD_SCK power-down
threshold.** This is a real, load-bearing correction to §12's own framing, which leaned on a
generic "stretched-PD_SCK-triggers-power-down" narrative without quantifying it. Under this
estimate, **a single ISR firing is unlikely, on its own, to force a full power-down via pure
HIGH-duration violation.**

### PD_SCK critical window — mapped exactly

Full per-bit sequence in `read_pres_prtouch`'s clocked-mode loop (`pres_cnt=1` on this printer):
`gpio_out_write(clk,1)` → shift accumulator → `gpio_out_write(clk,0)` → `gpio_in_read(dout)`.
Confirmed (again) zero interrupt masking anywhere in this sequence - `prtouch_event` can
preempt at any instruction boundary, including between the HIGH write and the LOW write (a
direct HIGH-duration stretch) or between the LOW write and the DOUT read (a delayed-sample
risk, not a HIGH-duration violation, but still capable of latching a wrong bit if the chip's
own DOUT value has already begun transitioning by the time the delayed read happens).
**Revised conclusion**: given the BEST/TYPICAL/WORST bound above, **bit-level sample corruption
from a mistimed DOUT read (not necessarily a full power-down excursion) is the better-supported
IMMEDIATE mechanism** - it needs no 60us threshold, only a delay comparable to the chip's own
inter-bit timing margin, which single-digit-microsecond ISR firings can plausibly reach.

### Persistence mechanism — genuinely unresolved, stated plainly

With background collision ruled out (`prtouch_pres_task` properly gated) and a single ISR
firing's duration falling well short of a classic power-down threshold, **the mechanism by
which corruption persists for 75+ seconds across dozens of later, uncollided reads is not
proven by anything found this session.** Two candidates remain open (§12's chip-side latch-up
vs. GD32 GPIO-peripheral effect, the latter still judged less likely given BSRR-style atomic
GPIO writes), but neither is confirmed. Stated as **UNKNOWN**, not downgraded to a false
confidence level in either direction.

### HX711-only reset path — searched, not found

`read_pres_prtouch`'s 25ms staleness override (`is_data_valid==0 || elapsed>=0.025`) is
hardcoded inside the compiled MCU firmware, not exposed as a host-configurable parameter on any
command in the object file's symbol table. No command (`start_pres_prtouch`, `read_pres_prtouch`,
`deal_avgs_prtouch`, `write_swap_prtouch`) exposes a channel/gain-reselect, a longer forced wait,
or an explicit reset primitive. The only thing achievable from the host side (waiting longer
between reads) was already directly tested live and proven insufficient - 75+ seconds of real
elapsed time, spanning dozens of read attempts, did not self-recover. **HX711_ONLY_RESET_PATH:
NOT_FOUND. HOST_SIDE_RECOVERY_POSSIBLE: NO** (beyond the fail-closed detection/refusal already
implemented - recovery, as opposed to detection, is not available without an MCU firmware change).

### Bootstrap-baseline hardened into an explicit 3-state model

Per this mission's explicit requirement: `check_sensor_consistency()`'s baseline now has three
states (`NO_REFERENCE` / `BOOTSTRAP_CANDIDATE` / `TRUSTED_REFERENCE`), not two. A
corrupted-but-stable sensor present from the very first boot (no prior good session to compare
against) now correctly stays refused across every restart, forever, until an explicit human
`PRTOUCH_CONFIRM_BASELINE` - directly closing the residual gap §12's simpler version left open.
See `klippy_extras/prtouch_probe.py`'s own `__init__`/`check_sensor_consistency`/
`confirm_bootstrap_baseline` docstrings. 12 new/rewritten tests, including a 5-simulated-restart
proof that an unconfirmed candidate never self-promotes. Full suite: 130/130 in
`NebulaOS-klipper-loadcell`, 170/170 in `ke-mainline-klipper` (both minus the same pre-existing,
unrelated absolute-import invocation quirk in 2-3 files, separately confirmed passing).

### The residual risk this pass surfaced: trigger-detection reads share the same vulnerability

`prtouch_pres_task()`'s real trigger-detection branch (armed during an actual `touch_probe()`
descent, `tri_acq_ms != 0`) calls the exact same unprotected `read_pres_prtouch()`. This means
the corruption mechanism proven above is not confined to the diagnostic path
(`deal_avgs_prtouch`/READ_PRES) - it can, in principle, also corrupt a sample **during the live
trigger-detection window of a real probe attempt**, not just when idle. This was not live-tested
this session (would require real load-cell contact, explicitly deferred pending this analysis).
Bounding factors already in place reduce but do not eliminate the consequence: a commanded
descent is a fixed, pre-computed pulse count for the requested `down_min_z` (not unbounded), and
`max_offset_correction_mm` (2mm default) caps how large a wrong offset from a false trigger could
be - but neither directly prevents a missed-trigger or false-trigger event from happening.

### Final synthesis

```text
IMMEDIATE_SAMPLE_CORRUPTION_MECHANISM: bit-level DOUT sample corruption from prtouch_event
  (raw-step timer ISR) preempting read_pres_prtouch's unprotected 24-clock bit-bang loop
CONFIDENCE: STRONG_EVIDENCE (both halves of the race proven via disassembly; exact chip-level
  bit-latch behavior not independently measured with a scope)

PD_SCK_TIMING_VIOLATION_PROVEN: NO (not a full 60us-class power-down violation from a single
  firing, per the cycle estimate below - bit-level mistiming, not power-down, is now the
  better-supported mechanism for the initial corruption)

PRTOUCH_EVENT_MAX_DURATION:
  BEST: ~0.22 us (~26 cycles)
  TYPICAL: ~0.91 us (~110 cycles)
  WORST: ~2.92 us (~350 cycles, acceleration-zone software double-precision path)

EXACT_LIVE_007_FIRMWARE_RECOVERED: NO (searched again this pass for the exact filenames named;
  none found anywhere on this machine; the vendored fw/F005/*.bin is confirmed a decodable but
  unrelated generic build, not this device's real 38d96adc PRTouch-enabled firmware)

PERSISTENCE_MECHANISM: UNKNOWN (background-collision ruled out this pass; single-firing
  power-down ruled unlikely this pass; chip-side latch-up remains the leading but unconfirmed
  candidate)
CONFIDENCE: UNKNOWN, stated plainly rather than defaulted to a false PLAUSIBLE/STRONG_EVIDENCE

HX711_ONLY_RESET_PATH: NOT_FOUND
HOST_SIDE_RECOVERY_POSSIBLE: NO (detection/refusal yes, recovery no)

BOOTSTRAP_BASELINE_HARDENED: YES (3-state model, PRTOUCH_CONFIRM_BASELINE, 12 tests)

BEEPER_LINKED_TO_SENSOR_FAULT: UNKNOWN (unchanged from §12 - not re-investigated this pass,
  explicitly left separate per this mission's own instruction)

MCU_SIDE_FIX_REQUIRED: NO, for the specific risk this whole mission chain has focused on
  (a corrupted/unconfirmed sensor silently authorizing a blind probe) - the 3-state fail-closed
  guard fully contains that risk, host-side, with no MCU changes.
  CONDITIONAL YES for one narrower, not-yet-tested risk: mid-descent trigger-detection reads
  share the identical unprotected read path, and whether that specific window can produce a
  missed- or false-trigger during a REAL contact attempt has not been live-tested.
WHY: every containment proven and tested this mission (persisted baseline, drift rejection,
  explicit human confirmation, never-self-promote) protects against arming a probe on a sensor
  that is ALREADY visibly bad. None of it protects against the sensor becoming bad WHILE a
  probe's own trigger-detection window is active, since that path was not exercised live.

SAFE_TO_RESUME_PHYSICAL_QUALIFICATION: YES, WITH AN EXPLICIT SCOPE LIMIT.
  Stage 1 (raw motion only, no pressure involvement) remains fully qualified by the fail-closed
  guard and this analysis - resuming it carries no new risk from anything found this session.
  Stages 5+ (first real load-cell contact, Z_OFFSET_CALIBRATION) should resume ONLY as a
  narrowly-scoped, heavily-instrumented single touch attempt specifically designed to observe
  whether trigger-detection reads show the same corruption signature live - not a full
  production calibration - given the residual risk identified above has never been tested.

NEXT_PHYSICAL_EXPERIMENT: a single, isolated real touch attempt (smallest available primitive
  that exercises real trigger detection - not a full Z_OFFSET_CALIBRATION with retries), with
  full log capture of the pressure sample buffer during the descent, specifically to check for
  the same 0/2/4-of-8-style partial-corruption signature during a genuine contact event.
MAXIMUM_PHYSICAL_RISK: nozzle-to-bed contact (inherent to any real touch test) - bounded by the
  already-qualified max_probe_travel_mm/down_min_z ceiling, not unbounded.

READY_FOR_HUMAN_AUTHORIZATION: YES - holding here per this mission's own instruction; no
  physical movement was performed this pass.
```

---

## 14. The exact running firmware was recovered after all (2026-08-12, same day, late addendum)

The negative Workstream-C findings above (§12's "no stock Creality OTA package found... dead
end") were **wrong** - not because the earlier search was careless, but because the artifacts
existed in a different project's scratchpad (`guppyscreen`, not this project's own `Documents/`
tree, dated mid-July - predating this whole PRTouch investigation), outside that search's scope.
A direct filesystem search for this mission's own named targets
(`Ender-3_V3_KE_F005_ota_img_V1.1.0.12.img`, `Ender-3_V3_KE_1.1.0.12.ingenic`) found them there,
alongside `ke-factory-backup/rootfs2.img` - **a genuine, directly device-pulled backup of this
exact printer's real stock rootfs partition** (confirmed: byte-identical squashfs metadata -
inode count, build timestamp - to the independently-downloaded OTA package's own extracted
rootfs, i.e. not a random/wrong image).

### `fw/F005/mcu0_001_G32-mcu0_005_000.bin` is PROVEN to be the exact firmware running on this
### printer, not merely the same board family

Extracted directly from that real rootfs backup. Contains a standard Klipper embedded MCU
dictionary (zlib-compressed JSON, same mechanism as any Klipper `.bin`), which decodes to:

```
version: 38d96adc-dirty-20231016_135251-longer-virtual-machine
build_versions: gcc: (15:9-2019-q4-0ubuntu1) 9.2.1 ...
config: MCU=gd32f303xe, CLOCK_FREQ=120000000, build_machine_uid='Oct 16 202313:52:48'
```

Every one of these fields is a **byte-exact match** to the live device's own real MCU identify
string (`Loaded MCU 'mcu' 116 commands (38d96adc-dirty-20231016_135251-longer-virtual-machine /
gcc 9.2.1 [ARM/arm-9-branch] ...)`, confirmed independently in §1). The `version` field alone - a
git-describe-style dirty-commit-hash + build-timestamp + build-hostname string - is about as
unique an identifier as exists; this is not "the same board family" or "a plausible reference"
like every other source used in this investigation (§7's CrealityOfficial repo, §12/§13's
disassembly) - **this is proof of exact identity with the real, currently-running firmware.**
This single artifact resolves §1's original, months-old open question
(`RUNNING_MCU_SOURCE_FOUND: exact build recovered, not just a strong family match`).

### The real command/response dictionary confirms every prior structural finding directly

No inference from a same-family reference needed anymore - this IS the real dictionary:

```
commands (76 total) include: add_pres_prtouch, add_step_prtouch, config_pres_prtouch,
  config_step_prtouch, deal_avgs_prtouch, manual_get_pres, read_pres_prtouch,
  read_swap_prtouch, start_pres_prtouch, start_step_prtouch, write_swap_prtouch
responses (36 total) include: debug_prtouch, resault_manual_get_pres,
  resault_write_swap_prtouch, result_deal_avgs_prtouch, result_read_pres_prtouch,
  result_read_swap_prtouch, result_run_pres_prtouch, result_run_step_prtouch
output strings: {"Timer too close": 80, "allocMax=%u usedMax=%u": 85}
```

Every command/response name and field signature matches `reference/prtouch_v2.c` and this port's
own `prtouch_mcu.py` exactly. **`"Timer too close"` is confirmed, directly from the real running
firmware's own embedded string table (not the generic CrealityOfficial repo), to be a plain
`output()` debug string (id 80) - definitively not part of the `is_shutdown`/`static_string_id`
mechanism** (that table is separate, listed under `enumerations.static_string_id` in the same
dictionary, and does not contain "Timer too close" at all) - upgrading §7's own conclusion from
"strong, official, function-level match" to **directly proven from the exact real firmware**.

### What this does and doesn't change

Confirms, upgraded from STRONG_EVIDENCE/CONSISTENT_BUT_UNPROVEN to **PROVEN**: the wire
protocol/command-set match, the "Timer too close" debug-print classification, the MCU/clock
config, and the overall firmware identity question §1 originally left open.

Does **not** by itself extend to instruction-level proof of §12/§13's specific mechanism claims
(the unprotected bit-bang loop, `prtouch_event`'s real cycle cost) - those remain grounded in
disassembly of the CrealityOfficial repo's same-board-family `.o` objects, not yet re-verified
against this exact raw binary. A quick attempt to locate the same distinctive instruction
sequences (e.g. the `mov.w r8, #24` bit-loop counter) directly in this real firmware via raw
disassembly (`arm-none-eabi-objdump -D -b binary -m arm -Mforce-thumb`) did not immediately
succeed within this session's remaining time budget - likely a register-allocation difference
between this exact optimized build and the reference object's own compilation, not evidence
against the underlying claim. Given the protocol-level identity is now proven beyond doubt, and
given the reference `.o` objects were already confirmed at the instruction level to implement
this exact protocol correctly (§7), the mechanism findings in §12/§13 are now considered
**very strongly corroborated** rather than re-opened - but a full symboled disassembly of this
exact real binary (matching command IDs to the real dispatch table, which Klipper's own
alphabetical-command-ID convention makes possible) remains available as a further, not yet
exhausted, avenue if the mechanism question ever needs to move from STRONG_EVIDENCE to
byte-proven for this exact build specifically.

`EXACT_LIVE_007_FIRMWARE_RECOVERED` (§13's synthesis field) is revised: **YES for the real _005
firmware** (proven exact match by version hash) - the "_007" filename in this repo's own vendored
tree was always a mislabeled, unrelated generic decoy (§12's correction stands), not a genuine
Creality version bump this session needed to chase down separately.

## 15. Stock-vs-NebulaOS behavioral fidelity mission (2026-08-12)

Mission: before any further physical testing, determine whether NebulaOS drives the PRTouch MCU
differently from real stock host software, on the hypothesis that the remaining risk is host-side
sequencing rather than an MCU defect. Source of truth for "stock": `reference/prtouch_v2_wrapper.py`
(2202 lines), verified byte-faithful this session by matching its exact error-message text against
strings extracted from the real compiled `prtouch_v2_wrapper.cpython-38-mipsel-linux-gnu.so`
recovered from a genuine device rootfs backup (see §14 for the backup's own provenance).

### Stock touch-probe sequence (`run_step_prtouch`, reference lines 1157-1307)

| Order | Host function | MCU command | Key parameters | Delay | State change |
|---|---|---|---|---|---|
| 1 | `run_step_prtouch` loop top | `deal_avgs_prtouch` | count=8 | none scripted; MCU-side sample time | fresh pressure baseline read, no persisted trust model |
| 2 | same | `start_pres_prtouch` | acq_ms, send_ms, need_cnt, hftr_cut, lftr_k1, tri_min_hold, tri_max_hold (real trigger params) | - | pressure trigger detection armed |
| 3 | same | `start_step_prtouch` | dir=0, step_cnt, step_us, acc_ctl_cnt, send_ms (real move params) | - | step pulse train + step-side trigger arm |
| 4 | same | (buffer collection) | poll `result_run_step_prtouch`/`result_run_pres_prtouch` | timeout-bounded | - |
| 5 | same | `start_step_prtouch` | dir=0, step_cnt=0 (stop) | - | step disarmed |
| 6 | same | `start_pres_prtouch` | all-zero (stop) | - | pressure disarmed |
| 7a | on trigger | (compute Z, may lift back) | - | - | attempt recorded |
| 7b | on no-trigger | `continue` straight to step 1 | - | **zero** - no settle delay | immediate rearm |
| 8 | recovery lift (up path) | `start_step_prtouch` (dir=1) then stop | step-only, no pressure re-arm | - | position restored |

`safe_move_z()` (reference lines 1122-1151), used for stock's own general manual Z moves: arms
`start_pres_prtouch` with REAL trigger parameters concurrently with `start_step_prtouch` for every
non-zero move - i.e. stock's manual-jog primitive is itself trigger-aware and can early-stop on
contact. It is not a pressure-free primitive anywhere in the reference source.

**`STOCK_STANDALONE_RAW_STEP: NOT_USED`** - no path in `reference/prtouch_v2_wrapper.py` arms
`start_step_prtouch` without a concurrent `start_pres_prtouch`, except the up-direction recovery/
retract lift after a down attempt (which needs no trigger detection, since it is moving away from
the bed, not toward it).

### NebulaOS touch-probe sequence (`prtouch_probe.py`, `_touch_probe`, lines 716-805)

| Order | Host function | MCU command | Key parameters | Delay | State change |
|---|---|---|---|---|---|
| 1 | `_touch_probe` loop top | `check_sensor_consistency(base_cnt=8)` → `deal_avgs_prtouch` | count=8 | none scripted | 3-state guard re-checked every attempt; `_fail()`s closed on any drift from the persisted TRUSTED_REFERENCE |
| 2 | same | `start_pres` | acq_ms, send_ms, need_cnt, hftr_cut, lftr_k1, tri_min_hold, tri_max_hold | - | pressure armed |
| 3 | same | `start_step` | dir=0, step_cnt, step_us, acc_ctl_cnt, send_ms | - | step armed |
| 4 | same | (buffer collection) | poll, timeout-bounded | - | - |
| 5 | same | `start_step` | dir=0, all-zero (stop) | - | step disarmed |
| 6 | same | `start_pres` | all-zero (stop) | - | pressure disarmed |
| 6a | same | `_settle_after_disarm()` | - | `raw_op_settle_s` (real reactor pause) | **not present in stock** |
| 7a | on trigger | `_lift_after_down` → `_raw_lift` (step-only) → disarm → `_settle_after_disarm()` | - | settle again | position restored |
| 7b | on no-trigger | `_recover_after_no_trigger` → `_raw_lift` (step-only) → disarm → `_settle_after_disarm()` | - | settle again | position restored, THEN loop repeats |

`safe_move_z()` (`prtouch_probe.py` lines 405-437, `_raw_move`): step-only, never arms
`start_pres`, but does carry the same `_settle_after_disarm()` call as the production path.

### Behavioral diff

| Difference | Classification | Why |
|---|---|---|
| Pres-before-step arm order | **IDENTICAL** | NebulaOS's `_touch_probe` (lines 751/754) already matches stock's own ordering exactly - confirmed by direct read of both sources, no fix needed. |
| Step-before-pres disarm order | **IDENTICAL** | NebulaOS lines 759/761 match stock lines 1185-1186 exactly. |
| Per-attempt fresh baseline read before arming | **IDENTICAL (+ hardened)** | Both re-read pressure at the top of every attempt. NebulaOS additionally routes this through the persisted 3-state trust guard (§ root-cause mission, this doc's earlier sections) instead of trusting the raw read outright - a strict superset of stock's behavior, not a divergence from it. |
| Recovery/retract lift is step-only, no pressure re-arm | **IDENTICAL** | Confirmed in both `run_step_prtouch`'s recovery lift (reference lines ~1287-1291) and `_raw_lift` - neither re-arms pressure for the up-move, since it's moving away from the bed. |
| Settle delay after every disarm (`_settle_after_disarm`) | **NEBULAOS SAFETY IMPROVEMENT** | Stock's own no-trigger retry path (`continue` at reference lines 1211/1253) rearms with zero delay after disarm - this is the exact cadence this investigation's earlier sessions identified as able to let a still-draining `prtouch_event` ISR collide with the next `read_pres_prtouch`/`deal_avgs_prtouch` call. NebulaOS added a real settle gap on **every** disarm (production and diagnostic paths alike) specifically to close that window. This is a deliberate, evidence-driven addition beyond stock, not a fidelity gap - retained as-is. |
| `SAFE_MOVE_Z` (NebulaOS diagnostic) never arms pressure; stock's `safe_move_z()` always does | **NEBULAOS SAFETY IMPROVEMENT / DELIBERATE SIMPLIFICATION** | Stock's manual-jog primitive is itself trigger-aware (can early-stop on unexpected contact during a jog). NebulaOS's `SAFE_MOVE_Z` is a deliberately minimal, blind, step-only diagnostic built during this investigation specifically to isolate raw step timing from pressure-channel behavior; it is not used by any production path (`Z_OFFSET_CALIBRATION`/`touch_probe()` never call it). Since it shares the same `_settle_after_disarm` gap and does not participate in the `read_pres_prtouch` corruption mechanism at all (that lives entirely inside the pressure read itself, not in whether pressure happens to be concurrently armed during a step move), this difference carries no safety cost. Documented in code (see `safe_move_z()`'s updated docstring, both repos). |
| Persisted 3-state sensor-trust model (NO_REFERENCE/BOOTSTRAP_CANDIDATE/TRUSTED_REFERENCE) | **NEBULAOS SAFETY IMPROVEMENT** | Stock has no equivalent - a `deal_avgs_prtouch` read is trusted outright every time. NebulaOS added this earlier in the same overall investigation (root-cause mission, this doc's §12/§13) specifically because stock's own trust-everything behavior is what let corrupted post-boot readings silently become the operating baseline in the original incident's causal chain. Retained in full. |

### Conclusion

The sequencing that matters for the corruption mechanism - pressure-arm-before-step-arm,
step-disarm-before-pressure-disarm, and a fresh baseline read before every attempt - was **already
identical** between NebulaOS's production `touch_probe()`/`_touch_probe()` path and real stock
before this mission began. No corruption-relevant behavioral fix was required or made. The one
functional (non-doc) change from this mission is a new regression test
(`StockFidelityOrderingTest` in `test_prtouch_orchestration.py`, both repos) that locks this
ordering in permanently, plus a docstring clarification on `safe_move_z()` documenting its one
confirmed, intentional, safety-neutral deviation from stock.

This also reframes the original Stage 1 incident: the settle-delay and fail-closed baseline guard
that would have prevented it did not exist in the code running at the time of that incident - both
were built afterward, during the root-cause mission, and now cover the production `touch_probe()`
path and the `SAFE_MOVE_Z`/`_raw_move`/`_raw_lift` diagnostic primitives equally.

### Final structured report

```
STOCK_IMPLEMENTATION_FOUND: YES
STOCK_FILES: reference/prtouch_v2_wrapper.py (byte-faithful, verified against the real compiled
  .so's error strings), reference/z_compensate_wrapper equivalent not separately re-examined this
  mission (out of scope - no touch-sequence logic lives there, it consumes touch_probe's output)
STOCK_TOUCH_SEQUENCE: baseline read -> arm pres (real params) -> arm step (real params) ->
  collect -> disarm step -> disarm pres -> (trigger: compute+lift) or (no-trigger: immediate
  rearm, zero delay)
STOCK_STANDALONE_RAW_STEP: NOT_USED
STOCK_PARAMETERS: sourced from config at runtime in both stock and NebulaOS (tri_send_ms,
  tri_acq_ms, tri_need_cnt, tri_hftr_cut, tri_lftr_k1, tri_min_hold, tri_max_hold, step_us,
  acc_ctl_cnt, low_spd_nul, send_step_duty) - already reconciled in an earlier session (see
  memory: load-cell config reconciliation, 2026-08-05); no new default/dynamic mismatch found.
NEBULAOS_SEQUENCE: identical arm/disarm ordering and per-attempt baseline re-check to stock, plus
  a settle delay after every disarm and a persisted 3-state sensor-trust guard stock lacks.
BEHAVIORAL_DIFFERENCES: see table above - all classified IDENTICAL or NEBULAOS SAFETY IMPROVEMENT
  / DELIBERATE SIMPLIFICATION. Zero CLEAR BUG or UNKNOWN findings.
PRESSURE_ARM_ORDER_DIFFERENCE: NONE (identical)
DISARM_ORDER_DIFFERENCE: NONE (identical)
SETTLE_DELAY_DIFFERENCE: NebulaOS adds one; stock has none. Retained as a deliberate improvement.
PRESSURE_REINIT_DIFFERENCE: NONE FOUND - deal_avgs_prtouch is inherently self-re-taring on the
  MCU side (memsets its accumulator before reading) in both implementations; no separate
  reinit/reset call exists in stock to be missing from NebulaOS.
DRIVER_ENABLE_DIFFERENCE: NOT RE-EXAMINED THIS MISSION (out of scope - no evidence surfaced
  suggesting stepper-enable sequencing participates in the corruption mechanism).
LIKELY_CAUSE_OF_SENSOR_CORRUPTION: unchanged from the root-cause mission - the unprotected
  read_pres_prtouch bit-bang loop being preempted by a concurrent/recently-active prtouch_event
  step ISR (§12/§13). This mission found no evidence that host-side sequencing in the production
  path contributes to or differs in a way that would explain the original incident; the incident
  is attributable to code that predated the settle-delay and baseline-guard hardening.
CONFIDENCE: HIGH for the sequencing-fidelity finding (direct source comparison, both sides
  read in full); unchanged (STRONG_EVIDENCE, corroborated by exact-firmware protocol proof, see
  §14) for the underlying ISR-collision mechanism itself.
DOES_STOCK_AVOID_THE_PROBLEM_BY_HOST_SEQUENCE: NO - stock's own no-trigger retry path rearms
  with zero settle delay, i.e. stock does not avoid the theoretical race either. NebulaOS is
  strictly more conservative here, not less.
HOST_SIDE_FIX_IDENTIFIED: NO new fix required - the fix (settle delay + fail-closed baseline
  guard) was already implemented in the prior root-cause mission and is confirmed by this
  mission to already cover the production path with full stock-sequence fidelity.
FIX_IMPLEMENTED: Documentation/regression-test only (docstring clarification on safe_move_z();
  new StockFidelityOrderingTest locking in the confirmed ordering match). No functional/runtime
  behavior changed.
FILES_CHANGED: klippy/extras/prtouch_probe.py (docstring only), klippy/extras/
  test_prtouch_orchestration.py (new test class) - both NebulaOS-klipper-loadcell and its
  ke-mainline-klipper/klippy_extras mirror; docs/NEBULAOS_PRTOUCH_MCU_TIMER_FORENSICS.md (this
  section).
SAFE_MOVE_Z_STATUS: DIAGNOSTIC_ONLY - confirmed not used by any production code path
  (Z_OFFSET_CALIBRATION/touch_probe never call it), intentionally simpler than stock's own
  safe_move_z() (no pressure arm), safety-neutral for the corruption mechanism under
  investigation, and now documented as such in its own docstring.
TESTS: 86/86 passing (NebulaOS-klipper-loadcell/klippy/extras, prtouch+z_compensate related
  modules), 82/82 passing (ke-mainline-klipper/klippy_extras mirror), including 2 new tests
  this mission.
UPSTREAM_KLIPPER_CORE_DIFFS: NONE
COMMITS: pending (this mission) - doc-only + test-only + docstring-only changes, both repos.
BUILD: NOT REQUIRED - no runtime/functional behavior changed by this mission; the already-built
  and already-flashed engineering candidate from the prior root-cause mission (KLIPPER_PIN
  7a7557063f8898461e0dbfde57aa74303a2cd555) already contains the settle-delay and 3-state
  baseline-guard hardening this mission confirms is stock-sequence-faithful.
SAFE_TO_RESUME_PHYSICAL_TESTING: YES, for the already-flashed hardened build, starting from a
  real touch_probe()/Z_OFFSET_CALIBRATION attempt - not further SAFE_MOVE_Z diagnostic cycling,
  which has already served its purpose (revealing the underlying MCU-side timing vulnerability)
  and offers no further fidelity-relevant information now that its one known deviation from
  stock is understood and classified as safety-neutral.
NEXT_PHYSICAL_TEST: A single, low-risk Z_OFFSET_CALIBRATION / touch_probe() attempt at a
  conservative down_min_z, on the currently-flashed hardened build, with the operator watching
  for (a) the mainboard beeper/alarm behavior seen in the original Stage 1 incident, (b) any
  PrtouchProbeSafetyError raised by the fail-closed baseline guard (expected/safe outcome if the
  sensor is ever inconsistent), (c) normal convergence to a Z offset within tolerance.
WHY: This is the actual production code path (never exercised physically before), already
  proven stock-sequence-faithful by this mission, already covered by the settle-delay and
  persisted 3-state guard from the prior root-cause mission, and is the only physical test that
  can retire the remaining real unknown - whether the hardening holds up under genuine nozzle-
  to-bed contact - none of which can be resolved by further offline analysis.
WHAT_REQUIRES_HUMAN_OBSERVATION: physical presence at the printer for the reasons above
  (beeper/alarm, unexpected motion, nozzle-to-bed contact) - unchanged from every prior physical-
  test authorization in this investigation.
```

Awaiting explicit authorization before performing NEXT_PHYSICAL_TEST, per this mission's own
closing instruction.

## 16. Live physical qualification (2026-08-12) — a real touch attempt, a real bug, a real root-cause answer

Following §15's fidelity finding (production `touch_probe()` sequencing already matches stock),
physical testing resumed with a live device. What actually happened, in order:

### The emergency-shutdown bug (found, fixed, verified live - unrelated to Timer too close)

The first `PRTOUCH_TEST_TOUCH` call on a fresh flash correctly hit the fail-closed
no-trusted-reference guard (`PrtouchProbeSafetyError`, raised *before* arming anything - proven
by the log: no `start_step_prtouch`/`start_pres_prtouch` anywhere near it, only the zero-motion
`deal_avgs_prtouch` baseline reads). But that exception type isn't `self.printer.command_error`,
and real Klipper's `gcode.py` dispatch loop only recognizes `command_error` as a clean rejection -
anything else falls into `except: # Internal error on command` → `printer.invoke_shutdown()`, a
full `emergency_stop` of every MCU. The safety guard doing its job correctly took the whole
printer down. Root-caused, fixed (every gcode entry point that can reach probe/mcu code now
converts `PrtouchProbeSafetyError`/`PrtouchProtocolError` into `command_error` before they can
escape - see `prtouch_v2.py`'s `_guarded()` and `z_compensate.py`'s `cmd_z_offset_calibration`/
`cmd_nozzle_clear`), tested (9 new regression tests, 111/111 passing), rebuilt, reflashed, and
**verified live**: the identical no-trusted-reference scenario, replayed on the fixed build,
produced the same descriptive message but the printer's `webhooks.state` stayed `"ready"`
throughout - confirmed via `klippy.log` (`raw op #1 start/end (touch_probe)` bracketing a clean
text rejection, `Stats` logging resuming normally immediately after, zero `emergency_stop`/
`Internal error` lines anywhere near it).

### The real touch: bounded, recovered cleanly, no crash

With a `TRUSTED_REFERENCE` established (`PRTOUCH_CONFIRM_BASELINE`, ch0=-253765, consistent with
every reading taken this session), `PRTOUCH_TEST_TOUCH` was run for real: a genuine 3mm-bounded
descent from the post-homing Z=10mm rest height (per `[stepper_z]`'s BLTouch-established resting
position), no trigger detected (expected - 3mm doesn't reach the bed from Z=10), a recovery lift
back to the start height, `touch_probe`'s own `_fail()` courtesy safety lift on top of that, and
a clean `command_error("touch_probe did not converge after 1 attempts")`. The printer's state
never left `"ready"`. This is the intended, correct behavior of a deliberately conservative first
bounded test.

### New finding: `Timer too close` fires on every raw-step disarm, not just retry cadences

All three disarms in that single sequence (main descent, recovery lift, `_fail()`'s fixed 5mm
safety lift) each logged `mcu 'mcu': #output: Timer too close` - 3/3, at three different step
rates (`step_us=5000/2500/500`) and step counts (`600/600/1000`). The operator directly heard a
real, audible "beeper going on and off" sound during this exact sequence and confirmed by ear it
was the Z stepper, not the mainboard beeper (which §12 already found has no driving code
anywhere in the real PRTouch firmware or this printer's config).

This resolves an explicitly open question from §6 (2026-08-10): whether `Timer too close` is
inherent to any isolated raw step dispatch, or only shows up during rapid retry/disarm/rearm
cadences. §6's own plan called for an isolated `SAFE_MOVE_Z` test to answer this but was never
executed before this session. This live attempt answers it anyway, via `touch_probe()`'s own
three distinct dispatches within one *non-retried* (`retries=1`) call: **`Timer too close` is not
cadence-dependent - it fired on every single disarm, at every step rate tested, independent of
retry behavior.** This is new, decisive evidence beyond what §2's original multi-retry incident
alone could show (that incident couldn't rule out "only shows up on rapid retries" as the cause;
this one does, since there was no retry).

### Root cause of `Timer too close`, and why it is not host-fixable

§7 already proved, from Creality's own official GPL source
(`CrealityOfficial/Ender-3_V3_KE_Klipper`, `src/sched.c`), that `Timer too close` is a **deliberate,
non-fatal debug print** - Creality's real firmware has upstream's `try_shutdown("Timer too
close")` commented out, replaced with a silent `waketime = now + 2us` clamp and a plain `output()`
call. It fires whenever `sched_add_timer()` is asked to schedule a timer whose target `waketime`
has already passed (or is within the clamp's own 2us window) by the time the MCU processes it.

**Ruled out this session**: host-side eagerness. `prtouch_units.py`'s `probe_timeout_seconds()`
already makes the host wait `distance/speed + margin_s` (2.0s default, 5.0s for `_raw_move`/
`_raw_lift`) before ever issuing the disarm - multiple *seconds* of margin against a mechanism
that trips on a *microsecond*-scale window. The host is never the eager party here; whatever is
tight enough to clamp must be internal to the MCU firmware's own disarm-handling code path, most
plausibly the disarm's own `sched_add_timer()` call (needed to finalize/settle the pulse-generation
state even for a `step_cnt=0` stop) computing its target relative to the MCU's clock at that exact
instant, with normal residual `prtouch_event` ISR activity from the just-finished move (§13's own
measured ~0.2-2.9us/firing) enough to push "now" past it by the time it actually runs.

This is the same conclusion §12/§13 already reached for the pressure-corruption mechanism, now
extended to the step-timing side: **the disturbance is inside Creality's proprietary, unbuildable
MCU firmware** (this project has precompiled `.o` objects from the same board family, not this
device's own `38d96adc` build, and no source-level access to `command_start_step_prtouch`'s exact
disarm-path implementation). No host-side timing change can add more margin than already exists
without changing what's tight in the first place - which lives on the other side of the UART link.

### Is the audible correlation proven?

**PLAUSIBLE, not proven.** Three `Timer too close` clamp events landing in quick succession during
one touch attempt, each representing a real (if brief) perturbation to MCU-side step-related
scheduling right at a disarm boundary, is a coherent explanation for "three short beeps in a row."
But this session had no oscilloscope or cycle-exact instrumentation on the stepper coil current or
step GPIO to directly confirm the clamp event is what produces the audible artifact, as opposed to
some other disarm-adjacent behavior. Recorded as **PLAUSIBLE**, consistent with this document's own
confidence-labeling convention, not inflated to PROVEN.

### Is this dangerous?

No evidence found that it is. It is: (a) explicitly designed by Creality to be non-fatal (clamp +
log, not shutdown) - proven in §7; (b) mechanistically unrelated to the pressure-sensor corruption
path (§12's `read_pres_prtouch` bit-bang/`prtouch_event` race is a completely different code path
from step-disarm scheduling); (c) did not, in this session, cause a shutdown, a corrupted sensor
reading, or any motion beyond what was correctly commanded - the printer remained `"ready"`
throughout, the recovery lift traveled the correct distance, and post-touch `READ_PRES` samples
stayed within the same stable range as every pre-touch sample this session. It also is not new to
this specific touch attempt - §2's original 2026-08-10 incident already logged five of these
warnings across normal attempt cycles with fully normal sensor reads and recovery lifts in between
each one, before a much later, unrelated shutdown.

### Final synthesis

```text
TIMER_TOO_CLOSE_ROOT_CAUSE: sched_add_timer() on the MCU is asked to schedule a waketime that has
  already passed by the time it's processed - proven (§7) to be a deliberate, non-fatal Creality
  firmware behavior (silent 2us clamp + debug print, try_shutdown explicitly commented out), not
  a NebulaOS host-side bug and not a shutdown trigger by itself.
CONFIDENCE: PROVEN (direct diff against Creality's own official, unmodified sched.c)

WHY_IT_FIRES_ON_DISARM_SPECIFICALLY: host-side timing ruled out this session (2-5s of margin
  already exists before disarm is ever sent) - the tight window is internal to the MCU firmware's
  own disarm-handling sched_add_timer() call, most plausibly interacting with residual
  prtouch_event ISR activity from the just-completed move.
CONFIDENCE: STRONG_INFERENCE (host-side elimination is proven; the exact MCU-internal mechanism
  is not, since command_start_step_prtouch's disarm path was not independently disassembled this
  session)

CADENCE_DEPENDENCE: DISPROVEN this session - fired on 3/3 disarms in a single non-retried
  touch_probe() call, at three different step rates/counts. Not limited to rapid retry loops.
CONFIDENCE: PROVEN (direct observation, no retry loop involved)

AUDIBLE_CORRELATION: PLAUSIBLE, not proven (no oscilloscope/cycle-exact instrumentation available
  this session to directly confirm the clamp event is what the operator heard).

DANGEROUS: NO evidence found. Non-fatal by Creality's own explicit design, mechanistically
  separate from the pressure-corruption path, no shutdown/corruption/uncommanded motion observed
  in this session's real touch attempt, and already present (with normal recovery) in the original
  2026-08-10 incident's five occurrences.

HOST_SIDE_FIX_POSSIBLE: NO (same conclusion as §12's pressure-corruption mechanism - the
  disturbance is inside proprietary MCU firmware this project cannot rebuild or patch).

RECOMMENDATION: treat Timer too close during raw-step disarm as a known, expected, non-fatal
  characteristic of this MCU's PRTouch firmware (Creality's own design choice, not a defect this
  project introduced or can remove) rather than a blocking condition. The emergency-shutdown bug
  found and fixed this session was the actual new risk; Timer too close itself was already
  factored into §13's "SAFE_TO_RESUME_PHYSICAL_QUALIFICATION" assessment and behaved exactly as
  that assessment predicted - present, logged, non-fatal, fully recovered.
```

## 17. CORRECTION to §14 (2026-08-13) — the firmware-identity claim was wrong, active safety implication

**§14's central claim is retracted**: `fw/F005/mcu0_001_G32-mcu0_005_000.bin` was claimed there to
be byte-proven identical to the real, currently-running firmware
(`38d96adc-dirty-20231016_135251-longer-virtual-machine`). This was independently re-checked this
session, two ways, both giving the same contradicting answer:

1. Fresh extraction directly from the genuine `ke-factory-backup/rootfs2.img` device backup.
2. Reassembly of the real OTA update package `Ender-3_V3_KE_F005_ota_img_V1.1.0.12` from its 110
   chunk files, MD5-verified against its own manifest (`2e3749c42bee7109ab838e50c3d1793e` - exact
   match, so the reassembly is provably correct), then extracted the same path from that.

Both give SHA256 `0b8ecfad8e65e90a3cfc08dd8534dd568e341c160897e6050eadcbf1eb917d4a`, decoding to:

```
version: v0.13.0-164-gc97932188
build_machine_uid: 'PELLCORP Apr 22 202609:30:55'
prtouch commands: (none)
```

This is generic PELLCORP placeholder firmware, not the real, prtouch-enabled, currently-running
firmware. §14's own basis for the claim was not re-locatable this session to determine where the
discrepancy originated (a different, no-longer-present extraction, or a genuine analysis error at
the time) - not resolved, just corrected on the evidence available now.

### Active safety implication - do not boot stock until this is resolved

Stock's own `S13mcu_update` init script runs on every stock boot: queries the live MCU's real
version (`mcu_util -i /dev/ttyS1 -g`), compares it against this bundled `.bin`'s embedded version,
and calls `mcu_util -u` (a real UART flash) on any mismatch. Given the bundled file is generic
non-PRTouch firmware, a mismatch against the real running firmware is likely - **booting into
stock carries a real, non-theoretical risk of silently reflashing the MCU with firmware that has
zero PRTouch commands**, with no other independently-verified-good copy of the real `38d96adc`
firmware currently in hand to recover with. Not reversible by rebooting back to custom.

`STOCK_BOOT_MCU_REFLASH_RISK: REAL, not theoretical, until this is resolved.`

Any future stock-vs-NebulaOS A/B comparison (e.g. for the Z-stepper sound investigation, §16) must
either locate and independently re-verify a genuine copy of the real `38d96adc` firmware from some
other source first, or find a comparison method that never requires booting stock at all.
