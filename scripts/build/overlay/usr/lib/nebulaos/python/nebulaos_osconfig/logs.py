# nebulaos_osconfig.logs - the general log level, the status file and "Save
# logs to USB" (G60, 2026-10-16).
#
#   log level   info | warning | debug, one setting for the system log
#               (syslogd -l), the screen and Moonraker (-v at debug). Klipper
#               has no log levels.
#   state file  printer_data/logs/nebulaos-state.txt: versions, slots, MCU,
#               boot, storage, memory - written at boot, every 30 minutes and
#               before a log zip. In the logs folder so Mainsail's own
#               "download as zip" carries it too. Never passwords or keys.
#   save logs   one zip on the USB stick with every log, the state file and
#               the printer's config files - streamed file by file (little
#               memory), lines that look like secrets blanked out.
import io
import json
import os
import re
import subprocess
import time
import zipfile

from . import common, image, mcu, network, system, wifi

LEVELS = ("info", "warning", "debug")
LEVEL_FILE = os.environ.get("NEBULAOS_LOG_LEVEL_FILE",
                            os.path.join(common.NEBULAOS_ROOT, "system", "log-level"))
# When Debug was switched on (epoch). Separate file: log-level itself stays one
# word, read by S01syslogd's defaults and S56moonraker.
DEBUG_SINCE_FILE = os.environ.get("NEBULAOS_LOG_DEBUG_SINCE_FILE", LEVEL_FILE + ".debug-since")
SYSLOGD_INIT = os.environ.get("NEBULAOS_SYSLOGD_INIT", "/etc/init.d/S01syslogd")
LOGS_DIR = os.environ.get("NEBULAOS_LOGS_DIR", "/opt/printer_data/logs")
STATE_FILE = os.path.join(LOGS_DIR, "nebulaos-state.txt")
USB_DIR = os.environ.get("NEBULAOS_MCU_USB_DIR", "/opt/printer_data/gcodes/USB")
CONFIG_DIR = os.environ.get("NEBULAOS_CONFIG_DIR", "/opt/printer_data/config")
EXTRA_LOG_DIRS = [os.path.join(common.NEBULAOS_ROOT, d)
                  for d in ("logs", "maintenance/logs", "system/diagnostics")]
# Single files outside those folders (the retention's own log).
EXTRA_FILES = [os.path.join(common.NEBULAOS_ROOT, "maintenance", "retention.log")]
RUN_FILES = ("/run/nebulaos-boot-scripts.log", "/var/run/nebulaos-boot-timing.log",
             "/run/nebulaos/data-fs.state", "/run/nebulaos/data-fs.e2fsck.log",
             "/run/nebulaos-mcu-guard.state", "/proc/meminfo", "/proc/cmdline")
CHUNK = 65536
DEBUG_HOURS = 24
_CLOCK_VALID = 1735689600          # 2025-01-01: before this the clock is not set yet

# Any "key = value" or "key: value" whose key looks like a secret.
_SECRET = re.compile(r"(?i)(\b(?:psk|password|passwd|passphrase|secret|token|api[_-]?key|"
                     r"private[_-]?key|auth[_-]?(?:key|token))\w*\s*[=:]\s*)\S.*")


def redact(line):
    return _SECRET.sub(lambda m: m.group(1) + "[redacted]", line)


def _read_level():
    """(level, epoch Debug was switched on or None)."""
    try:
        with open(LEVEL_FILE) as handle:
            level = handle.read().strip()
    except OSError:
        level = ""
    level = level if level in LEVELS else "info"
    set_at = None
    if level == "debug":
        try:
            with open(DEBUG_SINCE_FILE) as handle:
                raw = handle.read().strip()
            if raw.isdigit() and int(raw) >= _CLOCK_VALID:
                set_at = int(raw)
        except OSError:
            pass
    return level, set_at


def get_level():
    return _read_level()[0]


def status():
    level, set_at = _read_level()
    out = {"level": level, "levels": list(LEVELS),
           "applies_to": ["system log", "screen", "Moonraker (debug only, at its next start)"],
           "not_applicable": ["Klipper (no log levels)"]}
    if level == "debug" and set_at:
        out["debug_until"] = set_at + DEBUG_HOURS * 3600
    return out


def expire_debug(now=None):
    """G69: detailed logging switches itself back to info after DEBUG_HOURS,
    so a forgotten Debug never fills the disk. A level set before the clock
    was valid gets its start time now."""
    now = int(time.time()) if now is None else now
    level, set_at = _read_level()
    if level != "debug" or now < _CLOCK_VALID:
        return {"result": "UNCHANGED", "level": level}
    if set_at is None:
        common.atomic_write(DEBUG_SINCE_FILE, "%d\n" % now)
        return {"result": "UNCHANGED", "level": level}
    if now - set_at < DEBUG_HOURS * 3600:
        return {"result": "UNCHANGED", "level": level}
    return dict(set_level("info"), result="EXPIRED")


def set_level(level):
    if level not in LEVELS:
        raise common.invalid("INVALID_LEVEL", "level must be one of %s" % ", ".join(LEVELS))
    os.makedirs(os.path.dirname(LEVEL_FILE), exist_ok=True)
    common.atomic_write(LEVEL_FILE, level + "\n")
    now = int(time.time())
    if level == "debug" and now >= _CLOCK_VALID:
        common.atomic_write(DEBUG_SINCE_FILE, "%d\n" % now)
    elif level != "debug":
        try:
            os.unlink(DEBUG_SINCE_FILE)
        except OSError:
            pass
    rc, _, err = common.run([SYSLOGD_INIT, "restart"], 30)
    out = {"result": "APPLIED", "level": level, "system_log": "applied" if rc == 0 else
           "not restarted: %s" % err.strip()[:120]}
    out["moonraker"] = "at its next start"
    return out


# -- the status file -------------------------------------------------------------

def _section(title, body):
    return "== %s ==\n%s\n\n" % (title, body.rstrip())


def _fmt(obj):
    return json.dumps(obj, indent=2, sort_keys=True, default=str)


def state_text():
    parts = [_section("generated", time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()))]

    def add(title, fn):
        try:
            parts.append(_section(title, _fmt(fn())))
        except Exception as exc:  # one failing source never hides the rest
            parts.append(_section(title, "unavailable: %s" % str(exc)[:200]))

    add("system", system.info)
    add("slots", lambda: image.slots_info(may_mount=False))
    add("last system image install", lambda: image.status().get("last") or "none")
    add("mcu", mcu.status)
    add("log level", status)
    add("network", network.status)
    add("wi-fi", wifi.status)
    for path in ("/proc/uptime", "/proc/loadavg"):
        try:
            with open(path) as handle:
                parts.append(_section(path, handle.read()))
        except OSError:
            pass
    for title, argv in (("df -k", ["df", "-k"]), ("free", ["free"]),
                        ("processes", ["ps", "-o", "pid,ppid,vsz,rss,stat,args"])):
        rc, out, _ = common.run(argv, 10)
        if rc == 0:
            parts.append(_section(title, out))
    return redact_text("".join(parts))


def redact_text(text):
    return "\n".join(redact(line) for line in text.split("\n"))


def write_state():
    os.makedirs(LOGS_DIR, exist_ok=True)
    common.atomic_write(STATE_FILE, state_text())
    return {"result": "WRITTEN", "path": STATE_FILE}


# -- save logs to USB ---------------------------------------------------------------

def _usb_target():
    try:
        devs = sorted(d for d in os.listdir(USB_DIR) if not d.startswith("."))
    except OSError:
        devs = []
    for dev in devs:
        path = os.path.join(USB_DIR, dev)
        if os.path.isdir(path) and not os.path.islink(path) and os.access(path, os.W_OK):
            return path
    if devs:
        raise common.OsConfigError("USB_READ_ONLY", "the USB stick is read-only")
    raise common.OsConfigError("NO_USB", "no USB stick found")


def _files():
    """(path on the printer, name in the zip) - every log, run-time state
    and the printer's own config files."""
    out = []
    def nprefix(d):
        rel = os.path.relpath(d, common.NEBULAOS_ROOT)
        return "nebulaos/" + (rel if not rel.startswith("..") else os.path.basename(d))
    for base, prefix in [(LOGS_DIR, "logs")] + [(d, nprefix(d)) for d in EXTRA_LOG_DIRS]:
        try:
            names = sorted(os.listdir(base))
        except OSError:
            continue
        for name in names:
            full = os.path.join(base, name)
            if os.path.isfile(full) and not os.path.islink(full):
                out.append((full, "%s/%s" % (prefix, name)))
    for path in EXTRA_FILES:
        if os.path.isfile(path) and not os.path.islink(path):
            rel = os.path.relpath(path, common.NEBULAOS_ROOT)
            out.append((path, "nebulaos/" + rel))
    for path in RUN_FILES:
        if os.path.isfile(path):
            out.append((path, "run" + path.replace("/", "_")))
    for root, _, names in os.walk(CONFIG_DIR):
        rel = os.path.relpath(root, CONFIG_DIR)
        top = rel.split(os.sep)[0]
        if rel != "." and (top == "backups" or top.startswith(".")):
            continue
        for name in sorted(names):
            if name.endswith((".cfg", ".conf", ".json")) and not name.startswith("."):
                full = os.path.join(root, name)
                out.append((full, "config/" + os.path.normpath(os.path.join(rel, name))))
    return out


def _zipinfo(name, path=None):
    """The file's own date (zip cannot hold dates before 1980)."""
    try:
        mtime = os.stat(path).st_mtime if path else time.time()
    except OSError:
        mtime = time.time()
    stamp = time.gmtime(max(mtime, 315532800))
    info = zipfile.ZipInfo(name, date_time=stamp[:6])
    info.compress_type = zipfile.ZIP_DEFLATED
    return info


def _add_text_stream(zf, name, handle, path=None):
    with zf.open(_zipinfo(name, path), "w") as dst:
        for line in handle:
            if isinstance(line, bytes):
                line = line.decode("utf-8", "replace")
            dst.write(redact(line.rstrip("\n")).encode("utf-8") + b"\n")


def save_logs():
    target_dir = _usb_target()
    write_state()
    host = (system._read("/proc/sys/kernel/hostname") or "nebulaos").replace("/", "_")
    name = "nebulaos-logs-%s-%s.zip" % (host, time.strftime("%Y%m%d-%H%M%S", time.gmtime()))
    final = os.path.join(target_dir, name)
    tmp = final + ".part"
    count = 0
    try:
        with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
            for path, arc in _files():
                try:
                    with open(path, "r", encoding="utf-8", errors="replace", newline="") as handle:
                        _add_text_stream(zf, arc, handle, path)
                    count += 1
                except OSError:
                    continue
            proc = subprocess.Popen(["dmesg"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            try:
                _add_text_stream(zf, "run/dmesg.txt", io.TextIOWrapper(proc.stdout, errors="replace"))
            finally:
                proc.stdout.close()
                proc.wait(timeout=30)
        os.replace(tmp, final)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.sync()
    return {"result": "SAVED", "file": name, "files": count + 1,
            "bytes": os.path.getsize(final), "usb": os.path.basename(target_dir),
            "safe_to_remove": True}
