# nebulaos_osconfig.spoolman - the Spoolman server Moonraker talks to (G125,
# Run 22, Tim 2026-10-28: Settings > Connections > Spoolman on the screen, the
# same layout as the printer entry).
#
#   spoolman status                          {configured, server, host, port}
#   spoolman set --host HOST --port PORT     [spoolman] server: http://HOST:PORT
#   spoolman remove                          the [spoolman] section goes
#
# The setting lives where a user would put it by hand: the [spoolman] section
# of the user's moonraker.conf (config root, editable in Mainsail). Only that
# section's `server` line is touched - every other line, comment and option
# (sync_rate, ...) stays as it is; the file is written atomically. Not an
# [include]: Moonraker refuses to start on an include that matches no file.
# The Moonraker restart that makes it take effect is done by the Moonraker
# component (usr/lib/nebulaos/moonraker/nebulaos.py), after this returns.
# Refused while the printer is busy (G91 maintenance lock + request profile).
import os
import re

from . import common
from .common import invalid

MOONRAKER_CONF = os.environ.get("NEBULAOS_MOONRAKER_CONF",
                                "/opt/printer_data/config/moonraker.conf")
SECTION = "spoolman"
DEFAULT_PORT = 7912
_HOST_RE = re.compile(r"^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
                      r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$")
_SECTION_RE = re.compile(r"^\s*\[([^\]]+)\]\s*(?:[#;].*)?$")
_SERVER_RE = re.compile(r"^(\s*)server\s*[:=]\s*(.*?)\s*$")
_URL_RE = re.compile(r"^https?://\[?([^\]/:]+)\]?(?::(\d+))?/?$")


def _read_lines():
    try:
        with open(MOONRAKER_CONF) as handle:
            return handle.read().splitlines()
    except OSError as exc:
        raise common.OsConfigError("MOONRAKER_CONF_UNREADABLE",
                                   "cannot read %s (%s)" % (MOONRAKER_CONF, exc))


def _section_range(lines):
    """(start, end) of [spoolman]: the header line and the line after its
    last line, or None."""
    start = None
    for i, line in enumerate(lines):
        m = _SECTION_RE.match(line)
        if not m:
            continue
        if start is not None:
            return start, i
        if m.group(1).strip() == SECTION:
            start = i
    return (start, len(lines)) if start is not None else None


def _server(lines, rng):
    for i in range(rng[0] + 1, rng[1]):
        m = _SERVER_RE.match(lines[i])
        if m and not lines[i].lstrip().startswith(("#", ";")):
            return i, m.group(2)
    return None, None


def status():
    lines = _read_lines()
    rng = _section_range(lines)
    out = {"configured": False, "server": None, "host": None, "port": None}
    if rng is None:
        return out
    _, server = _server(lines, rng)
    if server:
        out.update(configured=True, server=server)
        m = _URL_RE.match(server)
        if m:
            out["host"] = m.group(1)
            out["port"] = int(m.group(2)) if m.group(2) else (
                443 if server.startswith("https") else 80)
    return out


def _check(host, port):
    host = (host or "").strip()
    if not _HOST_RE.match(host):
        raise invalid("INVALID_HOST", "not an IP address or host name")
    try:
        port = int(str(port).strip())
    except (TypeError, ValueError):
        raise invalid("INVALID_PORT", "the port must be a number")
    if not 1 <= port <= 65535:
        raise invalid("INVALID_PORT", "the port must be 1-65535")
    return host, port


def _write(lines):
    try:
        mode = os.stat(MOONRAKER_CONF).st_mode & 0o777
    except OSError:
        mode = 0o644
    common.atomic_write(MOONRAKER_CONF, "\n".join(lines) + "\n", mode)


@common.maintenance("spoolman")
def set_server(host, port):
    host, port = _check(host, port)
    url = "http://%s:%d" % (host, port)
    lines = _read_lines()
    rng = _section_range(lines)
    if rng is None:
        while lines and not lines[-1].strip():
            lines.pop()
        lines += ["", "[%s]" % SECTION, "server: %s" % url]
    else:
        idx, old = _server(lines, rng)
        if old == url:
            return dict(status(), result="UNCHANGED")
        if idx is None:
            lines.insert(rng[0] + 1, "server: %s" % url)
        else:
            lines[idx] = "%sserver: %s" % (_SERVER_RE.match(lines[idx]).group(1), url)
    _write(lines)
    return dict(status(), result="APPLIED", restart="moonraker")


@common.maintenance("spoolman")
def remove():
    lines = _read_lines()
    rng = _section_range(lines)
    if rng is None:
        return dict(status(), result="UNCHANGED")
    start, end = rng
    while start > 0 and not lines[start - 1].strip():
        start -= 1                       # the blank line before the section
    del lines[start:end]
    _write(lines)
    return dict(status(), result="APPLIED", restart="moonraker")
