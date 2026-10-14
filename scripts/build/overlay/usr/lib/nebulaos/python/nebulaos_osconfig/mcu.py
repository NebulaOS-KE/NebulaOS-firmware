# nebulaos_osconfig.mcu - MCU firmware from the touchscreen (development
# run 4, 2026-10-11): "plug in USB, pick a compiled .bin, flash - no Creality
# bootloader knowledge needed".
#
#   status   what the boot-time MCU guard found, who owns the MCU, last flash
#   list     candidate .bin files: Mainsail uploads (config/firmware/mcu), a
#            mounted USB stick (gcodes/USB/<dev>, /etc/usb-gcode-media.sh) and
#            the built-in NebulaOS firmware; each one checked offline
#   flash    one file, by id and the sha256 the user confirmed
#
# Flashing is NOT reimplemented here. The file is checked and prepared
# (mcu_image.prepare(): a raw NebulaOS-klipper-mcu build is packed into the
# Creality format), snapshotted to tmpfs so a pulled USB stick or a new upload
# cannot change it mid-flight, and handed to the existing CLI,
# `nebulaos-mcu flash <file>`, which refuses while printing, stops Klipper,
# runs mcu_flash_file.py (bootloader entry, hardware-id allow-list, transfer,
# app start) and restarts Klipper whatever happened.
import fcntl
import os
import re
import stat
import sys
import time

from . import common
from .common import invalid, OsConfigError

UPLOAD_DIR = os.environ.get("NEBULAOS_MCU_UPLOAD_DIR",
                            "/opt/printer_data/config/firmware/mcu")
USB_DIR = os.environ.get("NEBULAOS_MCU_USB_DIR", "/opt/printer_data/gcodes/USB")
BUILTIN = os.environ.get("NEBULAOS_MCU_BUILTIN",
                         "/opt/nebulaos/mcu-candidates/candidate-001.bin")
MCU_LIB = os.environ.get("NEBULAOS_MCU_LIB", "/etc/nebulaos")
MCU_CLI = os.environ.get("NEBULAOS_MCU_CLI", "/usr/bin/nebulaos-mcu")
GUARD_STATE = os.environ.get("NEBULAOS_MCU_GUARD_STATE", "/run/nebulaos-mcu-guard.state")
MANAGED_FLAG = os.environ.get("NEBULAOS_MCU_MANAGED_FLAG",
                              "/usr/data/nebulaos/mcu/managed")
LAST_FLASH = os.path.join(common.NEBULAOS_ROOT, "mcu", "last-flash.json")
STAGE_DIR = os.path.join(common.RUN_DIR, "mcu")
FLASH_TIMEOUT = int(os.environ.get("NEBULAOS_MCU_FLASH_SECONDS", "600"))

# Bounded scan: a USB stick full of files must not stall the screen.
MAX_FILE_BYTES = 1 << 20          # anything larger is reported, never read
MAX_ENTRIES = 400                 # directory entries looked at per root
USB_DEPTH = 1                     # the stick's top level and one folder down
_ID_PART = re.compile(r"^[^/\x00]+$")


def _image_module():
    if MCU_LIB not in sys.path:
        sys.path.insert(0, MCU_LIB)
    import mcu_image
    return mcu_image


# -- status ----------------------------------------------------------------------

def _read_state(path):
    out = {}
    try:
        with open(path) as handle:
            text = handle.read(16384)
    except OSError:
        return None
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] == "'":
            value = value[1:-1].replace("'\\''", "'")
        out[key.strip()] = value
    return out


def _managed():
    try:
        with open(MANAGED_FLAG) as handle:
            return handle.read().strip() != "false"
    except OSError:
        return True


def status():
    state = _read_state(GUARD_STATE)
    last, _ = common.read_json(LAST_FLASH)
    guard = None
    if state is not None:
        guard = {"result": state.get("MCU_GUARD_RESULT", "unknown"),
                 "lifecycle": state.get("MCU_LIFECYCLE_STATE", "unknown"),
                 "application_class": state.get("MCU_APPLICATION_CLASS", "unknown"),
                 "application_identity": state.get("MCU_APPLICATION_IDENTITY", "unknown"),
                 "timestamp": state.get("MCU_GUARD_TIMESTAMP", "unknown")}
    return {"guard": guard, "managed": _managed(), "last_flash": last,
            "upload_dir": UPLOAD_DIR}


# -- list ------------------------------------------------------------------------

def _inspect(path, size):
    """Common fields + the offline verdict for one regular file."""
    entry = {"size": size, "valid": False, "kind": None, "problem": None,
             "sha256": None, "klipper_version": None}
    if size > MAX_FILE_BYTES:
        entry["problem"] = "too large (%d bytes) to be MCU firmware" % size
        return entry
    try:
        with open(path, "rb") as handle:
            data = handle.read(MAX_FILE_BYTES + 1)
    except OSError as exc:
        entry["problem"] = "unreadable: %s" % exc.strerror
        return entry
    img = _image_module()
    entry["sha256"] = img.sha256(data)
    kind, reason = img.classify(data)
    entry.update(kind=kind, valid=kind is not None, problem=reason)
    if kind is not None:
        entry["klipper_version"] = img.klipper_version(data)
    return entry


def _creality_build(version):
    """Creality's MCU firmware: the exact identity the guard knows, or the
    build-host signature Creality's builds carry in their data dictionary."""
    if not version:
        return False
    _image_module()                     # puts MCU_LIB on sys.path
    try:
        import mcu_known_identities
        if version in mcu_known_identities.KNOWN_STOCK_VERSIONS:
            return True
    except ImportError:
        pass
    return "longer-virtual-machine" in version


def _version_note(entry, builtin_version):
    """G32: a firmware from another Klipper release than NebulaOS's own MCU
    firmware usually lacks commands the host Klipper needs, and Klipper then
    refuses the board. The same release (even another commit) is fine - that
    is how NebulaOS's firmware and host Klipper relate today."""
    img = _image_module()
    mine, theirs = img.release_of(builtin_version), img.release_of(entry.get("klipper_version"))
    if not entry.get("valid") or entry.get("native"):
        return None
    if _creality_build(entry.get("klipper_version")):
        # G35 (2026-10-14): accepted - going back to Creality's firmware needs
        # it - but said plainly.
        return ("Creality's own firmware: NebulaOS's Klipper cannot use it. Only for going "
                "back to Creality's firmware; Reinstall NebulaOS firmware undoes it")
    if theirs is None:
        return "Klipper version unknown - Klipper may not be able to use the board"
    if mine and theirs != mine:
        return ("built from Klipper %s, NebulaOS uses %s: Klipper will probably not "
                "connect" % (theirs, mine))
    return None


def _builtin_sha():
    try:
        with open(BUILTIN, "rb") as handle:
            return _image_module().sha256(handle.read(MAX_FILE_BYTES + 1))
    except OSError:
        return None


def _scan(root, depth):
    """(relative path, lstat) of *.bin regular files, no symlinks, no hidden
    entries, sorted, bounded."""
    found = []
    seen = [0]

    def walk(rel, level):
        try:
            names = sorted(os.listdir(os.path.join(root, rel) if rel else root))
        except OSError:
            return
        for name in names:
            seen[0] += 1
            if seen[0] > MAX_ENTRIES:
                return
            if name.startswith("."):
                continue
            sub = os.path.join(rel, name) if rel else name
            try:
                st = os.lstat(os.path.join(root, sub))
            except OSError:
                continue
            if stat.S_ISDIR(st.st_mode):
                if level < depth:
                    walk(sub, level + 1)
            elif stat.S_ISREG(st.st_mode) and name.lower().endswith(".bin"):
                found.append((sub, st))
    walk("", 0)
    return found


def _usb_mounts():
    try:
        names = sorted(os.listdir(USB_DIR))
    except OSError:
        return []
    return [n for n in names if not n.startswith(".")
            and os.path.isdir(os.path.join(USB_DIR, n))
            and not os.path.islink(os.path.join(USB_DIR, n))]


def list_files():
    files = []
    native = _builtin_sha()
    for rel, st in _scan(UPLOAD_DIR, 0):
        entry = {"id": "upload/" + rel, "source": "upload", "name": rel,
                 "mtime": int(st.st_mtime)}
        entry.update(_inspect(os.path.join(UPLOAD_DIR, rel), st.st_size))
        files.append(entry)
    mounts = _usb_mounts()
    for dev in mounts:
        for rel, st in _scan(os.path.join(USB_DIR, dev), USB_DEPTH):
            entry = {"id": "usb/%s/%s" % (dev, rel), "source": "usb", "name": rel,
                     "device": dev, "mtime": int(st.st_mtime)}
            entry.update(_inspect(os.path.join(USB_DIR, dev, rel), st.st_size))
            files.append(entry)
    builtin_version = None
    if native:
        try:
            with open(BUILTIN, "rb") as handle:
                builtin_version = _image_module().klipper_version(handle.read(MAX_FILE_BYTES + 1))
        except OSError:
            pass
    for entry in files:
        entry["native"] = bool(native) and entry["sha256"] == native
        entry["version_note"] = _version_note(entry, builtin_version)
    builtin = None
    if native:
        builtin = {"id": "builtin/" + os.path.basename(BUILTIN), "source": "builtin",
                   "name": "NebulaOS firmware", "sha256": native, "native": True,
                   "size": os.path.getsize(BUILTIN), "valid": True, "kind": "packed",
                   "problem": None, "klipper_version": builtin_version,
                   "version_note": None}
    return {"files": files, "builtin": builtin, "usb": mounts, "upload_dir": UPLOAD_DIR}


# -- flash -----------------------------------------------------------------------

def resolve(file_id):
    """Map an id from `list` back to a path inside its root. Raises invalid."""
    if not isinstance(file_id, str) or not file_id:
        raise invalid("INVALID_FILE", "no file given")
    parts = file_id.split("/")
    if any(not _ID_PART.match(p) or p in (".", "..") for p in parts):
        raise invalid("INVALID_FILE", "not a firmware file id: %r" % file_id)
    source = parts[0]
    if source == "builtin" and len(parts) == 2 and parts[1] == os.path.basename(BUILTIN):
        root, path = os.path.dirname(BUILTIN), BUILTIN
    elif source == "upload" and len(parts) == 2:
        root, path = UPLOAD_DIR, os.path.join(UPLOAD_DIR, parts[1])
    elif source == "usb" and 3 <= len(parts) <= 3 + USB_DEPTH:
        root = os.path.join(USB_DIR, parts[1])
        path = os.path.join(root, *parts[2:])
    else:
        raise invalid("INVALID_FILE", "not a firmware file id: %r" % file_id)
    real_root = os.path.realpath(root)
    real = os.path.realpath(path)
    if not real.startswith(real_root + os.sep):
        raise invalid("INVALID_FILE", "%s is outside its folder" % file_id)
    try:
        st = os.lstat(path)
    except OSError:
        raise invalid("FILE_NOT_FOUND", "%s is gone (USB stick removed?)" % file_id)
    if not stat.S_ISREG(st.st_mode):
        raise invalid("INVALID_FILE", "%s is not a regular file" % file_id)
    return path


def _record(entry):
    try:
        common.atomic_write_json(LAST_FLASH, entry)
    except OSError:
        pass


def flash(file_id, expected_sha):
    path = resolve(file_id)
    if not isinstance(expected_sha, str) or not re.match(r"^[0-9a-f]{64}$", expected_sha):
        raise invalid("INVALID_FILE", "the confirmed sha256 is missing")
    img = _image_module()
    with open(path, "rb") as handle:
        data = handle.read(MAX_FILE_BYTES + 1)
    if img.sha256(data) != expected_sha:
        raise invalid("FILE_CHANGED", "the file changed since it was listed; "
                      "look at it again before flashing")
    try:
        kind, image = img.prepare(data)
    except img.ImageError as exc:
        raise invalid("INVALID_FIRMWARE", exc.reason)

    os.makedirs(STAGE_DIR, exist_ok=True)
    lock_fd = os.open(os.path.join(STAGE_DIR, "flash.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise OsConfigError("BUSY", "an MCU flash is already running")
        staged = os.path.join(STAGE_DIR, "flash-%s.bin" % expected_sha[:16])
        common.atomic_write(staged, image, mode=0o600)
        with open(staged, "rb") as handle:
            if img.sha256(handle.read()) != img.sha256(image):
                raise OsConfigError("STAGE_FAILED", "could not stage the firmware in memory")
        started = time.time()
        rc, out, err = common.run([MCU_CLI, "flash", staged], FLASH_TIMEOUT)
        log = (out + err)[-3000:]
        record = {"file": file_id, "sha256": expected_sha, "image_sha256": img.sha256(image),
                  "kind": kind, "time": int(started), "seconds": int(time.time() - started),
                  "ok": rc == 0}
        try:
            os.unlink(staged)
        except OSError:
            pass
        if rc != 0:
            record["error"] = _failure_line(out, err, rc)
            _record(record)
            code = "REFUSED" if "REFUSED" in log else "FLASH_FAILED"
            raise OsConfigError(code, record["error"], log=log)
        _record(record)
        return {"result": "FLASHED", "file": file_id, "kind": kind,
                "native": "NebulaOS native firmware installed" in out,
                "managed": _managed(), "log": log}
    finally:
        os.close(lock_fd)


def _failure_line(out, err, rc):
    if rc == 124:
        return "the flash did not finish in %d s" % FLASH_TIMEOUT
    for text in (err, out):
        lines = [l.strip() for l in text.splitlines() if l.strip()]
        # mcu_flash_file.py's own reason comes before the CLI's summary line.
        for line in lines:
            if not line.startswith(("Flash failed.", "Restarting Klipper",
                                    "Stopping Klipper")):
                return line[:300]
    return "nebulaos-mcu flash exited with %d" % rc
