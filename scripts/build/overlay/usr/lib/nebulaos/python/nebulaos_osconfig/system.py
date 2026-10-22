# nebulaos_osconfig.system - read-only build/storage/service facts for the GUI
# (GUI/service readiness mission, 2026-10-09).
import json
import os
import re
import time

from . import common

SEED_MANIFEST = os.environ.get("NEBULAOS_SEED_MANIFEST",
                               "/opt/nebulaos-seeds/seed-manifest.json")
DATA_MOUNT = os.environ.get("NEBULAOS_DATA_MOUNT", "/usr/data")
DATA_FS_STATE = os.environ.get("NEBULAOS_DATA_FS_STATE", "/run/nebulaos/data-fs.state")
SFTP_SERVER = "/usr/libexec/sftp-server"
# Clean NebulaOS reset (S2, 2026-10-11): this flag, outside the namespace it
# wipes, makes S01persistent-datastore remove /usr/data/nebulaos on the next
# boot (see /usr/libexec/nebulaos/nebulaos-clean-reset).
CLEAN_RESET_FLAG = os.environ.get("NEBULAOS_CLEAN_RESET_FLAG",
                                  "/usr/data/.nebulaos-clean-reset")
# Left by nebulaos-clean-reset in the fresh namespace (G2): the screen says
# once that Wi-Fi has to be connected again, then clears it (ack-clean-reset).
AFTER_RESET_MARKER = os.path.join(common.NEBULAOS_ROOT, ".after-clean-reset")
CMDLINE = os.environ.get("NEBULAOS_CMDLINE", "/proc/cmdline")
SLOT_SWAP = os.environ.get("NEBULAOS_SLOT_SWAP", "/usr/libexec/nebulaos/nebulaos-slot-swap")
# docs/A_B_SLOT_MODEL.md: slot 1 (A) = kernel/rootfs p5/p7, slot 2 (B) =
# p6/p8. NebulaOS may run from either since 2026-10-14 (image updates).
ROOT_SLOTS = {"/dev/mmcblk0p7": "A", "/dev/mmcblk0p8": "B"}
# G65 (2026-10-16): one-line messages for the screen, one file each (e.g.
# config-edits.txt from config materialization), shown until acknowledged.
NOTICES_DIR = os.environ.get("NEBULAOS_NOTICES_DIR",
                             os.path.join(common.NEBULAOS_ROOT, "system", "notices"))
_NOTICE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")


def _read(path):
    try:
        with open(path) as handle:
            return handle.read().strip()
    except OSError:
        return ""


def build_info():
    try:
        with open(SEED_MANIFEST) as handle:
            manifest = json.load(handle)
    except (OSError, ValueError):
        return {"available": False}
    seeds = manifest.get("seeds") or {}

    def seed(name):
        return (seeds.get(name) or {}).get("seed_commit")
    return {"available": True,
            "nebulaos_version": manifest.get("nebulaos_version"),
            "firmware_head": manifest.get("firmware_head"),
            "build_date": manifest.get("build_date"),
            # Run 15: the screen pin under its new name; the old key stays
            # for anything that still reads it.
            "nebulascreen_pin": manifest.get("nebulascreen_pin") or manifest.get("guppyscreen_pin"),
            "guppyscreen_pin": manifest.get("guppyscreen_pin"),
            "klipper": seed("klipper"),
            "nebulaos_klipper_extensions": seed("nebulaos-klipper-extensions"),
            "moonraker": seed("moonraker")}


def storage_info():
    info = {"mount": DATA_MOUNT}
    try:
        st = os.statvfs(DATA_MOUNT)
        info.update(total_bytes=st.f_blocks * st.f_frsize,
                    free_bytes=st.f_bavail * st.f_frsize,
                    read_only=bool(st.f_flag & os.ST_RDONLY))
    except OSError as exc:
        info["error"] = str(exc)
    # G9 (/usr/libexec/nebulaos-datafs.sh): DATAFS_RESULT=, DATAFS_MOUNT=, ...
    state = common.parse_kv(_read(DATA_FS_STATE))
    info["boot_check"] = {k[len("DATAFS_"):].lower(): v.strip("'\"")
                          for k, v in state.items() if k.startswith("DATAFS_")} or None
    return info


def boot_slot():
    """"A" or "B" from root= on the kernel command line, None if unknown."""
    for arg in _read(CMDLINE).split():
        if arg.startswith("root="):
            return ROOT_SLOTS.get(arg[len("root="):])
    return None


def info():
    uname = os.uname()
    return {"build": build_info(),
            "slot": boot_slot(),
            "clean_reset_pending": os.path.exists(CLEAN_RESET_FLAG),
            "after_clean_reset": _read(AFTER_RESET_MARKER) or None,
            "kernel": {"release": uname.release, "version": uname.version},
            "hostname": _read("/proc/sys/kernel/hostname"),
            "storage": storage_info(),
            "sftp": {"available": os.access(SFTP_SERVER, os.X_OK)},
            "notices": notices()}


def notices():
    out = []
    try:
        names = sorted(os.listdir(NOTICES_DIR))
    except OSError:
        return out
    for name in names:
        nid = name[:-4] if name.endswith(".txt") else ""
        if _NOTICE_RE.match(nid):
            text = _read(os.path.join(NOTICES_DIR, name))
            if text:
                out.append({"id": nid, "text": text[:600]})
    return out


def ack_notice(nid):
    if not isinstance(nid, str) or not _NOTICE_RE.match(nid):
        raise common.invalid("INVALID_NOTICE", "unknown notice")
    try:
        os.unlink(os.path.join(NOTICES_DIR, nid + ".txt"))
    except FileNotFoundError:
        pass
    return {"result": "ACKNOWLEDGED", "id": nid}


# -- clean reset and boot slot (S2/S3, 2026-10-11) -----------------------------
# Both only arm the next boot; the Moonraker component refuses them while a
# print is active and reboots right after, or disarms them again if the
# reboot cannot be started.

def request_clean_reset():
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    common.atomic_write(CLEAN_RESET_FLAG, "requested=%s\n" % stamp, mode=0o600)
    return {"result": "SCHEDULED", "applies": "next boot"}


def ack_clean_reset():
    try:
        os.unlink(AFTER_RESET_MARKER)
    except FileNotFoundError:
        pass
    return {"result": "ACKNOWLEDGED"}


def cancel_clean_reset():
    try:
        os.unlink(CLEAN_RESET_FLAG)
        common.fsync_dir(os.path.dirname(CLEAN_RESET_FLAG))
    except FileNotFoundError:
        pass
    return {"result": "CANCELLED"}


def _slot_swap(target):
    rc, out, err = common.run([SLOT_SWAP, target], 30)
    if rc != 0:
        raise common.OsConfigError("SLOT_SWAP_FAILED",
                                   "could not set the boot slot (rc=%d)" % rc,
                                   log=(out + err).strip()[-1000:])


def swap_slot():
    """Next boot from the other slot (A <-> B), whichever is running.

    G91: refused while the printer is busy (request profile: a pending trial
    of the running slot counts - the fallback slot is never left while the
    new one is unconfirmed, S36). A switch into a slot that has not confirmed
    itself on this printer (system/slot-confirmed-<slot> missing or for other
    content) writes a TRIAL record, so S99nebulaos-image-trial checks it and
    falls back once (S30, S37). Creality's firmware never runs that check, so
    a switch into a Creality slot writes none."""
    current = boot_slot()
    if current not in ("A", "B"):
        raise common.OsConfigError("SLOT_UNKNOWN",
                                   "cannot tell which slot is running; nothing was changed")
    target = "A" if current == "B" else "B"
    from . import image   # image imports this module
    if not image.slot_bootable(target):
        raise common.OsConfigError("SLOT_EMPTY", "slot %s holds no system (an image install "
                                   "into it did not finish); install an image first" % target)
    common.refuse_if_busy("request")
    trial = None
    if not image.slot_confirmed(target):
        kname, _ = image.uimage_name(image._read_head(image.SLOTS[target]["kernel"]))
        kind = image.system_kind(kname)
        if kind != "creality":
            trial = {"from": current, "to": target, "reason": "slot_switch", "system": kind,
                     "file": None, "version": None, "started": int(time.time())}
            image.write_trial(trial)
    try:
        _slot_swap(target)
    except common.OsConfigError:
        if trial:
            image.remove_trial()
        raise
    return {"result": "ARMED", "next_boot": target, "from": current, "applies": "next boot",
            "trial": bool(trial)}


def keep_slot():
    """Undo swap_slot: next boot from the running slot again (and drop the
    TRIAL record that switch wrote)."""
    current = boot_slot()
    if current not in ("A", "B"):
        raise common.OsConfigError("SLOT_UNKNOWN", "cannot tell which slot is running")
    _slot_swap(current)
    from . import image
    trial, _ = common.read_json(image.TRIAL)
    if trial and trial.get("from") == current and trial.get("to") != current:
        image.remove_trial()
    return {"result": "DISARMED", "next_boot": current}
