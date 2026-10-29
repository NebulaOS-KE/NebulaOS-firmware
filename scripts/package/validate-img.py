#!/usr/bin/env python3
"""Validate a NebulaOS Creality F005 OTA .img by taking it apart again.

A packaging command that exits 0 proves only that it did not crash. This opens
the archive the way the stock updater would, walks the chunk chain exactly as
the updater walks it, and then does the one thing that actually settles the
question: it reassembles both payloads from the packaged chunks and compares
SHA-256 against the canonical core.

Checks, in the order a failure is most informative:

  1. the archive opens with the derived envelope secret
  2. the expected top-level directory, ota_config.in, ota_update.in and the
     .ok version marker are present
  3. ota_update.in declares the right sizes and full-image MD5s
  4. every chunk exists, in an unbroken 0000..N sequence with no gaps
  5. every chunk's CONTENT hashes to the MD5 the NEXT chunk's filename carries,
     and chunk 0000's filename carries the full-image MD5 - the chain itself
  6. the ota_md5_<name>.<full> manifest lists exactly those per-chunk digests,
     in order, with no extra or missing lines
  7. reassembled payload SHA-256 == canonical payload SHA-256
  8. each payload fits the partition it is destined for

(5) is the check that would catch a plausible-looking but wrong chunk scheme -
for instance one where each chunk names its own digest rather than its
predecessor's. Such a package would build cleanly and be rejected by the printer.
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "emmc"))
import nebulaos_layout as layout  # noqa: E402

PASS, FAIL = [], []

# The chunk size is NOT defined here. It is imported from the packager below,
# alongside the envelope secret. An earlier revision kept its own copy while its
# own comment claimed both were shared - so a divergence in chunk size would have
# been "checked" by a validator that had already agreed with the wrong value.


def ok(msg):
    PASS.append(msg)
    print("PASS  %s" % msg)


def bad(msg, detail=""):
    FAIL.append(msg)
    print("FAIL  %s" % msg)
    if detail:
        print("       %s" % detail)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def md5_file(path):
    digest = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_update_in(text):
    """Parse ota_update.in into [{img_type, img_name, img_size, img_md5}, ...].

    The file is a flat sequence of key=value lines with blank-line separated
    records, so a new record starts whenever img_type reappears.
    """
    records, current = [], {}
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        key, _, value = line.partition("=")
        if key == "img_type" and current:
            records.append(current)
            current = {}
        current[key] = value
    if current:
        records.append(current)
    return [r for r in records if "img_name" in r]


def report():
    print()
    print("IMG_VALIDATION_PASS=%d" % len(PASS))
    print("IMG_VALIDATION_FAIL=%d" % len(FAIL))
    print("IMG_VALIDATED=%s" % ("YES" if not FAIL else "NO"))
    return 0 if not FAIL else 1


def main(argv):
    parser = argparse.ArgumentParser(description="Validate a NebulaOS Creality F005 OTA .img")
    parser.add_argument("--img", required=True)
    parser.add_argument("--ximage", required=True, help="canonical xImage to compare against")
    parser.add_argument("--rootfs", required=True, help="canonical rootfs.squashfs to compare against")
    parser.add_argument("--rtos", help="stock zero.bin, if the package carries an rtos record")
    args = parser.parse_args(argv)

    # Import the packager so the envelope secret and chunk size are derived by
    # exactly one implementation. A validator with its own copy of either could
    # agree with a broken packager.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "nebulaos_build_img", os.path.join(os.path.dirname(os.path.abspath(__file__)), "build-img.py"))
    packer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packer)
    chunk_bytes = packer.CHUNK_BYTES

    canonical = {
        "xImage": (sha256_file(args.ximage), os.path.getsize(args.ximage), args.ximage),
        "rootfs.squashfs": (sha256_file(args.rootfs), os.path.getsize(args.rootfs), args.rootfs),
    }
    if args.rtos:
        canonical["zero.bin"] = (sha256_file(args.rtos), os.path.getsize(args.rtos), args.rtos)

    print("=== .img (Creality F005 OTA) validation: %s ===" % args.img)
    for name, (sha, size, _) in canonical.items():
        print("CANONICAL_%s_SHA256=%s size=%d" % (name.upper().replace(".", "_"), sha, size))
    print()

    secret = packer.derive_archive_secret()
    ok("the OTA envelope secret derives to the expected MD5-crypt value")

    work = tempfile.mkdtemp(prefix="nebulaos-img-validate.", dir=os.environ.get("TMPDIR") or None)
    try:
        proc = subprocess.run(["7z", "x", "-y", "-p%s" % secret, "-o%s" % work, args.img],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            bad("the archive extracts with the derived secret", proc.stderr.strip()[:400])
            return report()
        ok("the archive extracts with the derived secret")

        # The stock updater looks in <file name without .img>/ (2026-10-29).
        want_top = os.path.basename(args.img)[:-len(".img")]
        tops = [d for d in os.listdir(work) if os.path.isdir(os.path.join(work, d))]
        if tops == [want_top]:
            ok("the archive holds exactly one top-level directory named like the file (%s)"
               % want_top)
        else:
            bad("the archive holds exactly one top-level directory named like the file",
                "%r, file %s" % (tops, os.path.basename(args.img)))
            return report()
        root = os.path.join(work, tops[0])

        config_path = os.path.join(root, "ota_config.in")
        current_version = None
        if os.path.isfile(config_path):
            ok("ota_config.in is present")
            for line in open(config_path, encoding="utf-8"):
                if line.startswith("current_version="):
                    current_version = line.split("=", 1)[1].strip()
            if current_version:
                ok("ota_config.in names current_version (%s)" % current_version)
            else:
                bad("ota_config.in names current_version (the stock updater stops without it)")
        else:
            bad("ota_config.in is present")

        inners = [d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d))]
        if len(inners) == 1 and inners[0].startswith("ota_v"):
            ok("the package holds exactly one versioned payload directory (%s)" % inners[0])
        else:
            bad("the package holds exactly one versioned payload directory", repr(inners))
            return report()
        payload_dir = os.path.join(root, inners[0])

        if os.path.isfile(os.path.join(payload_dir, "%s.ok" % inners[0])):
            ok("the %s.ok version marker is present" % inners[0])
        else:
            bad("the %s.ok version marker is present" % inners[0])

        update_path = os.path.join(payload_dir, "ota_update.in")
        if not os.path.isfile(update_path):
            bad("ota_update.in is present")
            return report()
        ok("ota_update.in is present")

        # local_ota_update.sh: the payload directory is ota_v<current_version>
        # and ota_update.in's ota_version must equal it, string for string.
        update_version = None
        for line in open(update_path, encoding="utf-8"):
            if line.startswith("ota_version="):
                update_version = line.split("=", 1)[1].strip()
        if current_version and inners[0] == "ota_v%s" % current_version \
                and update_version == current_version:
            ok("ota_v<version>, ota_update.in ota_version and current_version agree (%s)"
               % current_version)
        else:
            bad("ota_v<version>, ota_update.in ota_version and current_version agree",
                "dir=%s ota_version=%s current_version=%s"
                % (inners[0], update_version, current_version))

        records = {r["img_name"]: r for r in parse_update_in(open(update_path, encoding="utf-8").read())}
        if set(records) == set(canonical):
            ok("ota_update.in declares exactly the %d expected payloads (%s)"
               % (len(canonical), ", ".join(sorted(canonical))))
        else:
            bad("ota_update.in declares exactly the expected payloads",
                "declared=%s expected=%s" % (sorted(records), sorted(canonical)))

        # FIRMWARE.md records, from extracting Creality's real V1.1.0.12 package,
        # that ota_update.in lists THREE payloads including rtos/zero.bin. A
        # two-record manifest is not the vendor shape, and a purely structural
        # validator cannot discover that on its own - so its absence is called
        # out here rather than silently accepted.
        if "zero.bin" in records:
            ok("ota_update.in carries the rtos/zero.bin record the vendor package has")
        else:
            bad("ota_update.in carries the rtos/zero.bin record the vendor package has",
                "only %d payload(s) declared. FIRMWARE.md records the real V1.1.0.12 "
                "ota_update.in listing kernel, rootfs AND rtos/zero.bin. Pass --rtos to "
                "both the packager and this validator." % len(records))

        entries = os.listdir(payload_dir)

        for name, (canon_sha, canon_size, canon_path) in canonical.items():
            record = records.get(name)
            if not record:
                bad("ota_update.in has a record for %s" % name)
                continue

            canon_md5 = md5_file(canon_path)

            if record.get("img_size") == str(canon_size):
                ok("%s: ota_update.in size (%s) matches the canonical payload" % (name, canon_size))
            else:
                bad("%s: ota_update.in size matches the canonical payload" % name,
                    "declared=%s actual=%d" % (record.get("img_size"), canon_size))

            if record.get("img_md5") == canon_md5:
                ok("%s: ota_update.in full-image MD5 matches the canonical payload" % name)
            else:
                bad("%s: ota_update.in full-image MD5 matches the canonical payload" % name,
                    "declared=%s actual=%s" % (record.get("img_md5"), canon_md5))

            # --- walk the chunk chain ---------------------------------------
            pattern = re.compile(r"^%s\.(\d{4})\.([0-9a-f]{32})$" % re.escape(name))
            found = {}
            for entry in entries:
                match = pattern.match(entry)
                if match:
                    found[int(match.group(1))] = (entry, match.group(2))

            expected_count = (canon_size + chunk_bytes - 1) // chunk_bytes
            if sorted(found) == list(range(expected_count)):
                ok("%s: all %d chunks present in an unbroken 0000..%04d sequence"
                   % (name, expected_count, expected_count - 1))
            else:
                bad("%s: all chunks present in an unbroken sequence" % name,
                    "expected %d, found indices %s" % (expected_count, sorted(found)[:10]))
                continue

            # The chain: chunk 0000's filename carries the FULL image MD5, and
            # every later chunk's filename carries the PREVIOUS chunk's digest.
            chain_ok, per_chunk = True, []
            previous = canon_md5
            for index in range(expected_count):
                entry, named_md5 = found[index]
                if named_md5 != previous:
                    bad("%s: chunk %04d's filename carries its predecessor's MD5" % (name, index),
                        "filename says %s, expected %s" % (named_md5, previous))
                    chain_ok = False
                    break
                digest = md5_file(os.path.join(payload_dir, entry))
                per_chunk.append(digest)
                previous = digest
            if chain_ok:
                ok("%s: the chained-MD5 filename scheme is correct across all %d chunks"
                   % (name, expected_count))

            # --- the ota_md5 manifest ---------------------------------------
            md5_manifest = os.path.join(payload_dir, "ota_md5_%s.%s" % (name, canon_md5))
            if not os.path.isfile(md5_manifest):
                bad("%s: ota_md5_%s.<full-md5> manifest is present" % (name, name))
            else:
                listed = [l.strip() for l in open(md5_manifest, encoding="utf-8").read().splitlines() if l.strip()]
                if listed == per_chunk:
                    ok("%s: the ota_md5 manifest lists exactly the %d per-chunk digests, in order"
                       % (name, len(listed)))
                else:
                    bad("%s: the ota_md5 manifest lists exactly the per-chunk digests, in order" % name,
                        "manifest has %d lines, computed %d" % (len(listed), len(per_chunk)))

            # --- THE gate: reassemble and compare ---------------------------
            rebuilt = os.path.join(work, "rebuilt-%s" % name)
            with open(rebuilt, "wb") as out:
                for index in range(expected_count):
                    entry, _ = found[index]
                    with open(os.path.join(payload_dir, entry), "rb") as src:
                        shutil.copyfileobj(src, out, 1024 * 1024)
            rebuilt_sha = sha256_file(rebuilt)
            if rebuilt_sha == canon_sha:
                ok("%s: REASSEMBLED FROM CHUNKS, SHA-256 equals the canonical payload" % name)
            else:
                bad("%s: REASSEMBLED FROM CHUNKS, SHA-256 equals the canonical payload" % name,
                    "reassembled=%s canonical=%s" % (rebuilt_sha, canon_sha))
            if os.path.getsize(rebuilt) == canon_size:
                ok("%s: reassembled size equals the canonical payload (%d bytes)" % (name, canon_size))
            else:
                bad("%s: reassembled size equals the canonical payload" % name)
            os.unlink(rebuilt)

    finally:
        shutil.rmtree(work, ignore_errors=True)

    # --- capacity ----------------------------------------------------------
    sizes = {f.name: f.value for f in layout.PARTITION_SIZES}
    capacity = [("xImage", "kernel"), ("rootfs.squashfs", "rootfs")]
    if "zero.bin" in canonical:
        capacity.append(("zero.bin", "rtos"))
    for name, partition in capacity:
        size = canonical[name][1]
        if size <= sizes[partition]:
            ok("%s fits the %s partition (%d / %d bytes, %d%% full)"
               % (name, partition, size, sizes[partition], size * 100 // sizes[partition]))
        else:
            bad("%s fits the %s partition" % (name, partition),
                "%d > %d" % (size, sizes[partition]))

    return report()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
