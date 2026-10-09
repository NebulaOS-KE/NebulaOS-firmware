# nebulaos_osconfig.bootdisplay - userspace boot display: mode and image
# (GUI/service readiness mission, 2026-10-09).
#
#   boot/display.json        source of truth (schema 1): mode, image
#   boot/display.env         MODE= for S01splash (shell)
#   boot/custom.png|bmp      validated user image
#   boot/cache/splash.raw    framebuffer-native render (derived)
#   boot/cache/splash.meta   geometry + source identity of the render
#
# Pillow runs only here (a short-lived helper process), never at boot: the
# boot script blits splash.raw when splash.meta matches the live framebuffer.
import hashlib
import io
import json
import os
import struct

from . import common
from .common import invalid, OsConfigError

SCHEMA = 1
MODES = ("logo", "console", "blank")
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
CONFIG_ROOT = os.environ.get("NEBULAOS_CONFIG_ROOT", "/opt/printer_data/config")
FB_DEV = os.environ.get("NEBULAOS_FB_DEV", "/dev/fb0")
FB_SYSFS = os.environ.get("NEBULAOS_FB_SYSFS", "/sys/class/graphics/fb0")
GUPPY_CONFIG = os.environ.get("NEBULAOS_GUPPY_CONFIG", "/opt/guppyscreen/guppyconfig.json")
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
    if (raw.get("schema") != SCHEMA or raw.get("mode") not in MODES
            or raw.get("image") not in ("builtin", "custom")):
        return default_config(), "CONFIG_INVALID"
    return {"schema": SCHEMA, "mode": raw["mode"], "image": raw["image"]}, None


def _persist(cfg):
    common.atomic_write_json(CONFIG, cfg)
    common.atomic_write(ENV, common.render_env([("MODE", cfg["mode"])]))


def custom_path():
    for ext in ("png", "bmp"):
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
    """GuppyScreen's display_rotate (LVGL quarter turns); the boot image must
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
        raise invalid("IMAGE_TOO_LARGE", "image file is larger than %d bytes" % MAX_FILE_BYTES)
    with open(path, "rb") as handle:
        head = handle.read(8)
    if head.startswith(_PNG_SIG):
        fmt = "PNG"
    elif head[:2] == b"BM":
        fmt = "BMP"
    else:
        raise invalid("IMAGE_FORMAT", "only PNG and BMP images are supported")
    Image, _, _ = _pil()
    try:
        with Image.open(path) as img:
            if img.format != fmt:
                raise invalid("IMAGE_FORMAT", "file signature and content disagree")
            width, height = img.size
            if width > MAX_DIMENSION or height > MAX_DIMENSION or width < 1 or height < 1:
                raise invalid("IMAGE_TOO_LARGE", "image must be at most %dx%d"
                              % (MAX_DIMENSION, MAX_DIMENSION))
            img.load()
    except OsConfigError:
        raise
    except Exception as exc:  # Pillow raises many types, incl. DecompressionBombError
        raise invalid("IMAGE_INVALID", "image could not be decoded: %s" % exc)
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

def status():
    cfg, error = load_config()
    meta = _read_meta()
    return {"config": cfg, "config_error": error, "modes": list(MODES),
            "custom_image_present": custom_path() is not None,
            "cache": {"present": os.path.isfile(RAW), "kind": meta.get("KIND"),
                      "geometry": [meta.get("XRES"), meta.get("YRES"), meta.get("BPP")]
                      if meta else None},
            "formats": ["png", "bmp"], "max_file_bytes": MAX_FILE_BYTES,
            "max_dimension": MAX_DIMENSION}


def set_mode(mode):
    cfg, _ = load_config()
    cfg = dict(cfg, mode=validate_mode(mode))
    _persist(cfg)
    return {"result": "APPLIED", "config": cfg, "applies": "next boot"}


def resolve_config_path(relpath):
    if not isinstance(relpath, str) or not relpath or relpath.startswith("/") or "\x00" in relpath:
        raise invalid("INVALID_PATH", "path must be relative to the config root")
    root = os.path.realpath(CONFIG_ROOT)
    full = os.path.realpath(os.path.join(root, relpath))
    if os.path.commonpath([root, full]) != root:
        raise invalid("INVALID_PATH", "path escapes the config root")
    return full


def set_image(relpath):
    src = resolve_config_path(relpath)
    fmt, width, height = validate_image_file(src)
    with open(src, "rb") as handle:
        data = handle.read(MAX_FILE_BYTES + 1)
    ext = "png" if fmt == "PNG" else "bmp"
    common.atomic_write(os.path.join(BOOT_DIR, "custom." + ext), data)
    other = os.path.join(BOOT_DIR, "custom." + ("bmp" if ext == "png" else "png"))
    if os.path.exists(other):
        os.unlink(other)
    cfg, _ = load_config()
    cfg = dict(cfg, image="custom")
    _persist(cfg)
    rendered = _render_now()
    return {"result": "APPLIED", "config": cfg, "image": {"format": fmt,
            "width": width, "height": height}, "render": rendered}


def reset_image():
    for ext in ("png", "bmp"):
        path = os.path.join(BOOT_DIR, "custom." + ext)
        if os.path.exists(path):
            os.unlink(path)
    cfg, _ = load_config()
    cfg = dict(cfg, image="builtin")
    _persist(cfg)
    rendered = _render_now()
    return {"result": "APPLIED", "config": cfg, "render": rendered}
