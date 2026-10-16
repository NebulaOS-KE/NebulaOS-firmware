# nebulaos_osconfig.snapshot - copies of the user's settings (G65, 2026-10-16).
#
#   config/backups/settings-<UTC>-<reason>/   visible in Mainsail
#       printer.cfg moonraker.conf songs.conf    (calibration is in printer.cfg)
#       macros/  guppyscreen/guppyconfig.json  calibration/
#       SNAPSHOT.txt                             what, why, which system, and
#                                                where the database copy is
#   Moonraker's database (Mainsail's settings - and login data and API keys,
#   so never under config, which Mainsail can download):
#       --db file   copied straight from printer_data/database (S04, before
#                   Moonraker starts - a consistent copy) into
#                   system/settings-db/<snapshot name>/
#       --db api    Moonraker's own POST /server/database/backup, which
#                   writes printer_data/backup/database/<snapshot name>.db
#                   (Moonraker refuses while printing - recorded, not hidden)
#
# When: at the first boot of every new or rolled-back system (S04, before any
# migration touches a setting) and from the housekeeping loop whenever the
# settings changed since the newest snapshot - so the newest copy always
# predates the next update (Moonraker updates components without a hook).
# The newest KEEP are kept, with their database copies.
import hashlib
import json
import os
import shutil
import time
import urllib.request

from . import common

PDATA = os.environ.get("NEBULAOS_PDATA", "/opt/printer_data")
CONFIG_DIR = os.environ.get("NEBULAOS_CONFIG_DIR", os.path.join(PDATA, "config"))
BACKUPS_DIR = os.path.join(CONFIG_DIR, "backups")
GUPPY_CONFIG = os.environ.get("NEBULAOS_GUPPY_CONFIG",
                              os.path.join(common.NEBULAOS_ROOT, "guppyscreen", "guppyconfig.json"))
CALIBRATION_DIR = os.path.join(PDATA, "calibration")
DATABASE_DIR = os.path.join(PDATA, "database")
API_BACKUP_DIR = os.path.join(PDATA, "backup", "database")
DB_FILE_DIR = os.environ.get("NEBULAOS_SETTINGS_DB_DIR",
                             os.path.join(common.NEBULAOS_ROOT, "system", "settings-db"))
SEED_MANIFEST = os.environ.get("NEBULAOS_SEED_MANIFEST", "/opt/nebulaos-seeds/seed-manifest.json")
MOONRAKER = os.environ.get("NEBULAOS_MOONRAKER_BASE", "http://127.0.0.1:7125")
PREFIX = "settings-"
KEEP = 5
FILES = ("printer.cfg", "moonraker.conf", "songs.conf")
REASONS = ("new-system", "changed", "manual")


def _system_label():
    try:
        with open(SEED_MANIFEST) as handle:
            manifest = json.load(handle)
        return "%s (built %s)" % (str(manifest.get("firmware_head") or "?")[:7],
                                  manifest.get("build_date") or "?")
    except (OSError, ValueError):
        return "unknown"


def _sources():
    """(path, name in the snapshot) of every settings file, sorted."""
    out = [(os.path.join(CONFIG_DIR, f), f) for f in FILES]
    out.append((GUPPY_CONFIG, "guppyscreen/guppyconfig.json"))
    for base, prefix in ((os.path.join(CONFIG_DIR, "macros"), "macros"),
                         (CALIBRATION_DIR, "calibration")):
        for root, dirs, names in os.walk(base):
            dirs[:] = sorted(d for d in dirs if not d.startswith("."))
            for name in sorted(names):
                if not name.startswith("."):
                    full = os.path.join(root, name)
                    out.append((full, os.path.join(prefix, os.path.relpath(full, base))))
    return [(p, n) for p, n in out if os.path.isfile(p) and not os.path.islink(p)]


def fingerprint():
    digest = hashlib.sha256()
    for path, name in _sources():
        digest.update(name.encode() + b"\0")
        with open(path, "rb") as handle:
            digest.update(hashlib.sha256(handle.read()).digest())
    return digest.hexdigest()


def snapshots():
    """Snapshot folder names, oldest first (the name starts with the UTC time)."""
    try:
        return sorted(d for d in os.listdir(BACKUPS_DIR)
                      if d.startswith(PREFIX) and os.path.isdir(os.path.join(BACKUPS_DIR, d)))
    except OSError:
        return []


def _info(name):
    out = {}
    try:
        with open(os.path.join(BACKUPS_DIR, name, "SNAPSHOT.txt")) as handle:
            for line in handle:
                key, sep, value = line.partition(":")
                if sep:
                    out[key.strip()] = value.strip()
    except OSError:
        pass
    return out


def _printing():
    try:
        with urllib.request.urlopen(MOONRAKER + "/printer/objects/query?print_stats", timeout=3) as r:
            state = json.load(r)["result"]["status"]["print_stats"]["state"]
        return state in ("printing", "paused")
    except Exception:
        return False


def _db_file_copy(name):
    files = [f for f in sorted(os.listdir(DATABASE_DIR))] if os.path.isdir(DATABASE_DIR) else []
    files = [f for f in files if os.path.isfile(os.path.join(DATABASE_DIR, f))]
    if not files:
        return "none (no database yet)"
    dest = os.path.join(DB_FILE_DIR, name)
    os.makedirs(dest, exist_ok=True)
    for f in files:                       # the -wal/-shm/-journal companions too
        shutil.copy2(os.path.join(DATABASE_DIR, f), os.path.join(dest, f))
    return dest


def _db_api_backup(name):
    if _printing():
        return "skipped: a print is running (Moonraker does not back up while printing)"
    req = urllib.request.Request(MOONRAKER + "/server/database/backup",
                                 data=json.dumps({"filename": name + ".db"}).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)["result"]["backup_path"]
    except Exception as exc:
        return "skipped: Moonraker backup failed (%s)" % str(exc)[:120]


def take(reason, db="api", if_changed=False, now=None):
    if reason not in REASONS:
        raise common.invalid("INVALID_REASON", "reason must be one of %s" % ", ".join(REASONS))
    if db not in ("api", "file", "none"):
        raise common.invalid("INVALID_DB", "db must be api, file or none")
    fp = fingerprint()
    existing = snapshots()
    if if_changed and existing and _info(existing[-1]).get("fingerprint") == fp:
        return {"result": "UNCHANGED", "newest": existing[-1]}
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime(now))
    name = "%s%s-%s" % (PREFIX, stamp, reason)
    final = os.path.join(BACKUPS_DIR, name)
    tmp = os.path.join(BACKUPS_DIR, "." + name + ".part")
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    copied = []
    try:
        for path, rel in _sources():
            os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
            shutil.copy2(path, os.path.join(tmp, rel))
            copied.append(rel)
        database = {"file": _db_file_copy, "api": _db_api_backup}.get(db, lambda n: "not taken")(name)
        lines = ["snapshot: %s" % name,
                 "reason: %s" % {"new-system": "first start of a new or rolled-back NebulaOS",
                                 "changed": "your settings changed since the last copy",
                                 "manual": "taken by hand"}[reason],
                 "system: %s" % _system_label(),
                 "taken: %s UTC" % time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(now)),
                 "database: %s" % database,
                 "fingerprint: %s" % fp,
                 "files: %s" % ", ".join(copied)]
        with open(os.path.join(tmp, "SNAPSHOT.txt"), "w") as handle:
            handle.write("\n".join(lines) + "\n")
        os.rename(tmp, final)
    except Exception:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    pruned = prune()
    return {"result": "TAKEN", "name": name, "files": len(copied), "database": database,
            "pruned": pruned}


def prune(keep=KEEP):
    """Newest KEEP stay (the newest is never removed), and always the newest
    "new-system" one - the copy from before the running system first touched
    the settings; older ones go together with their database copies."""
    names = snapshots()
    first = [n for n in names if n.endswith("-new-system")][-1:]
    gone = []
    for name in names[:-max(keep, 1)]:
        if name in first:
            continue
        shutil.rmtree(os.path.join(BACKUPS_DIR, name), ignore_errors=True)
        shutil.rmtree(os.path.join(DB_FILE_DIR, name), ignore_errors=True)
        try:
            os.unlink(os.path.join(API_BACKUP_DIR, name + ".db"))
        except OSError:
            pass
        gone.append(name)
    for stale in (os.listdir(BACKUPS_DIR) if os.path.isdir(BACKUPS_DIR) else []):
        if stale.startswith("." + PREFIX) and stale.endswith(".part"):
            shutil.rmtree(os.path.join(BACKUPS_DIR, stale), ignore_errors=True)
    return gone


def status():
    return {"snapshots": [dict(_info(n), name=n) for n in reversed(snapshots())], "keep": KEEP}
