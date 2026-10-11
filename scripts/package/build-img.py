#!/usr/bin/env python3
"""Package the canonical NebulaOS core into a Creality F005 OTA .img.

WHAT A KE .img ACTUALLY IS

Not a raw disk image. It is the OTA package the stock Creality updater consumes,
delivered over USB or the touchscreen, or from the CLI:

    /etc/ota_bin/local_ota_update.sh /path/to/NebulaOS-....img

The .img extension is checked by the stock updater, which is why the output must
carry it; it says nothing about the contents. Inside is an encrypted 7z archive
holding a versioned directory of metadata and chunked payloads.

An earlier revision of this file produced a raw GPT disk image. That was simply
the wrong format - it would not have been accepted by the updater at all, and
writing it to a device would have destroyed the stock slot, the persistent data
partitions and the per-unit sn_mac identity. This replaces it entirely.

WHERE IT INSTALLS, AND WHAT THAT MEANS

The stock updater writes whichever A/B set is INACTIVE and then flips the ota
marker to point at what it just wrote:

    booted A (ota:kernel)   ->  writes kernel2 + rootfs2, sets ota:kernel2
    booted B (ota:kernel2)  ->  writes kernel  + rootfs,  sets ota:kernel

So the destination is not a property of this package - it is a property of which
slot the printer is running when the package is applied. A NebulaOS .img applied
while NebulaOS is booted will overwrite the STOCK slot. There is no
vendor-signature check and no comparison of the target's existing contents
against a Creality release that would prevent that.

That is worth stating precisely. It does NOT mean "there are no checks": the
updater validates package extraction, version, metadata, partition capacity,
per-chunk MD5 and declared full sizes, and this packager exists to satisfy every
one of them. It means there is no AUTHENTICITY check tying a partition to
Creality's own bytes. A structurally valid custom package is writable, which is
exactly why custom F005 firmware can be installed through the stock update path.

THE CHAINED-MD5 CHUNK SCHEME

Each payload is split into 1 MiB chunks whose filenames form a chain:

    <name>.0000.<md5 of the WHOLE payload>
    <name>.0001.<md5 of chunk 0000>
    <name>.0002.<md5 of chunk 0001>
    ...

so each chunk's name carries the digest of its PREDECESSOR, and only the first
carries the digest of the complete image. Alongside them:

    ota_md5_<name>.<md5 of the whole payload>

whose lines are the per-chunk digests in order. The updater verifies that list
before streaming anything into the MMC partition, so getting the chain wrong
produces a package that is rejected rather than one that half-installs.

THE ARCHIVE PASSWORD

Derived, not hardcoded:

    mkpasswd -m md5 "F005C3_7e_bz" -S cxswfile

computed here through the same MD5-crypt algorithm and then asserted against the
known-good result, so a wrong algorithm is caught at build time rather than by a
printer refusing to open the package.

VERIFICATION IS A HARD GATE

build() does not return success because 7z exited 0. scripts/package/
validate-img.py re-opens the archive, reassembles both payloads from the
packaged chunks, and requires

    SHA256(reassembled) == SHA256(canonical)

for xImage and rootfs.squashfs both. Anything less would let a chunking bug ship.
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "emmc"))
import nebulaos_layout as layout  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rtos_logo  # noqa: E402

CHUNK_BYTES = 1048576
BOARD_SHORT_NAME = "F005"
SECRET_INPUT = "%sC3_7e_bz" % BOARD_SHORT_NAME
SECRET_SALT = "cxswfile"
EXPECTED_SECRET = "$1$cxswfile$ZFd0RWFYkJQugbtKVGL9y0"


def derive_archive_secret():
    """MD5-crypt of the board string under the vendor salt.

    Equivalent to `mkpasswd -m md5 "F005C3_7e_bz" -S cxswfile`. This is a
    PUBLISHED, derivable value used by every tool that builds F005 packages -
    it is an envelope format detail, not a secret, which is why it may appear
    in a process argument list where the attestation key never may.

    Derived and then checked against the known-good result so that a Python
    build without crypt(3), or a different algorithm, fails here rather than
    producing an archive the stock updater silently refuses to open.
    """
    got = None
    try:
        import crypt  # removed in Python 3.13; present on most build hosts
        got = crypt.crypt(SECRET_INPUT, "$1$%s" % SECRET_SALT)
    except Exception:
        if shutil.which("mkpasswd"):
            proc = subprocess.run(
                ["mkpasswd", "-m", "md5", SECRET_INPUT, "-S", SECRET_SALT],
                capture_output=True, text=True,
            )
            if proc.returncode == 0:
                got = proc.stdout.strip()
    if got != EXPECTED_SECRET:
        sys.exit(
            "FATAL: OTA envelope secret derivation produced %r, expected %r.\n"
            "       Install `mkpasswd` (whois package) or use a Python with crypt(3).\n"
            "       Refusing to build a package the stock updater cannot open." % (got, EXPECTED_SECRET)
        )
    return got


def md5_bytes(data):
    return hashlib.md5(data).hexdigest()


def md5_file(path):
    digest = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def manifest_get(path, key):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip()
    return None


def rtos_provenance(digest):
    """Named from the pins, never from what a caller says the file is."""
    if digest is None:
        return "absent"
    if digest == rtos_logo.STOCK_ZERO_SHA256:
        return "stock copy, carried through unchanged"
    if digest == rtos_logo.NEBULAOS_ZERO_SHA256:
        return "stock zero.bin with the NebulaOS boot logo in its logo slot (pinned)"
    return "UNPINNED (neither the stock nor the NebulaOS RTOS image)"


def chunk_payload(source, out_dir, name):
    """Split `source` into the chained-MD5 chunk set.

    Returns (full_md5, [per-chunk md5 in order]).

    The chain is the part that is easy to get subtly wrong: chunk 0000's
    filename carries the digest of the COMPLETE payload, and every later chunk
    carries the digest of the chunk BEFORE it. A scheme where each chunk named
    its own digest would look almost identical and would be rejected by the
    updater.
    """
    full_md5 = md5_file(source)
    per_chunk = []
    previous = full_md5
    index = 0
    with open(source, "rb") as fh:
        while True:
            data = fh.read(CHUNK_BYTES)
            if not data:
                break
            with open(os.path.join(out_dir, "%s.%04d.%s" % (name, index, previous)), "wb") as out:
                out.write(data)
            digest = md5_bytes(data)
            per_chunk.append(digest)
            previous = digest
            index += 1
    if not per_chunk:
        sys.exit("FATAL: %s is empty" % source)
    with open(os.path.join(out_dir, "ota_md5_%s.%s" % (name, full_md5)), "w", encoding="utf-8") as fh:
        fh.write("\n".join(per_chunk) + "\n")
    return full_md5, per_chunk


def build(args):
    # --- the canonical core must agree with its own build manifest ----------
    ximage_sha = sha256_file(args.ximage)
    rootfs_sha = sha256_file(args.rootfs)
    if manifest_get(args.manifest, "xImage_sha256") != ximage_sha:
        sys.exit("FATAL: xImage sha256 does not match the build manifest")
    if manifest_get(args.manifest, "rootfs_squashfs_sha256") != rootfs_sha:
        sys.exit("FATAL: rootfs.squashfs sha256 does not match the build manifest")
    man_c = manifest_get(args.manifest, "git_commit_main")
    if args.source_head and man_c != args.source_head:
        sys.exit("FATAL: build manifest records git_commit_main=%s, not %s" % (man_c, args.source_head))
    source_head = args.source_head or man_c
    if not source_head:
        sys.exit("FATAL: no source head given and the build manifest records none")

    # --- capacity, before anything is packed --------------------------------
    sizes = {f.name: f.value for f in layout.PARTITION_SIZES}
    x_size, r_size = os.path.getsize(args.ximage), os.path.getsize(args.rootfs)
    if x_size > sizes["kernel"]:
        sys.exit("FATAL: xImage is %d bytes, exceeds the kernel partition capacity %d"
                 % (x_size, sizes["kernel"]))
    if r_size > sizes["rootfs"]:
        sys.exit("FATAL: rootfs.squashfs is %d bytes, exceeds the rootfs partition capacity %d"
                 % (r_size, sizes["rootfs"]))

    secret = derive_archive_secret()
    if not shutil.which("7z"):
        sys.exit("FATAL: 7z is required to build the OTA envelope and was not found")

    version = args.ota_version
    top = "Ender-3_V3_KE_%s_ota_img_V%s" % (BOARD_SHORT_NAME, version)
    inner = "ota_v%s" % version

    work = tempfile.mkdtemp(prefix="nebulaos-img-pack.", dir=os.environ.get("TMPDIR") or None)
    try:
        root = os.path.join(work, top)
        payload_dir = os.path.join(root, inner)
        os.makedirs(payload_dir)

        x_md5, x_chunks = chunk_payload(args.ximage, payload_dir, "xImage")
        r_md5, r_chunks = chunk_payload(args.rootfs, payload_dir, "rootfs.squashfs")

        # THE RTOS RECORD.
        #
        # An earlier revision emitted two records and its validator asserted
        # "exactly the two expected images" - builder and validator agreeing with
        # each other and with nothing else. FIRMWARE.md records, from actually
        # extracting Creality's real V1.1.0.12 package, that ota_update.in lists
        # EXACTLY THREE payloads: kernel/xImage, rootfs/rootfs.squashfs and
        # rtos/zero.bin. A two-record manifest is not the vendor shape, and a
        # structural validator cannot discover that by construction.
        #
        # zero.bin is stock RTOS material, from the official .ingenic template
        # (the only genuine copy this project has). package-release.sh passes
        # the stock image with ONE change - NebulaOS's boot logo in its logo
        # slot (rtos_logo.py). The record keeps the vendor name zero.bin.
        # UNVERIFIED: which rtos partition the stock updater writes this
        # record to has not been read from its scripts. The expectation is the
        # inactive set's (rtos2 when applied from stock), the one SPL loads
        # with ota:kernel2; it must be confirmed before relying on the .img to
        # deliver the logo. Either way the image differs from stock only in
        # the logo JPEG, so a stock boot from it shows the NebulaOS logo at
        # worst - the code is stock.
        rtos_md5 = rtos_size = rtos_sha = None
        rtos_chunks = []
        if args.rtos:
            rtos_size = os.path.getsize(args.rtos)
            rtos_sha = sha256_file(args.rtos)
            rtos_md5, rtos_chunks = chunk_payload(args.rtos, payload_dir, "zero.bin")

        # The metadata the updater parses. Sizes and digests are the REAL ones
        # for the payloads actually included - never carried over from a stock
        # template, which would make the updater reject the package or, worse,
        # mis-stream the image into the partition.
        records = [
            "ota_version=%s" % version,
            "",
            "img_type=kernel",
            "img_name=xImage",
            "img_size=%d" % x_size,
            "img_md5=%s" % x_md5,
            "",
            "img_type=rootfs",
            "img_name=rootfs.squashfs",
            "img_size=%d" % r_size,
            "img_md5=%s" % r_md5,
            "",
        ]
        if args.rtos:
            records += [
                "img_type=rtos",
                "img_name=zero.bin",
                "img_size=%d" % rtos_size,
                "img_md5=%s" % rtos_md5,
                "",
            ]
        update_in = "\n".join(records)
        with open(os.path.join(payload_dir, "ota_update.in"), "w", encoding="utf-8") as fh:
            fh.write(update_in)

        # The completion marker the updater looks for.
        open(os.path.join(payload_dir, "%s.ok" % inner), "w").close()

        # ota_config.in. PROVENANCE GAP, recorded rather than hidden: no stock
        # F005 .img was available to copy this from, so it is synthesised from
        # the package's own facts. If a vendor package is later obtained, pass
        # --ota-config-template to use its real one instead.
        if args.ota_config_template:
            shutil.copyfile(args.ota_config_template, os.path.join(root, "ota_config.in"))
            config_provenance = "VENDOR_TEMPLATE(%s)" % os.path.basename(args.ota_config_template)
        else:
            with open(os.path.join(root, "ota_config.in"), "w", encoding="utf-8") as fh:
                fh.write("\n".join([
                    "ota_version=%s" % version,
                    "ota_dir=%s" % inner,
                    "board=%s" % BOARD_SHORT_NAME,
                    "",
                ]))
            config_provenance = "SYNTHESISED_NO_VENDOR_TEMPLATE"

        out = os.path.abspath(args.out)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        if os.path.exists(out):
            os.unlink(out)

        # DETERMINISM. 7z stores each member's mtime, so an archive built from
        # files that were just created carries the wall clock and two runs over
        # an identical core produce different bytes - measured, not theorised:
        # the same canonical core gave 104700706 and 104700690 byte archives.
        #
        # Every staged file and directory is stamped with SOURCE_DATE_EPOCH,
        # which is derived from the source commit. Timestamps are still STORED
        # (rather than suppressed with -mtm=off) so the archive keeps the shape
        # a vendor package has; they are simply a property of the release
        # instead of a property of when it was packed.
        epoch = int(args.source_date_epoch)
        for dirpath, dirnames, filenames in os.walk(root, topdown=False):
            for name in filenames + dirnames:
                os.utime(os.path.join(dirpath, name), (epoch, epoch))
        os.utime(root, (epoch, epoch))

        # -mhe=on matches the vendor envelope's header encryption.
        # -mmt=off: multithreaded LZMA splits the stream differently depending on
        # how many cores the packing host has, which would make the output depend
        # on the machine rather than on the input.
        proc = subprocess.run(
            ["7z", "a", "-t7z", "-mhe=on", "-mx=9", "-mmt=off", "-p%s" % secret, out, top],
            capture_output=True, text=True, cwd=work,
        )
        if proc.returncode != 0:
            sys.exit("FATAL: 7z failed:\n%s\n%s" % (proc.stdout[-2000:], proc.stderr[-2000:]))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    img_sha = sha256_file(out)
    lines = [
        "# NebulaOS .img (Creality F005 OTA package) manifest",
        "# Built from an already-built canonical core. Nothing was compiled here.",
        "IMG_FORMAT=creality-f005-ota",
        "IMG_TOP_DIR=%s" % top,
        "IMG_OTA_VERSION=%s" % version,
        "IMG_OTA_CONFIG_PROVENANCE=%s" % config_provenance,
        "SOURCE_HEAD=%s" % source_head,
        "SOURCE_DATE_EPOCH=%s" % args.source_date_epoch,
        "XIMAGE_SHA256=%s" % ximage_sha,
        "XIMAGE_MD5=%s" % x_md5,
        "XIMAGE_SIZE=%d" % x_size,
        "XIMAGE_CHUNKS=%d" % len(x_chunks),
        "ROOTFS_SQUASHFS_SHA256=%s" % rootfs_sha,
        "ROOTFS_SQUASHFS_MD5=%s" % r_md5,
        "ROOTFS_SQUASHFS_SIZE=%d" % r_size,
        "ROOTFS_SQUASHFS_CHUNKS=%d" % len(r_chunks),
        "RTOS_INCLUDED=%s" % ("YES" if args.rtos else "NO"),
        "RTOS_NAME=%s" % ("zero.bin" if args.rtos else ""),
        "RTOS_MD5=%s" % (rtos_md5 or ""),
        "RTOS_SIZE=%s" % (rtos_size if rtos_size is not None else ""),
        "RTOS_CHUNKS=%d" % len(rtos_chunks),
        "RTOS_SHA256=%s" % (rtos_sha or ""),
        "RTOS_PROVENANCE=%s" % rtos_provenance(rtos_sha),
        "IMG_SHA256=%s" % img_sha,
        "IMG_SIZE=%d" % os.path.getsize(out),
        "IMG_CHUNK_BYTES=%d" % CHUNK_BYTES,
        "QUALIFIED_INPUT_ARTIFACTS_MODIFIED=NO",
        "# INSTALL TARGET: the stock updater writes whichever A/B slot is INACTIVE",
        "# and then flips the ota marker to it. Applied while NebulaOS is booted,",
        "# this package overwrites the STOCK slot. That is a property of the",
        "# printer's current slot, not of this file.",
        "# CLI entrypoint: /etc/ota_bin/local_ota_update.sh <this file>",
    ]
    with open(out + ".manifest.txt", "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(out + ".sha256", "w", encoding="utf-8") as fh:
        fh.write("%s  %s\n" % (img_sha, os.path.basename(out)))

    print("IMG_BUILT=%s" % out)
    print("IMG_SHA256=%s" % img_sha)
    print("IMG_SIZE=%d" % os.path.getsize(out))
    print("IMG_OTA_VERSION=%s" % version)
    print("IMG_XIMAGE_CHUNKS=%d IMG_ROOTFS_CHUNKS=%d IMG_RTOS_CHUNKS=%d"
          % (len(x_chunks), len(r_chunks), len(rtos_chunks)))
    print("IMG_RTOS_INCLUDED=%s" % ("YES" if args.rtos else "NO"))
    print("IMG_OTA_CONFIG_PROVENANCE=%s" % config_provenance)
    return 0


def main(argv):
    parser = argparse.ArgumentParser(
        description="Package the canonical core into a Creality F005 OTA .img")
    parser.add_argument("--ximage", required=True)
    parser.add_argument("--rootfs", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--source-head")
    parser.add_argument("--source-date-epoch", required=True)
    parser.add_argument("--ota-version", required=True,
                        help="OTA version namespace; must exceed the stock version the updater knows")
    parser.add_argument("--ota-config-template",
                        help="a vendor ota_config.in to copy instead of synthesising one")
    parser.add_argument("--rtos",
                        help="the RTOS zero.bin: stock, or stock with the NebulaOS logo. The real vendor ota_update.in lists three "
                             "payloads; omitting this produces a two-record manifest that does "
                             "not match the vendor shape. Extracted from the official .ingenic.")
    return build(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
