# nebulaos_osconfig.bootdisplay - userspace boot display: mode and image
# (GUI/service readiness mission, 2026-10-09).
#
#   boot/display.json        source of truth (schema 1): mode, image
#   boot/display.env         MODE= for S01splash (shell)
#   printer_data/config/uploads/boot-logo/  images to pick from (G63
#                            2026-10-16, inside the config root; was
#                            printer_data/uploads, before that boot/uploads)
#   /usr/share/nebulaos/boot-logos/  the logos NebulaOS ships (G116, Run 21):
#                            listed with the uploads, read-only, never deleted
#   boot/custom.png|bmp|jpg  validated copy of the selected image
#   boot/cache/splash.raw    framebuffer-native render (derived)
#   boot/cache/splash.meta   geometry + source identity of the render
#
# Pillow runs only here (a short-lived helper process), never at boot: the
# boot script blits splash.raw when splash.meta matches the live framebuffer.
import hashlib
import re
import io
import json
import os
import struct

from . import common
from .common import invalid, OsConfigError

SCHEMA = 1
MODES = ("logo",)
# "console" (a text boot log on the LCD) was removed (D10, 2026-10-11): the
# framebuffer console deadlocked GuppyScreen's start on the RT kernel. A saved
# "console" is read as "logo"; it can no longer be selected. "blank" was
# retired by G58 (2026-10-15): there is always a boot logo.
RETIRED_MODES = {"console": "logo", "blank": "logo"}
RENDERER_VERSION = "1"
MAX_FILE_BYTES = 4 * 1024 * 1024
MAX_DIMENSION = 2048
MAX_PIXELS = MAX_DIMENSION * MAX_DIMENSION

BOOT_DIR = os.path.join(common.NEBULAOS_ROOT, "boot")
CONFIG = os.path.join(BOOT_DIR, "display.json")
ENV = os.path.join(BOOT_DIR, "display.env")
CACHE_DIR = os.path.join(BOOT_DIR, "cache")
RAW = os.path.join(CACHE_DIR, "splash.raw")
META = os.path.join(CACHE_DIR, "splash.meta")
# config/uploads/boot-logo (G63, inside Mainsail's config root): the only
# place an image may be picked from.
UPLOAD_DIR = os.environ.get("NEBULAOS_BOOT_UPLOAD_DIR",
                            "/opt/printer_data/config/uploads/boot-logo")
# G116 (Run 21): the shipped logos (an upload with the same name wins), and
# the boot screen a fresh install starts with - the same picture as the
# packaged power-on logo (scripts/package/make-rtos-logo.py).
SHIPPED_DIR = os.environ.get("NEBULAOS_BOOT_SHIPPED_DIR", "/usr/share/nebulaos/boot-logos")
FRESH_DEFAULT = "NebulaOS Ender-3 Blueprint Interface.jpg"
FB_DEV = os.environ.get("NEBULAOS_FB_DEV", "/dev/fb0")
FB_SYSFS = os.environ.get("NEBULAOS_FB_SYSFS", "/sys/class/graphics/fb0")
GUPPY_CONFIG = os.environ.get("NEBULAOS_GUPPY_CONFIG", "/opt/nebulascreen/nebulascreen.json")
SEED_MANIFEST = os.environ.get("NEBULAOS_SEED_MANIFEST", "/opt/nebulaos-seeds/seed-manifest.json")

FBIOGET_VSCREENINFO = 0x4600

_PNG_SIG = b"\x89PNG\r\n\x1a\n"


def default_config():
    return {"schema": SCHEMA, "mode": "logo", "image": "builtin"}


def validate_mode(value):
    if value not in MODES:
        raise invalid("INVALID_MODE", "mode must be one of %s" % ", ".join(MODES))
    return value


def load_config():
    raw, error = common.read_json(CONFIG)
    if raw is None:
        return default_config(), error
    if raw.get("mode") in RETIRED_MODES:
        raw = dict(raw, mode=RETIRED_MODES[raw["mode"]])
    if (not common.schema_readable(raw, SCHEMA) or raw.get("mode") not in MODES
            or raw.get("image") not in ("builtin", "custom")):
        return default_config(), "CONFIG_INVALID"
    cfg = {"schema": SCHEMA, "mode": raw["mode"], "image": raw["image"]}
    # G61 (2026-10-16): which upload the custom image came from, so the
    # screen's dropdown can show it as selected.
    if raw["image"] == "custom" and isinstance(raw.get("source"), str):
        cfg["source"] = raw["source"]
    return cfg, None


def _persist(cfg):
    common.atomic_write_json(CONFIG, cfg)
    common.atomic_write(ENV, common.render_env([("MODE", cfg["mode"])]))


def custom_path():
    for ext in ("png", "bmp", "jpg"):
        path = os.path.join(BOOT_DIR, "custom." + ext)
        if os.path.isfile(path):
            return path
    return None


# -- framebuffer geometry -------------------------------------------------------

def _sysfs(name):
    with open(os.path.join(FB_SYSFS, name)) as handle:
        return handle.read().strip()


def fb_geometry():
    """xres, yres, bpp, stride from sysfs; RGB layout from FBIOGET_VSCREENINFO
    (fb_var_screeninfo is all __u32, identical on every ABI)."""
    vx, vy = _sysfs("virtual_size").split(",")
    geo = {"bpp": int(_sysfs("bits_per_pixel")), "stride": int(_sysfs("stride"))}
    layout = None
    try:
        import fcntl
        fd = os.open(FB_DEV, os.O_RDONLY)
        try:
            buf = fcntl.ioctl(fd, FBIOGET_VSCREENINFO, bytes(160))
        finally:
            os.close(fd)
        v = struct.unpack("<40I", buf)
        geo["xres"], geo["yres"] = v[0], v[1]
        layout = {"r": (v[8], v[9]), "g": (v[11], v[12]), "b": (v[14], v[15])}
    except (OSError, ImportError):
        geo["xres"] = int(vx)
        geo["yres"] = int(vy)
    if layout is None:
        if geo["bpp"] == 16:
            layout = {"r": (11, 5), "g": (5, 6), "b": (0, 5)}
        else:
            layout = {"r": (16, 8), "g": (8, 8), "b": (0, 8)}
    geo["layout"] = layout
    return geo


def guppy_rotation():
    """NebulaScreen's display_rotate (LVGL quarter turns); the boot image must
    look the same way up as the UI that follows it."""
    try:
        with open(GUPPY_CONFIG) as handle:
            value = int(json.load(handle).get("display_rotate", 0))
        return value if value in (0, 1, 2, 3) else 0
    except (OSError, ValueError, AttributeError):
        return 0


def firmware_short_sha():
    try:
        with open(SEED_MANIFEST) as handle:
            return str(json.load(handle).get("firmware_head", ""))[:7]
    except (OSError, ValueError, AttributeError):
        return ""


# -- images ----------------------------------------------------------------------

def _pil():
    from PIL import Image, ImageDraw, ImageFont
    Image.MAX_IMAGE_PIXELS = MAX_PIXELS
    return Image, ImageDraw, ImageFont


def validate_image_file(path):
    """Bounded checks before any decode; returns (format, width, height)."""
    try:
        st = os.stat(path)
    except OSError:
        raise invalid("IMAGE_NOT_FOUND", "image file not found")
    if not os.path.isfile(path):
        raise invalid("IMAGE_INVALID", "not a regular file")
    if st.st_size > MAX_FILE_BYTES:
        raise invalid("IMAGE_TOO_LARGE", "the file is larger than %d MB"
                      % (MAX_FILE_BYTES // (1024 * 1024)))
    with open(path, "rb") as handle:
        head = handle.read(8)
    if head.startswith(_PNG_SIG):
        fmt = "PNG"
    elif head[:2] == b"BM":
        fmt = "BMP"
    elif head[:3] == b"\xff\xd8\xff":
        fmt = "JPEG"          # 2026-10-15: phone photos
    else:
        raise invalid("IMAGE_FORMAT", "this file is not a PNG, BMP or JPEG image")
    Image, _, _ = _pil()
    try:
        with Image.open(path) as img:
            if img.format != fmt:
                raise invalid("IMAGE_FORMAT", "this file is not a valid %s image" % fmt)
            width, height = img.size
            if width > MAX_DIMENSION or height > MAX_DIMENSION or width < 1 or height < 1:
                raise invalid("IMAGE_TOO_LARGE", "the image is larger than %d x %d pixels"
                              % (MAX_DIMENSION, MAX_DIMENSION))
            img.load()
    except OsConfigError:
        raise
    except Exception as exc:  # Pillow raises many types, incl. DecompressionBombError
        raise invalid("IMAGE_INVALID", "the image could not be read (damaged file?)",
                      detail=str(exc)[:200])
    return fmt, width, height


def builtin_image(width, height):
    Image, ImageDraw, ImageFont = _pil()
    img = Image.new("RGB", (width, height), (10, 12, 28))
    draw = ImageDraw.Draw(img)

    def font(size):
        try:
            return ImageFont.load_default(size=size)
        except TypeError:
            return ImageFont.load_default()

    def centred(text, y, size, colour):
        f = font(size)
        box = draw.textbbox((0, 0), text, font=f)
        draw.text(((width - (box[2] - box[0])) // 2, y), text, font=f, fill=colour)

    centred("NebulaOS", height // 2 - 46, 52, (220, 226, 255))
    centred("starting...", height // 2 + 22, 20, (150, 160, 200))
    sha = firmware_short_sha()
    if sha:
        centred(sha, height - 26, 14, (90, 100, 140))
    return img


def _fit(img, width, height):
    Image, _, _ = _pil()
    from PIL import ImageOps
    img = ImageOps.exif_transpose(img)    # a photo's own "rotate" flag
    img = img.convert("RGB")
    scale = min(float(width) / img.width, float(height) / img.height)
    size = (max(1, int(img.width * scale)), max(1, int(img.height * scale)))
    img = img.resize(size, Image.LANCZOS)
    canvas = Image.new("RGB", (width, height), (0, 0, 0))
    canvas.paste(img, ((width - size[0]) // 2, (height - size[1]) // 2))
    return canvas


def to_framebuffer(img, geo):
    """Packs an RGB image of exactly xres x yres into the framebuffer's pixel
    format, honouring stride."""
    width, height, bpp, stride = geo["xres"], geo["yres"], geo["bpp"], geo["stride"]
    layout = geo["layout"]
    if img.size != (width, height):
        raise ValueError("image size does not match the framebuffer")
    if bpp not in (16, 24, 32):
        raise OsConfigError("FB_UNSUPPORTED", "unsupported framebuffer depth %d" % bpp)
    bypp = bpp // 8
    if stride < width * bypp:
        raise OsConfigError("FB_UNSUPPORTED", "framebuffer stride too small")
    fast = {((16, 8), (8, 8), (0, 8)): "BGRX", ((0, 8), (8, 8), (16, 8)): "RGBX"}
    key = (layout["r"], layout["g"], layout["b"])
    pad = b"\x00" * (stride - width * bypp)
    if bpp == 32 and key in fast:
        row_bytes = img.tobytes("raw", fast[key])
        line = width * 4
        return b"".join(row_bytes[y * line:(y + 1) * line] + pad for y in range(height))
    out = bytearray()
    pixels = img.load()
    (ro, rl), (go, gl), (bo, bl) = layout["r"], layout["g"], layout["b"]
    for y in range(height):
        for x in range(width):
            r, g, b = pixels[x, y]
            value = ((r >> (8 - rl)) << ro) | ((g >> (8 - gl)) << go) | ((b >> (8 - bl)) << bo)
            out += value.to_bytes(bypp, "little")
        out += pad
    return bytes(out)


def _source_identity(cfg):
    path = custom_path() if cfg["image"] == "custom" else None
    if path:
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            digest.update(handle.read())
        return "custom", path, digest.hexdigest()
    return "builtin", None, "builtin-%s-%s" % (RENDERER_VERSION, firmware_short_sha())


def _read_meta():
    meta = {}
    try:
        with open(META) as handle:
            for line in handle:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    meta[k] = v.strip('"')
    except OSError:
        pass
    return meta


def render(if_stale=False, geo=None):
    cfg, _ = load_config()
    geo = geo or fb_geometry()
    rotate = guppy_rotation()
    kind, path, identity = _source_identity(cfg)
    expected = {"XRES": str(geo["xres"]), "YRES": str(geo["yres"]),
                "BPP": str(geo["bpp"]), "STRIDE": str(geo["stride"]),
                "SOURCE": identity, "ROTATE": str(rotate),
                "RENDERER": RENDERER_VERSION}
    if if_stale and os.path.isfile(RAW):
        meta = _read_meta()
        if all(meta.get(k) == v for k, v in expected.items()):
            return {"result": "UP_TO_DATE", "kind": kind}
    Image, _, _ = _pil()
    # The user sees the panel rotated by GuppyScreen's quarter turns.
    view_w, view_h = ((geo["xres"], geo["yres"]) if rotate in (0, 2)
                      else (geo["yres"], geo["xres"]))
    if path:
        with Image.open(path) as src:
            img = _fit(src, view_w, view_h)
    else:
        img = builtin_image(view_w, view_h)
    if rotate:
        img = img.rotate(-90 * rotate, expand=True)
    data = to_framebuffer(img, geo)
    common.atomic_write(RAW, data)
    expected["SIZE"] = str(len(data))
    expected["KIND"] = kind
    common.atomic_write(META, common.render_env(sorted(expected.items())))
    return {"result": "RENDERED", "kind": kind, "bytes": len(data)}


def _render_now():
    """Render right after a change; the background boot job retries later if
    the framebuffer is not usable now (the persisted choice already stands)."""
    try:
        return render()
    except OsConfigError as exc:
        return {"result": "RENDER_DEFERRED", "reason": exc.code}
    except (OSError, ValueError) as exc:
        return {"result": "RENDER_DEFERRED", "reason": str(exc)[:200]}


# -- public verbs ---------------------------------------------------------------

def _power_on(action, *args):
    """G58: the same choice for the RTOS power-on logo. Its outcome is
    reported beside the boot screen's, never instead of it."""
    from . import poweronlogo
    try:
        return action(*args) if action else poweronlogo.status()
    except OsConfigError as exc:
        return {"result": "FAILED", "error": exc.code, "message": str(exc)}
    except Exception as exc:   # an unexpected failure must not undo the splash change
        return {"result": "FAILED", "error": "INTERNAL", "message": str(exc)[:200]}


def status():
    cfg, error = load_config()
    meta = _read_meta()
    return {"config": cfg, "config_error": error, "modes": list(MODES),
            "power_on": _power_on(None),
            "custom_image_present": custom_path() is not None,
            "cache": {"present": os.path.isfile(RAW), "kind": meta.get("KIND"),
                      "geometry": [meta.get("XRES"), meta.get("YRES"), meta.get("BPP")]
                      if meta else None},
            "formats": ["png", "bmp", "jpeg"], "max_file_bytes": MAX_FILE_BYTES,
            "max_dimension": MAX_DIMENSION}


def set_mode(mode):
    cfg, _ = load_config()
    cfg = dict(cfg, mode=validate_mode(mode))
    _persist(cfg)
    return {"result": "APPLIED", "config": cfg, "applies": "next boot"}


IMAGE_EXTS = (".png", ".bmp", ".jpg", ".jpeg")
USB_DIR = os.environ.get("NEBULAOS_MCU_USB_DIR", "/opt/printer_data/gcodes/USB")
USB_DEPTH = 2
PREVIEW_DIR = os.path.join(common.RUN_DIR, "boot-preview")
PREVIEW_SIZE = (240, 136)


def _plain_name(filename):
    """G61: any ordinary file name - spaces, commas, capitals - checked for
    safety, not for style: no folders, no hidden files, no control chars."""
    return (isinstance(filename, str) and 0 < len(filename) <= 200
            and "/" not in filename and "\\" not in filename
            and not filename.startswith(".")
            and not any(ord(c) < 32 or ord(c) == 127 for c in filename))


def resolve_upload(filename):
    """A plain file name inside the boot upload root - no directories, no
    traversal, no symlink out of it."""
    if not _plain_name(filename):
        raise invalid("INVALID_FILENAME",
                      "give the name of an image in the boot logo folder (no folders)")
    root = os.path.realpath(UPLOAD_DIR)
    full = os.path.realpath(os.path.join(root, filename))
    if os.path.dirname(full) != root:
        raise invalid("INVALID_FILENAME", "file is not inside the boot upload root")
    return full


def _shipped(filename):
    """The shipped logo of that name, or None."""
    if not _plain_name(filename):
        return None
    root = os.path.realpath(SHIPPED_DIR)
    full = os.path.realpath(os.path.join(root, filename))
    if os.path.dirname(full) != root or not os.path.isfile(full):
        return None
    return full


def resolve_image(filename):
    """An upload, else a shipped logo of that name (G116)."""
    full = resolve_upload(filename)
    if not os.path.exists(full):
        return _shipped(filename) or full
    return full


# Run 10 test (2026-10-17): Apply changes the boot screen AND the power-on
# logo, or neither. The power-on logo is converted and the RTOS checked first;
# if writing it still fails, the boot screen goes back to what it was.
def _boot_snapshot():
    snap = {}
    for path in [CONFIG, ENV] + [os.path.join(BOOT_DIR, "custom." + e) for e in ("png", "bmp", "jpg")]:
        try:
            with open(path, "rb") as handle:
                snap[path] = handle.read()
        except OSError:
            snap[path] = None
    return snap


def _boot_restore(snap):
    for path, data in snap.items():
        if data is None:
            try:
                os.unlink(path)
            except OSError:
                pass
        else:
            common.atomic_write(path, data)


def _apply_both(change_boot, slot_bytes):
    from . import poweronlogo
    poweronlogo.check_writable()
    before = _boot_snapshot()
    cfg = change_boot()
    try:
        power = poweronlogo.write_slot(slot_bytes)
    except Exception as exc:
        _boot_restore(before)
        _render_now()
        code = exc.code if isinstance(exc, OsConfigError) else "POWER_ON_FAILED"
        raise OsConfigError(code, "the power-on logo could not be written (%s); nothing was "
                            "changed" % str(exc)[:160])
    return cfg, power


# G91 step 6: the power-on logo writes (RTOS partition) and the boot-screen
# change around them hold the maintenance lock and are refused while busy.
@common.maintenance("boot-logo")
def set_image(filename):
    src = resolve_image(filename)
    fmt, width, height = validate_image_file(src)
    with open(src, "rb") as handle:
        data = handle.read(MAX_FILE_BYTES + 1)
    ext = {"PNG": "png", "BMP": "bmp", "JPEG": "jpg"}[fmt]
    from . import poweronlogo
    slot_bytes, quality = poweronlogo.convert(src)          # before anything changes

    def change_boot():
        common.atomic_write(os.path.join(BOOT_DIR, "custom." + ext), data)
        for other_ext in ("png", "bmp", "jpg"):
            other = os.path.join(BOOT_DIR, "custom." + other_ext)
            if other_ext != ext and os.path.exists(other):
                os.unlink(other)
        cfg, _ = load_config()
        cfg = dict(cfg, mode="logo", image="custom", source=filename)
        _persist(cfg)
        return cfg
    cfg, power = _apply_both(change_boot, slot_bytes)
    power["quality"] = quality
    return {"result": "APPLIED", "config": cfg, "image": {"format": fmt,
            "width": width, "height": height}, "render": _render_now(),
            "power_on": power}


@common.maintenance("boot-logo")
def reset_image():
    from . import poweronlogo
    slot_bytes = poweronlogo.nebulaos_slot_bytes()

    def change_boot():
        for ext in ("png", "bmp", "jpg"):
            path = os.path.join(BOOT_DIR, "custom." + ext)
            if os.path.exists(path):
                os.unlink(path)
        cfg, _ = load_config()
        cfg = dict(cfg, mode="logo", image="builtin")
        cfg.pop("source", None)
        _persist(cfg)
        return cfg
    cfg, power = _apply_both(change_boot, slot_bytes)
    return {"result": "APPLIED", "config": cfg, "render": _render_now(), "power_on": power}


@common.maintenance("boot-logo")
def restore_original_logo():
    """G58: the original power-on logo back into the running slot's RTOS. The
    Linux boot screen is not changed."""
    from . import poweronlogo
    return poweronlogo.restore_original()


# -- G61: the boot logo page (2026-10-16) --------------------------------------
#
# One list for the screen's dropdown (NebulaOS + every image in the boot logo
# folder), the images on a USB stick for "Add from USB" (copied in, then
# selected), delete, and a small preview of exactly what will be shown.

def _images_in(root):
    try:
        names = sorted(os.listdir(root), key=str.lower)
    except OSError:
        return []
    out = []
    for name in names:
        full = os.path.join(root, name)
        if (_plain_name(name) and name.lower().endswith(IMAGE_EXTS)
                and os.path.isfile(full) and not os.path.islink(full)):
            out.append({"name": name, "size": os.path.getsize(full)})
    return out


def _usb_images():
    found = []
    try:
        devs = sorted(os.listdir(USB_DIR))
    except OSError:
        return found
    for dev in devs:
        base = os.path.join(USB_DIR, dev)
        if dev.startswith(".") or not os.path.isdir(base) or os.path.islink(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            depth = os.path.relpath(dirpath, base).count(os.sep)
            dirnames[:] = [d for d in sorted(dirnames) if not d.startswith(".")] if depth < USB_DEPTH else []
            for name in sorted(filenames, key=str.lower):
                full = os.path.join(dirpath, name)
                if (_plain_name(name) and name.lower().endswith(IMAGE_EXTS)
                        and os.path.isfile(full) and not os.path.islink(full)):
                    rel = os.path.relpath(full, base)
                    found.append({"id": "usb/%s/%s" % (dev, rel), "name": name,
                                  "size": os.path.getsize(full)})
            if len(found) >= 200:
                return found
    return found


def list_images():
    cfg, _ = load_config()
    selected = cfg.get("source") if cfg["image"] == "custom" else None
    uploads = _images_in(UPLOAD_DIR)
    names = set(i["name"] for i in uploads)
    # G116: the shipped logos first ("shipped": no Delete), then the uploads
    images = [dict(i, shipped=True) for i in _images_in(SHIPPED_DIR)
              if i["name"] not in names] + uploads
    if selected and selected not in [i["name"] for i in images]:
        selected = None            # the upload was deleted; the copy still shows
    return {"images": images, "selected": selected or "", "custom_active": cfg["image"] == "custom",
            "usb": _usb_images(), "usb_present": os.path.isdir(USB_DIR) and bool(
                [d for d in os.listdir(USB_DIR) if not d.startswith(".")]) if os.path.isdir(USB_DIR) else False}


def _resolve_usb(file_id):
    if not isinstance(file_id, str) or not file_id.startswith("usb/"):
        raise invalid("INVALID_FILE", "not a USB image id")
    parts = file_id.split("/")
    if len(parts) < 3 or any(p in ("", ".", "..") for p in parts):
        raise invalid("INVALID_FILE", "not a USB image id")
    root = os.path.realpath(os.path.join(USB_DIR, parts[1]))
    full = os.path.realpath(os.path.join(USB_DIR, *parts[1:]))
    if not full.startswith(root + os.sep) or not os.path.isfile(full):
        raise invalid("FILE_GONE", "the file is no longer on the USB stick")
    return full, parts[-1]


def import_usb(file_id):
    """Copy an image from the USB stick into the boot logo folder (validated
    first). Returns its name there - the screen selects it."""
    src, name = _resolve_usb(file_id)
    validate_image_file(src)
    if not _plain_name(name) or not name.lower().endswith(IMAGE_EXTS):
        raise invalid("INVALID_FILENAME", "this file name cannot be used")
    os.makedirs(UPLOAD_DIR, exist_ok=True)
    stem, ext = os.path.splitext(name)
    target, n = name, 1
    while os.path.exists(os.path.join(UPLOAD_DIR, target)):
        with open(src, "rb") as a, open(os.path.join(UPLOAD_DIR, target), "rb") as b:
            if a.read(MAX_FILE_BYTES + 1) == b.read(MAX_FILE_BYTES + 1):
                return {"result": "IMPORTED", "name": target, "existing": True}
        n += 1
        target = "%s (%d)%s" % (stem, n, ext)
    with open(src, "rb") as handle:
        data = handle.read(MAX_FILE_BYTES + 1)
    common.atomic_write(os.path.join(UPLOAD_DIR, target), data)
    return {"result": "IMPORTED", "name": target, "existing": False}


def delete_image(filename):
    path = resolve_upload(filename)
    if not os.path.isfile(path):
        if _shipped(filename):
            raise invalid("SHIPPED_IMAGE", "the logos that come with NebulaOS cannot be deleted")
        raise invalid("FILE_GONE", "the image is no longer there")
    os.unlink(path)
    return {"result": "DELETED", "name": filename}


def preview(filename):
    """A small PNG of exactly what the boot screen will show (fitted on
    black), for the screen. "" or "NebulaOS" = the built-in logo."""
    Image, _, _ = _pil()
    if filename in ("", None, "builtin"):
        img = builtin_image(480, 272)
        key = "builtin-" + firmware_short_sha()
    else:
        path = resolve_image(filename)
        validate_image_file(path)
        st = os.stat(path)
        key = hashlib.sha256(("%s|%d|%d" % (filename, st.st_size, int(st.st_mtime))).encode()).hexdigest()[:16]
        with Image.open(path) as src:
            img = _fit(src, 480, 272)
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    out = os.path.join(PREVIEW_DIR, "preview-%s.png" % key)
    if not os.path.exists(out):
        for old in os.listdir(PREVIEW_DIR):
            try:
                os.unlink(os.path.join(PREVIEW_DIR, old))
            except OSError:
                pass
        img.resize(PREVIEW_SIZE, Image.LANCZOS).save(out + ".tmp", "PNG")
        os.replace(out + ".tmp", out)
    return {"result": "OK", "path": out, "width": PREVIEW_SIZE[0], "height": PREVIEW_SIZE[1]}


def fresh_install_default():
    """G116: a fresh install (S04nebulaos-factory-seed's first seed) starts with
    the shipped Blueprint logo as its boot screen. Only the boot screen: the
    packaged power-on logo is already that picture. Never changes a printer
    that has a boot display setting or a custom image."""
    if os.path.exists(CONFIG) or custom_path() is not None:
        return {"result": "UNCHANGED"}
    src = _shipped(FRESH_DEFAULT)
    if src is None:
        return {"result": "UNCHANGED", "reason": "no shipped default logo"}
    validate_image_file(src)
    with open(src, "rb") as handle:
        data = handle.read(MAX_FILE_BYTES + 1)
    os.makedirs(BOOT_DIR, exist_ok=True)
    common.atomic_write(os.path.join(BOOT_DIR, "custom.jpg"), data)
    cfg = {"schema": SCHEMA, "mode": "logo", "image": "custom", "source": FRESH_DEFAULT}
    _persist(cfg)
    return {"result": "APPLIED", "config": cfg}
