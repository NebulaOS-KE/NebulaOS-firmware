# nebulaos_osconfig.logs - the general log level, the status file and "Save
# logs to USB" (G60, 2026-10-16).
#
#   log level   info | warning | debug | verbose, one setting for the system
#               log (syslogd -l), the screen, the kernel black box's detail
#               level (debug and verbose) and Moonraker (-v at verbose only:
#               its debug log is huge). Klipper has no log levels. Debug and
#               verbose go back to the image's default after 24 hours. The
#               default is /etc/nebulaos/log-level-default: info in a
#               release, debug in a test build (1.0.5).
#   state file  printer_data/logs/nebulaos-state.txt: versions, slots, MCU,
#               boot, storage, memory - written at boot, every 30 minutes and
#               before a log zip. In the logs folder so Mainsail's own
#               "download as zip" carries it too. Never passwords or keys.
#   save logs   one zip on the USB stick with every log, the state file and
#               the printer's config files - streamed file by file (little
#               memory), lines that look like secrets blanked out.
import json
import os
import re
import subprocess
import time
import zipfile

from . import common, image, mcu, network, system, wifi

LEVELS = ("info", "warning", "debug", "verbose")
# 1.0.5: the levels with the black box detail on, which end after DEBUG_HOURS.
DETAILED = ("debug", "verbose")
LEVEL_FILE = os.environ.get("NEBULAOS_LOG_LEVEL_FILE",
                            os.path.join(common.NEBULAOS_ROOT, "system", "log-level"))
# The level when none was chosen (or the file is broken), and the level Debug
# and Verbose go back to. Image-owned: info in a release, debug in a test build.
DEFAULT_FILE = os.environ.get("NEBULAOS_LOG_LEVEL_DEFAULT_FILE", "/etc/nebulaos/log-level-default")
# When Debug or Verbose was switched on (epoch). Separate file: log-level
# itself stays one word, read by S01syslogd's defaults, S03nebulaos-blackbox
# and S56moonraker.
DEBUG_SINCE_FILE = os.environ.get("NEBULAOS_LOG_DEBUG_SINCE_FILE", LEVEL_FILE + ".debug-since")
# The kernel flight recorder's control file: "detail=0|1" (kernel 1.0.5).
FLIGHTREC_CTL = os.environ.get("NEBULAOS_FLIGHTREC_CTL", "/proc/nebulaos_flightrec")
SYSLOGD_INIT = os.environ.get("NEBULAOS_SYSLOGD_INIT", "/etc/init.d/S01syslogd")
LOGS_DIR = os.environ.get("NEBULAOS_LOGS_DIR", "/opt/printer_data/logs")
STATE_FILE = os.path.join(LOGS_DIR, "nebulaos-state.txt")
USB_DIR = os.environ.get("NEBULAOS_MCU_USB_DIR", "/opt/printer_data/gcodes/USB")
CONFIG_DIR = os.environ.get("NEBULAOS_CONFIG_DIR", "/opt/printer_data/config")
EXTRA_LOG_DIRS = [os.path.join(common.NEBULAOS_ROOT, d)
                  for d in ("logs", "logs/crash", "maintenance/logs", "system/diagnostics")]
# Why the previous boot ended (S03nebulaos-blackbox, Run 24).
LAST_RESET_FILE = os.environ.get("NEBULAOS_LAST_RESET_FILE", "/run/nebulaos/last-reset")
RESET_HISTORY = os.path.join(common.NEBULAOS_ROOT, "logs", "reset-history.log")
# Single files outside those folders (the retention's own log).
EXTRA_FILES = [os.path.join(common.NEBULAOS_ROOT, "maintenance", "retention.log")]
RUN_FILES = ("/run/nebulaos-boot-scripts.log", "/var/run/nebulaos-boot-timing.log",
             "/run/nebulaos/data-fs.state", "/run/nebulaos/data-fs.e2fsck.log",
             "/run/nebulaos-mcu-guard.state", "/run/nebulaos/last-reset",
             # #27 (1.0.5): what the boot steps for stock's hardware settings found
             "/run/nebulaos/ddr-qos", "/run/nebulaos/usb-power",
             "/proc/meminfo", "/proc/cmdline")
CHUNK = 65536
DEBUG_HOURS = 24
# #27 (test build 2): the screen keeps its own level in its config
# (printers.<name>.log_level, spdlog names), read at its start. The one level
# above is written there at every screen start (S58nebulascreen) and when
# Debug expires, so the screen can no longer stay on debug on its own.
SCREEN_CONFIG = os.environ.get("NEBULAOS_SCREEN_CONFIG",
                               os.path.join(CONFIG_DIR, "nebulascreen", "nebulascreen.json"))
SCREEN_INIT = os.environ.get("NEBULAOS_SCREEN_INIT", "/etc/init.d/S58nebulascreen")
PRINT_ACTIVE = os.environ.get("NEBULAOS_PRINT_ACTIVE_MARKER", "/run/nebulaos/print-active")
SCREEN_LEVELS = {"info": "info", "warning": "warn", "debug": "debug", "verbose": "debug"}
# "Save logs to USB" limits (#27): Moonraker kills the helper at 300 s, so the
# helper stops adding files itself before that and still closes a valid zip.
SAVE_DEADLINE = float(os.environ.get("NEBULAOS_LOGS_SAVE_DEADLINE", "240"))
LOG_BUDGET = 25 * 1024 * 1024       # uncompressed bytes of printer_data/logs
CRASH_BUDGET = 20 * 1024 * 1024     # black box sets, newest first
TAIL_BYTES = 5 * 1024 * 1024        # larger files: only their last part
_CLOCK_VALID = 1735689600          # 2025-01-01: before this the clock is not set yet

# Any "key = value" or "key: value" whose key looks like a secret.
_SECRET = re.compile(r"(?i)(\b(?:psk|password|passwd|passphrase|secret|token|api[_-]?key|"
                     r"private[_-]?key|auth[_-]?(?:key|token))\w*\s*[=:]\s*)\S.*")


def redact(line):
    return _SECRET.sub(lambda m: m.group(1) + "[redacted]", line)


def default_level():
    """The image's default level: info unless the image says otherwise."""
    try:
        with open(DEFAULT_FILE) as handle:
            level = handle.read().strip()
    except OSError:
        level = ""
    return level if level in LEVELS else "info"


def _read_level():
    """(level, epoch Debug/Verbose was switched on or None)."""
    try:
        with open(LEVEL_FILE) as handle:
            level = handle.read().strip()
    except OSError:
        level = ""
    level = level if level in LEVELS else default_level()
    set_at = None
    if level in DETAILED:
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
    default = default_level()
    out = {"level": level, "levels": list(LEVELS), "default": default,
           "applies_to": ["system log", "screen", "black box detail (debug and verbose)",
                          "Moonraker (verbose only, at its next start)"],
           "not_applicable": ["Klipper (no log levels)"]}
    # "debug_until": when Debug or Verbose ends (the screen shows it).
    if level in DETAILED and level != default and set_at:
        out["debug_until"] = set_at + DEBUG_HOURS * 3600
    return out


def expire_debug(now=None):
    """G69: detailed logging (Debug, and Verbose since 1.0.5) goes back to the
    image's default level after DEBUG_HOURS, so a forgotten level never fills
    the disk. A level set before the clock was valid gets its start time now.
    A level equal to the default (Debug in a test build) never expires."""
    now = int(time.time()) if now is None else now
    level, set_at = _read_level()
    default = default_level()
    if level not in DETAILED or level == default or now < _CLOCK_VALID:
        return dict({"result": "UNCHANGED", "level": level}, **_screen_follow())
    if set_at is None:
        common.atomic_write(DEBUG_SINCE_FILE, "%d\n" % now)
        return {"result": "UNCHANGED", "level": level}
    if now - set_at < DEBUG_HOURS * 3600:
        return {"result": "UNCHANGED", "level": level}
    return dict(set_level(default), result="EXPIRED", **_screen_follow())


def apply_black_box(level):
    """The kernel black box's detail level follows the log level: on at Debug
    and Verbose. Returns on|off, or unavailable (no recorder, or an older
    kernel without the detail switch)."""
    want = 1 if level in DETAILED else 0
    if not os.path.exists(FLIGHTREC_CTL):
        return "unavailable"
    try:
        with open(FLIGHTREC_CTL, "w") as handle:
            handle.write("detail=%d\n" % want)
    except OSError:
        return "unavailable"
    return "on" if want else "off"


def sync_screen_level():
    """Write the one log level into the screen's config (every printer
    entry). Returns {"screen": level, "screen_config": APPLIED|UNCHANGED|
    MISSING}. Never raises for a missing or broken file."""
    want = SCREEN_LEVELS[get_level()]
    obj, _err = common.read_json(SCREEN_CONFIG)
    printers = obj.get("printers") if isinstance(obj, dict) else None
    if not isinstance(printers, dict):
        return {"screen": want, "screen_config": "MISSING"}
    changed = False
    for entry in printers.values():
        if isinstance(entry, dict) and entry.get("log_level") != want:
            entry["log_level"] = want
            changed = True
    if changed:
        common.atomic_write_json(SCREEN_CONFIG, obj)
    return {"screen": want, "screen_config": "APPLIED" if changed else "UNCHANGED"}


def _screen_follow():
    """Housekeeping: a screen whose config disagrees with the level gets it,
    and a running screen is restarted so it takes effect - not during a print
    (then at its next start, which S58 syncs)."""
    out = sync_screen_level()
    if out["screen_config"] == "APPLIED":
        if os.path.exists(PRINT_ACTIVE):
            out["screen_restart"] = "after the print"
        else:
            rc, _, _ = common.run([SCREEN_INIT, "restart"], 60)
            out["screen_restart"] = "done" if rc == 0 else "failed"
    return out


def set_level(level):
    if level not in LEVELS:
        raise common.invalid("INVALID_LEVEL", "level must be one of %s" % ", ".join(LEVELS))
    os.makedirs(os.path.dirname(LEVEL_FILE), exist_ok=True)
    common.atomic_write(LEVEL_FILE, level + "\n")
    now = int(time.time())
    if level in DETAILED and now >= _CLOCK_VALID:
        common.atomic_write(DEBUG_SINCE_FILE, "%d\n" % now)
    elif level not in DETAILED:
        try:
            os.unlink(DEBUG_SINCE_FILE)
        except OSError:
            pass
    rc, _, err = common.run([SYSLOGD_INIT, "restart"], 30)
    out = {"result": "APPLIED", "level": level, "system_log": "applied" if rc == 0 else
           "not restarted: %s" % err.strip()[:120]}
    out["black_box_detail"] = apply_black_box(level)
    out["moonraker"] = ("verbose log from its next start" if level == "verbose"
                        else "normal log from its next start")
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
    add("last restart", last_reset)
    add("slots", lambda: image.slots_info(may_mount=False))
    add("last system image install", lambda: image.status().get("last") or "none")
    add("mcu", mcu.status)
    add("log level", status)
    add("network", network.status)
    add("wi-fi", wifi.status)
    # #27: /proc/stat, interrupts and net/dev too (the counters since boot,
    # per CPU) - what load.log turns into per-minute lines.
    for path in ("/proc/uptime", "/proc/loadavg", "/proc/stat", "/proc/interrupts",
                 "/proc/net/dev"):
        try:
            with open(path) as handle:
                parts.append(_section(path, handle.read()))
        except OSError:
            pass
    parts.append(_section("cpu per process (average since its start)", _cpu_per_process()))
    for title, argv in (("df -k", ["df", "-k"]), ("free", ["free"]),
                        ("processes", ["ps", "-o", "pid,ppid,vsz,rss,stat,args"])):
        rc, out, _ = common.run(argv, 10)
        if rc == 0:
            parts.append(_section(title, out))
    return redact_text("".join(parts))


PROC_DIR = os.environ.get("NEBULAOS_PROC_DIR", "/proc")


def _cpu_per_process(proc=None):
    """'pid cpu% cpus comm' for every process that used CPU, busiest first.
    cpu% = (utime+stime) / time since the process started, % of one CPU."""
    proc = proc or PROC_DIR
    hz = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100
    try:
        with open(os.path.join(proc, "uptime")) as handle:
            uptime = float(handle.read().split()[0])
    except (OSError, ValueError, IndexError):
        return "unavailable"
    rows = []
    for name in os.listdir(proc):
        if not name.isdigit():
            continue
        try:
            with open(os.path.join(proc, name, "stat")) as handle:
                raw = handle.read()
            comm = raw[raw.index("(") + 1:raw.rindex(")")]
            fields = raw[raw.rindex(")") + 2:].split()
            used = (int(fields[11]) + int(fields[12])) / hz
            age = uptime - int(fields[19]) / hz
        except (OSError, ValueError, IndexError):
            continue
        cpus = ""
        try:
            with open(os.path.join(proc, name, "status")) as handle:
                for line in handle:
                    if line.startswith("Cpus_allowed_list:"):
                        cpus = line.split(":", 1)[1].strip()
                        break
        except OSError:
            pass
        if used > 0 and age > 0:
            rows.append((used / age * 100, int(name), cpus, comm, used))
    rows.sort(reverse=True)
    return "\n".join("%6d %5.1f%% %8.0fs cpus=%s %s" % (pid, pct, used, cpus or "?", comm)
                     for pct, pid, cpus, comm, used in rows[:40]) or "none"


def last_reset():
    """Why the previous boot ended, and the last few restarts."""
    out = {}
    try:
        with open(LAST_RESET_FILE) as handle:
            for line in handle:
                key, sep, value = line.rstrip("\n").partition("=")
                if sep:
                    out[key.lower()] = value
    except OSError:
        out["reason"] = "not recorded"
    try:
        with open(RESET_HISTORY) as handle:
            out["history"] = [l.rstrip("\n") for l in handle.readlines()[-10:]]
    except OSError:
        pass
    return out


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


# Rotated logs: klippy.log.1, klippy.log.2026-11-19, system.log.0,
# nebulascreen.1.log (spdlog's own rotation). Everything else in the logs
# folder is a current log.
_ROTATED = re.compile(r"\.log\.[^/]+$|\.\d+\.log$")
# Black box sets: one file per kind, named <stamp>-<KIND>-<what>.txt.
_CRASH_SET = re.compile(r"^(\d{8}T\d{6}Z)-")
# The same secret pattern as _SECRET, for a block of many lines: [ \t]
# instead of \s so a match never runs into the next line (per line, \s* could
# only meet the end of the line), "." already stops at a newline.
_SECRET_BLOCK = re.compile(r"(?im)(\b(?:psk|password|passwd|passphrase|secret|token|api[_-]?key|"
                           r"private[_-]?key|auth[_-]?(?:key|token))\w*[ \t]*[=:][ \t]*)\S.*")


# Every word the pattern can start with, casefolded the way (?i) matches
# (so also e.g. the long s or the Kelvin sign). A block without any of them
# cannot match: the regex - the slow part on the printer - is skipped, which
# is >98 % of the blocks in real klippy/screen logs.
_SECRET_WORDS = ("psk", "pass", "secret", "token", "key", "auth")


def redact_block(data):
    """bytes -> bytes, the same result as redact() on every line."""
    text = data.decode("utf-8", "replace")
    folded = text.casefold()
    if not any(word in folded for word in _SECRET_WORDS):
        return text.encode("utf-8")
    return _SECRET_BLOCK.sub(lambda m: m.group(1) + "[redacted]", text).encode("utf-8")


def _nprefix(d):
    rel = os.path.relpath(d, common.NEBULAOS_ROOT)
    return "nebulaos/" + (rel if not rel.startswith("..") else os.path.basename(d))


def _listdir(base):
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return []
    return [(os.path.join(base, n), n) for n in names
            if os.path.isfile(os.path.join(base, n)) and not os.path.islink(os.path.join(base, n))]


def _mtime(path):
    try:
        return os.stat(path).st_mtime
    except OSError:
        return 0


def _plan():
    """[(group, path or None, name in the zip)] in the order they go in:
    what a freeze or an MCU error needs first, so a cut-off save still has
    it (#27): state, run files, dmesg, NebulaOS's own logs (reset history,
    memguard, load), the black box newest first, config, the current logs,
    then the rotated logs newest first."""
    plan = []
    state = os.path.join(LOGS_DIR, os.path.basename(STATE_FILE))
    if os.path.isfile(state):
        plan.append(("evidence", state, "logs/" + os.path.basename(state)))
    for path in RUN_FILES:
        if os.path.isfile(path):
            plan.append(("evidence", path, "run" + path.replace("/", "_")))
    plan.append(("evidence", None, "run/dmesg.txt"))
    crash = []
    for d in EXTRA_LOG_DIRS:
        for full, n in _listdir(d):
            arc = "%s/%s" % (_nprefix(d), n)
            if os.path.basename(d) == "crash":
                crash.append((full, arc, n))
            else:
                plan.append(("evidence", full, arc))
    for path in EXTRA_FILES:
        if os.path.isfile(path) and not os.path.islink(path):
            plan.append(("evidence", path, "nebulaos/" + os.path.relpath(path, common.NEBULAOS_ROOT)))
    def crash_key(item):
        m = _CRASH_SET.match(item[2])
        return (m.group(1) if m else "", item[2])
    for full, arc, _ in sorted(crash, key=crash_key, reverse=True):
        plan.append(("crash", full, arc))
    for root, _, names in os.walk(CONFIG_DIR):
        rel = os.path.relpath(root, CONFIG_DIR)
        top = rel.split(os.sep)[0]
        if rel != "." and (top in ("backups", "uploads") or top.startswith(".")):
            continue
        for name in sorted(names):
            if name.endswith((".cfg", ".conf", ".json")) and not name.startswith("."):
                plan.append(("config", os.path.join(root, name),
                             "config/" + os.path.normpath(os.path.join(rel, name))))
    current, rotated = [], []
    for full, n in _listdir(LOGS_DIR):
        if full == state:
            continue
        (rotated if _ROTATED.search(n) else current).append((full, "logs/" + n))
    plan.extend(("current", full, arc) for full, arc in current)
    rotated.sort(key=lambda item: _mtime(item[0]), reverse=True)
    plan.extend(("rotated", full, arc) for full, arc in rotated)
    return plan


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


class _Save:
    """One save: the deadline, the budgets and what was left out."""

    def __init__(self, deadline):
        self.deadline = deadline
        self.stop_reason = None
        self.omitted = []
        self.log_bytes = 0
        self.crash_bytes = 0

    def stopping(self):
        if self.stop_reason is None and time.monotonic() >= self.deadline:
            self.stop_reason = "time limit"
        return self.stop_reason is not None

    def stream(self, zf, name, src, path=None, skipped=0):
        """Copy a binary stream into the zip, redacted block by block.
        Returns the bytes copied; stops at the deadline (the member is still
        closed properly, with a note at its end)."""
        copied = 0
        with zf.open(_zipinfo(name, path), "w") as dst:
            if skipped:
                dst.write(b"[Save logs: the first %d bytes are left out - size limit]\n" % skipped)
            rest = b""
            while True:
                if self.stopping():
                    dst.write(redact_block(rest) + b"\n[Save logs: cut here - %s]\n"
                              % self.stop_reason.encode())
                    self.omitted.append("%s: cut after %d bytes (%s)" % (name, copied, self.stop_reason))
                    return copied
                chunk = src.read(CHUNK)
                if not chunk:
                    break
                copied += len(chunk)
                buf = rest + chunk
                cut = buf.rfind(b"\n")
                if cut < 0 and len(buf) < 4 * CHUNK:
                    rest = buf
                    continue
                cut = len(buf) - 1 if cut < 0 else cut
                dst.write(redact_block(buf[:cut + 1]))
                rest = buf[cut + 1:]
            if rest:
                dst.write(redact_block(rest) + b"\n")
        return copied

    def add_file(self, zf, group, path, arc):
        try:
            size = os.path.getsize(path)
        except OSError:
            return False
        if group == "crash" and self.crash_bytes + size > CRASH_BUDGET and self.crash_bytes:
            self.omitted.append("%s: %d bytes (black box limit)" % (arc, size))
            return False
        if group == "rotated" and self.log_bytes >= LOG_BUDGET:
            self.omitted.append("%s: %d bytes (log size limit)" % (arc, size))
            return False
        try:
            with open(path, "rb") as src:
                skipped = 0
                if group in ("current", "rotated", "evidence") and size > TAIL_BYTES:
                    src.seek(size - TAIL_BYTES)
                    src.readline()               # start at a line boundary
                    skipped = src.tell()
                    self.omitted.append("%s: first %d of %d bytes (size limit)" % (arc, skipped, size))
                copied = self.stream(zf, arc, src, path, skipped)
        except OSError:
            return False
        if group == "crash":
            self.crash_bytes += copied
        elif group in ("current", "rotated"):
            self.log_bytes += copied
        return True


def save_logs():
    """Every log, the state file and the config into one zip on the USB
    stick (#27: evidence first, size limits, stops in time). A save that hit
    the time limit or was asked to stop still closes a valid zip and says
    partial; run/omitted.txt lists everything left out."""
    import signal
    started = time.monotonic()
    target_dir = _usb_target()
    write_state()
    host = (system._read("/proc/sys/kernel/hostname") or "nebulaos").replace("/", "_")
    name = "nebulaos-logs-%s-%s.zip" % (host, time.strftime("%Y%m%d-%H%M%S", time.gmtime()))
    final = os.path.join(target_dir, name)
    tmp = final + ".part"
    job = _Save(started + SAVE_DEADLINE)

    def on_term(signum, frame):
        job.stop_reason = "stopped"
    previous = signal.signal(signal.SIGTERM, on_term)
    count = 0
    try:
        with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
            for group, path, arc in _plan():
                if job.stopping():
                    job.omitted.append("%s (%s)" % (arc, job.stop_reason))
                    continue
                if path is None:                     # dmesg
                    proc = subprocess.Popen(["dmesg"], stdout=subprocess.PIPE,
                                            stderr=subprocess.DEVNULL)
                    try:
                        job.stream(zf, arc, proc.stdout)
                    finally:
                        proc.stdout.close()
                        proc.wait(timeout=30)
                    count += 1
                elif job.add_file(zf, group, path, arc):
                    count += 1
            summary = ["Save logs: %.0f s, %d files, logs %d bytes, black box %d bytes%s"
                       % (time.monotonic() - started, count, job.log_bytes, job.crash_bytes,
                          ", stopped early: " + job.stop_reason if job.stop_reason else "")]
            with zf.open(_zipinfo("run/omitted.txt"), "w") as dst:
                dst.write(("\n".join(summary + (job.omitted or ["nothing left out"])) + "\n").encode())
        os.replace(tmp, final)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    finally:
        signal.signal(signal.SIGTERM, previous)
    os.sync()
    return {"result": "SAVED", "file": name, "files": count + 1,
            "bytes": os.path.getsize(final), "usb": os.path.basename(target_dir),
            "partial": job.stop_reason is not None, "omitted": len(job.omitted),
            "safe_to_remove": True}
