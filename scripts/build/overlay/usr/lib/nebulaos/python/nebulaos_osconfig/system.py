# nebulaos_osconfig.system - read-only build/storage/service facts for the GUI
# (GUI/service readiness mission, 2026-10-09).
import json
import os

from . import common

SEED_MANIFEST = os.environ.get("NEBULAOS_SEED_MANIFEST",
                               "/opt/nebulaos-seeds/seed-manifest.json")
DATA_MOUNT = os.environ.get("NEBULAOS_DATA_MOUNT", "/usr/data")
DATA_FS_STATE = os.environ.get("NEBULAOS_DATA_FS_STATE", "/run/nebulaos/data-fs.state")
SFTP_SERVER = "/usr/libexec/sftp-server"


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
            "firmware_head": manifest.get("firmware_head"),
            "build_date": manifest.get("build_date"),
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


def info():
    uname = os.uname()
    return {"build": build_info(),
            "kernel": {"release": uname.release, "version": uname.version},
            "hostname": _read("/proc/sys/kernel/hostname"),
            "storage": storage_info(),
            "sftp": {"available": os.access(SFTP_SERVER, os.X_OK)}}
