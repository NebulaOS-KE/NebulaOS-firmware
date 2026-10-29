# nebulaos_osconfig.camera - Creality Nebula Camera controls (G121, Run 22,
# Tim's list 2026-10-28; investigation _scratch/run22/G121-nebulacam-investigation.md).
#
#   camera status                    stored settings, defaults, the camera
#   camera set --json '{...}'        change some settings (saved, then applied)
#   camera defaults                  every setting back to the camera's defaults
#   camera reset                     reboot the camera (XU selector 17)
#   camera version                   the camera's firmware string (XU selector 15)
#   camera apply [--device DEV]      re-apply everything (S50webcam, when the
#                                    camera appears - nothing persists in it)
#
# The camera (USB a108:2231, uvcvideo) keeps nothing over a reboot, power cycle
# or USB re-enumeration, so the settings live here (camera/camera.json, atomic)
# and are applied again each time it appears. Apply order (one control per
# ioctl): auto switches, manual values, the rest, then the IR mode.
#
# Exposure is one-way: the camera reads auto_exposure 0 (its own auto mode) but
# only accepts 1 (manual); the way back is a camera reset, which clears the
# stored manual flag BEFORE the reboot so the re-apply cannot switch it on.
#
# The vendor Extension Unit (GUID 41769ea2-04de-e347-8b2b-f4341aff003b, found in
# the USB descriptors, not assumed to be unit 6) is used ONLY through a frozen
# allow-list of (selector, query) pairs. Selector 13 (firmware update mode: the
# camera turns into a mass-storage device) is not in it and cannot be sent: no
# command-line or HTTP parameter carries a selector number.
#
# Flip stays in Mainsail (Tim). Gamma, hue, backlight compensation and focus
# (fixed lens) are never written.
import array
import errno
import fcntl
import os
import struct
import time

from . import common
from .common import invalid, OsConfigError

SCHEMA = 1
CAMERA_DIR = os.path.join(common.NEBULAOS_ROOT, "camera")
CONFIG = os.path.join(CAMERA_DIR, "camera.json")
FIRMWARE_CACHE = os.path.join(common.RUN_DIR, "camera-firmware.json")
SHED = os.path.join(common.RUN_DIR, "shed", "camera")
SYS_V4L = os.environ.get("NEBULAOS_SYS_V4L", "/sys/class/video4linux")
DEV_DIR = os.environ.get("NEBULAOS_DEV_DIR", "/dev")
USB_ID = ("a108", "2231")
RESET_WAIT = float(os.environ.get("NEBULAOS_CAMERA_RESET_WAIT", "15"))

# -- settings ---------------------------------------------------------------

IR_MODES = {"color": 0, "bw": 1, "auto": 2}            # XU16 byte 0
POWER_LINE = {"off": 0, "50": 1, "60": 2}              # power_line_frequency
RANGES = {"brightness": (50, 160), "contrast": (50, 160), "saturation": (50, 160),
          "sharpness": (50, 160), "wb_temperature": (300, 600), "zoom": (100, 200),
          "exposure_time": (1, 1000)}
def default_config():
    return {"schema": SCHEMA, "ir_mode": "auto", "power_line": "off",
            "brightness": 128, "contrast": 128, "saturation": 128, "sharpness": 128,
            "wb_auto": True, "wb_temperature": 417, "zoom": 100,
            "exposure_manual": False, "exposure_time": 156}


def _check_value(key, value):
    if key == "ir_mode":
        if value not in IR_MODES:
            raise invalid("INVALID_CAMERA_SETTING", "ir_mode is auto, color or bw")
        return value
    if key == "power_line":
        value = str(value)
        if value not in POWER_LINE:
            raise invalid("INVALID_CAMERA_SETTING", "power_line is off, 50 or 60")
        return value
    if key in ("wb_auto", "exposure_manual"):
        if not isinstance(value, bool):
            raise invalid("INVALID_CAMERA_SETTING", "%s is true or false" % key)
        return value
    if key in RANGES:
        lo, hi = RANGES[key]
        if isinstance(value, bool) or not isinstance(value, int) or not lo <= value <= hi:
            raise invalid("INVALID_CAMERA_SETTING", "%s is a whole number %d-%d" % (key, lo, hi))
        return value
    raise invalid("INVALID_CAMERA_SETTING", "unknown setting %r" % (key,))


def load_config():
    raw, error = common.read_json(CONFIG)
    cfg = default_config()
    if raw is None:
        return cfg, error
    try:
        if not common.schema_readable(raw, SCHEMA):
            raise invalid("CONFIG_INVALID", "unsupported schema")
        for key in default_config():
            if key != "schema" and key in raw:
                cfg[key] = _check_value(key, raw[key])
        return cfg, None
    except OsConfigError as exc:
        return default_config(), "%s: %s" % (exc.code, exc.message)


def _persist(cfg):
    common.atomic_write_json(CONFIG, cfg)


# -- the device ---------------------------------------------------------------

def _read(path):
    try:
        with open(path) as handle:
            return handle.read().strip()
    except OSError:
        return ""


def _usb_dir(node):
    """The USB device directory (idVendor/idProduct) above a video4linux node."""
    d = os.path.realpath(os.path.join(SYS_V4L, node, "device"))
    for _ in range(4):
        if os.path.exists(os.path.join(d, "idVendor")):
            return d
        d = os.path.dirname(d)
    return None


def find_camera():
    """{node, device, usb, identity} of the Nebula Camera's capture node, or None."""
    try:
        nodes = sorted(os.listdir(SYS_V4L))
    except OSError:
        return None
    for node in nodes:
        if not node.startswith("video") or _read(os.path.join(SYS_V4L, node, "index")) != "0":
            continue
        usb = _usb_dir(node)
        if usb is None:
            continue
        if (_read(os.path.join(usb, "idVendor")), _read(os.path.join(usb, "idProduct"))) != USB_ID:
            continue
        identity = "%s:%s" % (_read(os.path.join(usb, "busnum")), _read(os.path.join(usb, "devnum")))
        return {"node": node, "device": os.path.join(DEV_DIR, node), "usb": usb,
                "identity": identity}
    return None


# -- ioctls -------------------------------------------------------------------

def _mips():
    return os.uname().machine.startswith("mips")


def ioc_readwrite(type_char, nr, size, mips=None):
    """_IOWR as the kernel computes it: MIPS has 3 direction bits (read 2,
    write 4) and a 13-bit size; the generic layout 2 bits (read 2, write 1)."""
    mips = _mips() if mips is None else mips
    if mips:
        return (6 << 29) | (size << 16) | (ord(type_char) << 8) | nr
    return (3 << 30) | (size << 16) | (ord(type_char) << 8) | nr


V4L2_CTRL = struct.Struct("=Ii")                       # struct v4l2_control
CID = {"brightness": 0x00980900, "contrast": 0x00980901, "saturation": 0x00980902,
       "wb_auto": 0x0098090c, "power_line": 0x00980918, "wb_temperature": 0x0098091a,
       "sharpness": 0x0098091b, "exposure_auto": 0x009a0901,
       "exposure_time": 0x009a0902, "zoom": 0x009a090d}
EXPOSURE_MANUAL = 1                                     # V4L2_EXPOSURE_MANUAL


def _xu_struct():
    # struct uvc_xu_control_query: __u8 unit, selector, query; __u16 size; __u8 *data
    return struct.Struct("=BBBxHxxI" if struct.calcsize("P") == 4 else "=BBBxHxxQ")


UVC_SET_CUR, UVC_GET_CUR, UVC_GET_LEN = 0x01, 0x81, 0x85
# The ONLY extension-unit requests NebulaOS makes. Selector 13 (firmware
# update mode) and every other one is refused before any ioctl.
XU_ALLOWED = frozenset({(15, UVC_GET_CUR), (15, UVC_GET_LEN), (16, UVC_GET_CUR),
                        (16, UVC_GET_LEN), (16, UVC_SET_CUR), (17, UVC_SET_CUR)})
XU_GUID = "41769ea2-04de-e347-8b2b-f4341aff003b"
IR_PAYLOAD = 60


def _guid_forms():
    raw = bytes.fromhex(XU_GUID.replace("-", ""))
    mixed = raw[3::-1] + raw[5:3:-1] + raw[7:5:-1] + raw[8:]   # little-endian fields
    return raw, mixed


def xu_unit(usb_dir):
    """The extension unit ID from the raw USB descriptors (VC_EXTENSION_UNIT
    with the vendor GUID), or None."""
    try:
        with open(os.path.join(usb_dir, "descriptors"), "rb") as handle:
            blob = handle.read()
    except OSError:
        return None
    forms = _guid_forms()
    i = 0
    while i + 2 <= len(blob):
        length = blob[i]
        if length < 2:
            break
        if (length >= 21 and blob[i + 1] == 0x24 and blob[i + 2] == 0x06
                and blob[i + 4:i + 20] in forms):
            return blob[i + 3]
        i += length
    return None


class Device(object):
    """One open camera node. `ioctl` is replaceable (tests)."""

    def __init__(self, cam, ioctl=None):
        self.cam = cam
        self.ioctl = ioctl or fcntl.ioctl
        self.unit = xu_unit(cam["usb"])
        self.fd = os.open(cam["device"], os.O_RDWR)

    def close(self):
        os.close(self.fd)

    def set_ctrl(self, name, value):
        buf = bytearray(V4L2_CTRL.pack(CID[name], int(value)))
        self.ioctl(self.fd, ioc_readwrite("V", 28, V4L2_CTRL.size), buf)

    def xu(self, selector, query, length):
        if (selector, query) not in XU_ALLOWED:
            raise OsConfigError("XU_REFUSED", "extension unit selector %d query 0x%02x is "
                                "not allowed" % (selector, query))
        if self.unit is None:
            raise OsConfigError("CAMERA_XU_UNAVAILABLE", "the camera's extension unit "
                                "was not found (not a Nebula Camera firmware we know)")
        data = array.array("B", [0] * length)
        st = _xu_struct()
        q = bytearray(st.pack(self.unit, selector, query, length, data.buffer_info()[0]))
        self.ioctl(self.fd, ioc_readwrite("u", 0x21, st.size), q)
        return data

    def xu_payload(self, selector, query, data):
        """SET_CUR with the given bytes (allow-list checked like xu())."""
        if (selector, query) not in XU_ALLOWED:
            raise OsConfigError("XU_REFUSED", "extension unit selector %d query 0x%02x is "
                                "not allowed" % (selector, query))
        if self.unit is None:
            raise OsConfigError("CAMERA_XU_UNAVAILABLE", "the camera's extension unit "
                                "was not found")
        st = _xu_struct()
        q = bytearray(st.pack(self.unit, selector, query, len(data), data.buffer_info()[0]))
        self.ioctl(self.fd, ioc_readwrite("u", 0x21, st.size), q)


def _ir(dev, mode):
    length = dev.xu(16, UVC_GET_LEN, 2)
    if length[0] | (length[1] << 8) != IR_PAYLOAD:
        raise OsConfigError("CAMERA_IR_UNEXPECTED", "unexpected IR control size")
    data = dev.xu(16, UVC_GET_CUR, IR_PAYLOAD)
    data[0] = IR_MODES[mode]
    dev.xu_payload(16, UVC_SET_CUR, data)


def _apply(cfg, cam, ioctl=None):
    """Everything, in the camera's order. Stops at the first failure."""
    dev = Device(cam, ioctl)
    try:
        steps = [("wb_auto", 1 if cfg["wb_auto"] else 0)]
        if cfg["exposure_manual"]:
            steps.append(("exposure_auto", EXPOSURE_MANUAL))
        if not cfg["wb_auto"]:
            steps.append(("wb_temperature", cfg["wb_temperature"]))
        if cfg["exposure_manual"]:
            steps.append(("exposure_time", cfg["exposure_time"]))
        steps += [(k, cfg[k]) for k in ("brightness", "contrast", "saturation", "sharpness",
                                        "zoom")]
        steps.append(("power_line", POWER_LINE[cfg["power_line"]]))
        for name, value in steps:
            try:
                dev.set_ctrl(name, value)
            except OSError as exc:
                raise OsConfigError("CAMERA_APPLY_FAILED", "the camera refused %s=%s (%s)"
                                    % (name, value, errno.errorcode.get(exc.errno, exc)))
        try:
            _ir(dev, cfg["ir_mode"])
        except OSError as exc:
            raise OsConfigError("CAMERA_APPLY_FAILED", "the camera refused the IR mode (%s)"
                                % (errno.errorcode.get(exc.errno, exc),))
    finally:
        dev.close()


def _apply_now(cfg, ioctl=None):
    """APPLIED, or SAVED_APPLIES_LATER when the camera is absent or shed."""
    cam = find_camera()
    if cam is None or os.path.exists(SHED):
        return "SAVED_APPLIES_LATER"
    _apply(cfg, cam, ioctl)
    return "APPLIED"


# -- verbs ----------------------------------------------------------------------

def _firmware(cam, refresh=False, ioctl=None):
    cache, _ = common.read_json(FIRMWARE_CACHE)
    if not refresh and cache and cache.get("identity") == cam["identity"]:
        return cache.get("firmware")
    dev = Device(cam, ioctl)
    try:
        data = dev.xu(15, UVC_GET_CUR, IR_PAYLOAD)
    finally:
        dev.close()
    text = bytes(data).split(b"\0", 1)[0].decode("ascii", "replace").strip()
    common.atomic_write_json(FIRMWARE_CACHE, {"identity": cam["identity"], "firmware": text})
    return text


def status():
    cfg, error = load_config()
    cam = find_camera()
    out = {"config": cfg, "config_error": error, "defaults": default_config(),
           "ranges": {k: list(v) for k, v in RANGES.items()},
           "ir_modes": sorted(IR_MODES), "power_line_modes": sorted(POWER_LINE),
           "present": cam is not None, "device": cam["device"] if cam else None,
           "firmware": None}
    if cam:
        cache, _ = common.read_json(FIRMWARE_CACHE)    # never wakes the camera
        if cache and cache.get("identity") == cam["identity"]:
            out["firmware"] = cache.get("firmware")
    return out


def set_settings(changes, ioctl=None):
    if not isinstance(changes, dict) or not changes:
        raise invalid("INVALID_CAMERA_SETTING", "nothing to change")
    cfg, _ = load_config()
    new = dict(cfg)
    for key, value in changes.items():
        if key == "schema":
            raise invalid("INVALID_CAMERA_SETTING", "unknown setting 'schema'")
        new[key] = _check_value(key, value)
    if cfg["exposure_manual"] and not new["exposure_manual"]:
        raise invalid("EXPOSURE_ONE_WAY", "automatic exposure comes back only with "
                      "Reset camera")
    if "exposure_time" in changes and not new["exposure_manual"]:
        raise invalid("INVALID_CAMERA_SETTING", "exposure_time needs manual exposure")
    _persist(new)
    return {"result": _apply_now(new, ioctl), "config": new}


def defaults(ioctl=None, sleep=time.sleep, monotonic=time.monotonic):
    """Every setting back to the default (Tim 2026-10-29: "defaults resets
    all"), night mode and anti-flicker included. Manual exposure only goes
    back to automatic with a camera reboot, so then this is a reset - refused
    while the printer is busy, like Reset camera."""
    cfg, _ = load_config()
    new = default_config()
    if not cfg["exposure_manual"]:
        _persist(new)
        return {"result": _apply_now(new, ioctl), "config": new}
    common.refuse_if_busy("request")
    _persist(new)
    if find_camera() is None:
        return {"result": "SAVED_APPLIES_LATER", "config": new}
    return reset(ioctl, sleep, monotonic)


def version(ioctl=None):
    cam = find_camera()
    if cam is None:
        raise OsConfigError("CAMERA_ABSENT", "no Nebula Camera is connected")
    return {"result": "OK", "firmware": _firmware(cam, refresh=True, ioctl=ioctl)}


def apply(device=None, ioctl=None):
    cfg, _ = load_config()
    cam = find_camera()
    if cam is None or (device and cam["device"] != device):
        return {"result": "NO_CAMERA"}
    if os.path.exists(SHED):
        return {"result": "SAVED_APPLIES_LATER"}
    _apply(cfg, cam, ioctl)
    return {"result": "APPLIED", "device": cam["device"]}


def reset(ioctl=None, sleep=time.sleep, monotonic=time.monotonic):
    """Reboot the camera (back in ~4 s with all defaults), then apply the
    saved settings. Manual exposure ends here (the only way back to auto).
    Refused while the printer is busy: the camera shares the USB hub with
    the USB stick port."""
    common.refuse_if_busy("request")
    cam = find_camera()
    if cam is None:
        raise OsConfigError("CAMERA_ABSENT", "no Nebula Camera is connected")
    cfg, _ = load_config()
    if cfg["exposure_manual"]:
        cfg["exposure_manual"] = False
        _persist(cfg)
    dev = Device(cam, ioctl)
    try:
        dev.xu_payload(17, UVC_SET_CUR, array.array("B", [0] * IR_PAYLOAD))
    except OSError:
        pass                     # the camera may drop off the bus mid-request
    finally:
        try:
            dev.close()
        except OSError:
            pass
    deadline = monotonic() + RESET_WAIT
    sleep(2)
    while monotonic() < deadline:
        again = find_camera()
        if again is not None:
            try:
                _apply(cfg, again, ioctl)
                return {"result": "RESET", "config": cfg,
                        "reenumerated": again["identity"] != cam["identity"]}
            except (OsConfigError, OSError):
                pass             # not ready yet
        sleep(1)
    return {"result": "RESET_APPLIES_LATER", "config": cfg}
