# nebulaos_osconfig.cli - argv grammar and the JSON/exit-code contract
# (GUI/service readiness mission, 2026-10-09).
#
#   nebulaos-osconfig system info
#   nebulaos-osconfig network status|reset
#   nebulaos-osconfig network set-hostname --hostname NAME
#   nebulaos-osconfig network set-ipv4 --json '{"mode":"static",...}'
#   nebulaos-osconfig boot-display status|reset-image
#   nebulaos-osconfig boot-display set-mode --mode logo|console|blank
#   nebulaos-osconfig boot-display set-image --path REL_PATH_IN_CONFIG_ROOT
#   nebulaos-osconfig boot-display render [--if-stale]
#   nebulaos-osconfig display status|sleep|wake
#   nebulaos-osconfig display set-brightness --level 25|50|75|100
#
# stdout: exactly one JSON object, {"ok": true, ...} or
# {"ok": false, "error": CODE, "message": ...}. exit 0 ok, 1 invalid input
# (nothing written), 2 operation failed, 64 usage.
import json
import sys

from . import bootdisplay, common, display, network, system


def _opts(args, allowed):
    out = {}
    it = iter(args)
    for arg in it:
        if not arg.startswith("--") or arg[2:] not in allowed:
            raise common.invalid("USAGE", "unexpected argument %r" % arg)
        key = arg[2:]
        if allowed[key]:
            try:
                out[key] = next(it)
            except StopIteration:
                raise common.invalid("USAGE", "%s needs a value" % arg)
        else:
            out[key] = True
    return out


def _dispatch(argv):
    if len(argv) < 2:
        raise common.invalid("USAGE", "usage: nebulaos-osconfig DOMAIN VERB [options]")
    domain, verb, rest = argv[0], argv[1], argv[2:]
    read_only = {("system", "info"), ("network", "status"),
                 ("boot-display", "status"), ("display", "status")}
    if (domain, verb) in read_only:
        _opts(rest, {})
        return {"system": system.info, "network": network.status,
                "boot-display": bootdisplay.status, "display": display.status}[domain]()
    with common.Lock(domain):
        if domain == "network":
            if verb == "set-hostname":
                return network.set_hostname(_opts(rest, {"hostname": True}).get("hostname"))
            if verb == "set-ipv4":
                raw = _opts(rest, {"json": True}).get("json")
                try:
                    spec = json.loads(raw) if raw is not None else None
                except ValueError:
                    raise common.invalid("INVALID_IPV4", "--json is not valid JSON")
                return network.set_ipv4(spec)
            if verb == "reset":
                _opts(rest, {})
                return network.reset()
        elif domain == "boot-display":
            if verb == "set-mode":
                return bootdisplay.set_mode(_opts(rest, {"mode": True}).get("mode"))
            if verb == "set-image":
                return bootdisplay.set_image(_opts(rest, {"path": True}).get("path"))
            if verb == "reset-image":
                _opts(rest, {})
                return bootdisplay.reset_image()
            if verb == "render":
                return bootdisplay.render(
                    if_stale=bool(_opts(rest, {"if-stale": False}).get("if-stale")))
        elif domain == "display":
            if verb == "set-brightness":
                return display.set_brightness(_opts(rest, {"level": True}).get("level"))
            if verb == "sleep":
                _opts(rest, {})
                return display.sleep()
            if verb == "wake":
                _opts(rest, {})
                return display.wake()
    raise common.invalid("USAGE", "unknown command %s %s" % (domain, verb))


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        result = _dispatch(argv)
        out, code = dict({"ok": True}, **result), common.EXIT_OK
    except common.OsConfigError as exc:
        out = dict({"ok": False, "error": exc.code, "message": exc.message}, **exc.extra)
        code = common.EXIT_INVALID if exc.invalid else common.EXIT_FAILED
        if exc.code == "USAGE":
            code = 64
    except Exception as exc:  # never a traceback instead of the JSON contract
        out = {"ok": False, "error": "INTERNAL", "message": "%s: %s" % (type(exc).__name__, exc)}
        code = common.EXIT_FAILED
    sys.stdout.write(json.dumps(out, sort_keys=True) + "\n")
    return code
