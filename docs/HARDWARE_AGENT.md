# The Hardware Agent

The autonomous developer install: take a printer running NebulaOS, put a new
NebulaOS on it, and prove what landed.

```
NebulaOS running
  ↓  prove printer identity, prove the exact attested candidate
  ↓  prove Stock is reachable and safe to use
  ↓  software reboot to Stock
  ↓  write the NebulaOS slot
  ↓  verify the written bytes
  ↓  select NebulaOS
  ↓  software reboot
  ↓  verify the exact installed build
PART1_INSTALL_VERIFIED=YES
```

## The interface

```sh
run-nebulaos-hardware.sh --device <id> --control <C> inspect
run-nebulaos-hardware.sh --device <id> --control <C> status
run-nebulaos-hardware.sh --device <id> --control <C> diagnose
run-nebulaos-hardware.sh --device <id> --control <C> restart <service>
run-nebulaos-hardware.sh --device <id> --control <C> verify  <X> <ximage-sha256> <rootfs-sha256>
run-nebulaos-hardware.sh --device <id> --control <C> install <X> <ximage-sha256> <rootfs-sha256>
```

## Who may run it

| operation | kind | main agent | `nebulaos-hardware` |
|---|---|---|---|
| `inspect`, `status`, `diagnose`, `verify` | read-only | yes | yes |
| `restart <service>` | repair | yes | yes |
| `install` | flash | **no** | yes |

Enforced by the PreToolUse hook, which also binds the launcher to its committed
bytes and checks the grammar before the sandbox is left. No other agent may run
it. The main agent is refused `install` so that a flash nobody asked for stays
mechanically impossible for it, not merely against policy. What makes that
mechanical is the unsandboxed check, which admits only one lone launcher
invocation. A sandboxed launcher cannot reach a printer at all: it has no
network, and the credential store is denied. Either principal touches a printer
only when the user asks for a hardware task.

The main agent is recognised as a hook payload with no `agent_type`. Any
subagent kind that sends none would inherit the main agent's rights, which
include `restart` but not `install`.

## Diagnose and restart

`diagnose` prints a fixed, bounded, read-only report from the enrolled printer,
after its identity matches the profile:

- processes, memory, disk, the marker;
- the MCU guard's per-boot state;
- the update supervisor's locks and component states;
- Moonraker's `/server/info` and print state;
- tails of the Moonraker, Klippy and system logs, and `dmesg`;
- the Moonraker venv's packages.

`restart` is the only repair. It takes one service from a closed list: klipper,
moonraker, guppyscreen, webcam or nginx. It mirrors the on-device update
supervisor: stop, wait up to 20 s for the old process to exit, then start. It
refuses:

- a control commit C that is not published, **whatever the install mode**,
  because a repair composed from an unpublished commit is code nobody else can
  see;
- an open install transaction, and a printer running Stock;
- a print that is running or paused;
- any update-supervisor lock, or a component in `validating`, because a restart
  mid-validation reads as a failed update and can roll back;
- `klipper` without a proven idle printer, because an unreadable print state
  refuses.

Every attempt is appended to `~/.local/state/nebulaos-hardware/repairs/<device>.log`.

There is deliberately **no package install**. The Moonraker venv lives in
persistent `/usr/data`, and DEV_INSTALL writes only p6/p8. A package installed
there would survive the next install, pass S04's venv smoke test, and be
snapshotted as the supervisor's last-known-good env, so a later image missing
the same package would verify PASS. Product defects are fixed in the product and
reinstalled.

### The RTOS boot logo (`rtos-logo`, `rtos-logo-restore`)

`capture rtos-hashes` (read-only) reports sha256 of rtos (p3) and rtos2 (p4), both whole and over the
first 432824 bytes (the size of `zero.bin`), compared with the pinned stock and NebulaOS images. It
also reports the first 64 bytes, what fills the rest of each partition, and the marker.

`rtos-logo RTOS_LOGO_CONFIRM=RTOS2` writes the pinned NebulaOS RTOS image (stock `zero.bin` with only
its boot-logo JPEG replaced, `scripts/package/rtos_logo.py`) to rtos2, the RTOS SPL loads for
`ota:kernel2`. It runs only on NebulaOS from p8, with the marker on `ota:kernel2`, idle with heater
targets at zero, no open install transaction, and both locks held. The patch input is the printer's
own rtos2, and only if it starts with the pinned stock image. Before writing, it copies the whole 4
MiB to `<state>/rtos-backups/<device>/` and checks the copy against the device's hash. It then
stages and re-hashes the payload, re-checks the guards, and runs one `dd conv=notrunc,fsync` behind a
partition guard (sysfs name, by-partlabel link, size, not mounted). It reads the result back on the
device and from the host, and checks that rtos (p3) did not change. A second run writes nothing.
`rtos-logo-restore <backup-sha256> RTOS_RESTORE_CONFIRM=RTOS2` writes a backup back the same way.
If a write fails, the output names the restore command and says not to reboot. Policy `RTOS2_ONLY`
cannot select rtos, and an install never writes rtos2. USB recovery:
`docs/DEVELOPER_RECOVERY.md`, "RTOS logo: restoring rtos2". Rehearse it before the first write.

There is no `ssh`, `scp`, `dd`, `marker`, `reboot`, `flash`, raw `usbboot`,
`--host`, `--password` or `--command`. Not filtered — **absent**. `DeviceSession`
defines a closed vocabulary with no method that takes a command, a block device
or an offset, so this is a property of the code rather than a promise about
behaviour.

The target is an **enrolled device id**, never an address. An address is not an
identity: DHCP moves leases and the machine answering at a remembered IP may be
a different printer. Which addresses may be spoken to at all is a property of a
human-created profile.

## C and X

| | |
|---|---|
| **C** — control commit | the reviewed, published source of every privileged helper |
| **X** — product commit | the build being installed. Payload and data only |

Stated separately so that installing an **old** X still uses **current** control
machinery. If helpers came from X, installing a six-month-old build would run
six-month-old flashing code — including whatever bug was fixed since.

Helper bytes are read from C's **git objects** in a protected mirror, never from
the working tree. A working tree is mutable; `tools/` is explicitly unversioned
derived state the sandbox permits writing. Host-side control modules can't be
read from git at import time, so they are **compared** against C and any
difference refuses the operation.

## Capability is not policy

The generic flashing layer can express validated writes to the stock slot, the
NebulaOS slot, either individually, both, and full-device recovery layouts:

```
GENERIC_FLASH_CAPABILITY_STOCK=YES
GENERIC_FLASH_CAPABILITY_NEBULAOS=YES
```

A recovery tool that cannot rewrite Creality's slot is not a recovery tool, and
the device belongs to its owner. The developer `install` operation is separately
narrow:

```
DEV_INSTALL_POLICY=PRESERVE_STOCK
DEV_INSTALL_POLICY_WRITES_STOCK=NO
```

That's the policy of one operation, not a limit of the backend. Safety lives in
validated target selection, vendor-derived bounds, identity, provenance and
read-back — not in an allowlist.

**One exception.** `sn_mac` is refused at the *capability* layer, under every
policy including full-device recovery. It holds the per-unit factory MAC and
serial (`26096911004C14;FCEE11004C14;F005;NEBULA V1.0.0.1` on the reference
unit — the address stock's `wlan0` actually uses). Every other partition can be
restored from an image; this one cannot.

## Two install modes: DEV_INSTALL and RELEASE_INSTALL

The mode is a property of the **enrolled printer**, not of the request:
`INSTALL_MODE=dev` in `~/.config/nebulaos-hardware/devices/<id>/profile.conf`
(human-owned, denied to agents). Absent means `release`. An agent cannot switch a
printer into dev mode.

| | DEV_INSTALL (development printer) | RELEASE_INSTALL |
|---|---|---|
| Product proof | build record + build manifest + bytes agree on PRODUCT_HEAD and both hashes | HMAC v2 attestation (human key), release/candidate profile |
| Control code | CONTROL_HEAD's git objects in the local repo; executing host modules must equal it | control commit C from the protected mirror, published |
| Product publication | reported, not required | required |
| Identity, strict host key, idle, heaters, stock way-out, software reboot, p6/p8-only write, read-back SHA-256, select NebulaOS, reboot, PART1 | **required** | required |
| Report | `DEV_INSTALL=YES RELEASE_QUALIFIED=NO HARDWARE_QUALIFIED=NO` | `RELEASE_INSTALL=YES HARDWARE_QUALIFIED=NO` |

PRODUCT_HEAD (the commit that produced xImage/rootfs) and CONTROL_HEAD (the host
tooling doing the install) are separate identities. Changing Hardware Agent code
moves CONTROL_HEAD only; the product artifacts stay valid and are not rebuilt.

The launcher path is unchanged: it still runs the full online identity gate, so
at flash time every canonical repository must be clean and pushed. That is
stricter than DEV_INSTALL needs; relaxing it is a privilege-layer change and is
deliberately not part of this path.

## What `install` proves before it commits

Setting the marker to `ota:kernel` while NebulaOS runs is the point of no easy
return: after the reboot, the only way forward *or back* is through stock. So
everything stock depends on is checked first, while retreat is free.

- the enrolled printer, by eMMC CID and `SHA256(sn_mac)` — not by address, and
  not by `machine-id`, which differs per slot on the same physical printer
- a **v2 attestation** for X that verifies under the attestation key, whose
  digests equal the artifact bytes, whose profile is release or candidate
- X is published
- the printer is idle: not printing, not paused, every heater target zero
- stock is usable: slot present, a root account, dropbear, a Wi-Fi config, a
  pinned host key, a credential, a known address, room to stage
- payload and helpers staged and hashed **on the device**

Then, and only then, the marker moves — through the on-device
`write_ota_marker()`, because that helper is the only thing that fires the PLR
tombstone when switching away from NebulaOS.

## ARMED, and disarming

`ARMED_STOCK` means NebulaOS is still running and the marker says boot stock.

Every failure in that state sets the marker back and **reads the physical bytes
back** to confirm. A resumed transaction that finds the device armed disarms
*first*, before considering anything else — it does not assume it meant to
continue.

Once slot 2 verifies, the marker is the **immediate** next operation. Not log
collection, not a status report.

## The MCU cost, stated up front

Booting Creality's slot lets its updater reflash the GD32 with stock firmware,
destroying the qualified MCU build. That is why Phase 1.8B removed every
*automatic* route into stock. This install goes there deliberately, because
`flash-spare-slot.sh` refuses to write the slot it is booted from — a rule
written after a real incident where a write landed on the live rootfs.

NebulaOS's guard gets **one bounded restore attempt** on the way back.
`PART1_INSTALL_VERIFIED=YES` requires that no restore was needed:
`MCU_RESTORE_RESULT` is *observed*, and any restore fails the check. A pass on a
printer whose MCU is running Creality's firmware would be a false pass.

This project performs software reboots and cannot power-cycle, so the window is
survivable by construction — but `POWER_CYCLE_DANGEROUS=YES` appears in the
journal and the output throughout it, because a human pulling the plug is the
remaining risk.

## Enrolment is a human act

```sh
tools/hardware/enroll-device.sh --device printer-01 --address 192.168.0.98 --os nebulaos
tools/hardware/enroll-device.sh --device printer-01 --address 192.168.0.138 --os stock
```

Both OSes, before any install. Enrolment is the moment someone asserts *this
physical printer is the one called `<id>`*, and everything downstream rests on
that assertion having been made by someone who could see it. An installer that
can enrol can enrol the wrong printer — which is the trust-on-first-use failure
the rest of this design exists to prevent.

`enroll-device.sh` is deliberately **not** a launcher an agent may run, and the
profile store is denied to agents by permission rules and by the sandbox.

Host keys are pinned **per OS** — stock and NebulaOS are different systems on
one printer — and checked with `StrictHostKeyChecking=yes`. No TOFU, no
automatic re-pinning. A changed key is a refusal; a human re-enrols.

## Prerequisites

| | |
|---|---|
| `~/.config/nebulaos-attest/attest.key` | human-created, 0600 in a 0700 dir. Without it nothing can be attested and every install refuses |
| `~/.config/nebulaos-hardware/devices/<id>/` | enrolled profile, both OSes |
| `~/.local/state/nebulaos-hardware/mirror.git` | protected control mirror, created on first use |

All three are denied to agents. That is the control, not an obstacle: an agent
that can read the attestation key can mint an attestation for any bytes.

## What it does not claim

`PART1_INSTALL_VERIFIED` says an exact image is installed and the system came
up. It is **not** `HARDWARE_QUALIFIED`. Motion, heating, extrusion, calibration
and printing are Part 2, and nothing here touches them.

## Testing

`tests/hardware-install-simulation-tests.py` — 89 assertions across 28
scenarios, driving the real state machine against a simulated printer whose
`boot()` derives which slot comes up **from the marker bytes**, exactly as the
bootloader does. An installer that mis-parses the marker boots the wrong thing
there too.

The simulator lives under `tests/`; production has no import path to it. The
seam is `session_factory` — SSH in production, simulator in tests.

## Related

- [`A_B_SLOT_MODEL.md`](A_B_SLOT_MODEL.md) — partitions and the marker
- [`DEVELOPER_RECOVERY.md`](DEVELOPER_RECOVERY.md) — when it will not boot
- [`RELEASE_ARTIFACTS.md`](RELEASE_ARTIFACTS.md) — the three delivery formats
- [`NEBULAOS_OTA_FLOW.md`](NEBULAOS_OTA_FLOW.md) — why automatic stock fallback was removed
