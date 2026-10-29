# nebulaos_osconfig.cli - argv grammar and the JSON/exit-code contract
# (GUI/service readiness mission, 2026-10-09).
#
#   nebulaos-osconfig system info
#   nebulaos-osconfig system clean-reset|cancel-clean-reset|ack-clean-reset
#   nebulaos-osconfig system swap-slot|keep-slot
#   nebulaos-osconfig system ack-notice --id ID
#   nebulaos-osconfig system storage | cleanup-plan [--videos]   (read-only, walk the drive)
#   nebulaos-osconfig system busy --profile request|point_of_no_return|git|restart|recovery
#                                 [--holder TOKEN]   (G91 busy check, read-only)
#   nebulaos-osconfig system cleanup-creality [--videos]
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
#   nebulaos-osconfig logs status | set-level --level info|warning|debug | write-state | save
#   nebulaos-osconfig logs expire-debug        (housekeeping: Debug ends after 24 h)
#   nebulaos-osconfig settings status
#   nebulaos-osconfig settings snapshot --reason new-system|changed|manual
#                                       [--db api|file|none] [--if-changed]
#   nebulaos-osconfig boot-display restore-original-logo
#   nebulaos-osconfig boot-display list-images | preview [--file NAME]
#   nebulaos-osconfig boot-display import-usb --file usb/<dev>/<path> | delete-image --file NAME
#   nebulaos-osconfig boot-display set-image --file NAME_IN_UPLOAD_ROOT
#   nebulaos-osconfig boot-display render [--if-stale]
#   nebulaos-osconfig boot-display fresh-default   (S04nebulaos-factory-seed, first seed only)
#   nebulaos-osconfig display status|sleep|wake
#   nebulaos-osconfig display set-brightness --level 25|50|75|100
#   nebulaos-osconfig spoolman status|remove | set --host HOST --port PORT   (G125)
#   nebulaos-osconfig camera status|defaults|reset|version | set --json '{...}' |
#                     apply [--device /dev/videoN]                       (G121)
#   nebulaos-osconfig ota status | check [--force]     (G79 S2: signed release check)
#   nebulaos-osconfig mcu status|list
#   nebulaos-osconfig mcu flash --file ID --sha256 HEX   (ID and HEX from `list`)
#   nebulaos-osconfig updates readiness                  (the last check, read-only)
#   nebulaos-osconfig updates check-readiness [--if-changed]
#
# stdout: exactly one JSON object, {"ok": true, ...} or
# {"ok": false, "error": CODE, "message": ...}. exit 0 ok, 1 invalid input
# (nothing written), 2 operation failed, 3 refused because the printer is busy
# (G91: CODE is the busy reason, "refused": true; nothing changed), 64 usage.
import json
import sys

from . import (bootdisplay, camera, cleanup, common, display, image, logs, mcu, network,
               ota, snapshot, spoolman, system, updates, wifi)


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
             ("boot-display", "list-images"), ("boot-display", "preview"),
             ("wifi", "status"), ("mcu", "status"), ("mcu", "list"),
             ("image", "list"), ("image", "status"), ("logs", "status"),
             ("settings", "status"), ("system", "storage"), ("system", "cleanup-plan"),
             ("updates", "readiness"), ("system", "busy"), ("spoolman", "status"),
             ("camera", "status"), ("ota", "status")}

# G27 (2026-10-12): every change is one line in the system log (persistent
# system.log), success or failure. Read-only verbs are not logged (the screen
# polls them), nor is anything from stdin (the Wi-Fi password arrives there).
# Display sleep/wake run at every screen timeout, so only failures of those.
_QUIET_OK = {("display", "sleep"), ("display", "wake"), ("boot-display", "render"),
             ("logs", "write-state"), ("logs", "expire-debug"),
             ("updates", "check-readiness"), ("camera", "apply")}
# Read-only verbs that ARE the domain's status/info function.
_STATUS_ALIASES = {("system", "info"), ("mcu", "list"), ("image", "list")}
# A snapshot is logged when one is taken, not when nothing changed.
_QUIET_RESULTS = ("UNCHANGED",)
_LOGGED_ARGS = ("--hostname", "--ssid", "--mode", "--file", "--level", "--sha256", "--reason",
                "--host", "--port")
_LOGGED_RESULT = ("result", "ssid", "address", "address_mode", "address_note",
                  "next_boot", "applies", "name", "database")


def _audit(argv, out):
    if len(argv) < 2 or (argv[0], argv[1]) in READ_ONLY:
        return
    if out.get("ok") and (argv[0], argv[1]) in _QUIET_OK and out.get("result") != "EXPIRED":
        return
    if out.get("ok") and out.get("result") in _QUIET_RESULTS:
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


def _syslog_line(text):
    try:
        import syslog
        syslog.openlog("nebulaos-osconfig")
        syslog.syslog(syslog.LOG_NOTICE, "cleanup-creality " + text[:300])
        syslog.closelog()
    except Exception:
        pass


def _dispatch(argv):
    if len(argv) < 2:
        raise common.invalid("USAGE", "usage: nebulaos-osconfig DOMAIN VERB [options]")
    domain, verb, rest = argv[0], argv[1], argv[2:]
    if (domain, verb) == ("system", "storage"):
        _opts(rest, {})
        return cleanup.storage()
    if (domain, verb) == ("system", "cleanup-plan"):
        return cleanup.plan(bool(_opts(rest, {"videos": False}).get("videos")))
    if (domain, verb) == ("image", "trial"):
        _opts(rest, {})
        return image.trial()
    if (domain, verb) == ("image", "worker"):
        o = _opts(rest, {"file": True, "sha256": True, "holder": True})
        image.run_job(o.get("file"), o.get("sha256"), o.get("holder"))
        return {"result": "DONE"}
    # Read-only verbs with their own function (not the domain's status):
    # list-images and preview used to fall through to bootdisplay.status, so
    # the Boot logo page saw no images and "no USB stick" (found on ke-dev
    # 2026-10-16, Run 9 test).
    if (domain, verb) == ("boot-display", "list-images"):
        _opts(rest, {})
        return bootdisplay.list_images()
    if (domain, verb) == ("boot-display", "preview"):
        return bootdisplay.preview(_opts(rest, {"file": True}).get("file") or "")
    if (domain, verb) == ("updates", "readiness"):
        _opts(rest, {})
        return updates.readiness()
    if (domain, verb) == ("system", "busy"):
        o = _opts(rest, {"profile": True, "holder": True})
        return common.busy_state(o.get("profile") or "request", o.get("holder"))
    if (domain, verb) in READ_ONLY:
        _opts(rest, {})
        if verb != "status" and (domain, verb) not in _STATUS_ALIASES:
            raise common.invalid("USAGE", "no handler for %s %s" % (domain, verb))
        if domain == "mcu":
            return mcu.status() if verb == "status" else mcu.list_files()
        if domain == "image":
            return image.status() if verb == "status" else image.list_files()
        return {"system": system.info, "network": network.status,
                "boot-display": bootdisplay.status, "display": display.status,
                "wifi": wifi.status, "logs": logs.status,
                "settings": snapshot.status, "spoolman": spoolman.status,
                "camera": camera.status, "ota": ota.status}[domain]()
    if (domain, verb) == ("mcu", "flash"):
        # Its own non-blocking lock: a second flash is refused, never queued.
        opts = _opts(rest, {"file": True, "sha256": True})
        return mcu.flash(opts.get("file"), opts.get("sha256"))
    with common.Lock(domain):
        if domain == "ota":
            if verb == "check":
                return ota.check(force=bool(_opts(rest, {"force": False}).get("force")))
        if domain == "camera":
            if verb == "set":
                raw = _opts(rest, {"json": True}).get("json")
                try:
                    changes = json.loads(raw) if raw is not None else None
                except ValueError:
                    raise common.invalid("INVALID_CAMERA_SETTING", "--json is not valid JSON")
                return camera.set_settings(changes)
            if verb in ("defaults", "reset", "version"):
                _opts(rest, {})
                return {"defaults": camera.defaults, "reset": camera.reset,
                        "version": camera.version}[verb]()
            if verb == "apply":
                return camera.apply(_opts(rest, {"device": True}).get("device"))
        if domain == "spoolman":
            if verb == "set":
                o = _opts(rest, {"host": True, "port": True})
                return spoolman.set_server(o.get("host"), o.get("port"))
            if verb == "remove":
                _opts(rest, {})
                return spoolman.remove()
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
            if verb == "list-images":
                _opts(rest, {})
                return bootdisplay.list_images()
            if verb == "import-usb":
                return bootdisplay.import_usb(_opts(rest, {"file": True}).get("file"))
            if verb == "delete-image":
                return bootdisplay.delete_image(_opts(rest, {"file": True}).get("file"))
            if verb == "preview":
                return bootdisplay.preview(_opts(rest, {"file": True}).get("file") or "")
            if verb == "fresh-default":
                _opts(rest, {})
                return bootdisplay.fresh_install_default()
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
            if verb == "cleanup-creality":
                videos = bool(_opts(rest, {"videos": False}).get("videos"))
                return cleanup.clean_creality(videos, log=_syslog_line)
            if verb == "ack-notice":
                return system.ack_notice(_opts(rest, {"id": True}).get("id"))
        elif domain == "logs":
            if verb == "status":
                _opts(rest, {})
                return logs.status()
            if verb == "set-level":
                return logs.set_level(_opts(rest, {"level": True}).get("level"))
            if verb == "write-state":
                _opts(rest, {})
                return logs.write_state()
            if verb == "save":
                _opts(rest, {})
                return logs.save_logs()
            if verb == "expire-debug":
                _opts(rest, {})
                return logs.expire_debug()
        elif domain == "settings":
            if verb == "snapshot":
                o = _opts(rest, {"reason": True, "db": True, "if-changed": False})
                return snapshot.take(o.get("reason"), db=o.get("db", "api"),
                                     if_changed=bool(o.get("if-changed")))
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
        elif domain == "updates":
            if verb == "check-readiness":
                o = _opts(rest, {"if-changed": False})
                return updates.check(if_changed=bool(o.get("if-changed")))
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
        if exc.refused:
            out["refused"] = True
            code = common.EXIT_REFUSED
        if exc.code == "USAGE":
            code = 64
    except Exception as exc:  # never a traceback instead of the JSON contract
        out = {"ok": False, "error": "INTERNAL", "message": "%s: %s" % (type(exc).__name__, exc)}
        code = common.EXIT_FAILED
    _audit(argv, out)
    sys.stdout.write(json.dumps(out, sort_keys=True) + "\n")
    return code
