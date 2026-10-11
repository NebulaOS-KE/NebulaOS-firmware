"""rtos-logo and rtos-logo-restore: the NebulaOS boot logo on rtos2, and the way back.

WHAT IS WRITTEN, AND WHAT NEVER IS

SPL loads rtos2 (p4) when the OTA marker is ota:kernel2 and rtos (p3)
otherwise. `rtos-logo` writes rtos2 with the pinned NebulaOS RTOS image - the
stock zero.bin with only its 480x272 boot-logo JPEG replaced
(scripts/package/rtos_logo.py). `rtos-logo-restore` writes a backup taken by
this module back to rtos2. Nothing here can name rtos (p3), a kernel, a rootfs
or the marker: the policy is targets.RTOS2_ONLY and the device-side writer
refuses any other target on its own.

WHY THIS NEEDS ITS OWN SAFETY CASE

The RTOS runs before Linux. A broken rtos2 is a NebulaOS boot that stops in
SPL, recoverable only over USB mask-ROM (docs/DEVELOPER_RECOVERY.md, "RTOS
logo: restoring rtos2"). So:

  * the printer must be running NebulaOS from p8 with the marker on
    ota:kernel2, idle with every heater target at zero, with no install
    transaction open and both the host and the device lock held;
  * the stock bytes the logo is patched into are the printer's OWN rtos2, and
    only if its first 432824 bytes are the pinned stock image; anything else
    is refused (an already-patched rtos2 is reported and left alone);
  * the complete 4 MiB rtos2 is copied to the host and verified against the
    device's own hash BEFORE anything is written. The backup is never
    overwritten, and a restore must name it by sha256;
  * the write is one dd with fsync of the staged, hash-checked file, read back
    on the device, then hashed again from the host over the written length and
    over the whole partition; rtos (p3) is hashed before and after and must not
    change;
  * a failed or unverified write says, every time: do not reboot or power
    cycle, restore from the named backup.

There is no reboot here. The new logo shows at the next NebulaOS boot.
"""

import hashlib
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_HERE, "..", "..", "scripts", "package"))

import nebulaos_device as device      # noqa: E402
import nebulaos_journal as journal    # noqa: E402
import nebulaos_marker as marker      # noqa: E402
import nebulaos_target as targets     # noqa: E402
import rtos_logo                      # noqa: E402

LOGO_CONFIRM_WORD = "RTOS_LOGO_CONFIRM=RTOS2"
RESTORE_CONFIRM_WORD = "RTOS_RESTORE_CONFIRM=RTOS2"
STAGED_LOGO = "zero2.bin"
STAGED_RESTORE = "rtos2-restore.bin"
NEBULAOS_ROOT = "/dev/mmcblk0p8"


class RtosError(Exception):
    """A refusal or a failure. `written` is True once bytes may have reached rtos2."""

    def __init__(self, message, written=False, backup=None):
        super().__init__(message)
        self.written = written
        self.backup = backup


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def backup_dir(device_id):
    path = os.path.join(journal.state_home(), "rtos-backups", device_id)
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


def write_backup(device_id, image, facts):
    """Keep `image` (a whole rtos2) on the host. -> path. O_EXCL, never replaced;
    re-read and re-hashed after the write."""
    digest = sha256(image)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    for n in range(100):
        path = os.path.join(backup_dir(device_id), "rtos2-%s-%s%s.bin"
                            % (stamp, digest[:16], "-%d" % n if n else ""))
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            break
        except FileExistsError:
            continue
    else:
        raise RtosError("no free backup file name under %s" % backup_dir(device_id))
    with os.fdopen(fd, "wb") as fh:
        fh.write(image)
        fh.flush()
        os.fsync(fh.fileno())
    with open(path, "rb") as fh:
        if sha256(fh.read()) != digest:
            raise RtosError("the host backup %s does not read back as %s" % (path, digest))
    with open(path[:-4] + ".txt", "x", encoding="utf-8") as fh:
        fh.write("".join("%s=%s\n" % kv for kv in [("SHA256", digest), ("SIZE", len(image))] + facts))
    return path


def find_backup(device_id, digest):
    """-> (path, bytes) of this device's backup whose content is `digest`."""
    d = backup_dir(device_id)
    for name in sorted(os.listdir(d)):
        if name.endswith(".bin") and digest[:16] in name:
            with open(os.path.join(d, name), "rb") as fh:
                data = fh.read()
            if sha256(data) == digest:
                return os.path.join(d, name), data
    raise RtosError("no rtos2 backup with sha256 %s for this device under %s" % (digest, d))


def log(device_id, control_commit, op, result, detail):
    path = os.path.join(os.path.dirname(backup_dir(device_id)), "%s.log" % device_id)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write("%s DEVICE=%s CONTROL=%s OP=%s RESULT=%s DETAIL=%s\n" % (
            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), device_id, control_commit,
            op, result, (detail or "").replace("\n", " ")[:300]))


class RtosOperation:
    """One rtos-logo or rtos-logo-restore run against a connected, identity-
    matched NebulaOS session. The caller holds the host lock and has checked
    that no install transaction is open."""

    def __init__(self, device_id, session, say, control_commit):
        self.device_id = device_id
        self.session = session
        self.say = say
        self.control_commit = control_commit
        self.target = targets.RTOS2_ONLY.select("rtos2")
        self.size = self.target.size

    # -- guards ---------------------------------------------------------------
    def _guards(self):
        s = self.session
        if s.which_os() != device.OS_NEBULAOS:
            raise RtosError("the printer is not running NebulaOS")
        root = s.active_root()
        self.say("ACTIVE_ROOT=%s" % root)
        if root != NEBULAOS_ROOT:
            raise RtosError("NebulaOS should run from %s but root=%s" % (NEBULAOS_ROOT, root))
        state, why = marker.parse(s.read_marker_block())
        self.say(marker.describe(state, why))
        if state != marker.KERNEL2:
            raise RtosError("the OTA marker does not select NebulaOS (%s: %s); rtos2 is the RTOS "
                            "of the NebulaOS slot and is written only while that slot is selected"
                            % (state, why))
        idle = s.idle_state()
        self.say(idle.describe())
        if not idle.is_idle():
            raise RtosError("rtos2 is written only on a proven idle printer: %s" % idle.why_not_idle())

    def _backup(self, op):
        """The whole rtos2 to the host, proven equal to the device's own hash."""
        image = self.session.read_target_image("rtos2")
        on_device = self.session.region_sha256("rtos2", self.size)
        if len(image) != self.size or sha256(image) != on_device:
            raise RtosError("the copy of rtos2 (%d bytes, %s) does not match the device's hash %s"
                            % (len(image), sha256(image)[:16], on_device[:16]))
        path = write_backup(self.device_id, image, [
            ("DEVICE", self.device_id), ("OP", op), ("CONTROL", self.control_commit),
            ("BOOT_ID", self.session.boot_id()), ("TAKEN_AT", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))])
        self.say("RTOS2_BACKUP=%s" % path)
        self.say("RTOS2_BACKUP_SHA256=%s" % sha256(image))
        return image, path

    def _write(self, payload, staged_name, backup_path, backup_sha):
        """Stage, re-check, write, read back. -> True, or raise RtosError."""
        s = self.session
        plan = self.target.plan_write(len(payload), sha256(payload))
        self.say(plan.describe())
        rtos_before = s.region_sha256("rtos", targets.resolve("rtos").size)
        self.say("RTOS_P3_SHA256_BEFORE=%s" % rtos_before)

        import tempfile
        with tempfile.TemporaryDirectory(prefix=".nebulaos-rtos.") as tmpdir:
            local = os.path.join(tmpdir, staged_name)
            with open(local, "wb") as fh:
                fh.write(payload)
            staged = s.stage_file(local, staged_name)
        if staged != plan.payload_sha256:
            raise RtosError("the staged %s hashes %s on the device, expected %s"
                            % (staged_name, staged, plan.payload_sha256))
        self.say("STAGED=%s sha256=%s" % (staged_name, staged))

        # The window between the checks and the write is a print or a slot
        # switch away from mattering: look again.
        self._guards()
        try:
            ok, report = s.apply_rtos2_plan(plan, staged_name)
        except Exception as exc:
            raise RtosError("the rtos2 write did not report back: %s" % str(exc)[:200],
                            written=True, backup=(backup_path, backup_sha))
        for key in sorted(report):
            self.say("RTOS2_%s=%s" % (key.upper(), report[key]))
        if not ok:
            raise RtosError("the rtos2 write failed or did not read back as %s" % plan.payload_sha256,
                            written=report.get("rtos2_write") == "STARTED",
                            backup=(backup_path, backup_sha))
        written = s.region_sha256("rtos2", len(payload))
        rtos_after = s.region_sha256("rtos", targets.resolve("rtos").size)
        self.say("RTOS2_READBACK_SHA256=%s" % written)
        self.say("RTOS_P3_SHA256_AFTER=%s" % rtos_after)
        if written != plan.payload_sha256:
            raise RtosError("rtos2 reads back as %s from the host, expected %s"
                            % (written, plan.payload_sha256), written=True,
                            backup=(backup_path, backup_sha))
        if rtos_after != rtos_before:
            raise RtosError("rtos (p3) changed during an rtos2 write (%s -> %s)"
                            % (rtos_before[:16], rtos_after[:16]), written=True,
                            backup=(backup_path, backup_sha))
        self.say("RTOS_P3_UNCHANGED=YES")
        return True

    # -- the operations -------------------------------------------------------
    def logo(self):
        self._guards()
        image, path = self._backup("rtos-logo")
        head = image[:rtos_logo.STOCK_ZERO_SIZE]
        kind = {rtos_logo.STOCK_ZERO_SHA256: "stock",
                rtos_logo.NEBULAOS_ZERO_SHA256: "nebulaos"}.get(sha256(head), "unknown")
        self.say("RTOS2_FIRST_%d_IS=%s" % (rtos_logo.STOCK_ZERO_SIZE, kind))
        if kind == "nebulaos":
            self.say("RTOS2_LOGO=ALREADY_PRESENT (nothing written)")
            return "ALREADY_PRESENT"
        if kind != "stock":
            raise RtosError("rtos2 does not start with the pinned stock RTOS image (%s); refusing to "
                            "patch unknown bytes. Restore a known backup or investigate first."
                            % sha256(head))
        try:
            patched = rtos_logo.nebulaos_image(head)
        except rtos_logo.LogoError as exc:
            raise RtosError("cannot build the pinned NebulaOS RTOS image: %s" % exc)
        self._write(patched, STAGED_LOGO, path, sha256(image))
        full = self.session.region_sha256("rtos2", self.size)
        expect = sha256(patched + image[len(patched):])
        self.say("RTOS2_FULL_SHA256=%s" % full)
        if full != expect:
            raise RtosError("rtos2 as a whole is %s, expected %s (the bytes after the image changed)"
                            % (full, expect), written=True, backup=(path, sha256(image)))
        self.say("RTOS2_LOGO=WRITTEN (shows at the next NebulaOS boot)")
        return "WRITTEN"

    def restore(self, backup_sha):
        path, data = find_backup(self.device_id, backup_sha)
        self.say("RTOS2_RESTORE_FROM=%s" % path)
        if len(data) != self.size:
            raise RtosError("the backup is %d bytes, rtos2 is %d" % (len(data), self.size))
        if data[rtos_logo.RTOS_TAG_OFFSET:rtos_logo.RTOS_TAG_OFFSET + 4] != rtos_logo.RTOS_TAG:
            raise RtosError("the backup has no RTOS tag at byte %d; SPL would refuse it"
                            % rtos_logo.RTOS_TAG_OFFSET)
        self._guards()
        if self.session.region_sha256("rtos2", self.size) == backup_sha:
            self.say("RTOS2_RESTORE=ALREADY_EQUAL (nothing written)")
            return "ALREADY_EQUAL"
        image, current = self._backup("rtos-logo-restore")
        self._write(data, STAGED_RESTORE, current, sha256(image))
        self.say("RTOS2_RESTORE=WRITTEN")
        return "WRITTEN"
