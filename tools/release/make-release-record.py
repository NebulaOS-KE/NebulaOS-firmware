#!/usr/bin/env python3
"""Write the NebulaOS release record for system updates over the internet (G79).

Tim 2026-10-29 (Run 23): no signing key. The record is a release asset next to
the image; the printer fetches both over HTTPS from github.com only and keeps the
image when its size and sha256 match the record:

    nebulaos-release.json      {product, channel, version, img {name, size, sha256},
                                source_head, [min_version, max_version, notes_url]}

    make-release-record.py --img NebulaOS-Ender3V3KE-<ver>.img --version <x.y.z>
                           --source-head <40-hex> --out <dir>
                           [--min-version x.y.z] [--max-version x.y.z] [--notes-url URL]

The printer side is nebulaos_osconfig/ota.py.
"""
import argparse
import hashlib
import json
import os
import re
import sys

PRODUCT = "NebulaOS-Ender3V3KE"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def record(img, version, source_head, min_version=None, max_version=None, notes_url=None):
    rec = {"ota_schema": 1, "product": PRODUCT, "channel": "stable", "version": version,
           "img": {"name": os.path.basename(img), "size": os.path.getsize(img),
                   "sha256": sha256_file(img)},
           "source_head": source_head}
    if min_version:
        rec["min_version"] = min_version
    if max_version:
        rec["max_version"] = max_version
    if notes_url:
        rec["notes_url"] = notes_url
    return (json.dumps(rec, sort_keys=True, indent=2) + "\n").encode()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--img", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--source-head", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--min-version")
    ap.add_argument("--max-version")
    ap.add_argument("--notes-url")
    a = ap.parse_args(argv)
    for v in (a.version, a.min_version, a.max_version):
        if v is not None and not re.fullmatch(r"\d+\.\d+\.\d+", v):
            ap.error("versions are x.y.z: %r" % v)
    if not re.fullmatch(r"[0-9a-f]{40}", a.source_head):
        ap.error("--source-head must be a full 40-hex commit")
    if not re.fullmatch(r"NebulaOS-Ender3V3KE-[0-9A-Za-z.+-]{1,64}\.img", os.path.basename(a.img)):
        ap.error("not a packaged NebulaOS image name: %s" % a.img)
    os.makedirs(a.out, exist_ok=True)
    data = record(a.img, a.version, a.source_head, a.min_version, a.max_version, a.notes_url)
    rec_path = os.path.join(a.out, "nebulaos-release.json")
    with open(rec_path, "wb") as handle:
        handle.write(data)
    print("RELEASE_RECORD=%s" % rec_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
