# nebulaos_osconfig.cleanup - storage overview and "Clean up Creality files"
# (G66, 2026-10-16; architecture review 2026-10-16 followed).
#
# The data drive (/usr/data) is shared: NebulaOS keeps everything in
# /usr/data/nebulaos plus the print files in /usr/data/printer_data/gcodes;
# the Creality system (and the community helper script's add-ons for it)
# keep their data next to it. "Clean up Creality files" removes that data
# from a FIXED list - never "everything else" - with these guards:
#   - /usr/data/printer_data/gcodes (NebulaOS's print files, the USB stick
#     mount below it) is never touched; of printer_data only the other
#     entries go
#   - nothing that is, or contains, a mount point; symlinks are removed as
#     links, never followed; nothing outside /usr/data
#   - the swap file only when it is not in use
#   - Creality's timelapse videos only when asked for
#   - refused while printing (the Moonraker component checks first)
# Everything not on the list stays: macaddr.txt, wpa_supplicant.conf,
# factory_test_result, .nebulaos-clean-reset*, .keep, nebulaos*, ...
# Whatever the other slot runs is allowed; when it is Creality the screen
# says plainly that it will stop working.
import os
import stat
import time

from . import common, image

DATA = os.environ.get("NEBULAOS_DATA_MOUNT", "/usr/data")
PROC_MOUNTS = os.environ.get("NEBULAOS_PROC_MOUNTS", "/proc/mounts")
PROC_SWAPS = os.environ.get("NEBULAOS_PROC_SWAPS", "/proc/swaps")
NEBULAOS_ROOT = common.NEBULAOS_ROOT

# (path under /usr/data, what it is). Entries that do not exist are skipped.
CREALITY = [
    ("creality", "Creality's data: settings, calibration, logs, old update files"),
    ("opt", "Entware tools (helper script)"),
    ("helper-script", "Helper script"),
    ("moonraker", "Moonraker of the Creality system"),
    ("mainsail", "Mainsail of the Creality system"),
    ("fluidd", "Fluidd of the Creality system"),
    ("guppyscreen", "Old GuppyScreen install"),
    ("nginx", "Web server of the Creality system"),
    ("timelapse", "Timelapse add-on of the Creality system"),
    ("klipper", "Klipper of the Creality system"),
    ("klippy-env", "Klipper of the Creality system"),
    ("moonraker-env", "Moonraker of the Creality system"),
    ("KlipperScreen", "KlipperScreen of the Creality system"),
    ("moonraker-timelapse", "Timelapse add-on of the Creality system"),
    ("mobileraker_companion", "Mobileraker add-on of the Creality system"),
    ("octoeverywhere", "OctoEverywhere add-on of the Creality system"),
    ("cartographer-klipper", "Cartographer add-on of the Creality system"),
    ("swap", "Swap file of the Creality system"),
]
PRINTER_DATA = "printer_data"          # only its entries other than KEEP_IN_PRINTER_DATA
KEEP_IN_PRINTER_DATA = ("gcodes",)
VIDEOS = "creality/userdata/delay_image"


def _mounts():
    out = []
    try:
        with open(PROC_MOUNTS) as handle:
            for line in handle:
                parts = line.split()
                if len(parts) > 1:
                    out.append(parts[1].replace("\\040", " "))
    except OSError:
        pass
    return out


def _swaps():
    try:
        with open(PROC_SWAPS) as handle:
            return [line.split()[0] for line in handle.readlines()[1:] if line.split()]
    except OSError:
        return []


def _size(path, skip=None):
    """Bytes on disk below path - no symlinks followed, never into another
    filesystem (a USB stick under gcodes), `skip` subtree left out."""
    total = 0
    try:
        st = os.lstat(path)
    except OSError:
        return 0
    if not stat.S_ISDIR(st.st_mode):
        return st.st_blocks * 512

    def same_fs(d):
        try:
            return os.lstat(d).st_dev == st.st_dev
        except OSError:
            return False
    for root, dirs, files in os.walk(path, followlinks=False):
        dirs[:] = [d for d in dirs if os.path.join(root, d) != skip
                   and same_fs(os.path.join(root, d))]
        for name in dirs + files:
            try:
                total += os.lstat(os.path.join(root, name)).st_blocks * 512
            except OSError:
                pass
    return total + st.st_blocks * 512


def _blocked(path, mounts, swaps):
    """Why this path must not be deleted, or None."""
    real = os.path.realpath(path) if not os.path.islink(path) else os.path.join(
        os.path.realpath(os.path.dirname(path)), os.path.basename(path))
    data = os.path.realpath(DATA)
    if not real.startswith(data + os.sep):
        return "outside the data drive"
    for m in mounts:
        if m == real or m.startswith(real + os.sep):
            return "a drive is mounted there"
    for sw in swaps:
        if sw in (real, path) or sw.startswith(real + os.sep) or sw.startswith(path + os.sep):
            return "in use as swap"
    nb = os.path.realpath(NEBULAOS_ROOT)
    if real == nb or real.startswith(nb + os.sep) or nb.startswith(real + os.sep):
        return "NebulaOS"
    return None


def _candidates(include_videos):
    """[(absolute path, label, skip subtree or None)] that exist."""
    out = []
    for rel, label in CREALITY:
        path = os.path.join(DATA, rel)
        if os.path.lexists(path):
            skip = None
            if rel == "creality" and not include_videos:
                skip = os.path.join(DATA, VIDEOS)
            out.append((path, label, skip))
    pd = os.path.join(DATA, PRINTER_DATA)
    if os.path.isdir(pd) and not os.path.islink(pd):
        for name in sorted(os.listdir(pd)):
            if name not in KEEP_IN_PRINTER_DATA:
                out.append((os.path.join(pd, name), "Creality's Klipper files (printer_data/%s)" % name, None))
    return out


def other_slot_system():
    try:
        slots = image.slots_info(may_mount=False)
        running = slots.get("running")
        other = {"A": "B", "B": "A"}.get(running)
        return (slots.get(other) or {}).get("system") or "unknown"
    except Exception:
        return "unknown"


def plan(include_videos=False):
    mounts, swaps = _mounts(), _swaps()
    items, total = [], 0
    for path, label, skip in _candidates(include_videos):
        why = _blocked(path, mounts, swaps)
        size = _size(path, skip) if not why else 0
        items.append({"path": path, "label": label, "bytes": size, "kept": why})
        if not why:
            total += size
    videos = os.path.join(DATA, VIDEOS)
    return {"items": items, "bytes": total,
            "videos_bytes": _size(videos) if os.path.isdir(videos) else 0,
            "include_videos": bool(include_videos), "other_slot": other_slot_system()}


def _remove(path, skip):
    """Delete without following links, never into another filesystem."""
    if os.path.islink(path) or not os.path.isdir(path):
        os.unlink(path)
        return
    dev = os.lstat(path).st_dev
    for root, dirs, files in os.walk(path, topdown=False, followlinks=False):
        if skip and (root == skip or root.startswith(skip + os.sep)):
            continue
        for name in files:
            os.unlink(os.path.join(root, name))
        for name in dirs:
            full = os.path.join(root, name)
            if skip and (full == skip or skip.startswith(full + os.sep)):
                continue
            if os.path.islink(full):
                os.unlink(full)
            elif os.lstat(full).st_dev == dev:
                os.rmdir(full)
    if not skip or not skip.startswith(path + os.sep):
        os.rmdir(path)


def clean_creality(include_videos=False, log=None):
    mounts, swaps = _mounts(), _swaps()
    removed, kept, freed_before = [], [], _free()
    for path, label, skip in _candidates(include_videos):
        why = _blocked(path, mounts, swaps)
        if why:
            kept.append({"path": path, "why": why})
            continue
        try:
            _remove(path, skip)
            removed.append(path)
            if log:
                log("removed %s" % path)
        except OSError as exc:
            kept.append({"path": path, "why": str(exc)[:120]})
    os.sync()
    return {"result": "CLEANED", "removed": removed, "kept": kept,
            "freed_bytes": max(0, _free() - freed_before)}


def _free():
    try:
        st = os.statvfs(DATA)
        return st.f_bavail * st.f_frsize
    except OSError:
        return 0


def storage():
    """What uses the data drive, for the System page (on demand - it walks)."""
    pd = os.path.join(NEBULAOS_ROOT, "printer_data")
    cfg = os.path.join(pd, "config")
    parts = [
        ("Print files", [os.path.join(DATA, PRINTER_DATA, "gcodes")]),
        ("Logs", [os.path.join(pd, "logs"), os.path.join(NEBULAOS_ROOT, "logs"),
                  os.path.join(NEBULAOS_ROOT, "maintenance")]),
        ("Uploads", [os.path.join(cfg, "uploads")]),
        ("Backups", [os.path.join(cfg, "backups"), os.path.join(NEBULAOS_ROOT, "backups"),
                     os.path.join(NEBULAOS_ROOT, "system", "migration-backups"),
                     os.path.join(NEBULAOS_ROOT, "system", "settings-db")]),
    ]
    out, counted = [], 0
    for label, paths in parts:
        size = sum(_size(p) for p in paths if os.path.exists(p))
        counted += size
        out.append({"label": label, "bytes": size})
    nebulaos = max(0, _size(NEBULAOS_ROOT) - counted + _size(os.path.join(DATA, PRINTER_DATA, "gcodes")))
    out.append({"label": "NebulaOS", "bytes": nebulaos})
    other = plan(include_videos=True)
    out.append({"label": "Creality files", "bytes": other["bytes"]})
    try:
        st = os.statvfs(DATA)
        total, free = st.f_blocks * st.f_frsize, st.f_bavail * st.f_frsize
    except OSError:
        total = free = 0
    return {"parts": out, "total_bytes": total, "free_bytes": free,
            "other_slot": other["other_slot"], "at": int(time.time())}

