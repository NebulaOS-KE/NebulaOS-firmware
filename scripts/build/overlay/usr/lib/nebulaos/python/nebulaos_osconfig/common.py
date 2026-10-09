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

NEBULAOS_ROOT = os.environ.get("NEBULAOS_ROOT", "/usr/data/nebulaos")
RUN_DIR = os.environ.get("NEBULAOS_OSCONFIG_RUN", "/run/nebulaos")
LOCK_DIR = RUN_DIR

EXIT_OK = 0
EXIT_INVALID = 1      # the request was rejected by validation; nothing written
EXIT_FAILED = 2       # valid request, the operation failed (state as reported)


class OsConfigError(Exception):
    """A failure with a stable machine-readable code. `invalid` marks input
    validation errors (nothing was written)."""

    def __init__(self, code, message, invalid=False, **extra):
        super(OsConfigError, self).__init__(message)
        self.code = code
        self.message = message
        self.invalid = invalid
        self.extra = extra


def invalid(code, message, **extra):
    return OsConfigError(code, message, invalid=True, **extra)


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
