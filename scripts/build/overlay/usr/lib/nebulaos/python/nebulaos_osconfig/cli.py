# nebulaos_osconfig.cli - argv grammar and the JSON/exit-code contract
# (GUI/service readiness mission, 2026-10-09).
#
#   nebulaos-osconfig system info
#   nebulaos-osconfig system clean-reset|cancel-clean-reset|ack-clean-reset
#   nebulaos-osconfig system swap-slot|keep-slot
#   nebulaos-osconfig image list|status|ack
#   nebulaos-osconfig image check --file ID
#   nebulaos-osconfig image install --file ID --sha256 HEX   (starts "image worker")
#   nebulaos-osconfig wifi status|scan
#   nebulaos-osconfig wifi connect --stdin     {"ssid": ..., "password": ...}
#   nebulaos-osconfig wifi forget --ssid SSID
#   nebulaos-osconfig network status|reset
#   nebulaos-osconfig network set-hostname --hostname NAME
#   nebulaos-osconfig network set-ipv4 --json '{"mode":"static",...}'
#   nebulaos-osconfig boot-display status|reset-image
#   nebulaos-osconfig boot-display set-mode --mode logo
#   nebulaos-osconfig boot-display restore-original-logo
#   nebulaos-osconfig boot-display set-image --file NAME_IN_UPLOAD_ROOT
#   nebulaos-osconfig boot-display render [--if-stale]
#   nebulaos-osconfig display status|sleep|wake
#   nebulaos-osconfig display set-brightness --level 25|50|75|100
#   nebulaos-osconfig mcu status|list
#   nebulaos-osconfig mcu flash --file ID --sha256 HEX   (ID and HEX from `list`)
#
# stdout: exactly one JSON object, {"ok": true, ...} or
# {"ok": false, "error": CODE, "message": ...}. exit 0 ok, 1 invalid input
# (nothing written), 2 operation failed, 64 usage.
import json
import sys

from . import bootdisplay, common, display, image, mcu, network, system, wifi


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


READ_ONLY = {("system", "info"), ("network", "status"),
             ("boot-display", "status"), ("display", "status"),
             ("wifi", "status"), ("mcu", "status"), ("mcu", "list"),
             ("image", "list"), ("image", "status")}

# G27 (2026-10-12): every change is one line in the system log (persistent
# system.log), success or failure. Read-only verbs are not logged (the screen
# polls them), nor is anything from stdin (the Wi-Fi password arrives there).
# Display sleep/wake run at every screen timeout, so only failures of those.
_QUIET_OK = {("display", "sleep"), ("display", "wake"), ("boot-display", "render")}
_LOGGED_ARGS = ("--hostname", "--ssid", "--mode", "--file", "--level", "--sha256")
_LOGGED_RESULT = ("result", "ssid", "address", "address_mode", "address_note",
                  "next_boot", "applies")


def _audit(argv, out):
    if len(argv) < 2 or (argv[0], argv[1]) in READ_ONLY:
        return
    if out.get("ok") and (argv[0], argv[1]) in _QUIET_OK:
        return
    parts = [argv[0], argv[1]]
    for i, arg in enumerate(argv[2:-1], start=2):
        if arg in _LOGGED_ARGS:
            parts.append("%s=%s" % (arg[2:], argv[i + 1]))
    if out.get("ok"):
        parts.append("ok")
        parts += ["%s=%s" % (k, out[k]) for k in _LOGGED_RESULT
                  if out.get(k) not in (None, "")]
    else:
        parts.append("FAILED %s: %s" % (out.get("error"), out.get("message")))
    try:
        import syslog
        syslog.openlog("nebulaos-osconfig")
        syslog.syslog(syslog.LOG_NOTICE if out.get("ok") else syslog.LOG_WARNING,
                      " ".join(str(p) for p in parts)[:900])
        syslog.closelog()
    except Exception:  # logging never changes the outcome
        pass


def _dispatch(argv):
    if len(argv) < 2:
        raise common.invalid("USAGE", "usage: nebulaos-osconfig DOMAIN VERB [options]")
    domain, verb, rest = argv[0], argv[1], argv[2:]
    if (domain, verb) == ("image", "trial"):
        _opts(rest, {})
        return image.trial()
    if (domain, verb) == ("image", "worker"):
        o = _opts(rest, {"file": True, "sha256": True})
        image.run_job(o.get("file"), o.get("sha256"))
        return {"result": "DONE"}
    if (domain, verb) in READ_ONLY:
        _opts(rest, {})
        if domain == "mcu":
            return mcu.status() if verb == "status" else mcu.list_files()
        if domain == "image":
            return image.status() if verb == "status" else image.list_files()
        return {"system": system.info, "network": network.status,
                "boot-display": bootdisplay.status, "display": display.status,
                "wifi": wifi.status}[domain]()
    if (domain, verb) == ("mcu", "flash"):
        # Its own non-blocking lock: a second flash is refused, never queued.
        opts = _opts(rest, {"file": True, "sha256": True})
        return mcu.flash(opts.get("file"), opts.get("sha256"))
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
                return bootdisplay.set_image(_opts(rest, {"file": True}).get("file"))
            if verb == "reset-image":
                _opts(rest, {})
                return bootdisplay.reset_image()
            if verb == "restore-original-logo":
                _opts(rest, {})
                return bootdisplay.restore_original_logo()
            if verb == "render":
                return bootdisplay.render(
                    if_stale=bool(_opts(rest, {"if-stale": False}).get("if-stale")))
        elif domain == "system":
            verbs = {"clean-reset": system.request_clean_reset,
                     "cancel-clean-reset": system.cancel_clean_reset,
                     "ack-clean-reset": system.ack_clean_reset,
                     "swap-slot": system.swap_slot, "keep-slot": system.keep_slot}
            if verb in verbs:
                _opts(rest, {})
                return verbs[verb]()
        elif domain == "image":
            if verb == "check":
                return image.check(_opts(rest, {"file": True}).get("file"))
            if verb == "install":
                o = _opts(rest, {"file": True, "sha256": True})
                return image.install(o.get("file"), o.get("sha256"))
            if verb == "ack":
                _opts(rest, {})
                return image.ack()
        elif domain == "wifi":
            if verb == "scan":
                _opts(rest, {})
                return wifi.scan()
            if verb == "connect":
                if not _opts(rest, {"stdin": False}).get("stdin"):
                    raise common.invalid("USAGE", "connect reads its request from --stdin")
                return wifi.connect(wifi.read_stdin_spec(sys.stdin))
            if verb == "forget":
                return wifi.forget(_opts(rest, {"ssid": True}).get("ssid"))
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
    _audit(argv, out)
    sys.stdout.write(json.dumps(out, sort_keys=True) + "\n")
    return code
