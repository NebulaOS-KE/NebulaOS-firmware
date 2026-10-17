# nebulaos_osconfig.poweronlogo - the power-on logo: the picture the RTOS
# (zero.bin, in the running slot's rtos/rtos2 partition) draws before Linux
# starts. G58/G40 (human design, 2026-10-15):
#
#   - always a logo, NebulaOS's by default; the only choice is an image the
#     user uploaded to the boot logo folder (the same one becomes the Linux
#     boot screen, bootdisplay.py);
#   - "Set NebulaOS logo" when the original logo is still in the RTOS;
#   - "Restore Creality logo" - the original, saved on the printer before the
#     first change (or copied from the other slot's RTOS, which still has it);
#   - the running slot's RTOS, A or B: slot A too once it holds NebulaOS (G40).
#
# Only the logo slot inside zero.bin is written (rtos_logo.py: 480x272
# baseline JPEG, 4:2:0, at most 10899 bytes at 0x5e50c). Before a write the
# whole image outside that slot must hash to FRAME_SHA256 - the stock image
# with the slot zeroed, the same for every logo - so an RTOS that is not the
# known one is never touched. Every write is read back. The Moonraker
# component refuses all of this while printing.
import hashlib
import io
import os

from . import common, system
from .common import invalid, OsConfigError

import rtos_logo  # /usr/lib/nebulaos/python/rtos_logo.py (scripts/package copy)

RTOS_PARTS = {"A": ("mmcblk0p3", "rtos"), "B": ("mmcblk0p4", "rtos2")}
DEV_DIR = os.environ.get("NEBULAOS_DEV_DIR", "/dev")
SYS_BLOCK = os.environ.get("NEBULAOS_SYS_BLOCK", "/sys/class/block")
# Pinned from the stock image (rtos_logo.STOCK_ZERO_SHA256), 2026-10-15.
FRAME_SHA256 = "264c4c45b7fe34652619e0c9851fee0edc84b2d8b237201b825b76b12cc1f0cd"
ORIGINAL_LOGO_SHA256 = "71f4e50356c01586f294658df402f753c20f87790908a4e79c93bb9b10b22e9a"
OFFSET, SIZE = rtos_logo.LOGO_SLOT_OFFSET, rtos_logo.LOGO_SLOT_SIZE
IMAGE_SIZE = rtos_logo.STOCK_ZERO_SIZE
BACKUP = os.environ.get("NEBULAOS_RTOS_LOGO_BACKUP",
                        os.path.join(common.NEBULAOS_ROOT, "system", "rtos-logo", "original.jpg"))
# The panel shows the stored JPEG turned 180 degrees from how NebulaOS uses
# it (make-rtos-logo.py; upright on ke-dev in R3, 2026-10-15).
ROTATE = 180
QUALITIES = (90, 80, 70, 60, 50, 40, 30)
# Run 11 test (ke-dev, 2026-10-17): photos did not fit the 10899-byte slot
# even at quality 30, and Apply refused. Below that, the logo is softened -
# scaled down and back up (less detail, same size on screen) - with lower
# qualities, so every image fits. The boot screen keeps the full image.
SOFTEN = ((1.0, (20, 15, 10)), (0.75, (40, 30, 20, 10)), (0.5, (40, 30, 20, 10)),
          (0.35, (30, 20, 10)), (0.25, (20, 10, 5)))


def _dev(slot):
    part, name = RTOS_PARTS[slot]
    try:
        with open(os.path.join(SYS_BLOCK, part, "uevent")) as handle:
            if "PARTNAME=%s\n" % name not in handle.read():
                raise OsConfigError("PARTITION_MISMATCH", "%s is not the %s partition" % (part, name))
    except OSError:
        raise OsConfigError("PARTITION_MISMATCH", "cannot identify the %s partition" % name)
    return os.path.join(DEV_DIR, part)


def _read_image(slot):
    with open(_dev(slot), "rb") as handle:
        return handle.read(IMAGE_SIZE)


def _frame_ok(image):
    if len(image) != IMAGE_SIZE:
        return False
    frame = image[:OFFSET] + b"\0" * SIZE + image[OFFSET + SIZE:]
    return hashlib.sha256(frame).hexdigest() == FRAME_SHA256


def _nebulaos_slot():
    with open(rtos_logo.LOGO_ASSET, "rb") as handle:
        logo = handle.read()
    if rtos_logo.sha256(logo) != rtos_logo.NEBULAOS_LOGO_SHA256:
        raise OsConfigError("ASSET_DAMAGED", "the NebulaOS logo file in this image is damaged")
    return logo + b"\0" * (SIZE - len(logo))


def classify(image):
    """-> "original" | "nebulaos" | "custom" | "unknown" for an RTOS image."""
    if not _frame_ok(image):
        return "unknown"
    slot = image[OFFSET:OFFSET + SIZE]
    if hashlib.sha256(slot).hexdigest() == ORIGINAL_LOGO_SHA256:
        return "original"
    try:
        if slot == _nebulaos_slot():
            return "nebulaos"
    except OsConfigError:
        pass
    try:
        info = rtos_logo.parse_jpeg(slot)
        if (info.width, info.height) == (rtos_logo.LOGO_WIDTH, rtos_logo.LOGO_HEIGHT):
            return "custom"
    except rtos_logo.LogoError:
        pass
    return "unknown"


def _backup_ok():
    try:
        with open(BACKUP, "rb") as handle:
            return hashlib.sha256(handle.read(SIZE + 1)).hexdigest() == ORIGINAL_LOGO_SHA256
    except OSError:
        return False


def _saved_original():
    """The original logo slot (10899 bytes) if the printer has it, else None."""
    try:
        with open(BACKUP, "rb") as handle:
            data = handle.read(SIZE + 1)
        if hashlib.sha256(data).hexdigest() == ORIGINAL_LOGO_SHA256:
            return data
    except OSError:
        pass
    for slot in RTOS_PARTS:
        try:
            image = _read_image(slot)
        except (OSError, OsConfigError):
            continue
        if classify(image) == "original":
            return image[OFFSET:OFFSET + SIZE]
    return None


def status():
    slot = system.boot_slot()
    out = {"slot": slot, "logo": "unknown", "writable": False}
    if slot not in RTOS_PARTS:
        out["reason"] = "cannot tell which slot is running"
        return out
    try:
        out["logo"] = classify(_read_image(slot))
    except (OSError, OsConfigError) as exc:
        out["reason"] = "cannot read the %s partition: %s" % (RTOS_PARTS[slot][1], exc)
        return out
    out["writable"] = out["logo"] != "unknown"
    if not out["writable"]:
        out["reason"] = "the RTOS in this slot is not the known one; it is never changed"
    out["original_available"] = _saved_original() is not None
    return out


def check_writable():
    """Read-only: raises when the running slot's RTOS cannot take a logo -
    checked before anything changes (Apply changes both logos or neither)."""
    slot = system.boot_slot()
    if slot not in RTOS_PARTS:
        raise OsConfigError("SLOT_UNKNOWN", "cannot tell which slot is running; nothing was changed")
    if classify(_read_image(slot)) == "unknown":
        raise OsConfigError("RTOS_UNKNOWN", "the RTOS in slot %s is not the known one; "
                            "nothing was changed" % slot)
    return slot


def nebulaos_slot_bytes():
    return _nebulaos_slot()


def write_slot(slot_bytes):
    return _write(slot_bytes)


def _write(slot_bytes):
    """Write a new logo slot into the running slot's RTOS, read back."""
    if len(slot_bytes) != SIZE:
        raise OsConfigError("INTERNAL", "logo slot has the wrong size")
    slot = system.boot_slot()
    if slot not in RTOS_PARTS:
        raise OsConfigError("SLOT_UNKNOWN", "cannot tell which slot is running; nothing was changed")
    dev = _dev(slot)
    image = _read_image(slot)
    kind = classify(image)
    if kind == "unknown":
        raise OsConfigError("RTOS_UNKNOWN", "the RTOS in slot %s is not the known one; "
                            "nothing was changed" % slot)
    if image[OFFSET:OFFSET + SIZE] == slot_bytes:
        return {"result": "UNCHANGED", "slot": slot}
    if kind == "original" and not _backup_ok():
        # the original, kept before it is replaced the first time
        os.makedirs(os.path.dirname(BACKUP), exist_ok=True)
        common.atomic_write(BACKUP, image[OFFSET:OFFSET + SIZE])
    fd = os.open(dev, os.O_WRONLY | getattr(os, "O_SYNC", 0))
    try:
        os.lseek(fd, OFFSET, os.SEEK_SET)
        view = memoryview(slot_bytes)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
    finally:
        os.close(fd)
    after = _read_image(slot)
    if after[OFFSET:OFFSET + SIZE] != slot_bytes or not _frame_ok(after):
        raise OsConfigError("WRITE_FAILED", "the %s partition did not read back as written"
                            % RTOS_PARTS[slot][1])
    return {"result": "WRITTEN", "slot": slot, "logo": classify(after),
            "applies": "next power-on"}


def convert(path):
    """An uploaded PNG/BMP -> a logo slot: fit into 480x272 on black, turned
    180 degrees, baseline JPEG 4:2:0, the best quality that fits."""
    from . import bootdisplay
    bootdisplay.validate_image_file(path)
    Image, _, _ = bootdisplay._pil()
    with Image.open(path) as src:
        img = bootdisplay._fit(src, rtos_logo.LOGO_WIDTH, rtos_logo.LOGO_HEIGHT)
    img = img.rotate(-ROTATE, expand=True)
    steps = [(1.0, q) for q in QUALITIES] + [(f, q) for f, qs in SOFTEN for q in qs]
    for factor, quality in steps:
        candidate = img
        if factor < 1.0:
            w, h = img.size
            small = img.resize((max(1, int(w * factor)), max(1, int(h * factor))), Image.BILINEAR)
            candidate = small.resize((w, h), Image.BILINEAR)
        buf = io.BytesIO()
        candidate.save(buf, "JPEG", quality=quality, subsampling=2, optimize=False, progressive=False)
        data = buf.getvalue()
        if len(data) <= SIZE:
            info = rtos_logo.parse_jpeg(data)
            if ((info.width, info.height) != (rtos_logo.LOGO_WIDTH, rtos_logo.LOGO_HEIGHT)
                    or not info.baseline() or info.length != len(data)):
                raise OsConfigError("CONVERT_FAILED", "the converted logo is not a plain JPEG")
            label = quality if factor == 1.0 else "%d, softened %d%%" % (quality, int(factor * 100))
            return data + b"\0" * (SIZE - len(data)), label
    raise invalid("IMAGE_TOO_DETAILED", "this image does not fit the power-on logo's %d bytes "
                  "even at low quality; use a simpler image" % SIZE)


def set_custom(path):
    slot_bytes, quality = convert(path)
    out = _write(slot_bytes)
    out["quality"] = quality
    return out


def set_nebulaos():
    return _write(_nebulaos_slot())


def restore_original():
    original = _saved_original()
    if original is None:
        raise OsConfigError("NO_ORIGINAL", "this printer has no copy of the original logo")
    return _write(original)
