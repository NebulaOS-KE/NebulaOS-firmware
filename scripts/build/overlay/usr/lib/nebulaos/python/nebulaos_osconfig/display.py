# nebulaos_osconfig.display - display backlight brightness and sleep/wake
# (GUI/service readiness mission, 2026-10-09).
#
#   display/display.json   source of truth (schema 1): brightness, touch_wake
#   display/display.env    scalars for the shell side (/etc/nebulaos-backlight.sh
#                          boot restore, and the S98 touch-wake gate)
#
# Hardware is driven only through /usr/libexec/nebulaos/nebulaos-backlight
# over the kernel controller's standard backlight class device
# (/sys/class/backlight/nebulaos_backlight) - see that library's header.
import os

from . import common
from .common import invalid, OsConfigError

SCHEMA = 1
LEVELS = (25, 50, 75, 100)
DEFAULT_LEVEL = 100

DISPLAY_DIR = os.path.join(common.NEBULAOS_ROOT, "display")
CONFIG = os.path.join(DISPLAY_DIR, "display.json")
ENV = os.path.join(DISPLAY_DIR, "display.env")
BACKLIGHT = os.environ.get("NEBULAOS_BACKLIGHT_CLI",
                           "/usr/libexec/nebulaos/nebulaos-backlight")
TIMEOUT = 15


def default_config():
    return {"schema": SCHEMA, "brightness": DEFAULT_LEVEL, "touch_wake": True}


def validate_level(value):
    try:
        level = int(value)
    except (TypeError, ValueError):
        raise invalid("INVALID_BRIGHTNESS", "brightness must be one of %s"
                      % ", ".join(map(str, LEVELS)))
    if isinstance(value, bool) or level not in LEVELS or str(value).strip() != str(level):
        raise invalid("INVALID_BRIGHTNESS", "brightness must be one of %s "
                      "(the levels the backlight controller supports)"
                      % ", ".join(map(str, LEVELS)))
    return level


def load_config():
    raw, error = common.read_json(CONFIG)
    if raw is None:
        return default_config(), error
    try:
        if raw.get("schema") != SCHEMA:
            raise invalid("CONFIG_INVALID", "unsupported schema")
        tw = raw.get("touch_wake", True)
        if not isinstance(tw, bool):
            raise invalid("CONFIG_INVALID", "touch_wake must be a boolean")
        return {"schema": SCHEMA, "brightness": validate_level(raw.get("brightness")),
                "touch_wake": tw}, None
    except OsConfigError as exc:
        return default_config(), "%s: %s" % (exc.code, exc.message)


def _persist(cfg):
    common.atomic_write_json(CONFIG, cfg)
    common.atomic_write(ENV, common.render_env([
        ("BRIGHTNESS", cfg["brightness"]),
        ("TOUCH_WAKE", "1" if cfg["touch_wake"] else "0")]))


def _cli(*args):
    return common.run([BACKLIGHT] + list(args), TIMEOUT)


def hardware_status():
    rc, out, err = _cli("status")
    kv = common.parse_kv(out) if rc == 0 else {}
    st = {"available": kv.get("available") == "1"}
    if st["available"]:
        level = kv.get("level", "")
        selected = kv.get("selected", "")
        st.update({
            "interface": kv.get("interface") or None,
            "level": int(level) if level.isdigit() else None,
            "selected_level": int(selected) if selected.isdigit() else None,
            "asleep": kv.get("asleep") == "1",
            "touch_wake_running": kv.get("touch_wake") == "1",
        })
    elif rc != 0:
        st["error"] = (err or out).strip()[-500:]
    return st


def status():
    cfg, error = load_config()
    return {
        "config": cfg,
        "config_error": error,
        "levels": list(LEVELS),
        "interface": "sysfs",
        "backlight": hardware_status(),
    }


def _fail(code, rc, out, err):
    raise OsConfigError(code, "backlight controller operation failed (rc=%d)" % rc,
                        detail=(err or out).strip()[-500:])


def set_brightness(value):
    level = validate_level(value)
    cfg, _ = load_config()
    new_cfg = dict(cfg, brightness=level)
    _persist(new_cfg)
    rc, out, err = _cli("set", str(level))
    if rc == 0:
        return {"result": "APPLIED", "config": new_cfg, "backlight": hardware_status()}
    if rc == 3:
        return {"result": "SAVED_APPLIES_ON_WAKE", "config": new_cfg,
                "backlight": hardware_status()}
    # Persisted anyway: the controller converged to safe-on (lit); the level
    # is retried at the next boot/wake. The caller sees the failure.
    _fail("BRIGHTNESS_APPLY_FAILED", rc, out, err)


def sleep():
    cfg, _ = load_config()
    if not cfg["touch_wake"]:
        raise OsConfigError("SLEEP_UNAVAILABLE",
                            "touch-wake is disabled; sleeping the backlight would "
                            "leave no independent way to wake it")
    # display.env must allow the on-demand touch-wake watcher.
    _persist(cfg)
    rc, out, err = _cli("sleep")
    if rc == 0:
        return {"result": "ASLEEP", "backlight": hardware_status()}
    if rc == 4:
        raise OsConfigError("SLEEP_UNAVAILABLE",
                            "no touch-wake watcher could be started; the backlight "
                            "was left on", detail=(err or out).strip()[-500:])
    _fail("SLEEP_FAILED", rc, out, err)


def wake():
    cfg, _ = load_config()
    rc, out, err = _cli("wake")
    if rc != 0:
        _fail("WAKE_FAILED", rc, out, err)
    # A level changed while asleep is applied now.
    hw = hardware_status()
    if hw.get("available") and hw.get("level") not in (None, cfg["brightness"]):
        rc, out, err = _cli("set", str(cfg["brightness"]))
        if rc != 0:
            _fail("BRIGHTNESS_APPLY_FAILED", rc, out, err)
        hw = hardware_status()
    return {"result": "AWAKE", "backlight": hw}
