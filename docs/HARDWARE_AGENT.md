# The Hardware Agent

The autonomous developer install: take a printer running NebulaOS, put a new
NebulaOS on it, and prove what landed.

Since 2026-10-14 NebulaOS may occupy **either or both** A/B slots (human
decision; [`A_B_SLOT_MODEL.md`](A_B_SLOT_MODEL.md)). The install reads the
printer's slot state first and takes one of two paths:

```
PRESERVE_STOCK (NebulaOS in slot 2,          INACTIVE_SLOT (NebulaOS in slot N, the
Creality in slot 1, kept)                    other slot NebulaOS or released)
  ↓  identity, exact product                   ↓  identity, exact product
  ↓  prove Stock is reachable and safe          ↓  prove the running slot is the way back
  ↓  software reboot to Stock                   ↓  re-read the live root (/proc/cmdline)
  ↓  write slot 2                               ↓  write the OTHER slot from NebulaOS
  ↓  verify the written bytes                   ↓  verify the written bytes
  ↓  select slot 2                              ↓  select the other slot
  ↓  software reboot                            ↓  software reboot into it
  ↓  verify the exact installed build           ↓  verify the exact installed build
PART1_INSTALL_VERIFIED=YES                    PART1_INSTALL_VERIFIED=YES
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
| `reboot REBOOT_CONFIRM=NEBULAOS` | software reboot, writes nothing | yes | yes |
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
persistent `/usr/data`, and DEV_INSTALL writes only one slot's kernel and rootfs. A package installed
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
`ota:kernel2`. It runs only on NebulaOS from p8 (slot 2). NebulaOS running from slot 1 is refused
with that reason: SPL then loads rtos (p3), which is out of scope. It needs the marker on
`ota:kernel2`, idle with heater
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

### `reboot`

`reboot REBOOT_CONFIRM=NEBULAOS` software-reboots an idle NebulaOS printer and writes nothing. It
reads the slot state and refuses unless the marker selects a slot that **holds NebulaOS**: slot 1 or
slot 2, whichever it is. A marker on a Creality slot, on an empty slot or on one it cannot
identify is refused. Writing nothing means the next boot can never be Creality. The output says
`REBOOT_INTO_SLOT=<n>` and `REBOOT_SWITCHES_SLOT=YES|NO`. `YES` means the marker already selects
the other NebulaOS slot, for example after an on-printer update. Success means the printer is
rediscovered as NebulaOS, with a changed boot id, running from that slot.

There is no `ssh`, `scp`, `dd`, `marker`, raw reboot, `flash`, raw `usbboot`,
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
narrow. It uses exactly one of three policies, chosen from the device's slot
state (`nebulaos_slots.plan_install`):

| policy | may write | when |
|---|---|---|
| `PRESERVE_STOCK` | kernel2, rootfs2, marker | NebulaOS runs from slot 2, Creality is in slot 1 and is not released |
| `INACTIVE_SLOT_1` | kernel, rootfs, marker | NebulaOS runs from slot 2 and slot 1 holds NebulaOS or is released |
| `INACTIVE_SLOT_2` | kernel2, rootfs2, marker | NebulaOS runs from slot 1 and slot 2 holds NebulaOS or is released |

No policy can select both slots, and none can select rtos/rtos2 or `sn_mac`.

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
| Identity, strict host key, idle, heaters, way-out/way-back proof, one-slot-only write (never the running slot), read-back SHA-256, select the new slot, reboot, PART1 | **required** | required |
| `INSTALL_OTHER_SLOT=expendable` (may overwrite a Creality or unidentified other slot) | honoured | **ignored**, the other slot is preserved |
| Report | `DEV_INSTALL=YES RELEASE_QUALIFIED=NO HARDWARE_QUALIFIED=NO` | `RELEASE_INSTALL=YES HARDWARE_QUALIFIED=NO` |

PRODUCT_HEAD (the commit that produced xImage/rootfs) and CONTROL_HEAD (the host
tooling doing the install) are separate identities. Changing Hardware Agent code
moves CONTROL_HEAD only; the product artifacts stay valid and are not rebuilt.

The launcher path is unchanged: it still runs the full online identity gate, so
at flash time every canonical repository must be clean and pushed. That is
stricter than DEV_INSTALL needs; relaxing it is a privilege-layer change and is
deliberately not part of this path.

## NebulaOS in either or both slots

### Slot state

`inspect` and `verify` print the slot state. `install` prints it before it decides anything and
again after the reboot, and it records it in the journal. `status` never contacts the printer and
shows the recorded values as `TRANSACTION_LAST_OBSERVED_*`:

```
SLOT_RUNNING=1|2            from root= in /proc/cmdline
SLOT_MARKER_SELECTS=1|2     from the marker bytes in p1
SLOT_NEXT_BOOT_HOLDS=...
SLOT_<n>_HOLDS=nebulaos|creality|empty|unknown
SLOT_<n>_KERNEL=<uImage name, e.g. Linux-6.6.18-rt23>
SLOT_<n>_FIRMWARE_HEAD=<firmware_head from /opt/nebulaos-seeds/seed-manifest.json>
SLOT_<n>_EVIDENCE=...
SLOT_NEBULAOS_IN=1,2
INSTALL_WOULD_TAKE=INACTIVE_SLOT|PRESERVE_STOCK|REFUSED (...)     (inspect)
```

The running slot holds what is running. `which_os` identifies it with the same structural markers
described below. The other slot is classified **on the printer**, read-only
(`nebulaos_device.slot_facts_script`):

- it reads the uImage header (magic and name) of each kernel partition and the squashfs magic of
  each rootfs;
- it mounts the other rootfs read-only in a private temporary directory, the same way the stock
  way-out proof does. The live root is inspected in place and never mounted again, and a
  partition without a squashfs superblock is not mounted at all;
- it looks for `/etc/ota_marker.sh` plus `/opt/nebulaos` (NebulaOS) or `/etc/ota_bin` (Creality).
  These are the markers `which_os` uses;
- the kernel name must not contradict the rootfs. NebulaOS ships Linux 6.x and Creality's KE
  firmware ships 4.4.

The result is `empty` when there is no squashfs or no uImage header, so the slot has nothing
bootable. It is `unknown` when the mount failed, when both or neither marker is present, or when
the kernel and the rootfs disagree (a half-written slot). Nothing is ever loop-mounted on the
host.

### Which path, and the human's permission

| running | other slot holds | `INSTALL_OTHER_SLOT` | result |
|---|---|---|---|
| slot 2 | Creality | unset / `preserve` | `PRESERVE_STOCK`: via Creality, as before |
| slot 1 or 2 | NebulaOS | any | `INACTIVE_SLOT`: write the other slot |
| slot 1 or 2 | Creality, empty, unknown | `expendable` (DEV device) | `INACTIVE_SLOT`, `DEV_INSTALL_OVERWRITES_CREALITY=YES` if Creality |
| slot 1 | Creality | unset / `preserve` | refused: the agent does not boot Creality from slot 2 |
| slot 1 or 2 | empty, unknown | unset / `preserve` | refused |
| unknown root | – | – | refused |
| already running Creality from slot 1 | Creality (slot 2) | unset / `preserve` | refused; otherwise the stock path writes slot 2, NebulaOS's original home, as before |

The permission to destroy a Creality system is explicit. It is a human-owned key in
`~/.config/nebulaos-hardware/devices/<id>/profile.conf`:

```
INSTALL_OTHER_SLOT=expendable     # absent or "preserve" = keep it
```

The tool never infers it and never writes it. Any other value refuses the install. On a RELEASE
device the key is ignored and reported as ignored. Every refusal that the key would lift names it.

### The INACTIVE_SLOT path

- The way back is the NebulaOS slot that is running now. No policy can select it, and the
  way-back proof checks all of the following: the root is still that slot, the system is NebulaOS,
  the target is the other slot, the policy cannot reach the running slot, the marker selects the
  running slot, and the staging area has room.
- If the marker selects the other slot when the install starts, the install first points it back
  at the running slot and reads it back. That slot is about to be written. If the other slot is
  Creality, the original `ARMED_STOCK` disarm handles it.
- The live root is re-read just before the write. `scripts/flash-spare-slot.sh --target-slot N`
  then resolves the live root from `/proc/cmdline` twice and refuses the running slot itself. The
  default without the option is still slot 2.
- The marker moves only after both partitions verify by SHA-256. If the marker write does not
  verify, the marker is put back on the running slot and read back, and nothing reboots.
- Creality is never booted on this path. There is no stock window, no MCU exposure and no
  `POWER_CYCLE_DANGEROUS` state. The journal uses `SLOT_FLASHING` / `SLOT_FLASH_VERIFIED`, which
  are not stock-window states.
- PART1 verifies the target slot's partitions, root and marker. If the new slot does not come back,
  the previous NebulaOS is still intact in the old slot, and setting the marker to it returns
  there.

## What `install` proves before it commits (PRESERVE_STOCK)

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

`tests/hardware-install-simulation-tests.py` drives the real state machine
against a simulated printer. It has 299 assertions across 55 scenarios; in this
sandbox the 3 way-out shell checks fail because `mount` is blocked. The
simulator's `boot()` derives the slot that comes up **from the marker bytes**,
exactly as the bootloader does, and what that slot holds from its bytes. An
installer that mis-parses the marker, or writes the wrong slot, boots the wrong
thing there too. The both-slots scenarios cover:

- B=NebulaOS + A=Creality, with and without the key;
- A+B NebulaOS, in both directions;
- A=NebulaOS + B=Creality;
- an unidentifiable other slot;
- three independent refusals to write the running slot;
- marker and flash failures;
- reboot and rtos-logo rules;
- the slot probe itself, run in a real shell against fixtures.

`tests/flash-spare-slot-preflight-tests.sh` covers `--target-slot`.

The simulator lives under `tests/`; production has no import path to it. The
seam is `session_factory` — SSH in production, simulator in tests.

## Related

- [`A_B_SLOT_MODEL.md`](A_B_SLOT_MODEL.md) — partitions and the marker
- [`DEVELOPER_RECOVERY.md`](DEVELOPER_RECOVERY.md) — when it will not boot
- [`RELEASE_ARTIFACTS.md`](RELEASE_ARTIFACTS.md) — the three delivery formats
- [`NEBULAOS_OTA_FLOW.md`](NEBULAOS_OTA_FLOW.md) — why automatic stock fallback was removed
