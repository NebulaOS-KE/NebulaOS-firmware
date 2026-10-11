"""A simulated Ender-3 V3 KE, good enough to test an installer against.

WHY THIS LIVES UNDER tests/

Production code under tools/hardware/ contains no reference to this module and
no import path that reaches it. An installer built from the shipped tree cannot
construct a simulator even by mistake, because there is nothing there to
construct. Tests inject it through the same `session_factory` seam that
production fills with SSH.

That is a structural guarantee rather than a naming convention: moving this file
into tools/ is the only way to break it, and that would be visible in a diff.

WHAT IT MODELS

Enough of a printer for the install state machine to be wrong against:

  * ten partitions with real vendor offsets, holding real bytes
  * the OTA marker, with the byte formats a real device actually contains
  * which slot boots, decided by the marker at boot time - not by a flag
  * boot ids that change across a reboot, because that is how the installer
    proves a reboot happened
  * DHCP addresses that can move across a reboot
  * per-OS SSH host keys and credentials, so a mismatch is expressible
  * printer busy / heater targets
  * the stock MCU updater, which may act during the stock window
  * a device-side flash lock

FAULT INJECTION

Every adversarial case the mission names is a field on SimulatedPrinter, not a
special code path in the test: wrong printer, host-key mismatch, IP change,
stock unavailable, printer busy, heater active, marker write failure, crash
while armed, SSH loss, flash interruption, hash mismatch, journal conflict,
concurrent installer, MCU updater acted. The installer sees a device behaving
badly, not a mock refusing to be called.
"""

import hashlib
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "..", "..", "tools", "hardware"))

import nebulaos_device as device      # noqa: E402
import nebulaos_marker as marker      # noqa: E402
import nebulaos_target as targets     # noqa: E402


class SimTransportError(device.DeviceError):
    """The simulated network or SSH layer refused or dropped."""


class SimulatedPrinter:
    """The persistent model. Survives 'reboots'; sessions come and go."""

    def __init__(self,
                 emmc_cid="0x15010047444734303038",
                 sn_mac_payload=b"26096911004C14;FCEE11004C14;F005;NEBULA V1.0.0.1;;;;;",
                 nebulaos_address="192.168.0.98",
                 stock_address="192.168.0.138",
                 nebulaos_host_key="ssh-ed25519 AAAANEBULAOSKEY",
                 stock_host_key="ssh-ed25519 AAAASTOCKKEY",
                 nebulaos_password="openke",
                 stock_password="Creality2023"):
        self.emmc_cid = emmc_cid
        self.sn_mac_payload = sn_mac_payload
        self.addresses = {device.OS_NEBULAOS: nebulaos_address, device.OS_STOCK: stock_address}
        self.host_keys = {device.OS_NEBULAOS: nebulaos_host_key, device.OS_STOCK: stock_host_key}
        self.passwords = {device.OS_NEBULAOS: nebulaos_password, device.OS_STOCK: stock_password}

        # Partition contents. Only the ones an install reads or writes are
        # modelled with real bytes; the rest exist so the layout is complete.
        self.partitions = {
            "ota": marker.canonical(marker.KERNEL2),
            "sn_mac": sn_mac_payload,
            "kernel": b"\xde\xad" * 1024,        # stock kernel, contents irrelevant
            "rootfs": b"\xbe\xef" * 4096,        # stock rootfs
            "kernel2": b"",                      # NebulaOS slot, initially empty
            "rootfs2": b"",
            "rtos": b"\x00" * 16,
            "rtos2": b"\x00" * 16,
        }

        self.running_os = device.OS_NEBULAOS
        self.boot_id = "boot-0001"
        self._boot_counter = 1
        self.staged = {}                         # name -> bytes
        self.flash_lock_holder = None

        # Health / activity
        self.printing = False
        self.paused = False
        self.heater_targets = {"extruder": 0, "heater_bed": 0}
        self.klippy_state = "ready"
        self.services = {"klipper": "running", "moonraker": "running",
                         "nginx": "running", "guppyscreen": "running"}
        self.mcu_serial = "usb-Klipper_stm32-if00"
        self.mcu_guard_restores = 0
        # Stock's /tmp/mcu_update.log as the real S13mcu_update leaves it after a
        # software reboot from NebulaOS: the handshake fails and it does nothing.
        self.stock_mcu_update_log = "usart_rec_Process: select time out\nhandshake /dev/ttyS1 fail, ret=1\n"

        # Stock way-out facts
        self.stock_has_dropbear = True
        self.stock_has_wifi_conf = True
        self.stock_has_root_account = True
        self.free_bytes = 4 * 1024 * 1024 * 1024

        # --- fault injection ---------------------------------------------
        self.fail_marker_write = False           # writes silently do not land
        self.marker_write_garbled = False        # writes land as neither marker
        self.marker_write_raises = False         # writes raise before landing
        self.marker_write_lands_then_raises = None  # state: bytes land, THEN it raises
        self.corrupt_flash = False               # flash writes land wrong
        self.interrupt_flash_after = None        # write N bytes then drop
        self.flash_helper_fails = False
        self.helper_must_equal = None            # bytes the staged helper must have
        self.stock_unavailable = False           # stock never answers
        self.nebulaos_unavailable = False
        self.drop_after_ops = None               # SSH dies after N operations
        self.change_address_on_boot = False
        self.next_address_on_boot = {}           # os -> the exact address to move to
        self.busy_after_marker_set = None        # marker state that makes the printer busy
        self.stock_updater_acts_on_boot = False
        self.mcu_guard_restores_on_boot = False
        self.mcu_guard_result = "PASS"            # the guard's own verdict
        self.identity_override = None            # pretend to be a different printer
        self.supervisor_lock = None              # e.g. "klipper.lock": update supervisor busy
        self.supervisor_validating = False       # a component is in state=validating
        self.print_state_readable = True         # False: Moonraker down, print state unknown
        self.restarts = []                       # services restarted, in order
        self.reboot_does_nothing = False         # marker set, device never reboots
        self.backup_read_short = False           # rtos2 copy arrives one byte short
        self.rtos_write_raises = False           # rtos2 write drops half-way
        self.rtos_write_corrupt = False          # rtos2 write lands one byte wrong
        self.busy_after_staging = None           # staged name after which a print starts
        self.rtos2_writes = 0

        self._ops = 0
        self.log = []

    # -- identity ----------------------------------------------------------
    def sn_mac_sha256(self):
        return hashlib.sha256(self.sn_mac_payload).hexdigest()

    def identity(self):
        if self.identity_override:
            return self.identity_override
        return (self.emmc_cid, self.sn_mac_sha256())

    # -- boot --------------------------------------------------------------
    def boot(self):
        """Reboot: read the marker, boot the slot it names, take a new boot id.

        This is the modelling decision that makes the simulator worth having.
        Which OS comes up is DERIVED from the marker bytes, exactly as the real
        bootloader derives it - so an installer that mis-parses the marker, or
        forgets to set it, boots the wrong thing here too.
        """
        if self.reboot_does_nothing:
            self.log.append("reboot requested but the device did not reboot")
            return
        state, _ = marker.parse(self.partitions["ota"])
        if state == marker.KERNEL:
            self.running_os = device.OS_STOCK
            if self.stock_updater_acts_on_boot:
                self.stock_mcu_update_log = "mcu firmware update ok\n"
                self.log.append("stock MCU updater acted on boot")
        elif state == marker.KERNEL2:
            self.running_os = device.OS_NEBULAOS
            if self.mcu_guard_restores_on_boot:
                self.mcu_guard_restores += 1
                self.log.append("NebulaOS MCU guard performed an automatic restore")
            # Booting NebulaOS means slot 2 must actually contain something.
            if not self.partitions["kernel2"] or not self.partitions["rootfs2"]:
                self.running_os = device.OS_UNKNOWN
                self.log.append("slot 2 is empty - the device failed to boot NebulaOS")
        else:
            # An indeterminate marker: the bootloader's behaviour is genuinely
            # unpredictable. Model it as staying where it was, which is the
            # benign outcome; the installer must never rely on it.
            self.log.append("indeterminate marker at boot - slot selection undefined")

        self._boot_counter += 1
        self.boot_id = "boot-%04d" % self._boot_counter
        if self.running_os in self.next_address_on_boot:
            self.addresses[self.running_os] = self.next_address_on_boot.pop(self.running_os)
            self.log.append("DHCP moved to %s" % self.addresses[self.running_os])
        elif self.change_address_on_boot:
            base = self.addresses[self.running_os].rsplit(".", 1)[0]
            self.addresses[self.running_os] = "%s.%d" % (base, 100 + self._boot_counter)
            self.log.append("DHCP moved to %s" % self.addresses[self.running_os])

    def reachable(self, which_os):
        if which_os == device.OS_STOCK and self.stock_unavailable:
            return False
        if which_os == device.OS_NEBULAOS and self.nebulaos_unavailable:
            return False
        return self.running_os == which_os

    def tick(self):
        self._ops += 1
        if self.drop_after_ops is not None and self._ops > self.drop_after_ops:
            raise SimTransportError("connection lost (simulated)")


class SimSession(device.DeviceSession):
    """One connection to a SimulatedPrinter, as the installer sees it."""

    def __init__(self, printer, which_os, address, host_key, password):
        self.printer = printer
        self.expect_os = which_os
        self.address = address
        self.closed = False

        if printer.addresses.get(which_os) != address:
            raise SimTransportError("no route to %s (nothing is listening there)" % address)
        if not printer.reachable(which_os):
            raise SimTransportError("connection refused at %s" % address)
        if host_key != printer.host_keys[which_os]:
            raise SimTransportError(
                "host key verification failed for %s: offered %r, pinned %r"
                % (address, printer.host_keys[which_os], host_key))
        if password != printer.passwords[which_os]:
            raise SimTransportError("permission denied (password) for %s" % address)

    def _t(self):
        if self.closed:
            raise SimTransportError("session is closed")
        self.printer.tick()

    # -- identity ----------------------------------------------------------
    def probe_identity(self):
        self._t()
        cid, snmac = self.printer.identity()
        return device.Identity(cid, snmac, "machine-%s" % self.printer.running_os,
                               ["ota", "sn_mac", "rtos", "rtos2", "kernel", "kernel2",
                                "rootfs", "rootfs2", "rootfs_data", "userdata"])

    def which_os(self):
        self._t()
        return self.printer.running_os

    def active_root(self):
        self._t()
        return {device.OS_NEBULAOS: "/dev/mmcblk0p8",
                device.OS_STOCK: "/dev/mmcblk0p7"}.get(self.printer.running_os, "unknown")

    def boot_id(self):
        self._t()
        return self.printer.boot_id

    def _stock_mcu_update(self):
        """Mirrors STOCK_MCU_UPDATE_PROBE: the log exists only on stock's tmpfs."""
        if self.printer.running_os != device.OS_STOCK or self.printer.stock_mcu_update_log is None:
            return "absent"
        log = self.printer.stock_mcu_update_log.lower()
        if "identify fail" in log or ("handshake" in log and "fail" in log):
            return "did_not_act"
        return "acted_or_unknown"

    # -- marker ------------------------------------------------------------
    def read_marker_block(self):
        self._t()
        block = self.printer.partitions["ota"]
        return block + b"\x00" * max(0, 512 - len(block))

    def write_marker(self, state):
        self._t()
        if self.printer.marker_write_raises:
            raise device.DeviceError("marker write failed (simulated I/O error)")
        if self.printer.marker_write_lands_then_raises == state:
            # The realistic bad case: dd conv=fsync has already committed the
            # bytes and the connection dies before the caller learns anything.
            # The device IS armed; the installer believes it never got that far.
            self.printer.partitions["ota"] = marker.canonical(state)
            self.printer.log.append("marker set to %s, then the connection dropped" % state)
            self.printer.marker_write_lands_then_raises = None
            raise SimTransportError("connection lost after the marker write committed")
        if self.printer.fail_marker_write:
            self.printer.log.append("marker write to %s silently did not land" % state)
            return True
        if self.printer.marker_write_garbled:
            # Lands, but as bytes that are neither kernel nor kernel2: read-back
            # of ANY target fails, so the stock write AND the disarm both fail.
            self.printer.partitions["ota"] = b"ota:kern\xff"
            self.printer.log.append("marker write to %s landed garbled" % state)
            return True
        self.printer.partitions["ota"] = marker.canonical(state)
        self.printer.log.append("marker set to %s" % state)
        # Models a human starting a print from the touchscreen in the seconds
        # between arming and the reboot - the exact race the post-arm idle
        # re-check exists for.
        if self.printer.busy_after_marker_set == state:
            self.printer.printing = True
            self.printer.log.append("a print started after the marker was set to %s" % state)
        return True

    # -- safety ------------------------------------------------------------
    def idle_state(self):
        self._t()
        return device.IdleState(self.printer.printing, self.printer.paused,
                                dict(self.printer.heater_targets),
                                self.printer.klippy_state, "simulated")

    def service_health(self):
        self._t()
        facts = dict(self.printer.services)
        facts["moonraker_http"] = "200" if self.printer.services["moonraker"] == "running" else "000"
        facts["web_http"] = "200" if self.printer.services["nginx"] == "running" else "000"
        return facts

    def mcu_state(self):
        self._t()
        return {
            "mcu_serial": self.printer.mcu_serial,
            "mcu_guard_restore": str(self.printer.mcu_guard_restores),
            "mcu_guard_result": self.printer.mcu_guard_result,
            "stock_mcu_update": self._stock_mcu_update(),
        }

    # -- diagnosis and repair ---------------------------------------------
    def diagnose(self):
        self._t()
        return "===== processes =====\n" + "\n".join(
            "%s %s" % kv for kv in sorted(self.printer.services.items())) + "\n"

    def capture(self, profile):
        self._t()
        if profile not in device.captures.CAPTURE_PROFILES:
            raise device.DeviceError("unknown capture profile %r" % profile)
        self.printer.captures = getattr(self.printer, "captures", []) + [profile]
        return "CAPTURE_PROFILE=%s\nsimulated\nEND_UTC=x\n" % profile

    def exercise(self, profile):
        self._t()
        if profile not in device.captures.EXERCISE_PROFILES:
            raise device.DeviceError("unknown exercise profile %r" % profile)
        self.printer.exercises = getattr(self.printer, "exercises", []) + [profile]
        return "EXERCISE_PROFILE=%s\nsimulated\nEND_UTC=x\n" % profile

    def restart_service(self, name):
        # The same decisions, in the same order, as device.restart_script().
        self._t()
        if name not in device.RESTARTABLE_SERVICES:
            raise device.DeviceError("unknown service %r" % name)
        p = self.printer
        def refuse(why):
            return {"restart_result": "REFUSED", "restart_reason": why}
        if self.which_os() != device.OS_NEBULAOS:
            return refuse("no init script on this image")
        if p.supervisor_lock:
            return refuse("update supervisor lock held: %s" % p.supervisor_lock)
        if p.supervisor_validating:
            return refuse("update supervisor is validating")
        if p.print_state_readable and (p.printing or p.paused):
            return refuse("a print is active or paused")
        if name in device.PRINT_CRITICAL_SERVICES and not p.print_state_readable:
            return refuse("print state unreadable")
        p.services[name] = "running"
        p.restarts.append(name)
        p.log.append("restarted %s" % name)
        return {"restart_result": "DONE"}

    def stock_wayout_facts(self):
        self._t()
        return {
            "stock_mount": "mounted",
            "stock_ssh_init": "1" if self.printer.stock_has_dropbear else "0",
            "stock_ssh_binary": "1" if self.printer.stock_has_dropbear else "0",
            "wpa_conf": "present" if self.printer.stock_has_wifi_conf else "absent",
            "stock_rootfs": "present" if self.printer.partitions.get("rootfs") else "absent",
            "stock_kernel": "present" if self.printer.partitions.get("kernel") else "absent",
            "shadow": "1" if self.printer.stock_has_root_account else "0",
            "free_kib": str(self.printer.free_bytes // 1024),
        }

    # -- payload -----------------------------------------------------------
    def free_space(self, path):
        self._t()
        return self.printer.free_bytes

    def stage_file(self, local_path, name):
        self._t()
        with open(local_path, "rb") as fh:
            data = fh.read()
        self.printer.staged[name] = data
        if self.printer.busy_after_staging == name:
            self.printer.printing = True
        return hashlib.sha256(data).hexdigest()

    def staged_sha256(self, name):
        self._t()
        data = self.printer.staged.get(name)
        return hashlib.sha256(data).hexdigest() if data is not None else ""

    def apply_write_plans(self, plans, manifest_name):
        self._t()

        # The real session shells out to the STAGED helper:
        #   sh /usr/data/nebulaos-hwagent/flash-spare-slot.sh ...
        # so if nothing staged it, there is nothing to run. Modelling that is
        # what makes the "already on stock" path testable: an independent review
        # found that path never staged the helper, and this scenario passed
        # anyway because the simulator wrote partitions directly and never
        # consulted it.
        helper = self.printer.staged.get("flash-spare-slot.sh")
        if helper is None:
            return False, ("sh: can't open '/usr/data/nebulaos-hwagent/flash-spare-slot.sh': "
                           "No such file or directory")
        if self.printer.helper_must_equal is not None and helper != self.printer.helper_must_equal:
            return False, "flash-spare-slot.sh: staged helper is not the expected bytes"

        if self.printer.flash_helper_fails:
            return False, "flash-spare-slot.sh: preflight refused (simulated)"

        # The real helper refuses to write the slot it is booted from. Model it,
        # because an installer that tries is a bug worth catching here.
        live = self.active_root()
        for plan in plans:
            if targets.resolve(plan.target.name).device == live:
                return False, ("flash-spare-slot.sh: refusing to write %s, which is the live root"
                               % plan.target.name)

        source = {"kernel2": self.printer.staged.get("xImage"),
                  "rootfs2": self.printer.staged.get("rootfs.squashfs")}
        written = 0
        for plan in plans:
            data = source.get(plan.target.name)
            if data is None:
                return False, "nothing staged for %s" % plan.target.name
            if self.printer.interrupt_flash_after is not None \
                    and written + len(data) > self.printer.interrupt_flash_after:
                keep = max(0, self.printer.interrupt_flash_after - written)
                self.printer.partitions[plan.target.name] = data[:keep]
                self.printer.log.append("flash interrupted inside %s" % plan.target.name)
                raise SimTransportError("connection lost during flash (simulated)")
            if self.printer.corrupt_flash:
                data = data[:-1] + bytes([(data[-1] ^ 0xFF) if data else 0])
                self.printer.log.append("flash landed corrupted in %s" % plan.target.name)
            self.printer.partitions[plan.target.name] = data
            written += len(data)
        return True, "flash-spare-slot.sh: wrote and verified %d plan(s)" % len(plans)

    def read_target_image(self, target_name):
        # Mirrors the SSH session: only BACKUP_READABLE, always the whole partition.
        self._t()
        if target_name not in device.BACKUP_READABLE:
            raise device.DeviceError("%s is not a target this agent copies off the device" % target_name)
        size = targets.resolve(target_name).size
        data = self.printer.partitions.get(target_name, b"")
        data = data + b"\x00" * max(0, size - len(data))
        if self.printer.backup_read_short:
            data = data[:-1]
        if len(data) != size:
            raise device.DeviceError("read %d bytes of %s, expected %d" % (len(data), target_name, size))
        return data

    def apply_rtos2_plan(self, plan, staged_name):
        self._t()
        # The same refusal the shell writer makes, before anything else.
        device.rtos2_write_script(plan, staged_name)
        data = self.printer.staged.get(staged_name)
        if data is None or len(data) != plan.payload_size \
                or hashlib.sha256(data).hexdigest() != plan.payload_sha256:
            return False, {"guard": "STAGED_SHA"}
        old = self.printer.partitions.get("rtos2", b"")
        if self.printer.rtos_write_raises:
            self.printer.partitions["rtos2"] = data[:len(data) // 2] + old[len(data) // 2:]
            self.printer.log.append("rtos2 write interrupted")
            raise SimTransportError("connection lost during the rtos2 write (simulated)")
        if self.printer.rtos_write_corrupt:
            data = data[:-1] + bytes([data[-1] ^ 0xFF])
        self.printer.partitions["rtos2"] = data + old[len(data):]
        self.printer.rtos2_writes += 1
        self.printer.log.append("rtos2 written (%d bytes)" % len(data))
        readback = hashlib.sha256(self.printer.partitions["rtos2"][:plan.payload_size]).hexdigest()
        return readback == plan.payload_sha256, {
            "rtos2_write": "STARTED", "rtos2_dd_rc": "0", "rtos2_readback_sha256": readback}

    def region_sha256(self, target_name, length):
        self._t()
        data = self.printer.partitions.get(target_name, b"")
        return hashlib.sha256(data[:length]).hexdigest()

    # -- lifecycle ---------------------------------------------------------
    def reboot(self):
        self._t()
        self.printer.boot()
        self.closed = True
        return True

    def acquire_flash_lock(self, owner):
        self._t()
        if self.printer.flash_lock_holder and self.printer.flash_lock_holder != owner:
            return False, self.printer.flash_lock_holder
        self.printer.flash_lock_holder = owner
        return True, owner

    def release_flash_lock(self, owner):
        self._t()
        if self.printer.flash_lock_holder == owner:
            self.printer.flash_lock_holder = None
        return True

    def close(self):
        self.closed = True


def make_session_factory(printer, profile):
    """Build the seam the Installer takes.

    Reads the host key and credential from the ENROLLED PROFILE, exactly as the
    SSH factory does, so a profile with a wrong pinned key fails here the same
    way it would fail against a real printer.
    """
    def factory(which_os, address):
        host_key = profile.host_key(which_os)
        password = profile.credential(which_os)
        return SimSession(printer, which_os, address, host_key, password)
    return factory
