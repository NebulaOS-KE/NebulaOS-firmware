# nebulaos_osconfig.common - shared plumbing for the NebulaOS OS-settings
# helper (GUI/service readiness mission, 2026-10-09).
#
# The helper is the narrow layer behind the [nebulaos] Moonraker component:
# argv in, exactly one JSON object out, validated input, atomic persistent
# writes, one lock. It never runs a shell and never interpolates input into a
# command line.
import errno
import fcntl
import json
import os
import subprocess
import time

NEBULAOS_ROOT = os.environ.get("NEBULAOS_ROOT", "/usr/data/nebulaos")
RUN_DIR = os.environ.get("NEBULAOS_OSCONFIG_RUN", "/run/nebulaos")
LOCK_DIR = RUN_DIR

EXIT_OK = 0
EXIT_INVALID = 1      # the request was rejected by validation; nothing written
EXIT_FAILED = 2       # valid request, the operation failed (state as reported)
EXIT_REFUSED = 3      # G91: refused because the printer is busy; nothing changed


class OsConfigError(Exception):
    """A failure with a stable machine-readable code. `invalid` marks input
    validation errors (nothing was written)."""

    def __init__(self, code, message, invalid=False, **extra):
        super(OsConfigError, self).__init__(message)
        self.code = code
        self.message = message
        self.invalid = invalid
        self.refused = False
        self.extra = extra


def invalid(code, message, **extra):
    return OsConfigError(code, message, invalid=True, **extra)


class Refused(OsConfigError):
    """G91: refused because the printer is busy (busy_state). The code is the
    busy reason (PRINTING, PAUSED, ...); exit 3; nothing was changed."""

    def __init__(self, state):
        super(Refused, self).__init__(state["reason"], state["message"],
                                      reason=state["reason"], profile=state["profile"])
        self.refused = True


class Lock(object):
    """Serialises changes within one domain (GUI, Mainsail and SSH may race).
    Per domain, so a display wake never waits behind a network apply."""

    def __init__(self, domain):
        self.path = os.path.join(LOCK_DIR, "osconfig-%s.lock" % domain)
        self.fd = None

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        try:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
        finally:
            os.close(self.fd)
        return False


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write(path, data, mode=0o644):
    """tmp + fsync + rename + directory fsync (journal-less ext4 /usr/data)."""
    if isinstance(data, str):
        data = data.encode("utf-8")
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)
    fsync_dir(directory)


def atomic_write_json(path, obj):
    atomic_write(path, json.dumps(obj, indent=2, sort_keys=True) + "\n")


def read_json(path):
    """(obj, error): obj is None when missing (error None) or unreadable
    (error set). Never raises for a bad file - callers fall back to
    defaults and report the error."""
    try:
        with open(path, "rb") as handle:
            raw = handle.read(65536)
    except OSError as exc:
        if exc.errno == errno.ENOENT:
            return None, None
        return None, "unreadable: %s" % exc
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        return None, "corrupt: %s" % exc
    if not isinstance(obj, dict):
        return None, "corrupt: not an object"
    return obj, None


def render_env(pairs):
    """KEY=value lines for the boot shell. Values are already validated by the
    caller; this only refuses characters a shell reader could misparse."""
    lines = []
    for key, value in pairs:
        value = str(value)
        for ch in value:
            if not (ch.isalnum() or ch in "._- "):
                raise ValueError("refusing to render %r into an env file" % value)
        lines.append('%s="%s"' % (key, value))
    return "\n".join(lines) + "\n"


def run(argv, timeout, env=None):
    """argv-only subprocess (never a shell). Returns (rc, stdout, stderr);
    a timeout is rc 124."""
    try:
        proc = subprocess.run(argv, capture_output=True, text=True,
                              timeout=timeout, env=env)
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timeout after %ss" % timeout
    except OSError as exc:
        return 127, "", str(exc)


def parse_kv(text):
    out = {}
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            out[key.strip()] = value.strip()
        elif ": " in line:
            key, value = line.split(": ", 1)
            out[key.strip()] = value.strip()
    return out


# -- G91: the shared busy check ----------------------------------------------------
#
# One answer to "may this disruptive action run now?" for every update path
# (design _scratch/run16/G91-update-design.md v2.1/v3). busy_state(profile)
# returns {"busy", "reason", "message", "profile", "klippy"}. Reasons, the
# first that applies wins:
#
#   PRINTING     print_stats printing (or the memguard print-active marker)
#   PAUSED       print_stats paused
#   ACTIVE       a heater target > 0, idle_timeout "Printing" (now, or in
#                memguard's last 3 samples: the klipper-active marker), or a
#                PLR resume in progress
#   CALIBRATING  "busy" in nebulaos_calibration / nebulaos_load_cell_calibration
#                / nebulaos_bed_tram (a missing field = not calibrating)
#   UPDATING     the maintenance lock or the MCU flash lock held by someone
#                else, Moonraker's update_manager busy, or a pending image
#                trial for the running slot (request profile)
#   LOW_MEMORY   memguard deny-maintenance
#   UNKNOWN      Klippy alive but its state could not be read
#
# Klippy reachability (R2, N1): Moonraker's klippy_state first; when Moonraker
# does not answer, or says disconnected/startup, Klippy's own API socket. A
# positive "Klippy not ready" (error, shutdown, startup, or no Klippy at all)
# means no print can run: the print reasons and the memguard markers do not
# apply then (R3). The memguard markers only ever make the answer more busy.
#
# Profiles (R1): which reasons count.
#   request             every user-started update/install/flash/switch/reset
#   point_of_no_return  re-checks inside a running job (the caller's own lock
#                       is excluded by its holder token; no pending-trial rule)
#   git                 the git wrapper inside a Moonraker update: not
#                       update_manager busy
#   restart             supervisorctl restart/stop of klipper, the screen's
#                       Restart Klipper / Restart MCU: G95 (Tim 2026-10-22) -
#                       only a POSITIVE answer refuses (print_stats printing/
#                       paused, a heater target or idle_timeout "Printing" from
#                       a live reply, or the memguard markers while Klippy
#                       answers). No answer, a timeout, an error = UNKNOWN =
#                       allowed: a hung Klipper can always be restarted.
#   screen              the update supervisor's own NebulaScreen restarts: the
#                       pre-G95 restart rule (print + activity, UNKNOWN = busy)
#   recovery            supervisor rollback, image trial fallback: print +
#                       activity only; UNKNOWN only together with the
#                       print-active marker (N3); never a lock
KLIPPY_SOCK = os.environ.get("NEBULAOS_KLIPPY_SOCK", "/opt/printer_data/comms/klippy.sock")
KLIPPY_PIDFILE = os.environ.get("NEBULAOS_KLIPPY_PIDFILE", "/var/run/klippy.pid")
PROC_DIR = os.environ.get("NEBULAOS_PROC_DIR", "/proc")
MOONRAKER_BASE = os.environ.get("NEBULAOS_MOONRAKER_BASE", "http://127.0.0.1:7125")
MAINTENANCE_LOCK = os.path.join(RUN_DIR, "maintenance.lock")
MCU_FLASH_LOCK = os.path.join(RUN_DIR, "mcu", "flash.lock")
IMAGE_TRIAL = os.environ.get("NEBULAOS_IMAGE_TRIAL",
                             os.path.join(NEBULAOS_ROOT, "system", "image-update-trial.json"))
BUSY_TIMEOUT = float(os.environ.get("NEBULAOS_BUSY_TIMEOUT", "3"))

BUSY_REASONS = ("PRINTING", "PAUSED", "ACTIVE", "CALIBRATING", "UPDATING", "LOW_MEMORY",
                "UNKNOWN")
BUSY_MESSAGES = {
    "PRINTING": "Not possible while a print is running.",
    "PAUSED": "Not possible while a print is paused.",
    "ACTIVE": "Not possible while the printer is moving or heating.",
    "CALIBRATING": "Not possible while a calibration is running.",
    "UPDATING": "Another update is running.",
    "LOW_MEMORY": "Not possible right now: the printer is low on memory.",
    "UNKNOWN": "Printer state unknown - not possible right now.",
}
TRIAL_MESSAGE = "The new system is still being checked - try again after the check."
TRIAL_POSTPONED_MESSAGE = "The new system is checked after the print - try again then."
PROFILES = {
    "request": {"PRINTING", "PAUSED", "ACTIVE", "CALIBRATING", "UPDATING", "LOW_MEMORY",
                "UNKNOWN", "update_manager", "trial"},
    "point_of_no_return": {"PRINTING", "PAUSED", "ACTIVE", "CALIBRATING", "UPDATING",
                           "LOW_MEMORY", "UNKNOWN", "update_manager"},
    "git": {"PRINTING", "PAUSED", "ACTIVE", "CALIBRATING", "UPDATING", "LOW_MEMORY",
            "UNKNOWN"},
    "restart": {"PRINTING", "PAUSED", "ACTIVE"},
    "screen": {"PRINTING", "PAUSED", "ACTIVE", "UNKNOWN"},
    "recovery": {"PRINTING", "PAUSED", "ACTIVE"},
}
# G95: profiles that count only what a live, answering Klippy says (the
# memguard markers too only while Klippy answers; never UNKNOWN).
POSITIVE_ONLY = {"restart"}
# What one query asks Klippy (through Moonraker or its socket).
BUSY_OBJECTS = {
    "print_stats": ["state"],
    "idle_timeout": ["state"],
    "extruder": ["target"],
    "heater_bed": ["target"],
    "nebulaos_power_loss_recovery": ["resume_in_progress"],
    "nebulaos_calibration": ["busy"],
    "nebulaos_load_cell_calibration": ["busy"],
    "nebulaos_bed_tram": ["busy"],
}


def _http_json(path, timeout):
    import urllib.request
    # The local Moonraker: never through a proxy from the environment.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(MOONRAKER_BASE + path, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))["result"]


def klippy_socket_request(method, params, timeout):
    """One request on Klippy's API socket (JSON + 0x03). Returns the result,
    raises OSError when nothing listens (no Klippy) and ValueError when Klippy
    answered with an error or garbage."""
    import socket
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(KLIPPY_SOCK)
        sock.sendall(json.dumps({"id": 1, "method": method, "params": params}).encode() + b"\x03")
        data = b""
        while b"\x03" not in data:
            block = sock.recv(65536)
            if not block:
                raise ValueError("Klippy closed the connection")
            data += block
    finally:
        sock.close()
    reply = json.loads(data.split(b"\x03", 1)[0].decode("utf-8", "replace"))
    if "result" not in reply:
        raise ValueError("Klippy error: %s" % reply.get("error"))
    return reply["result"]


def _query_string():
    return "&".join("%s=%s" % (k, ",".join(v)) for k, v in sorted(BUSY_OBJECTS.items()))


def klippy_facts(timeout=None):
    """{"klippy": "ready"|"not_ready"|"unknown", "status": {...} | None,
    "moonraker": bool, "update_manager_busy": bool | None}."""
    timeout = BUSY_TIMEOUT if timeout is None else timeout
    facts = {"klippy": "unknown", "status": None, "moonraker": False,
             "update_manager_busy": None}
    try:
        state = _http_json("/server/info", timeout).get("klippy_state")
        facts["moonraker"] = True
    except Exception:
        state = None
    if facts["moonraker"]:
        try:
            facts["update_manager_busy"] = bool(_http_json("/machine/update/status", timeout)
                                                .get("busy"))
        except Exception:
            facts["update_manager_busy"] = None
    if state == "ready":
        try:
            facts["status"] = _http_json("/printer/objects/query?" + _query_string(),
                                         timeout)["status"]
            facts["klippy"] = "ready"
        except Exception:
            facts["klippy"] = "unknown"      # alive and ready, but the query failed
        return facts
    if state in ("error", "shutdown"):
        facts["klippy"] = "not_ready"        # Moonraker talks to it: positive
        return facts
    # Moonraker down, or disconnected/startup (N1): no Klippy process means
    # no print (v3.6); a running one is asked on its own socket.
    if not klippy_pid_alive():
        facts["klippy"] = "not_ready"
        return facts
    try:
        info = klippy_socket_request("info", {}, timeout)
    except OSError:
        facts["klippy"] = "not_ready" if not _socket_alive() else "unknown"
        return facts
    except ValueError:
        facts["klippy"] = "unknown"
        return facts
    if info.get("state") != "ready":
        facts["klippy"] = "not_ready"
        return facts
    try:
        facts["status"] = klippy_socket_request("objects/query", {"objects": BUSY_OBJECTS},
                                                timeout)["status"]
        facts["klippy"] = "ready"
    except (OSError, ValueError, KeyError, TypeError):
        facts["klippy"] = "unknown"
    return facts


def klippy_pid_alive():
    try:
        with open(KLIPPY_PIDFILE) as handle:
            pid = handle.read().strip()
    except OSError:
        return False
    return pid.isdigit() and os.path.isdir(os.path.join(PROC_DIR, pid))


def _socket_alive():
    """Something accepted the connection but did not answer in time (a hung
    Klippy) - versus nothing listening (connect refused, no socket file)."""
    import socket
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    except OSError:
        return False
    sock.settimeout(1)
    try:
        sock.connect(KLIPPY_SOCK)
        return True
    except OSError:
        return False
    finally:
        sock.close()


def _num(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def status_reasons(status):
    """Busy reasons a Klippy status says, in table order."""
    status = status if isinstance(status, dict) else {}

    def get(obj, key):
        rec = status.get(obj)
        return rec.get(key) if isinstance(rec, dict) else None
    out = []
    state = get("print_stats", "state")
    if state == "printing":
        out.append("PRINTING")
    elif state == "paused":
        out.append("PAUSED")
    if (get("idle_timeout", "state") == "Printing"
            or _num(get("extruder", "target")) > 0 or _num(get("heater_bed", "target")) > 0
            or get("nebulaos_power_loss_recovery", "resume_in_progress") is True):
        out.append("ACTIVE")
    if any(get(obj, "busy") is True for obj in
           ("nebulaos_calibration", "nebulaos_load_cell_calibration", "nebulaos_bed_tram")):
        out.append("CALIBRATING")
    return out


def lock_holder(path):
    """The token in a held flock file, "" when held without one, None when
    the lock is free (or the file does not exist)."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return None
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except OSError:
            try:
                return os.read(fd, 256).decode("utf-8", "replace").split()[0]
            except (OSError, IndexError):
                return ""
        fcntl.flock(fd, fcntl.LOCK_UN)
        return None
    finally:
        os.close(fd)


class MaintenanceLock(object):
    """P6: one install/update/flash at a time (/run/nebulaos/maintenance.lock,
    flock, tmpfs - it cannot survive a reboot). acquire() refuses (UPDATING)
    instead of waiting. The token is written into the file, so a holder's own
    busy checks exclude it (busy_state(..., holder=token)). The fd may be handed
    to a child process (pass_fds); the lock lives as long as any copy is open."""

    def __init__(self, token, path=None):
        self.token = token
        self.path = path or MAINTENANCE_LOCK
        self.fd = None

    def acquire(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            raise Refused(busy_result("request", "UPDATING"))
        os.ftruncate(fd, 0)
        os.write(fd, ("%s %d\n" % (self.token, os.getpid())).encode())
        self.fd = fd
        return self

    def release(self):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
                self.fd = None

    def __enter__(self):
        return self.acquire()

    def __exit__(self, *exc):
        self.release()
        return False


def busy_result(profile, reason, message=None, klippy=None):
    return {"busy": reason is not None, "reason": reason, "profile": profile,
            "message": message or BUSY_MESSAGES.get(reason, ""), "klippy": klippy}


def trial_pending():
    """The pending image trial record for the RUNNING slot (v3.2), or None."""
    trial, _ = read_json(IMAGE_TRIAL)
    if not trial:
        return None
    from . import system     # system imports this module
    return trial if trial.get("to") == system.boot_slot() else None


def busy_state(profile, holder=None, facts=None):
    """G91 busy check. holder: the caller's own maintenance-lock token (never
    counted). facts: klippy_facts() output (tests and callers that already
    have it)."""
    if profile not in PROFILES:
        raise invalid("INVALID_PROFILE", "unknown busy profile %r" % profile)
    counts = PROFILES[profile]
    facts = klippy_facts() if facts is None else facts
    klippy = facts.get("klippy")
    marker = os.path.exists(os.path.join(RUN_DIR, "print-active"))
    active_marker = os.path.exists(os.path.join(RUN_DIR, "klipper-active"))
    reasons = []
    if klippy == "ready":
        reasons += status_reasons(facts.get("status"))
    marker_states = ("ready",) if profile in POSITIVE_ONLY else ("ready", "unknown")
    if klippy in marker_states:
        # R3: the markers count only while Klippy may be printing.
        if marker and "PAUSED" not in reasons:
            reasons.append("PRINTING")
        if active_marker:
            reasons.append("ACTIVE")
    for lock, own in ((MAINTENANCE_LOCK, holder), (MCU_FLASH_LOCK, holder)):
        token = lock_holder(lock)
        if token is not None and (own is None or token != own):
            reasons.append("UPDATING")
    if "update_manager" in counts and facts.get("update_manager_busy"):
        reasons.append("UPDATING")
    updating_message = None
    if "trial" in counts and "UPDATING" not in reasons:
        trial = trial_pending()
        if trial:
            reasons.append("UPDATING")
            updating_message = (TRIAL_POSTPONED_MESSAGE if trial.get("postponed")
                                else TRIAL_MESSAGE)
    if os.path.exists(os.path.join(RUN_DIR, "memguard", "deny-maintenance")):
        reasons.append("LOW_MEMORY")
    if klippy == "unknown":
        reasons.append("UNKNOWN")
    for reason in BUSY_REASONS:
        if reason in reasons and reason in counts:
            message = updating_message if reason == "UPDATING" else None
            return busy_result(profile, reason, message, klippy)
    return busy_result(profile, None, klippy=klippy)


def refuse_if_busy(profile="request", holder=None):
    """Raise Refused when busy_state says so; return the state otherwise."""
    state = busy_state(profile, holder)
    if state["busy"]:
        raise Refused(state)
    return state


# The maintenance-lock token of the action running in this process (set by
# @maintenance), for a child that re-checks at its own point of no return
# (nebulaos-mcu reads it from NEBULAOS_MAINTENANCE_HOLDER).
CURRENT_HOLDER = None


def maintenance(name):
    """G91 v2.7 step 6 (P1, P6): the decorated disruptive action takes the
    maintenance lock (a second one is refused UPDATING, never queued) and is
    refused (Refused, exit 3) while the request busy check says busy - its own
    lock excluded. Nothing has been changed when either refuses."""
    import functools

    def wrap(fn):
        @functools.wraps(fn)
        def run(*args, **kwargs):
            global CURRENT_HOLDER
            token = "%s-%d" % (name, os.getpid())
            with MaintenanceLock(token):
                refuse_if_busy("request", holder=token)
                outer, CURRENT_HOLDER = CURRENT_HOLDER, token
                try:
                    return fn(*args, **kwargs)
                finally:
                    CURRENT_HOLDER = outer
        return run
    return wrap


# S34 (G91 v2.5): a reboot-type point of no return waits until Klippy has
# been settled for REBOOT_GRACE seconds - SAVE_CONFIG rewrites printer.cfg
# and restarts Klippy in-process, a FIRMWARE_RESTART or service restart
# starts a new process - then syncs. Bounded: never more than REBOOT_GRACE.
REBOOT_GRACE = float(os.environ.get("NEBULAOS_REBOOT_GRACE", "3"))
PRINTER_CFG = os.environ.get("NEBULAOS_PRINTER_CFG", "/opt/printer_data/config/printer.cfg")


def _klippy_age():
    """Seconds since the Klippy process started, None when unknown."""
    try:
        with open(KLIPPY_PIDFILE) as handle:
            pid = handle.read().strip()
        with open(os.path.join(PROC_DIR, pid, "stat")) as handle:
            fields = handle.read().rsplit(")", 1)[1].split()
        with open(os.path.join(PROC_DIR, "uptime")) as handle:
            uptime = float(handle.read().split()[0])
        return uptime - int(fields[19]) / float(os.sysconf("SC_CLK_TCK"))
    except (OSError, ValueError, IndexError):
        return None


def klippy_settled_for():
    """Seconds since the last Klippy (re)start or printer.cfg write (SAVE_CONFIG)."""
    ages = []
    try:
        ages.append(time.time() - os.stat(PRINTER_CFG).st_mtime)
    except OSError:
        pass
    age = _klippy_age()
    if age is not None:
        ages.append(age)
    return min(ages) if ages else None


def reboot_grace(sleep=None):
    """Wait out the rest of REBOOT_GRACE after a Klippy (re)start or a
    printer.cfg write, then sync. Returns the seconds waited."""
    sleep = sleep or time.sleep
    age = klippy_settled_for()
    waited = 0.0
    if age is not None and 0 <= age < REBOOT_GRACE:
        waited = REBOOT_GRACE - age
        sleep(waited)
    os.sync()
    return waited
