# nebulaos_osconfig.stats - print statistics from before NebulaOS (Run 23,
# Tim 2026-11-02: Settings > Printer > Statistics).
#
#   stats baseline     what the printer printed before NebulaOS, imported once
#
# NebulaOS counts its own prints with Moonraker's history (on by default; the
# NebulaOS Moonraker component adds them up). What came before lives on the
# data drive, next to NebulaOS, and is read here - never written:
#
#   creality   Creality's lifetime print time: /usr/data/creality/userdata/
#              config/user_data_not_deleted.json, kept by Creality's
#              master-server (stock 1.1.0.12: "total_time" in seconds, the
#              sum of Klipper's print_stats.print_duration per print). The
#              file is base64 of AES-128-CBC; key and IV are master-server's.
#   moonraker  an earlier Moonraker's history (OpenKE, helper script):
#              /usr/data/printer_data/database/moonraker-sql.db, tables
#              job_totals and job_history (Moonraker's own schema).
#
# A source is imported once and then kept in /usr/data/nebulaos/system/
# stats-baseline.json, so its numbers survive "Clean up Creality files" or a
# reinstall of Creality's system. A source that is absent or unreadable is
# looked at again next time. "Clean up Creality files" keeps both sources
# (cleanup.STATISTICS_KEEP, printer_data/database).
import base64
import json
import os
import sqlite3
import subprocess
import time

from . import common

DATA = os.environ.get("NEBULAOS_DATA_MOUNT", "/usr/data")
BASELINE = os.path.join(common.NEBULAOS_ROOT, "system", "stats-baseline.json")
CREALITY_COUNTER = "creality/userdata/config/user_data_not_deleted.json"
OLD_MOONRAKER_DB = "printer_data/database/moonraker-sql.db"
OPENSSL = os.environ.get("NEBULAOS_OPENSSL", "openssl")
# AES-128-CBC key and IV of Creality's master-server (stock 1.1.0.12), hex.
# None: not known for this build - the counter is reported unreadable.
CREALITY_KEY = None
CREALITY_IV = None
MAX_FILE = 64 * 1024
STATUSES = ("completed", "cancelled", "error", "klippy_shutdown", "klippy_disconnect",
            "interrupted", "server_exit")


def _path(rel):
    return os.path.join(DATA, rel)


def decrypt_creality(blob, key_hex, iv_hex):
    """Plain text of a Creality-encrypted file (base64 of AES-128-CBC,
    PKCS#7), or None."""
    try:
        raw = base64.b64decode(blob.strip(), validate=True)
    except ValueError:
        return None
    if not raw or len(raw) % 16:
        return None
    try:
        out = subprocess.run([OPENSSL, "enc", "-d", "-aes-128-cbc", "-K", key_hex,
                              "-iv", iv_hex], input=raw, capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout if out.returncode == 0 else None


def read_creality_counter():
    path = _path(CREALITY_COUNTER)
    if not os.path.isfile(path):
        return {"status": "absent"}
    try:
        with open(path, "rb") as handle:
            blob = handle.read(MAX_FILE)
    except OSError as exc:
        return {"status": "unreadable", "reason": str(exc)[:120]}
    if not CREALITY_KEY or not CREALITY_IV:
        return {"status": "unreadable", "reason": "unknown file format"}
    plain = decrypt_creality(blob, CREALITY_KEY, CREALITY_IV)
    try:
        obj = json.loads(plain.decode("utf-8")) if plain else None
    except (UnicodeDecodeError, ValueError):
        obj = None
    seconds = obj.get("total_time") if isinstance(obj, dict) else None
    if not isinstance(seconds, int) or isinstance(seconds, bool) or seconds < 0:
        return {"status": "unreadable", "reason": "not a Creality print counter"}
    return {"status": "imported", "print_time": float(seconds)}


def read_old_moonraker():
    path = _path(OLD_MOONRAKER_DB)
    if not os.path.isfile(path):
        return {"status": "absent"}
    try:
        conn = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=2)
    except sqlite3.Error as exc:
        return {"status": "unreadable", "reason": str(exc)[:120]}
    try:
        totals = {}
        for field, maximum, total in conn.execute(
                "SELECT field, maximum, total FROM job_totals "
                "WHERE provider = 'history' AND instance_id = 'default'"):
            totals[field] = total if total is not None else maximum
        jobs = {}
        for status, count in conn.execute(
                "SELECT status, COUNT(*) FROM job_history "
                "WHERE instance_id = 'default' GROUP BY status"):
            jobs[status] = count
        first = conn.execute("SELECT MIN(start_time) FROM job_history").fetchone()[0]
    except sqlite3.Error as exc:
        return {"status": "unreadable", "reason": str(exc)[:120]}
    finally:
        conn.close()
    return {"status": "imported",
            "print_time": float(totals.get("total_print_time") or 0),
            "job_time": float(totals.get("total_time") or 0),
            "filament_mm": float(totals.get("total_filament_used") or 0),
            "longest_print": float(totals.get("longest_print") or 0),
            "jobs": int(totals.get("total_jobs") or 0),
            "by_status": jobs, "since": first}


READERS = {"creality": read_creality_counter, "moonraker": read_old_moonraker}


def baseline():
    """{"sources": {name: {status, ...}}}: each source as imported once, or
    as it looks now when it has not been imported."""
    saved, _err = common.read_json(BASELINE)
    sources = dict(saved.get("sources") or {}) if isinstance(saved, dict) else {}
    changed = False
    for name, reader in READERS.items():
        if (sources.get(name) or {}).get("status") == "imported":
            continue
        found = reader()
        if found.get("status") == "imported":
            found["imported_at"] = int(time.time())
            changed = True
        sources[name] = found
    if changed:
        common.atomic_write_json(BASELINE, {"sources": sources})
    return {"sources": sources}
