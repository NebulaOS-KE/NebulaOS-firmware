#!/usr/bin/env python3
"""Put the NebulaOS logo into a copy of the stock RTOS image (zero.bin).

WHAT zero.bin IS, AND WHY ONLY ONE SLOT IS TOUCHED

zero.bin is the FreeRTOS image SPL loads from the `rtos`/`rtos2` partition
before Linux. It draws the first picture on the LCD (and very likely lights the
panel). SPL picks `rtos2` (p4) when the OTA marker is `ota:kernel2` and `rtos`
(p3) otherwise - read from the SPL's own code, see
_analysis/gui-service-audit/14-early-boot-logo-research.md. So a NebulaOS logo
in the image written to `rtos2` is seen only when NebulaOS boots; Creality's
slot keeps Creality's logo.

The image carries seven embedded JPEGs. The only 480x272 one, the logo the KE
shows, is

    offset 0x5e50c, 10899 bytes, baseline (SOF0), 4:2:0, 480x272
    RTOS symbol: creality_portrait_rot270_480x272

This module replaces exactly those 10899 bytes: zero-fill, then the new JPEG at
the start of the slot. The code, the other six JPEGs and the file size are not
changed. zero.bin has no checksum or signature to fix up.

WHAT IS CHECKED, EVERY TIME

  * the input is the pinned stock image (size and sha256), unless a caller
    explicitly asks for an unpinned experiment;
  * the slot is found by walking real JPEG segments (marker lengths, entropy
    data, EOI), not by searching for FFD8/FFD9 byte pairs, and must start at
    the pinned offset, be exactly the pinned length and be the only 480x272
    top-level JPEG;
  * the new logo is one complete baseline JPEG, 480x272, 3 components with the
    same sampling as the stock logo, nothing after its EOI, and fits the slot;
  * after patching: the file size is unchanged, EVERY byte outside the slot is
    identical to stock, the slot holds the logo followed only by zeros, and the
    image still parses with the same seven JPEGs.

The technique follows pellcorp's creality-firmware zero/patch-zero-bin.py; this
is NebulaOS's own implementation with the byte-identity check added.

USAGE

    rtos_logo.py patch --stock zero.bin --logo nebulaos-rtos-logo.jpg --out zero2.bin
    rtos_logo.py verify --stock zero.bin --patched zero2.bin --logo nebulaos-rtos-logo.jpg
    rtos_logo.py list zero.bin

Inputs are never written. `patch` refuses an output path that exists.
"""

import argparse
import hashlib
import os
import sys

# --- pins -------------------------------------------------------------------
# Kept in step with manifests/dependencies.conf (RTOS_STOCK_ZERO_*,
# RTOS_NEBULAOS_*); tests/release-packaging-tests.sh fails when they differ.
STOCK_ZERO_SIZE = 432824
STOCK_ZERO_SHA256 = "2a6b8fcdc7acb73eb7c0fe660906c94989b9f1fb2a3436f3c897766e18dfc340"
LOGO_SLOT_OFFSET = 0x5E50C
LOGO_SLOT_SIZE = 10899
LOGO_WIDTH = 480
LOGO_HEIGHT = 272
# The committed NebulaOS logo (scripts/package/assets/nebulaos-rtos-logo.jpg)
# and the stock image with that logo in the slot.
NEBULAOS_LOGO_SHA256 = "099a8433ac8e50194f55429169605107e05dc501bceb30c94629930fd854a161"
NEBULAOS_ZERO_SHA256 = "242b8e8a559c740f21c1e5e69d8ffdaf5f330ced84764adcfaca1fd45b6732d4"

RTOS_TAG_OFFSET = 8
RTOS_TAG = b"RTOS"

HERE = os.path.dirname(os.path.abspath(__file__))
LOGO_ASSET = os.path.join(HERE, "assets", "nebulaos-rtos-logo.jpg")


class LogoError(Exception):
    """An input or a result this module will not accept."""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# --- JPEG walking -----------------------------------------------------------

# Markers without a length field.
_STANDALONE = {0x01} | set(range(0xD0, 0xD8))
# Start-of-frame markers (C4 = DHT, C8 = JPG extension and CC = DAC are not).
_SOF = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}


class JpegInfo:
    __slots__ = ("offset", "length", "sof", "width", "height", "components")

    def __init__(self, offset, length, sof, width, height, components):
        self.offset = offset
        self.length = length
        self.sof = sof
        self.width = width
        self.height = height
        self.components = components      # ((id, h, v), ...)

    def baseline(self):
        return self.sof == 0xC0

    def describe(self):
        return ("offset=0x%x length=%d %dx%d sof=0x%02x sampling=%s"
                % (self.offset, self.length, self.width, self.height, self.sof,
                   ",".join("%dx%d" % (h, v) for _, h, v in self.components)))


def parse_jpeg(data, start=0):
    """Walk one JPEG starting at `start`. -> JpegInfo, or raise LogoError.

    Segments are skipped by their own length fields, so an EXIF thumbnail
    inside APP1 is never mistaken for the end of the image. After each SOS the
    entropy-coded data is scanned: FF00 is a stuffed byte, FFD0-FFD7 are
    restart markers, any other FFxx ends the scan.
    """
    n = len(data)
    if data[start:start + 2] != b"\xff\xd8":
        raise LogoError("no SOI at 0x%x" % start)
    pos = start + 2
    sof = width = height = None
    components = ()
    while True:
        if pos >= n:
            raise LogoError("JPEG at 0x%x runs past the end of the data" % start)
        if data[pos] != 0xFF:
            raise LogoError("JPEG at 0x%x: expected a marker at 0x%x" % (start, pos))
        while pos < n and data[pos] == 0xFF:      # fill bytes
            pos += 1
        if pos >= n:
            raise LogoError("JPEG at 0x%x ends inside a marker" % start)
        marker = data[pos]
        pos += 1
        if marker == 0xD9:                        # EOI
            break
        if marker == 0xD8:
            raise LogoError("JPEG at 0x%x: nested SOI at 0x%x" % (start, pos - 2))
        if marker in _STANDALONE:
            continue
        if pos + 2 > n:
            raise LogoError("JPEG at 0x%x: truncated segment length" % start)
        seglen = (data[pos] << 8) | data[pos + 1]
        if seglen < 2 or pos + seglen > n:
            raise LogoError("JPEG at 0x%x: bad segment length %d at 0x%x" % (start, seglen, pos))
        body = data[pos + 2:pos + seglen]
        if marker in _SOF:
            if sof is not None:
                raise LogoError("JPEG at 0x%x has more than one frame header" % start)
            if len(body) < 6:
                raise LogoError("JPEG at 0x%x: short frame header" % start)
            sof = marker
            height = (body[1] << 8) | body[2]
            width = (body[3] << 8) | body[4]
            count = body[5]
            if len(body) < 6 + 3 * count:
                raise LogoError("JPEG at 0x%x: short component table" % start)
            components = tuple((body[6 + 3 * i], body[7 + 3 * i] >> 4, body[7 + 3 * i] & 0x0F)
                               for i in range(count))
        pos += seglen
        if marker == 0xDA:                        # SOS: entropy data follows
            while True:
                if pos + 1 >= n:
                    raise LogoError("JPEG at 0x%x: scan runs past the end of the data" % start)
                if data[pos] == 0xFF:
                    nxt = data[pos + 1]
                    if nxt == 0x00 or 0xD0 <= nxt <= 0xD7:
                        pos += 2
                        continue
                    break
                pos += 1
    if sof is None:
        raise LogoError("JPEG at 0x%x has no frame header" % start)
    return JpegInfo(start, pos - start, sof, width, height, components)


def find_jpegs(data):
    """Every top-level JPEG in `data`, in order. A candidate SOI that does not
    parse is skipped; a JPEG found inside another one's bytes is not top-level."""
    found = []
    pos = 0
    while True:
        pos = data.find(b"\xff\xd8\xff", pos)
        if pos < 0:
            return found
        try:
            info = parse_jpeg(data, pos)
        except LogoError:
            pos += 1
            continue
        found.append(info)
        pos += info.length


# --- the slot and the logo ---------------------------------------------------

def check_stock(stock, allow_unpinned=False):
    """The input image: pinned bytes, RTOS tag, and the logo slot where it should be."""
    if len(stock) != STOCK_ZERO_SIZE:
        raise LogoError("stock zero.bin is %d bytes, expected %d" % (len(stock), STOCK_ZERO_SIZE))
    got = sha256(stock)
    if got != STOCK_ZERO_SHA256 and not allow_unpinned:
        raise LogoError("stock zero.bin has sha256 %s, expected the pinned %s"
                        % (got, STOCK_ZERO_SHA256))
    if stock[RTOS_TAG_OFFSET:RTOS_TAG_OFFSET + 4] != RTOS_TAG:
        raise LogoError("stock zero.bin has no RTOS tag at byte %d" % RTOS_TAG_OFFSET)
    return locate_slot(stock)


def locate_slot(image):
    """-> JpegInfo of the logo slot. Requires it at the pinned offset and length,
    480x272 and baseline, and the only 480x272 top-level JPEG in the image."""
    try:
        slot = parse_jpeg(image, LOGO_SLOT_OFFSET)
    except LogoError as exc:
        raise LogoError("no JPEG at the logo slot 0x%x: %s" % (LOGO_SLOT_OFFSET, exc))
    if (slot.width, slot.height) != (LOGO_WIDTH, LOGO_HEIGHT):
        raise LogoError("the slot JPEG is %dx%d, expected %dx%d"
                        % (slot.width, slot.height, LOGO_WIDTH, LOGO_HEIGHT))
    if not slot.baseline():
        raise LogoError("the slot JPEG is not baseline (SOF 0x%02x)" % slot.sof)
    sized = [j for j in find_jpegs(image) if (j.width, j.height) == (LOGO_WIDTH, LOGO_HEIGHT)]
    if [j.offset for j in sized] != [LOGO_SLOT_OFFSET]:
        raise LogoError("expected exactly one %dx%d JPEG, at 0x%x; found %s"
                        % (LOGO_WIDTH, LOGO_HEIGHT, LOGO_SLOT_OFFSET,
                           ", ".join("0x%x" % j.offset for j in sized) or "none"))
    return slot


def check_logo(logo, slot):
    """The replacement JPEG: one complete baseline image the RTOS can show."""
    try:
        info = parse_jpeg(logo, 0)
    except LogoError as exc:
        raise LogoError("the logo is not a well-formed JPEG: %s" % exc)
    if info.length != len(logo):
        raise LogoError("the logo has %d bytes after its EOI" % (len(logo) - info.length))
    if not info.baseline():
        raise LogoError("the logo must be a baseline JPEG (SOF0), not SOF 0x%02x" % info.sof)
    if (info.width, info.height) != (LOGO_WIDTH, LOGO_HEIGHT):
        raise LogoError("the logo is %dx%d, the slot needs %dx%d"
                        % (info.width, info.height, LOGO_WIDTH, LOGO_HEIGHT))
    want = tuple((h, v) for _, h, v in slot.components)
    have = tuple((h, v) for _, h, v in info.components)
    if have != want:
        raise LogoError("the logo's sampling %s differs from the stock logo's %s"
                        % (have, want))
    if len(logo) > LOGO_SLOT_SIZE:
        raise LogoError("the logo is %d bytes, the slot holds %d" % (len(logo), LOGO_SLOT_SIZE))
    return info


def patch(stock, logo, allow_unpinned=False):
    """-> the patched image. Raises LogoError; never returns a partial result."""
    slot = check_stock(stock, allow_unpinned)
    check_logo(logo, slot)
    end = LOGO_SLOT_OFFSET + LOGO_SLOT_SIZE
    out = (stock[:LOGO_SLOT_OFFSET] + logo + b"\x00" * (LOGO_SLOT_SIZE - len(logo)) + stock[end:])
    verify(stock, out, logo)
    return out


def verify(stock, patched, logo):
    """Prove `patched` is `stock` with exactly the logo slot replaced by `logo`."""
    if len(patched) != len(stock):
        raise LogoError("patched image is %d bytes, stock is %d" % (len(patched), len(stock)))
    end = LOGO_SLOT_OFFSET + LOGO_SLOT_SIZE
    if patched[:LOGO_SLOT_OFFSET] != stock[:LOGO_SLOT_OFFSET] or patched[end:] != stock[end:]:
        differ = sum(1 for i in range(len(stock))
                     if not LOGO_SLOT_OFFSET <= i < end and patched[i] != stock[i])
        raise LogoError("%d byte(s) outside the logo slot differ from stock" % differ)
    region = patched[LOGO_SLOT_OFFSET:end]
    if region[:len(logo)] != logo:
        raise LogoError("the logo slot does not start with the logo")
    if region[len(logo):].strip(b"\x00"):
        raise LogoError("the logo slot is not zero-filled after the logo")
    if len(find_jpegs(patched)) != len(find_jpegs(stock)):
        raise LogoError("the patched image no longer has the stock image's JPEG count")
    if locate_slot(patched).length != len(logo):
        raise LogoError("the slot does not parse back as the logo")
    return True


def nebulaos_image(stock):
    """The pinned NebulaOS zero2.bin from pinned stock bytes and the committed asset.

    Used by the Hardware Agent, whose stock source is the printer's own rtos2:
    every input and the result are checked against their pins."""
    with open(LOGO_ASSET, "rb") as fh:
        logo = fh.read()
    if sha256(logo) != NEBULAOS_LOGO_SHA256:
        raise LogoError("%s has sha256 %s, expected the pinned %s"
                        % (LOGO_ASSET, sha256(logo), NEBULAOS_LOGO_SHA256))
    out = patch(stock, logo)
    if sha256(out) != NEBULAOS_ZERO_SHA256:
        raise LogoError("the patched image has sha256 %s, expected the pinned %s"
                        % (sha256(out), NEBULAOS_ZERO_SHA256))
    return out


# --- CLI ----------------------------------------------------------------------

def _read(path):
    with open(path, "rb") as fh:
        return fh.read()


def cmd_patch(args):
    if os.path.lexists(args.out):
        raise LogoError("refusing to overwrite %s" % args.out)
    for p in (args.stock, args.logo):
        if os.path.abspath(p) == os.path.abspath(args.out):
            raise LogoError("the output must not be an input")
    stock, logo = _read(args.stock), _read(args.logo)
    out = patch(stock, logo, allow_unpinned=args.allow_unpinned_stock)
    pinned_logo = sha256(logo) == NEBULAOS_LOGO_SHA256
    if args.require_pinned and (not pinned_logo or sha256(out) != NEBULAOS_ZERO_SHA256):
        raise LogoError("--require-pinned: logo %s / result %s are not the pinned %s / %s"
                        % (sha256(logo), sha256(out), NEBULAOS_LOGO_SHA256, NEBULAOS_ZERO_SHA256))
    tmp = args.out + ".tmp"
    with open(tmp, "xb") as fh:
        fh.write(out)
    os.replace(tmp, args.out)
    print("RTOS_STOCK_SHA256=%s" % sha256(stock))
    print("RTOS_LOGO_SHA256=%s" % sha256(logo))
    print("RTOS_LOGO_BYTES=%d" % len(logo))
    print("RTOS_LOGO_SLOT=0x%x+%d" % (LOGO_SLOT_OFFSET, LOGO_SLOT_SIZE))
    print("RTOS_PATCHED=%s" % args.out)
    print("RTOS_PATCHED_SHA256=%s" % sha256(out))
    print("RTOS_PATCHED_SIZE=%d" % len(out))
    print("RTOS_PATCHED_PINNED=%s" % ("YES" if sha256(out) == NEBULAOS_ZERO_SHA256 else "NO"))
    print("RTOS_BYTES_DIFFERENT_OUTSIDE_SLOT=0")
    return 0


def cmd_verify(args):
    stock, patched, logo = _read(args.stock), _read(args.patched), _read(args.logo)
    check_stock(stock, allow_unpinned=args.allow_unpinned_stock)
    check_logo(logo, locate_slot(stock))
    verify(stock, patched, logo)
    print("RTOS_PATCHED_SHA256=%s" % sha256(patched))
    print("RTOS_PATCHED_VERIFIED=YES")
    return 0


def cmd_list(args):
    data = _read(args.image)
    print("IMAGE_SHA256=%s" % sha256(data))
    print("IMAGE_SIZE=%d" % len(data))
    for info in find_jpegs(data):
        print("JPEG %s" % info.describe())
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description="NebulaOS logo in the stock RTOS image")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("patch", help="write a patched copy")
    p.add_argument("--stock", required=True)
    p.add_argument("--logo", default=LOGO_ASSET)
    p.add_argument("--out", required=True)
    p.add_argument("--require-pinned", action="store_true",
                   help="refuse unless the logo and the result equal their pins (packaging)")
    p.add_argument("--allow-unpinned-stock", action="store_true",
                   help="local experiments only; never for a package")
    p = sub.add_parser("verify", help="prove a patched image against stock and the logo")
    p.add_argument("--stock", required=True)
    p.add_argument("--patched", required=True)
    p.add_argument("--logo", default=LOGO_ASSET)
    p.add_argument("--allow-unpinned-stock", action="store_true")
    p = sub.add_parser("list", help="list the top-level JPEGs in an image")
    p.add_argument("image")
    args = parser.parse_args(argv)
    try:
        return {"patch": cmd_patch, "verify": cmd_verify, "list": cmd_list}[args.cmd](args)
    except (LogoError, OSError) as exc:
        sys.stderr.write("RTOS_LOGO=REFUSED\nREASON: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
