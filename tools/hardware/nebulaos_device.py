"""The semantic operations an installer may perform on a printer.

WHY THIS IS AN INTERFACE AND NOT A PILE OF SSH CALLS

Two reasons, and the second is the important one.

First: every adversarial case this project needs to test - a wrong printer, a
host-key mismatch, a lease that moved, Stock unreachable, a print running, a
heater at temperature, a marker write that does not land, a crash while ARMED, a
dropped connection mid-flash, a hash mismatch, a second installer - is a
property of the DEVICE, not of SSH. Putting the device behind an interface means
all of them can be exercised offline against a simulator, which is the only way
any of them get tested before a real printer is at risk.

Second, and structurally: this class defines a CLOSED VOCABULARY. There is no
`run(command)` here, and no `read(device, offset, length)`. A caller can ask
"what is the marker", "is the printer idle", "write this plan" - it cannot ask
for an arbitrary command, an arbitrary block device or an arbitrary offset,
because no method takes one. That is what makes "the agent has no dd, no raw
offsets, no --command" a fact about the code rather than a promise about
behaviour.

Trusted internal code composes the real commands. It lives here, below the
interface, where it can be reviewed once.

THE SIMULATOR IS NOT IN THIS PACKAGE

Production code under tools/hardware/ contains no reference to any simulator and
no import path that could reach one. The simulator implements this same
interface and lives under tests/, so a shipped installer cannot construct it
even by accident - there is nothing to construct. Tests inject it.
"""

import abc
import hashlib
import os
import shlex
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nebulaos_capture as captures  # noqa: E402
import nebulaos_marker as marker  # noqa: E402
import nebulaos_target as targets  # noqa: E402

OS_NEBULAOS = "nebulaos"
OS_STOCK = "stock"
OS_UNKNOWN = "unknown"


class DeviceError(Exception):
    """An operation that could not be completed or could not be trusted."""


class Identity:
    """What makes this printer THIS printer.

    An IP address is not an identity - DHCP moves leases, and the machine
    answering at a remembered address may be a different one. These are the
    signals that do not move.
    """

    __slots__ = ("emmc_cid", "sn_mac_sha256", "machine_id", "partlabels")

    def __init__(self, emmc_cid, sn_mac_sha256, machine_id, partlabels):
        self.emmc_cid = emmc_cid
        self.sn_mac_sha256 = sn_mac_sha256
        self.machine_id = machine_id
        self.partlabels = tuple(sorted(partlabels or ()))

    def fingerprint(self):
        """A single stable value, over the signals that are per-unit and physical.

        Deliberately excludes machine_id: it lives in the rootfs, so it differs
        between the stock slot and the NebulaOS slot on the SAME printer. Using
        it here would make one physical device look like two.
        """
        blob = "|".join([
            "cid=%s" % (self.emmc_cid or ""),
            "sn_mac=%s" % (self.sn_mac_sha256 or ""),
        ]).encode("utf-8")
        return hashlib.sha256(blob).hexdigest()

    def is_complete(self):
        return bool(self.emmc_cid) and bool(self.sn_mac_sha256)

    def describe(self):
        return "\n".join([
            "DEVICE_EMMC_CID=%s" % (self.emmc_cid or "unknown"),
            "DEVICE_SN_MAC_SHA256=%s" % (self.sn_mac_sha256 or "unknown"),
            "DEVICE_MACHINE_ID=%s" % (self.machine_id or "unknown"),
            "DEVICE_FINGERPRINT=%s" % self.fingerprint(),
        ])


class IdleState:
    __slots__ = ("printing", "paused", "heater_targets", "klippy_state", "detail")

    def __init__(self, printing, paused, heater_targets, klippy_state, detail=""):
        self.printing = printing
        self.paused = paused
        self.heater_targets = dict(heater_targets or {})
        self.klippy_state = klippy_state
        self.detail = detail

    def is_idle(self):
        """Idle means not printing, not paused, and every heater target at zero.

        A paused print counts as active: resuming into a slot switch loses the
        job. A non-zero target counts as active even if the current temperature
        is low, because a target is an intent to heat.
        """
        if self.printing or self.paused:
            return False
        return all(float(v) == 0.0 for v in self.heater_targets.values())

    def why_not_idle(self):
        reasons = []
        if self.printing:
            reasons.append("a print is running")
        if self.paused:
            reasons.append("a print is paused")
        hot = {k: v for k, v in self.heater_targets.items() if float(v) != 0.0}
        if hot:
            reasons.append("heater target(s) not zero: %s"
                           % ", ".join("%s=%s" % (k, v) for k, v in sorted(hot.items())))
        return "; ".join(reasons) or "idle"

    def describe(self):
        return "\n".join([
            "PRINTER_PRINTING=%s" % ("YES" if self.printing else "NO"),
            "PRINTER_PAUSED=%s" % ("YES" if self.paused else "NO"),
            "PRINTER_HEATER_TARGETS=%s"
            % (",".join("%s=%s" % kv for kv in sorted(self.heater_targets.items())) or "none"),
            "PRINTER_KLIPPY_STATE=%s" % (self.klippy_state or "unknown"),
            "PRINTER_IDLE=%s" % ("YES" if self.is_idle() else "NO"),
            "PRINTER_IDLE_DETAIL=%s" % self.why_not_idle(),
        ])


class DeviceSession(abc.ABC):
    """The closed vocabulary. Implemented by SSH and, in tests, by a simulator."""

    # --- identity and state ------------------------------------------------
    @abc.abstractmethod
    def probe_identity(self):
        """-> Identity. Read-only."""

    @abc.abstractmethod
    def which_os(self):
        """-> OS_NEBULAOS | OS_STOCK | OS_UNKNOWN, decided structurally."""

    @abc.abstractmethod
    def active_root(self):
        """-> the resolved root= device, e.g. '/dev/mmcblk0p8'."""

    @abc.abstractmethod
    def boot_id(self):
        """-> an opaque per-boot value. Changes across a reboot; that IS the proof."""

    # --- the marker --------------------------------------------------------
    @abc.abstractmethod
    def read_marker_block(self):
        """-> the raw 512 bytes of the marker partition."""

    @abc.abstractmethod
    def write_marker(self, state):
        """Set the marker to `state` using the mechanism correct for the running OS.

        On NebulaOS this MUST route through /etc/ota_marker.sh's
        write_ota_marker(), because that helper fires the PLR tombstone when the
        target is stock. Writing the bytes directly would skip it and leave a
        stale journal that a later return to NebulaOS might try to resume.
        """

    # --- safety facts ------------------------------------------------------
    @abc.abstractmethod
    def idle_state(self):
        """-> IdleState."""

    @abc.abstractmethod
    def service_health(self):
        """-> dict of service name -> running bool, plus endpoint results."""

    @abc.abstractmethod
    def mcu_state(self):
        """-> dict: identity, whether the Stock MCU updater appears to have acted,
        and whether NebulaOS's MCU guard performed an automatic restore."""

    @abc.abstractmethod
    def stock_wayout_facts(self):
        """-> dict of the read-only facts that decide whether Stock is usable."""

    # --- payload and flashing ---------------------------------------------
    @abc.abstractmethod
    def free_space(self, path):
        """-> free bytes at `path`."""

    @abc.abstractmethod
    def stage_file(self, local_path, name):
        """Copy a local file into the staging area under `name`. -> sha256 ON THE DEVICE."""

    @abc.abstractmethod
    def staged_sha256(self, name):
        """-> sha256 of an already-staged file, recomputed on the device."""

    @abc.abstractmethod
    def apply_write_plans(self, plans, manifest_name):
        """Execute validated write plans. -> (ok, report).

        Takes WritePlan objects, never paths or offsets.
        """

    @abc.abstractmethod
    def region_sha256(self, target_name, length):
        """-> sha256 of the first `length` bytes of a named target.

        Length-bounded on purpose: a partition is larger than its payload, and
        hashing the padding would be comparing the wrong thing.
        """

    # --- diagnosis and repair ----------------------------------------------
    @abc.abstractmethod
    def diagnose(self):
        """-> text. A fixed, bounded, read-only report composed by this module."""

    @abc.abstractmethod
    def capture(self, profile):
        """-> text. One read-only capture profile, by NAME, from the fixed table
        in nebulaos_capture (TOOL-01). Never a script or a path."""

    @abc.abstractmethod
    def exercise(self, profile):
        """-> text. One reversible exercise profile, by NAME, from the fixed
        table in nebulaos_capture (TOOL-02); its undo runs from a trap."""

    @abc.abstractmethod
    def restart_service(self, name):
        """Restart one service named in RESTARTABLE_SERVICES, with the update
        supervisor's semantics. -> dict with restart_result=DONE|REFUSED|FAILED
        and restart_reason. Takes a service NAME, never a script or a path."""

    # --- lifecycle ---------------------------------------------------------
    @abc.abstractmethod
    def reboot(self):
        """Software reboot. Never a power cycle - this project cannot perform one,
        and a power cycle into stock is what auto-flashes the MCU."""

    @abc.abstractmethod
    def acquire_flash_lock(self, owner):
        """-> (ok, holder). A device-side lock so two installers cannot both write."""

    @abc.abstractmethod
    def release_flash_lock(self, owner):
        """Release a lock this owner holds."""

    @abc.abstractmethod
    def close(self):
        """Release transport resources."""


# ---------------------------------------------------------------------------
# The SSH implementation.
# ---------------------------------------------------------------------------


# The MCU guard (overlay etc/init.d/S50nebulaos-mcu-guard, write_state) records
# its outcome for THIS boot in a tmpfs state file. That file, not a grep of a
# persistent syslog, is the authority: it cannot carry a restore from an earlier
# boot, and its MCU_RESTORE_RESULT field is exactly what the guard decided.
#   not_attempted          -> 0 (no restore this boot)
#   any other value        -> 1 (a restore was attempted: stock's updater acted)
#   file missing/unreadable -> unknown (the guard's verdict cannot be read, which
#                             callers must treat as a failed check, never a pass)
MCU_GUARD_STATE = "/run/nebulaos-mcu-guard.state"


def mcu_restore_probe_cmd(state_path=MCU_GUARD_STATE):
    """-> shell text printing mcu_guard_restore=<0|1|unknown>, mcu_restore_result=<raw>
    and mcu_guard_result=<PASS|WARN|FAIL|unknown> (the guard's own verdict)."""
    q = shlex.quote(state_path)
    return ("r=$(sed -n 's/^MCU_RESTORE_RESULT=//p' %s 2>/dev/null | head -n 1); "
            "case \"$r\" in not_attempted) n=0 ;; '') n=unknown ;; *) n=1 ;; esac; "
            "printf 'mcu_guard_restore=%%s\\n' \"$n\"; "
            "printf 'mcu_restore_result=%%s\\n' \"${r:-unknown}\"; "
            "g=$(sed -n 's/^MCU_GUARD_RESULT=//p' %s 2>/dev/null | head -n 1); "
            "printf 'mcu_guard_result=%%s\\n' \"${g:-unknown}\"" % (q, q))

# Stock's own MCU updater (/etc/init.d/S13mcu_update -> mcu_util) runs at every
# stock boot and logs to /tmp/mcu_update.log on STOCK's tmpfs. Against a chip
# still running NebulaOS's firmware after a software reboot its handshake fails
# ("identify fail" / "handshake /dev/ttyS1 fail") and it does nothing - observed
# live (docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md, PRINTER_MAINBOARD_PRECONNECTION_
# CHECKLIST.md). Only meaningful on a stock session; classified fail-closed:
#   did_not_act       the log shows the handshake/identify failure
#   absent            no log (on NebulaOS this is expected; on stock it is not)
#   acted_or_unknown  a log that does NOT show the failure: assume it acted
STOCK_MCU_UPDATE_PROBE = (
    "f=/tmp/mcu_update.log; "
    "if [ ! -f \"$f\" ]; then u=absent; "
    "elif grep -qiE 'identify fail|handshake .*fail' \"$f\"; then u=did_not_act; "
    "else u=acted_or_unknown; fi; "
    "printf 'stock_mcu_update=%s\\n' \"$u\"")

# The services `restart` may name: service -> (init script, pidfile). Closed on
# purpose - an agent names a service, never a script. Paths are the overlay's
# own (etc/init.d/S55klipper, S56moonraker, S58guppyscreen, S50webcam) and
# Buildroot's nginx package (S50nginx).
RESTARTABLE_SERVICES = {
    "klipper": ("/etc/init.d/S55klipper", "/var/run/klippy.pid"),
    "moonraker": ("/etc/init.d/S56moonraker", "/var/run/moonraker.pid"),
    "guppyscreen": ("/etc/init.d/S58guppyscreen", "/var/run/guppyscreen.pid"),
    "webcam": ("/etc/init.d/S50webcam", "/var/run/ustreamer-supervisor.pid"),
    "nginx": ("/etc/init.d/S50nginx", "/run/nginx.pid"),
}

# Restarting Klippy ends a print and drops heater control, so it needs a
# PROVEN idle printer: an unreadable print state refuses. The others do not
# control the machine, so for them only a readable printing/paused state refuses.
PRINT_CRITICAL_SERVICES = frozenset({"klipper"})

# Read-only. Every section is bounded, and the whole report is capped, so a
# runaway log cannot flood the operator's terminal.
DIAGNOSE_SCRIPT = (
    "sec(){ printf '\\n===== %s =====\\n' \"$1\"; }; "
    "t(){ [ -f \"$1\" ] && { echo \"--- $1\"; tail -n 80 \"$1\"; }; }; "
    "{ "
    "sec system; uname -a; uptime; cat /proc/cmdline; "
    "sec memory; free; "
    "sec disk; df -h; "
    "sec marker; dd if=/dev/mmcblk0p1 bs=512 count=1 2>/dev/null | tr -d '\\000' | head -c 64; echo; "
    "sec processes; ps w; "
    "sec mcu-guard; cat /run/nebulaos-mcu-guard.state 2>&1; "
    "sec update-supervisor; ls -l /usr/data/nebulaos/updates/locks 2>&1; "
    "for f in /usr/data/nebulaos/updates/*/state.json; do [ -f \"$f\" ] && { echo \"--- $f\"; cat \"$f\"; }; done; "
    "sec moonraker-http; "
    "curl -s --max-time 5 http://127.0.0.1:7125/server/info 2>&1; echo; "
    "curl -s --max-time 5 'http://127.0.0.1:7125/printer/objects/query?print_stats&webhooks' 2>&1; echo; "
    "sec logs; "
    "for d in /opt/printer_data/logs /usr/data/printer_data/logs; do "
    "t \"$d/moonraker.log\"; t \"$d/klippy.log\"; done; "
    "t /var/log/messages; "
    "sec dmesg; dmesg 2>&1 | tail -n 80; "
    "sec moonraker-venv; ls /usr/data/nebulaos/envs/moonraker/lib/python3*/site-packages 2>&1 | head -n 80; "
    "} 2>&1 | head -c 262144")


def restart_script(name):
    """-> shell text restarting one known service, or raise DeviceError.

    Mirrors the update supervisor (etc/nebulaos-update-supervisor.sh):
    safe_stop_start - stop, wait up to 20s for the old process to exit, start,
    because the init scripts' own `restart` races BusyBox start-stop-daemon -
    and its print-idle gate. It also refuses while the supervisor holds any
    update lock or has a component in `validating`: a restart in the middle of a
    validation reads as a failed update and can roll back into factory-fallback.
    """
    if name not in RESTARTABLE_SERVICES:
        raise DeviceError("unknown service %r; restartable: %s"
                          % (name, ", ".join(sorted(RESTARTABLE_SERVICES))))
    init, pidfile = RESTARTABLE_SERVICES[name]
    critical = "1" if name in PRINT_CRITICAL_SERVICES else "0"
    return (
        "init=%s; pid=%s; critical=%s; R=/usr/data/nebulaos; "
        "refuse(){ printf 'restart_result=REFUSED\\nrestart_reason=%%s\\n' \"$1\"; exit 0; }; "
        "[ -x \"$init\" ] || refuse \"no init script $init on this image\"; "
        "for l in \"$R\"/updates/locks/*.lock; do "
        "[ -e \"$l\" ] && refuse \"update supervisor lock held: ${l##*/}\"; done; "
        "for s in \"$R\"/updates/*/state.json; do "
        "[ -f \"$s\" ] && grep -qE '\"state\": *\"validating\"' \"$s\" "
        "&& refuse \"update supervisor is validating: $s\"; done; "
        "st=$(wget -q -O - -T 5 'http://127.0.0.1:7125/printer/objects/query?print_stats=state' 2>/dev/null); "
        "printf '%%s' \"$st\" | grep -qE '\"state\": *\"(printing|paused)\"' "
        "&& refuse 'a print is active or paused'; "
        "if [ \"$critical\" = 1 ]; then printf '%%s' \"$st\" | grep -qE '\"state\": *\"' "
        "|| refuse 'print state unreadable (is Moonraker down?); restarting klipper needs a proven idle printer'; fi; "
        "old=$(cat \"$pid\" 2>/dev/null); "
        "\"$init\" stop >/dev/null 2>&1; "
        "n=0; while [ -n \"$old\" ] && [ -d \"/proc/$old\" ]; do "
        "n=$((n+1)); [ \"$n\" -ge 20 ] && break; sleep 1; done; "
        "\"$init\" start >/dev/null 2>&1; sleep 3; "
        "new=$(cat \"$pid\" 2>/dev/null); "
        "printf 'restart_old_pid=%%s\\nrestart_new_pid=%%s\\n' \"$old\" \"$new\"; "
        # A process that outlived the wait makes start-stop-daemon refuse to
        # start ("already running"): the pid is unchanged, nothing restarted.
        "if [ -n \"$old\" ] && [ \"$new\" = \"$old\" ]; then "
        "printf 'restart_result=FAILED\\nrestart_reason=old process %%s did not exit; not restarted\\n' \"$old\"; "
        "elif [ -n \"$new\" ] && [ -d \"/proc/$new\" ]; then printf 'restart_result=DONE\\n'; "
        "else printf 'restart_result=FAILED\\nrestart_reason=not running after start (pidfile %%s)\\n' \"$pid\"; fi"
        % (shlex.quote(init), shlex.quote(pidfile), critical))


_STAGE_DIR = "/usr/data/nebulaos-hwagent"
_LOCK_PATH = _STAGE_DIR + "/flash.lock"


class SshDeviceSession(DeviceSession):
    """Speaks to a real printer.

    Construction requires an already-resolved address and an already-decided
    credential: this class does not discover printers and does not choose
    passwords. Both come from the enrolled device profile, so a caller cannot
    point it somewhere by supplying a string.

    Host key policy is STRICT. The enrolled profile supplies the expected host
    key for the OS being addressed, it is written to a private known_hosts, and
    StrictHostKeyChecking=yes means a changed key is a refusal rather than a
    prompt. There is deliberately no accept-new anywhere: trust-on-first-use is
    how a machine that moved onto a remembered lease gets flashed.
    """

    def __init__(self, address, username, password, known_hosts_path, connect_timeout=10):
        self.address = address
        self.username = username
        self._password = password
        self.known_hosts_path = known_hosts_path
        self.connect_timeout = connect_timeout
        self._askpass = None

    # -- plumbing ----------------------------------------------------------
    def _ensure_askpass(self):
        """A private helper that prints the password.

        The password never appears in argv, where every local user could read it
        out of the process list. sshpass is not available in this environment and
        setsid breaks stdout capture here, so SSH_ASKPASS is the mechanism -
        the same one scripts/qa/display-live-capture.sh already uses.
        """
        if self._askpass:
            return self._askpass
        import tempfile
        fd, path = tempfile.mkstemp(prefix=".nebulaos-askpass.")
        os.fchmod(fd, 0o700)
        with os.fdopen(fd, "w") as fh:
            fh.write("#!/bin/sh\nprintf '%s\\n' " + shlex.quote(self._password) + "\n")
        self._askpass = path
        return path

    def _ssh_opts(self):
        return [
            "-o", "PreferredAuthentications=password",
            "-o", "PubkeyAuthentication=no",
            # STRICT. Not accept-new. See the class docstring.
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=%s" % self.known_hosts_path,
            "-o", "ConnectTimeout=%d" % self.connect_timeout,
            "-o", "BatchMode=no",
        ]

    def _run(self, script, timeout=120):
        """Run a shell script composed BY THIS MODULE on the device.

        Private by convention and by review: no method of DeviceSession exposes
        it, so an agent has no route to it.
        """
        env = dict(os.environ)
        env["SSH_ASKPASS"] = self._ensure_askpass()
        env["SSH_ASKPASS_REQUIRE"] = "force"
        argv = ["ssh"] + self._ssh_opts() + ["%s@%s" % (self.username, self.address), script]
        try:
            proc = subprocess.run(argv, capture_output=True, text=True,
                                  timeout=timeout, env=env)
        except subprocess.TimeoutExpired:
            raise DeviceError("command timed out after %ds against %s" % (timeout, self.address))
        return proc.returncode, proc.stdout, proc.stderr

    def _scp(self, local_path, remote_path, timeout=900):
        env = dict(os.environ)
        env["SSH_ASKPASS"] = self._ensure_askpass()
        env["SSH_ASKPASS_REQUIRE"] = "force"
        # -O: the legacy SCP protocol. OpenSSH >= 9.0 defaults to SFTP, and the
        # printer's dropbear (stock and NebulaOS) has no sftp-server - found on
        # the first real DEV_INSTALL run: "sh: /usr/libexec/sftp-server: not found".
        argv = ["scp", "-O"] + self._ssh_opts() + [
            local_path, "%s@%s:%s" % (self.username, self.address, remote_path)]
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=env)
        except subprocess.TimeoutExpired:
            raise DeviceError("transfer of %s timed out" % local_path)
        if proc.returncode != 0:
            raise DeviceError("transfer of %s failed: %s" % (local_path, proc.stderr.strip()[:300]))

    def _kv(self, script, timeout=60):
        rc, out, err = self._run(script, timeout=timeout)
        if rc != 0:
            raise DeviceError("probe failed (rc=%d): %s" % (rc, err.strip()[:300]))
        result = {}
        for line in out.splitlines():
            if "=" in line:
                k, _, v = line.partition("=")
                result[k.strip()] = v.strip()
        return result

    # -- identity ----------------------------------------------------------
    def probe_identity(self):
        facts = self._kv(
            "printf 'cid=%s\\n' \"$(cat /sys/block/mmcblk0/device/cid 2>/dev/null)\"; "
            "printf 'snmac=%s\\n' \"$(dd if=/dev/mmcblk0p2 bs=1024 count=1 2>/dev/null "
            "| sha256sum | cut -d' ' -f1)\"; "
            "printf 'machine=%s\\n' \"$(cat /etc/machine-id 2>/dev/null)\"; "
            "printf 'labels=%s\\n' \"$(ls /dev/disk/by-partlabel/ 2>/dev/null | tr '\\n' ',')\"")
        return Identity(
            emmc_cid=facts.get("cid") or None,
            sn_mac_sha256=facts.get("snmac") or None,
            machine_id=facts.get("machine") or None,
            partlabels=[p for p in (facts.get("labels") or "").split(",") if p],
        )

    def which_os(self):
        """Decided structurally, from files only one of the two images has.

        Not from /etc/os-release or a hostname, both of which are strings a
        misconfiguration could make lie.
        """
        rc, out, _ = self._run(
            "if [ -f /etc/ota_marker.sh ] && [ -d /opt/nebulaos ]; then echo nebulaos; "
            "elif [ -d /etc/ota_bin ]; then echo stock; else echo unknown; fi")
        if rc != 0:
            return OS_UNKNOWN
        value = out.strip()
        return value if value in (OS_NEBULAOS, OS_STOCK) else OS_UNKNOWN

    def active_root(self):
        rc, out, _ = self._run(
            "cat /proc/cmdline | tr ' ' '\\n' | grep '^root=' | head -1 | cut -d= -f2-")
        if rc != 0:
            raise DeviceError("cannot read /proc/cmdline")
        value = out.strip()
        if value.startswith("PARTUUID=") or value.startswith("LABEL="):
            rc2, out2, _ = self._run(
                "readlink -f /dev/disk/by-%s/%s 2>/dev/null"
                % ("partuuid" if value.startswith("PARTUUID=") else "label",
                   value.split("=", 1)[1]))
            if rc2 == 0 and out2.strip():
                return out2.strip()
        return value

    def boot_id(self):
        rc, out, _ = self._run("cat /proc/sys/kernel/random/boot_id 2>/dev/null")
        return out.strip() if rc == 0 else ""

    # -- marker ------------------------------------------------------------
    def read_marker_block(self):
        target = targets.resolve("ota")
        rc, out, err = self._run(
            "dd if=%s bs=512 count=1 2>/dev/null | od -An -tx1 -v" % target.device)
        if rc != 0:
            raise DeviceError("cannot read the marker partition: %s" % err.strip()[:200])
        hexbytes = out.split()
        if not hexbytes:
            raise DeviceError("marker read returned nothing")
        return bytes(int(h, 16) for h in hexbytes)

    def write_marker(self, state):
        if state not in (marker.KERNEL, marker.KERNEL2):
            raise DeviceError("refusing to write marker state %r" % state)
        running = self.which_os()
        if running == OS_NEBULAOS:
            # Through the on-device helper, so the PLR tombstone fires when the
            # target is stock. That is the whole reason not to write the bytes
            # directly from here: the helper is the only thing that tombstones
            # the NebulaOS PLR journal on a switch away from NebulaOS.
            #
            # Its exit status is MEANINGLESS and is not checked. Both of its dd
            # calls are `2>/dev/null` with unchecked status, and the function
            # returns whatever its trailing sync/if block returned, so
            # write_ota_marker cannot report failure. The read-back in
            # _set_marker_verified is the only evidence that this landed.
            self._run(". /etc/ota_marker.sh; write_ota_marker %s" % shlex.quote(state))
        elif running == OS_STOCK:
            # Stock's own helper is a TOGGLE with no argument, so it cannot be
            # asked for a specific slot. Write the canonical bytes instead.
            #
            # The bytes are produced by nebulaos_marker.canonical() and shipped
            # base64-encoded, so the 512-byte layout is never re-derived in
            # shell. An earlier revision computed canonical(state), threw it
            # away, and rebuilt the same format with `printf '%s\n\n'` plus a
            # seek/count zero-fill - a second implementation of the one thing
            # nebulaos_marker exists to own, and one that would drift silently.
            import base64
            payload = base64.b64encode(marker.canonical(state)).decode("ascii")
            self._run(
                "printf '%%s' %s | base64 -d | dd of=%s bs=512 count=1 conv=fsync 2>/dev/null; sync"
                % (shlex.quote(payload), targets.resolve("ota").device))
            # No rc check here, deliberately. The dd is silenced and a remote
            # shell's exit status reflects the last command, so it is not
            # evidence either way. The read-back in the caller is the only
            # evidence that this landed - see _set_marker_verified.
        else:
            raise DeviceError("refusing to write the marker from an unidentified OS")
        # Drop caches so the read-back comes from the device, not the page cache.
        self._run("sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; true")
        return True

    # -- safety facts ------------------------------------------------------
    def idle_state(self):
        rc, out, _ = self._run(
            "curl -s --max-time 5 http://127.0.0.1:7125/printer/objects/query"
            "?print_stats\\&extruder\\&heater_bed 2>/dev/null")
        printing = paused = False
        heaters = {}
        klippy = "unknown"
        if rc == 0 and out.strip():
            import json
            try:
                data = json.loads(out).get("result", {}).get("status", {})
                state = (data.get("print_stats") or {}).get("state", "")
                printing = state == "printing"
                paused = state == "paused"
                for name in ("extruder", "heater_bed"):
                    obj = data.get(name) or {}
                    if "target" in obj:
                        heaters[name] = obj["target"]
            except (ValueError, AttributeError):
                pass
        info = self._kv("printf 'k=%s\\n' \"$(curl -s --max-time 5 "
                        "http://127.0.0.1:7125/server/info 2>/dev/null "
                        "| sed -n 's/.*\"klippy_state\": *\"\\([a-z]*\\)\".*/\\1/p')\"")
        klippy = info.get("k") or "unknown"
        if not heaters:
            # No answer is not evidence of zero. Report it as unknown-and-unsafe
            # by putting a sentinel target in, so is_idle() is False.
            heaters = {"unreadable": 1}
        return IdleState(printing, paused, heaters, klippy,
                         detail="moonraker query" if rc == 0 else "moonraker unreachable")

    def service_health(self):
        facts = self._kv(
            # BusyBox `ps w` (NebulaOS's BusyBox has no pgrep - found on the first
            # real DEV_INSTALL of the Buildroot 2025 image, where every service
            # read "stopped" while nginx was serving HTTP 200). The bracketed
            # patterns cannot match this probe's own command line.
            "P=$(ps w 2>/dev/null); "
            "for pair in 'klipper:[k]lippy' 'moonraker:[m]oonraker' "
            "'guppyscreen:[g]uppyscreen' 'nginx:[n]ginx'; do "
            "  n=${pair%%:*}; pat=${pair#*:}; "
            "  if printf '%s\\n' \"$P\" | grep -q \"$pat\"; then printf '%s=running\\n' \"$n\"; "
            "  else printf '%s=stopped\\n' \"$n\"; fi; done; "
            "printf 'moonraker_http=%s\\n' \"$(curl -s -o /dev/null -w '%{http_code}' "
            "--max-time 5 http://127.0.0.1:7125/server/info 2>/dev/null)\"; "
            "printf 'web_http=%s\\n' \"$(curl -s -o /dev/null -w '%{http_code}' "
            "--max-time 5 http://127.0.0.1/ 2>/dev/null)\"")
        return facts

    def diagnose(self):
        rc, out, err = self._run(DIAGNOSE_SCRIPT, timeout=90)
        if rc != 0 and not out:
            raise DeviceError("diagnose failed (rc=%d): %s" % (rc, err.strip()[:300]))
        return out

    def capture(self, profile):
        try:
            script, timeout = captures.capture_script(profile)
        except captures.CaptureError as exc:
            raise DeviceError(str(exc))
        rc, out, err = self._run(script, timeout=timeout + 60)
        if rc != 0 and not out:
            raise DeviceError("capture %s failed (rc=%d): %s" % (profile, rc, err.strip()[:300]))
        return out

    def exercise(self, profile):
        try:
            script, timeout = captures.exercise_script(profile)
        except captures.CaptureError as exc:
            raise DeviceError(str(exc))
        rc, out, err = self._run(script, timeout=timeout + 60)
        if rc != 0 and not out:
            raise DeviceError("exercise %s failed (rc=%d): %s" % (profile, rc, err.strip()[:300]))
        return out

    def restart_service(self, name):
        # Up to 20s for the old process, 3s settle, plus the probes.
        return self._kv(restart_script(name), timeout=90)

    def mcu_state(self):
        return self._kv(
            mcu_restore_probe_cmd() + "; " + STOCK_MCU_UPDATE_PROBE + "; "
            # The KE's MCU is on a UART (/dev/ttyS1, machine.cfg [mcu] serial), so
            # /dev/serial/by-id (USB only) never lists it. Presence is what Klipper
            # itself reports: the MCU's firmware version via Moonraker.
            "printf 'mcu_uart=%s\\n' \"$([ -c /dev/ttyS1 ] && echo present || echo absent)\"; "
            "printf 'mcu_serial=%s\\n' \"$(curl -s --max-time 5 "
            "'http://127.0.0.1:7125/printer/objects/query?mcu' 2>/dev/null "
            "| sed -n 's/.*\"mcu_version\": *\"\\([^\"]*\\)\".*/\\1/p')\"")

    def stock_wayout_facts(self):
        # Facts about STOCK are read from stock's own root filesystem, not from
        # the running NebulaOS system: /etc here is NebulaOS's, which ships its
        # own dropbear script, so an earlier revision's "stock has an SSH
        # daemon" check could never fail. Slot 1's rootfs (p7) is a squashfs; it
        # is mounted READ-ONLY in a private temporary directory and unmounted
        # before this returns. A mount that fails yields zeros - fail closed.
        # Wi-Fi: stock's wpa_supplicant runs with /usr/data/wpa_supplicant.conf
        # on the shared data partition (its /proc/<pid>/cmdline, FIRMWARE.md);
        # stock's /etc/wpa_supplicant.conf is an unused template.
        return self._kv(
            "m=$(mktemp -d /tmp/.nebulaos-stockro.XXXXXX); "
            "if [ -n \"$m\" ] && mount -t squashfs -o ro /dev/mmcblk0p7 \"$m\" 2>/dev/null; then "
            "ok=mounted; "
            "i=$(ls \"$m/etc/init.d\" 2>/dev/null | grep -ciE 'dropbear|sshd'); "
            "b=0; for x in usr/sbin/dropbear usr/bin/dropbear sbin/dropbear usr/sbin/sshd; do "
            "[ -x \"$m/$x\" ] && b=1; done; "
            "s=$(grep -c '^root:' \"$m/etc/shadow\" 2>/dev/null); "
            "umount \"$m\"; else ok=failed; i=0; b=0; s=0; fi; "
            "[ -n \"$m\" ] && rmdir \"$m\" 2>/dev/null; "
            "printf 'stock_mount=%s\\n' \"$ok\"; "
            "printf 'stock_ssh_init=%s\\n' \"${i:-0}\"; "
            "printf 'stock_ssh_binary=%s\\n' \"$b\"; "
            "printf 'shadow=%s\\n' \"${s:-0}\"; "
            "printf 'wpa_conf=%s\\n' \"$([ -s /usr/data/wpa_supplicant.conf ] "
            "&& grep -q 'ssid=' /usr/data/wpa_supplicant.conf && echo present || echo absent)\"; "
            "printf 'stock_rootfs=%s\\n' \"$([ -b /dev/mmcblk0p7 ] && echo present || echo absent)\"; "
            "printf 'stock_kernel=%s\\n' \"$([ -b /dev/mmcblk0p5 ] && echo present || echo absent)\"; "
            "printf 'free_kib=%s\\n' \"$(df -k /usr/data | awk 'NR==2{print $4}')\"")

    # -- payload -----------------------------------------------------------
    def free_space(self, path):
        facts = self._kv("printf 'free=%%s\\n' \"$(df -k %s | awk 'NR==2{print $4}')\"" % shlex.quote(path))
        try:
            return int(facts.get("free", "0")) * 1024
        except ValueError:
            return 0

    def stage_file(self, local_path, name):
        self._run("mkdir -p %s" % _STAGE_DIR)
        # Quoted like every other remote path here. scp's destination is shell-
        # expanded on the far side by pre-9.0 OpenSSH, and `name` being a literal
        # today is a property of the callers, not of this function.
        remote = "%s/%s" % (_STAGE_DIR, shlex.quote(name))
        self._scp(local_path, remote)
        return self.staged_sha256(name)

    def staged_sha256(self, name):
        facts = self._kv("printf 'sha=%%s\\n' \"$(sha256sum %s/%s 2>/dev/null | cut -d' ' -f1)\""
                         % (_STAGE_DIR, shlex.quote(name)))
        return facts.get("sha", "")

    def apply_write_plans(self, plans, manifest_name):
        """Delegate to scripts/flash-spare-slot.sh, which owns slot-2 writes.

        Not reimplemented here. That script carries the live-target collision
        refusal, the partlabel and major/minor checks, the capacity checks and
        the post-write read-back, and it has its own offline test suite. A second
        implementation would be a second thing to keep correct.

        The plans are still validated here first, so the write that reaches it
        has been through the target/policy layer.
        """
        for plan in plans:
            if plan.target.name not in ("kernel2", "rootfs2"):
                raise DeviceError(
                    "the on-device flash helper is specialised for slot 2; %s needs the "
                    "generic backend, which this session does not expose"
                    % plan.target.name)
        rc, out, err = self._run(
            "sh %s/flash-spare-slot.sh %s/xImage %s/rootfs.squashfs %s/%s"
            % (_STAGE_DIR, _STAGE_DIR, _STAGE_DIR, _STAGE_DIR, shlex.quote(manifest_name)),
            timeout=1800)
        return rc == 0, out + err

    def region_sha256(self, target_name, length):
        target = targets.resolve(target_name)
        if length <= 0 or length > target.size:
            raise DeviceError("region length %d is outside %s (capacity %d)"
                              % (length, target_name, target.size))
        facts = self._kv(
            "printf 'sha=%%s\\n' \"$(dd if=%s bs=1M count=%d 2>/dev/null | head -c %d "
            "| sha256sum | cut -d' ' -f1)\""
            % (target.device, (length + 1048575) // 1048576, length), timeout=600)
        return facts.get("sha", "")

    # -- lifecycle ---------------------------------------------------------
    def reboot(self):
        self._run("sync; (sleep 1; reboot) >/dev/null 2>&1 &")
        return True

    def acquire_flash_lock(self, owner):
        rc, out, _ = self._run(
            "mkdir -p %s; if mkdir %s.d 2>/dev/null; then printf '%%s' %s > %s; echo ACQUIRED; "
            "else printf 'HELD=%%s\\n' \"$(cat %s 2>/dev/null)\"; fi"
            % (_STAGE_DIR, _LOCK_PATH, shlex.quote(owner), _LOCK_PATH, _LOCK_PATH))
        if "ACQUIRED" in out:
            return True, owner
        holder = ""
        for line in out.splitlines():
            if line.startswith("HELD="):
                holder = line.split("=", 1)[1]
        return False, holder

    def release_flash_lock(self, owner):
        self._run("if [ \"$(cat %s 2>/dev/null)\" = %s ]; then rm -rf %s.d %s; fi"
                  % (_LOCK_PATH, shlex.quote(owner), _LOCK_PATH, _LOCK_PATH))
        return True

    def close(self):
        if self._askpass:
            try:
                os.unlink(self._askpass)
            except OSError:
                pass
            self._askpass = None
