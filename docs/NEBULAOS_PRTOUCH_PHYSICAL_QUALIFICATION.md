# PRTouch raw-op fix — physical qualification procedure

Prepared 2026-08-11, closure/preparation mission. This is the test sheet for the operator
(printer physically present) after flashing the engineering package built from
`integration/prtouch-timer-fix-and-migrate-exec-bit`
(`NebulaOS-KE/NebulaOS-firmware`) / `4ae82620` (`coreflake1/NebulaOS-klipper`).

**Nothing in this document was executed by the assistant.** All commands below are for you to
run once you decide to proceed. Stop at the first failed check in any stage.

---

## Before you start: one live device correction needed

Live-device inspection this session found a leftover from the very first investigation
session: `/opt/printer_data/config/printer.cfg`'s `[z_compensate]` section still has

```
z_offset_down_min_z: 1  # TEMP no-trigger free-air test, revert after
z_offset_down_min_z: 1
```

(duplicated, both lines). This was never reverted after the original no-trigger test. It only
affects `Z_OFFSET_CALIBRATION` (not the Stage 1 `SAFE_MOVE_Z` test below), but should be
cleaned up before any real calibration is attempted — real production calibration needs its
actual travel budget back. A config-only edit, zero motion risk; the assistant did not make
this edit itself because it exceeded this session's read-only-inspection authorization. Revert
it yourself, or ask for it explicitly next session:

```
ssh root@<device-ip>   # password: openke
sed -i '/z_offset_down_min_z: 1  # TEMP no-trigger free-air test, revert after/d' /opt/printer_data/config/printer.cfg
grep -A3 '^\[z_compensate\]' /opt/printer_data/config/printer.cfg   # confirm only one z_offset_down_min_z line remains, or none (default 10 applies)
```

---

## Stage 0 — flash / boot validation (no load-cell movement)

After flashing the engineering package:

| Check | How | Pass |
|---|---|---|
| Boots | watch the display / `ping` the device | reaches a login-capable state |
| Klipper ready | `curl -s http://127.0.0.1:7125/printer/objects/query?webhooks` | `"state": "ready"` |
| Moonraker healthy | same query, or `curl -s http://127.0.0.1:7125/server/info` | responds, no error |
| GuppyScreen healthy | look at the physical screen | shows the normal UI, not a crash/blank screen |
| OTA marker healthy | `. /etc/ota_marker.sh; cat /proc/cmdline \| grep -o 'root=[^ ]*'` | matches the slot you just flashed |
| `READ_PRES` valid | `curl -s -X POST "http://127.0.0.1:7125/printer/gcode/script?script=READ_PRES"` then check `klippy.log` | `ok=True`, a plausible baseline reading (order of magnitude similar to the ~-250,000 range recorded in earlier sessions — exact value drifts, that's expected) |
| No unexpected errors | `tail -100 /usr/data/nebulaos/printer_data/logs/klippy.log` | no tracebacks, no `#output:` warnings, no shutdown lines |
| Fix actually present | `grep -c "_own_raw_operation\|_settle_after_disarm" /opt/klipper/klippy/extras/prtouch_probe.py` | non-zero (confirms the flashed rootfs really has the new code, not a stale mirror) |

**Do not proceed to Stage 1 if any of the above fails.**

---

## Stage 1 — first raw movement

Exactly one operation:

```
SAFE_MOVE_Z DIR=1 DIS=1 SPD=1
```

Direction: **UP / away from the bed.** Distance: 1&nbsp;mm. Speed: 1&nbsp;mm/s.

### Before you send it

**Physically verify the nozzle has at least 10–15&nbsp;mm of clearance above the bed** (well
beyond the commanded 1&nbsp;mm) — this command has no pressure arm, no trigger detection, and no
awareness of the bed at all; it will physically move exactly 1&nbsp;mm regardless of what's
beneath the nozzle, so the clearance requirement is about giving yourself margin to visually
confirm the movement, not about collision risk (direction is UP).

### Exact expected raw parameters (computed from this printer's real, live config —
`[stepper_z]` `microsteps: 16` `rotation_distance: 8`, `[prtouch_v2]` `step_base: 2` — via the
actual, unmodified `prtouch_units.py` functions, not approximated)

```
start_step_prtouch oid=<step_oid> dir=1 send_ms=10 step_cnt=200 step_us=5000 \
    acc_ctl_cnt=100 low_spd_nul=5 send_step_duty=16 auto_rtn=0

collect_step_samples timeout = 6.0s   (1.0s expected move + 5.0s margin)
settle after disarm           = 0.01s (tri_send_ms / 1000 - the fix's own yield)
```

> Note: an earlier draft of this static proof (first closure session) used `step_cnt=400,
> step_us=2500` — that used the code's *default* `step_base=1`, not this printer's actually
> configured `step_base: 2`. The numbers above are the corrected ones, re-verified directly
> against the live `[prtouch_v2]` section during this session.

### Capture logs immediately before and after
See the capture script below — run it once right before sending the command, and again right
after.

### Pass criteria (all required)
- Exactly one raw operation logged (`prtouch_probe: raw op #N start (safe_move_z)` /
  `... end (safe_move_z)` — one N, appearing once each).
- Physical nozzle moves approximately 1&nbsp;mm upward (visually confirm).
- Motor sound is clean/normal — no grinding, clicking, or stall sound.
- **No** `#output: Timer too close` line anywhere in the log window.
- **No** `sentinel timer called` / `Transition to shutdown` anywhere in the log window.
- No unexpected `manual_get_steps`/`manual_get_pres` sample-repair spam beyond what a normal
  single move produces.
- Clean disarm: `start_step_prtouch ... step_cnt=0` logged after the arm.
- `prtouch_probe: raw op #N disarm dir=1` appears, followed by evidence of the settle (the next
  log line's timestamp is ≥0.01s later than the disarm line's timestamp).
- `webhooks.state` is still `"ready"` after the command returns.
- MCU remains responsive: a follow-up `objects/query?webhooks` succeeds immediately.
- `READ_PRES` still returns `ok=True` with a plausible reading afterward.

### Hard stop — abort immediately and do not proceed to Stage 2 if
- Any abnormal sound.
- Movement in the wrong direction or wrong approximate distance.
- Any `Timer too close` or shutdown-related log line.
- Any timeout or MCU-unresponsive condition.
- Anything else that doesn't match the pass criteria above.

If you hit a hard-stop condition, run the capture script immediately (before touching anything
else) and keep the printer powered but idle — that's exactly the evidence needed to continue
the investigation.

---

## Stage 2 — isolated DOWN move (prepared, NOT to run automatically)

```
SAFE_MOVE_Z DIR=0 DIS=1 SPD=1
```

**REQUIRES REVIEW OF STAGE 1 RESULTS + FRESH AUTHORIZATION.** Do not run this back-to-back with
Stage 1 — a deliberate pause between the two is intentional, since the incident's own rapid
disarm-then-immediate-rearm cadence is exactly what this whole fix targets, and Stage 1 and
Stage 2 being genuinely separate, human-paced operations is part of what's being validated.

Same computed parameters as Stage 1, with `dir=0` in place of `dir=1`. Before sending, confirm
clearance beneath the nozzle this time (downward move) — at least 10–15&nbsp;mm above the bed,
consistent with Stage 0's own general safety margin.

No calibration (`Z_OFFSET_CALIBRATION`), no `NOZZLE_CLEAR`/`CRTENSE_NOZZLE_CLEAR`, and no
further sequencing tests should be attempted until both isolated moves are individually
qualified and you've explicitly decided to continue.

---

## Read-only incident capture (use before and after every stage)

Pure inspection — no motion, no additional raw MCU operations. Safe to run at any time,
including immediately after a hard-stop.

```sh
#!/bin/sh
# capture-prtouch-state.sh - read-only PRTouch/incident evidence capture.
# Usage: ssh root@<device-ip> 'sh -s' < capture-prtouch-state.sh > capture-$(date +%s).txt
# (or copy this script to the device and run it there - either way, nothing here sends a
# gcode command or touches the MCU beyond what READ_PRES/status queries already do.)

echo "=== timestamp ==="
date -u

echo "=== webhooks state ==="
curl -s http://127.0.0.1:7125/printer/objects/query?webhooks

echo "=== toolhead / idle_timeout ==="
curl -s "http://127.0.0.1:7125/printer/objects/query?toolhead&idle_timeout"

echo "=== z_compensate status ==="
curl -s "http://127.0.0.1:7125/printer/objects/query?z_compensate"

echo "=== MCU stats (last line) ==="
tail -n 200 /usr/data/nebulaos/printer_data/logs/klippy.log | grep '^Stats' | tail -1

echo "=== last 300 lines of klippy.log ==="
tail -n 300 /usr/data/nebulaos/printer_data/logs/klippy.log

echo "=== PRTouch instrumentation lines (raw op start/end/arm/disarm) ==="
grep "prtouch_probe: raw op" /usr/data/nebulaos/printer_data/logs/klippy.log | tail -n 100

echo "=== any #output MCU messages ==="
grep "#output" /usr/data/nebulaos/printer_data/logs/klippy.log | tail -n 50

echo "=== any shutdown/sentinel lines ==="
grep -i "shutdown\|sentinel" /usr/data/nebulaos/printer_data/logs/klippy.log | tail -n 50

echo "=== moonraker access log tail ==="
tail -n 100 /usr/data/nebulaos/printer_data/logs/moonraker.log

echo "=== capture complete ==="
```

This performs only HTTP GET status queries and log reads — no `gcode/script` POST of any kind,
so it cannot itself trigger motion or add MCU traffic.
