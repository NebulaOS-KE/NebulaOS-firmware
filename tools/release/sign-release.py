#!/usr/bin/env python3
"""Sign a NebulaOS release record for system updates over the internet (G79 S1).

Run by the project owner, OFFLINE, with the owner's Ed25519 private key - the key
never touches CI or a build machine. Writes, next to the packaged image:

    nebulaos-release.json      the record the printer verifies (raw bytes)
    nebulaos-release.json.sig  Ed25519 signature over exactly those bytes

    sign-release.py --img NebulaOS-Ender3V3KE-<ver>.img --version <x.y.z>
                    --source-head <40-hex> --key owner-ed25519.pem --out <dir>
                    [--min-version x.y.z] [--max-version x.y.z] [--notes-url URL]

The printer (nebulaos_osconfig/ota.py) checks the signature with the public keys
in its read-only image keyring before it parses anything. Publishing (only
RELEASE builds, the gates of design v2) is a separate step, not this tool.
A key pair: openssl genpkey -algorithm ed25519 -out owner-ed25519.pem;
openssl pkey -in owner-ed25519.pem -pubout -out <name>.pem (the public half goes
into the image keyring /usr/share/nebulaos/ota-keys/).
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
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
    ap.add_argument("--key", required=True, help="the owner's Ed25519 PRIVATE key (PEM)")
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
    sig_path = rec_path + ".sig"
    rc = subprocess.call(["openssl", "pkeyutl", "-sign", "-inkey", a.key, "-rawin",
                          "-in", rec_path, "-out", sig_path])
    if rc != 0:
        os.unlink(rec_path)
        sys.exit("signing failed (openssl exit %d); nothing written" % rc)
    print("RELEASE_RECORD=%s" % rec_path)
    print("RELEASE_SIGNATURE=%s" % sig_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
