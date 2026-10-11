#!/usr/bin/env python3
"""Generate the NebulaOS RTOS logo: scripts/package/assets/nebulaos-rtos-logo.jpg.

The RTOS stage (zero.bin) draws one 480x272 JPEG to the panel before Linux
starts. Stock's is the CREALITY wordmark stored rotated, because Creality's GUI
uses the pad in portrait. On the KE the panel is mounted upside down relative
to how NebulaOS uses it: the userspace splash and GuppyScreen render landscape
with a 180 degree turn (splash.meta ROTATE="2", GuppyScreen display_rotate 2).
So this asset is a LANDSCAPE card stored rotated 180 degrees, the same transform
nebulaos_osconfig/bootdisplay.py applies to its built-in splash.

The card copies bootdisplay.builtin_image(): the same background, the same
"NebulaOS" / "starting..." text, sizes, positions and colours, so the RTOS logo
and the S01 splash read as one continuous screen. The splash adds the build's
short SHA at the bottom later; a static pre-Linux image cannot know it.

ROTATION IS A PARAMETER. The final orientation is confirmed on the printer.
--rotate takes 0, 90, 180 or 270 clockwise degrees (default 180), applied like
bootdisplay's `img.rotate(-90 * quarter_turns, expand=True)`; for 90 and 270
the card is laid out portrait (272x480) first, so the stored JPEG is always
480x272.

ENCODING. Baseline JPEG (SOF0), 4:2:0, Pillow's standard Huffman tables
(optimize off), no EXIF, quality 90: the same structure as the stock asset, so
the RTOS decoder sees nothing new. The result must fit the 10899-byte slot.

REPRODUCIBILITY. Text rasterisation and JPEG encoding depend on the Pillow,
FreeType and libjpeg versions, so the committed bytes - pinned by sha256 in
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
QUALITY = 90

# bootdisplay.builtin_image()
BACKGROUND = (10, 12, 28)
TITLE = ("NebulaOS", -46, 52, (220, 226, 255))
SUBTITLE = ("starting...", 22, 20, (150, 160, 200))


def card(width, height):
    from PIL import Image, ImageDraw, ImageFont
    img = Image.new("RGB", (width, height), BACKGROUND)
    draw = ImageDraw.Draw(img)
    for text, dy, size, colour in (TITLE, SUBTITLE):
        try:
            font = ImageFont.load_default(size=size)
        except TypeError:
            sys.exit("FATAL: this Pillow cannot size its default font (needs >= 10.1 with FreeType)")
        box = draw.textbbox((0, 0), text, font=font)
        draw.text(((width - (box[2] - box[0])) // 2, height // 2 + dy), text, font=font, fill=colour)
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
    return "pillow=%s freetype2=%s libjpeg_turbo=%s" % (
        PIL.__version__, features.version("freetype2"), features.version("libjpeg_turbo"))


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
