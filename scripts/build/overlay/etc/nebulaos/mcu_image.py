"""Offline inspection and preparation of a user-supplied MCU application
image for the KE's GD32F303 behind the Creality serial bootloader
(development run 4, 2026-10-11: "plug in USB, pick a compiled .bin, flash -
no Creality bootloader knowledge needed").

Two shapes of file are accepted, and nothing else:

  packed  A Creality-format application image: the 16-byte metadata header
          at offset 0x200 ("mcu0_NNN_000", CRC-16/XMODEM, length) passes
          creality_validator.validate_format(expect_type="mcu0"). This is
          what NebulaOS-klipper-mcu's build calls klipper-creality.bin, what
          the shipped candidate-001.bin is, and what stock Creality MCU
          images are.
  raw     A plain `make` output (out/klipper.bin) of a NebulaOS-klipper-mcu
          tree: its linker script reserves exactly those 16 bytes as a
          placeholder of 0xFF (src/stm32/gd32_creality_metadata.c). It is
          packed here exactly the way tools/creality_packer.py does it -
          overwrite the 16 bytes in place, never insert - with the metadata
          version build.sh uses ("900"), so the user never needs the packer.

Both must also carry a plausible Cortex-M vector table for the
post-bootloader application slot (initial SP inside the 64 KiB SRAM, Thumb
reset vector inside app flash from 0x08003000) - this is what rejects a
build for another board or flash offset, e.g. an upstream Klipper build
without the Creality reservation, whose bytes at 0x200 are code, not 0xFF.

What this cannot prove offline: that the firmware was built from the same
Klipper version as the host Klipper (a mismatch leaves Klipper unable to use
the MCU), or that it runs at all. The bootloader region itself is never at
risk - the Creality protocol has no address field (docs/mcu-flash-layout.md).

Pure functions over bytes; no I/O beyond the optional import of
creality_validator from CREALITY_FLASH_PATH (/opt/nebulaos/tools).
"""

import hashlib
import os
import struct
import sys

sys.path.insert(0, os.environ.get("CREALITY_FLASH_PATH", "/opt/nebulaos/tools"))
import creality_validator as validator  # noqa: E402

PACKED = "packed"
RAW = "raw"

METADATA_OFFSET = validator.METADATA_OFFSET          # 0x200
METADATA_SIZE = validator.METADATA_SIZE              # 0x10
CRC_FIELD_OFFSET = validator.CRC_FIELD_OFFSET        # 0x20C
LENGTH_FIELD_OFFSET = validator.LENGTH_FIELD_OFFSET  # 0x20E
MAX_IMAGE_SIZE = validator.MAX_IMAGE_SIZE            # 65535
MIN_IMAGE_SIZE = METADATA_OFFSET + METADATA_SIZE
RAW_PLACEHOLDER = b"\xff" * METADATA_SIZE
# NebulaOS-klipper-mcu scripts/build.sh METADATA_VERSION, also what the
# shipped (and hardware-proven) candidate-001.bin carries.
PACK_TYPE = "mcu0"
PACK_VERSION = "900"


class ImageError(Exception):
    """Not a flashable image for this printer. `reason` is for people."""

    def __init__(self, reason):
        super(ImageError, self).__init__(reason)
        self.reason = reason


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def pack(raw):
    """creality_packer.pack(raw, "mcu0", "900", "000"): overwrite the 16
    reserved bytes, never change the length."""
    image = bytearray(raw)
    header = ("%s_%s_000" % (PACK_TYPE, PACK_VERSION)).encode("ascii")
    image[METADATA_OFFSET:METADATA_OFFSET + len(header)] = header
    struct.pack_into("<H", image, LENGTH_FIELD_OFFSET, len(image))
    masked = bytearray(image)
    masked[CRC_FIELD_OFFSET:CRC_FIELD_OFFSET + 4] = b"\x00\x00\x00\x00"
    struct.pack_into("<H", image, CRC_FIELD_OFFSET, validator.crc16_xmodem(bytes(masked)))
    assert len(image) == len(raw)
    return bytes(image)


def _first(fails):
    return fails[0] if fails else ""


def classify(data):
    """Returns (kind, None) or (None, reason). Never raises for bad bytes."""
    size = len(data)
    if size == 0:
        return None, "the file is empty"
    if size < MIN_IMAGE_SIZE:
        return None, "too small for MCU firmware (%d bytes)" % size
    if size > MAX_IMAGE_SIZE:
        return None, ("too large (%d bytes); the printer's bootloader takes at "
                      "most %d bytes" % (size, MAX_IMAGE_SIZE))
    vector_fails = validator.validate_vector_table(data)
    window = data[METADATA_OFFSET:METADATA_OFFSET + METADATA_SIZE]
    if window == RAW_PLACEHOLDER:
        if vector_fails:
            return None, "not built for this printer's mainboard (%s)" % _first(vector_fails)
        return RAW, None
    if window[0:4] == PACK_TYPE.encode("ascii"):
        fails = validator.validate_format(data, expect_type=PACK_TYPE)
        if fails:
            return None, "damaged firmware image (%s)" % _first(fails)
        if vector_fails:
            return None, "not built for this printer's mainboard (%s)" % _first(vector_fails)
        return PACKED, None
    if window[4:5] == b"_" and window[8:9] == b"_":
        board = window[0:4].decode("ascii", "replace")
        return None, "Creality firmware for another board (%r, this one is %r)" % (
            board, PACK_TYPE)
    return None, ("not firmware for this printer's mainboard (no Creality header "
                  "and no NebulaOS placeholder at 0x200)")


def prepare(data):
    """(kind, image_to_flash). Raises ImageError. A raw build is packed; the
    packed result is validated again before it is returned."""
    kind, reason = classify(data)
    if kind is None:
        raise ImageError(reason)
    image = pack(data) if kind == RAW else bytes(data)
    fails = validator.validate_format(image, expect_type=PACK_TYPE)
    if fails:  # pragma: no cover - pack() is deterministic; belt and braces
        raise ImageError("internal packing error (%s)" % _first(fails))
    return kind, image
