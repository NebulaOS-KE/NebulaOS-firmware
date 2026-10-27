#!/usr/bin/env python3
"""Generate the NebulaOS RTOS logo: scripts/package/assets/nebulaos-rtos-logo.jpg.

The RTOS stage (zero.bin) draws one 480x272 JPEG to the panel before Linux
starts. Stock's is the CREALITY wordmark stored rotated, because Creality's GUI
uses the pad in portrait. On the KE the panel is mounted upside down relative
to how NebulaOS uses it: the userspace splash and GuppyScreen render landscape
with a 180 degree turn (splash.meta ROTATE="2", GuppyScreen display_rotate 2).
So this asset is a LANDSCAPE card stored rotated 180 degrees, the same transform
nebulaos_osconfig/bootdisplay.py applies to its built-in splash.

G116 (Run 21, Tim): the logo is the shipped boot logo "NebulaOS Ender-3
Blueprint Interface" (overlay usr/share/nebulaos/boot-logos/, made by
make-boot-logos.py), the default boot screen of a fresh install, so a fresh
install shows the same picture before and after Linux starts. Until Run 21 it
was bootdisplay.builtin_image()'s "NebulaOS / starting..." text card.

ROTATION IS A PARAMETER. The final orientation is confirmed on the printer.
--rotate takes 0, 90, 180 or 270 clockwise degrees (default 180), applied like
bootdisplay's `img.rotate(-90 * quarter_turns, expand=True)`; for 90 and 270
the card is laid out portrait (272x480) first, so the stored JPEG is always
480x272.

ENCODING. Baseline JPEG (SOF0), 4:2:0, Pillow's standard Huffman tables
(optimize off), no EXIF: the same structure as the stock asset, so the RTOS
decoder sees nothing new. The result must fit the 10899-byte slot: the detailed
Blueprint picture fits at quality 22 (checked by eye against softened variants,
Run 21).

REPRODUCIBILITY. JPEG decoding and encoding depend on the Pillow and
libjpeg versions, so the committed bytes - pinned by sha256 in
rtos_logo.py and manifests/dependencies.conf - are the asset, not this script's
output on an arbitrary host. `--check` regenerates in memory and reports whether
this host reproduces them. The asset in the repository was generated with the
versions recorded in assets/nebulaos-rtos-logo.txt.

    make-rtos-logo.py --out assets/nebulaos-rtos-logo.jpg [--rotate 180]
    make-rtos-logo.py --check
"""

import argparse
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rtos_logo  # noqa: E402

WIDTH, HEIGHT = rtos_logo.LOGO_WIDTH, rtos_logo.LOGO_HEIGHT
QUALITY = 22
SOURCE = os.path.join(HERE, "..", "build", "overlay", "usr", "share", "nebulaos", "boot-logos",
                      "NebulaOS Ender-3 Blueprint Interface.jpg")


def card(width, height):
    """The shipped 480x272 boot logo (laid out portrait for 90/270)."""
    from PIL import Image
    with Image.open(SOURCE) as src:
        img = src.convert("RGB")
    if (width, height) != img.size:
        img = img.rotate(90, expand=True)
    return img


def render(rotate):
    if rotate not in (0, 90, 180, 270):
        raise ValueError("rotate must be 0, 90, 180 or 270")
    w, h = (WIDTH, HEIGHT) if rotate in (0, 180) else (HEIGHT, WIDTH)
    img = card(w, h)
    if rotate:
        img = img.rotate(-rotate, expand=True)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=QUALITY, subsampling=2, optimize=False, progressive=False)
    data = buf.getvalue()
    info = rtos_logo.parse_jpeg(data)
    if (info.width, info.height) != (WIDTH, HEIGHT) or not info.baseline():
        raise RuntimeError("encoder produced %s" % info.describe())
    if len(data) > rtos_logo.LOGO_SLOT_SIZE:
        raise RuntimeError("%d bytes do not fit the %d-byte slot" % (len(data), rtos_logo.LOGO_SLOT_SIZE))
    return data


def versions():
    import PIL
    from PIL import features
    return "pillow=%s libjpeg_turbo=%s" % (PIL.__version__, features.version("libjpeg_turbo"))


def main(argv):
    parser = argparse.ArgumentParser(description="Generate the NebulaOS RTOS logo JPEG")
    parser.add_argument("--rotate", type=int, default=180, help="clockwise degrees (default 180)")
    parser.add_argument("--out", help="write the JPEG here (refuses to overwrite)")
    parser.add_argument("--check", action="store_true",
                        help="compare a fresh render with the committed asset")
    args = parser.parse_args(argv)
    data = render(args.rotate)
    print("RTOS_LOGO_GENERATOR=%s rotate=%d quality=%d" % (versions(), args.rotate, QUALITY))
    print("RTOS_LOGO_BYTES=%d" % len(data))
    print("RTOS_LOGO_SHA256=%s" % rtos_logo.sha256(data))
    if args.out:
        with open(args.out, "xb") as fh:
            fh.write(data)
        print("RTOS_LOGO_WRITTEN=%s" % args.out)
    if args.check:
        with open(rtos_logo.LOGO_ASSET, "rb") as fh:
            same = fh.read() == data
        print("RTOS_LOGO_REPRODUCED=%s" % ("YES" if same else "NO"))
        return 0 if same else 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
