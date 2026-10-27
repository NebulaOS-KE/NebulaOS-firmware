#!/usr/bin/env python3
"""Convert the boot logos NebulaOS ships (G116, Run 21) into the image:
scripts/build/overlay/usr/share/nebulaos/boot-logos/<name>.jpg.

Every logo is shown in Settings > Display > Boot logo next to the user's own
uploads (nebulaos_osconfig/bootdisplay.py SHIPPED_DIR). The screen is 480x272,
so each logo is stored at exactly that size: scaled to cover it and centred
(the sources are ~1666x944, the same shape, so at most a few pixels are cut),
then a baseline JPEG, quality 92, 4:4:4. bootdisplay then shows it without
scaling; Apply still makes the power-on logo from it (poweronlogo.convert).

The committed JPEGs are the assets (another Pillow may encode other bytes);
this script records how they were made. The source PNGs are Tim's
(2026-10-15/26, not in the repository).

    make-boot-logos.py <source-dir> <out-dir>
"""

import os
import sys

WIDTH, HEIGHT = 480, 272
QUALITY = 92

# source file -> shipped name (without .jpg)
NAMES = {
    "0454072c-010d-44e0-8380-0b981fa079a7.png": "NebulaOS Galaxy Printer",
    "0ec00568-f036-4afb-99d8-2cf60429a7c4.png": "NebulaOS Blue Horizon",
    "19d697bb-ce36-44a4-acff-7f07f9ac4557.png": "NebulaOS Black Eclipse",
    "1c1b523d-f5a5-425c-b408-ffd2f5932aec.png": "NebulaOS Neon HUD",
    "2edc8e43-b8f1-47b3-bc74-22d5646c620b.png": "NebulaOS Ender-3 Night",
    "5ccbe12b-c178-40fe-b90e-c842d92b1653.png": "NebulaOS Maker Toys",
    "NebulaOS Ender-3 Blueprint Interface.png": "NebulaOS Ender-3 Blueprint Interface",
    "ca5f858e-75c1-47ac-ae63-1ea484241360.png": "NebulaOS Sunny Workshop",
    "cf19964a-26ef-40d3-9b66-7e330812a387.png": "NebulaOS Maker Desk",
    "da5da558-6f0a-4826-bc8b-72254cb8431a.png": "NebulaOS Deep Space",
    "dc27cd86-ff11-4eb2-96b6-8d71e2eda198.png": "NebulaOS Synthwave",
}


def cover(img):
    from PIL import Image
    img = img.convert("RGB")
    scale = max(float(WIDTH) / img.width, float(HEIGHT) / img.height)
    size = (max(WIDTH, round(img.width * scale)), max(HEIGHT, round(img.height * scale)))
    img = img.resize(size, Image.LANCZOS)
    left, top = (size[0] - WIDTH) // 2, (size[1] - HEIGHT) // 2
    return img.crop((left, top, left + WIDTH, top + HEIGHT))


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__)
    from PIL import Image
    src_dir, out_dir = argv
    os.makedirs(out_dir, exist_ok=True)
    for src, name in sorted(NAMES.items(), key=lambda kv: kv[1]):
        with Image.open(os.path.join(src_dir, src)) as img:
            out = cover(img)
        path = os.path.join(out_dir, name + ".jpg")
        out.save(path, "JPEG", quality=QUALITY, subsampling=0, optimize=True, progressive=False)
        print("%s %d" % (path, os.path.getsize(path)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
