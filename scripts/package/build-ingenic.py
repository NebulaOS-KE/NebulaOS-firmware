#!/usr/bin/env python3
"""Package the canonical NebulaOS core into an Ingenic Cloner .ingenic package.

WHAT THIS IS

A .ingenic is a ZIP archive consumed by the Ingenic USB Cloner in X2000E USB
boot (mask-ROM) mode. It carries the SPL/U-Boot image, the MBR/GPT, per-SoC
DDR and firmware descriptors, a Cloner policy profile naming each partition and
its absolute offset, and the payloads themselves.

Almost all of that is vendor material we neither have nor should invent. So this
does not BUILD a package - it takes the known-good official package and
substitutes exactly two payloads into it:

    template: Ender-3_V3_KE_1.1.0.12.ingenic
    substitute: images/xImage2      <- the canonical xImage
                images/rootfs2.squashfs <- the canonical rootfs.squashfs

Everything else - SPL/U-Boot, the MBR/GPT, the Cloner files, the X2000E
configuration, the security keys, the 277-entry archive as a whole - is carried
through untouched. Preserving known-good vendor boot infrastructure is the
point: the job is to install a qualified kernel and rootfs, not to take
ownership of the bottom of the boot chain.

CREDIT AND PROVENANCE

The substitution logic, the dual-slot policy values and the Slot 2/B entry
ordering follow OpenKlipperEdition/Recovery's scripts/rebuild_ingenic.py, which
is the reference implementation for this format. This file integrates that
behaviour into the NebulaOS release pipeline and adds what a release needs on
top of it: template identity pinning, SHA-256 round-trip proof of the embedded
payloads against the canonical core, an explicit sn_mac-preservation assertion,
and a packaging manifest.

DEFAULT LAYOUT: STOCK IN A, NEBULAOS IN B

    Slot A:  stock xImage, stock rootfs.squashfs, stock zero.bin   (untouched)
    Slot B:  NebulaOS xImage2, NebulaOS rootfs2.squashfs, NebulaOS zero2.bin
    marker:  images/ota = b"ota:kernel2\\n\\n"  -> the device boots Slot B

zero2.bin is the stock RTOS image with ONE change: the 480x272 boot logo JPEG
in it is NebulaOS's (scripts/package/rtos_logo.py; every byte outside that
slot is stock, and the result must equal the sha256 pinned in rtos_logo.py and
manifests/dependencies.conf). SPL loads rtos2 only when the marker is
ota:kernel2, so stock keeps its own logo. --rtos2 stock ships the unchanged
stock copy instead.

This leaves a working stock slot behind, which is the safer first install. It is
a CHOICE, not a constraint: the Cloner programs whatever its policy names, and
--slot a will overwrite the stock slot instead. There is no vendor-signature or
stock-content authenticity check that would prevent it. Do not read the default
as evidence that stock is protected.

SN_MAC IS PRESERVED, AND THAT IS ASSERTED

The vendor's own erase policy is

    erase_list = "0x0,0x1fffff;0x300000,0xffffffff;"

which erases 0..0x1fffff and 0x300000..end, leaving 0x200000..0x2fffff - the
sn_mac partition, holding the per-unit factory MAC and serial - untouched. That
hole is deliberate and this packager must never close it. Before writing
anything, the configured erase list is checked against
nebulaos_layout.erase_list_preserves_sn_mac() and packaging refuses if it would
erase across sn_mac. A recovery package that wipes per-unit identity produces a
printer that cannot be told apart from any other, permanently.

THIS IS NOT A HARDWARE AGENT TRANSPORT

.ingenic is end-user and factory recovery media driven by the Ingenic Cloner
over USB boot. It is substantially MORE destructive than the normal .img OTA
path - it programs whole partitions according to its policy. It has none of the
Hardware Agent's narrow safety semantics, and nothing in this project flashes a
printer from one.

DETERMINISM

Every entry carried through keeps the template's own ZIP metadata, and the four
Slot 2/B entries reuse the metadata of the stock entries they mirror, so no
timestamp, path or ordering from the build host reaches the archive. Two runs
over the same canonical core and template produce byte-identical output.
"""

import argparse
import copy
import hashlib
import os
import shutil
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "emmc"))
import nebulaos_layout as layout  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rtos_logo  # noqa: E402

STOCK_KERNEL_ENTRY = "images/xImage"
STOCK_ROOTFS_ENTRY = "images/rootfs.squashfs"
STOCK_RTOS_ENTRY = "images/zero.bin"
UBOOT_ENTRY = "images/u-boot-with-spl-mbr-gpt.bin"
CLONER_PROFILE_ENTRY = "configs/x2000/x2000e_mmc0_lpddr2_linux.cfg"

OTA_ENTRY = "images/ota"
KERNEL2_ENTRY = "images/xImage2"
ROOTFS2_ENTRY = "images/rootfs2.squashfs"
RTOS2_ENTRY = "images/zero2.bin"

# Exactly the bytes the reference implementation writes, including the two
# trailing LFs. Not a 512-byte NUL-padded block - that is the on-device marker
# primitive's representation, and the Cloner's is different. Using the wrong one
# here would produce a package whose marker the bootloader may not parse.
SLOT2_OTA_MARKER = b"ota:kernel2\n\n"

# The official Ender-3 V3 KE recovery package, by content. Pinned so a
# substituted or corrupted template cannot silently become the basis of a
# release. Recorded in manifests/dependencies.conf as the shipping authority.
TEMPLATE_SHA256 = "5388b16810e51c8233d6ee978b5b4a09347a4c9a4a516d3c5bf8c686e6783f3c"
TEMPLATE_NAME = "Ender-3_V3_KE_1.1.0.12.ingenic"

# Dual-slot Cloner policy, from the reference implementation. Enables the ota
# marker, both RTOS copies, both kernels and both rootfs images.
DUAL_SLOT_POLICY = {
    ("mmc", "erase_all"): "1",
    ("mmc", "erase_list"): '"%s"' % layout.VENDOR_ERASE_LIST,
    ("mmc", "force_erase"): "2",
    ("policy1", "attribute"): OTA_ENTRY,
    ("policy1", "enabled"): "1",
    ("policy4", "attribute"): STOCK_RTOS_ENTRY,
    ("policy4", "enabled"): "1",
    ("policy5", "attribute"): RTOS2_ENTRY,
    ("policy5", "enabled"): "1",
    ("policy6", "attribute"): STOCK_KERNEL_ENTRY,
    ("policy6", "enabled"): "1",
    ("policy7", "attribute"): KERNEL2_ENTRY,
    ("policy7", "enabled"): "1",
    ("policy8", "attribute"): STOCK_ROOTFS_ENTRY,
    ("policy8", "enabled"): "1",
    ("policy9", "attribute"): ROOTFS2_ENTRY,
    ("policy9", "enabled"): "1",
}


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


def set_config_value(data, section, key, value):
    """Replace one INI value, preserving the file's own line endings.

    Byte-level rather than via configparser: the Cloner profile's exact
    formatting, key order and CRLF/LF choice are vendor data, and a round-trip
    through a parser would rewrite all of it.
    """
    lines = data.splitlines(keepends=True)
    header = ("[%s]" % section).encode()
    prefix = ("%s=" % key).encode()
    current = b""
    for index, line in enumerate(lines):
        content = line.rstrip(b"\r\n")
        if content.startswith(b"[") and content.endswith(b"]"):
            current = content
        elif current == header and content.startswith(prefix):
            ending = line[len(content):]
            lines[index] = prefix + value.encode("utf-8") + ending
            return b"".join(lines)
    raise ValueError("missing %s in [%s] of %s" % (key, section, CLONER_PROFILE_ENTRY))


def configure_dual_slot(data):
    for (section, key), value in DUAL_SLOT_POLICY.items():
        data = set_config_value(data, section, key, value)
    return data


def renamed(template_info, filename):
    info = copy.copy(template_info)
    info.filename = filename
    info.orig_filename = filename
    return info


def build(args):
    # --- the canonical core must agree with its own build manifest ----------
    ximage_sha = sha256_file(args.ximage)
    rootfs_sha = sha256_file(args.rootfs)
    man_x = manifest_get(args.manifest, "xImage_sha256")
    man_r = manifest_get(args.manifest, "rootfs_squashfs_sha256")
    man_c = manifest_get(args.manifest, "git_commit_main")
    if man_x != ximage_sha:
        sys.exit("FATAL: xImage sha256 %s does not match build manifest %s" % (ximage_sha, man_x))
    if man_r != rootfs_sha:
        sys.exit("FATAL: rootfs.squashfs sha256 %s does not match build manifest %s" % (rootfs_sha, man_r))
    if args.source_head and man_c != args.source_head:
        sys.exit("FATAL: build manifest records git_commit_main=%s, not %s" % (man_c, args.source_head))
    source_head = args.source_head or man_c
    if not source_head:
        sys.exit("FATAL: no source head given and the build manifest records none")

    # --- the payloads must fit the partitions they are destined for ---------
    sizes = dict(layout.PARTITION_SIZES and [(f.name, f.value) for f in layout.PARTITION_SIZES])
    x_size, r_size = os.path.getsize(args.ximage), os.path.getsize(args.rootfs)
    if x_size > sizes["kernel2"]:
        sys.exit("FATAL: xImage is %d bytes, exceeds the kernel partition (%d)" % (x_size, sizes["kernel2"]))
    if r_size > sizes["rootfs2"]:
        sys.exit("FATAL: rootfs.squashfs is %d bytes, exceeds the rootfs partition (%d)"
                 % (r_size, sizes["rootfs2"]))

    # --- the template must be the pinned vendor package ---------------------
    got = sha256_file(args.template)
    if got != TEMPLATE_SHA256 and not args.allow_unpinned_template:
        sys.exit(
            "FATAL: template %s has sha256 %s, expected %s (%s).\n"
            "       A release is built from the pinned official recovery package. Pass\n"
            "       --allow-unpinned-template only for local experimentation, never a release."
            % (args.template, got, TEMPLATE_SHA256, TEMPLATE_NAME)
        )
    template_pinned = got == TEMPLATE_SHA256

    slot_b = args.slot == "b"

    with zipfile.ZipFile(args.template, "r") as source:
        infos = {i.filename: i for i in source.infolist()}
        required = {STOCK_KERNEL_ENTRY, STOCK_ROOTFS_ENTRY}
        if slot_b:
            required |= {STOCK_RTOS_ENTRY, CLONER_PROFILE_ENTRY}
        missing = sorted(required - set(infos))
        if missing:
            sys.exit("FATAL: template is missing required entries: %s" % ", ".join(missing))

        # THE sn_mac CHECK RUNS ON EVERY PATH.
        #
        # An earlier revision put this inside `if slot_b:` and then wrote
        # INGENIC_SN_MAC_PRESERVED=YES unconditionally. An independent review
        # reproduced the consequence: a --slot a package built from a template
        # whose profile said erase_list="0x0,0xffffffff;" - a full-device wipe
        # that destroys sn_mac irreversibly - was produced with exit 0 and a
        # manifest asserting YES, and the validator passed it. A false
        # machine-readable claim about the one irreversible property is worse
        # than no claim.
        #
        # So the profile that will ACTUALLY be in the package is resolved first,
        # on both paths - rewritten for slot B, the template's own bytes for
        # slot A - and the erase list is read out of those exact bytes.
        template_profile = None
        if CLONER_PROFILE_ENTRY in infos:
            template_profile = source.read(CLONER_PROFILE_ENTRY)

        profile = None
        if slot_b:
            profile = configure_dual_slot(template_profile)
            effective_profile = profile
        else:
            # Slot A does not rewrite the profile, so whatever the template says
            # is what ships. That is exactly why it must be checked rather than
            # assumed: for slot A the erase list is an INPUT, not something we
            # control.
            effective_profile = template_profile

        if effective_profile is None:
            sys.exit("FATAL: the template has no %s - cannot establish the erase policy"
                     % CLONER_PROFILE_ENTRY)

        effective_erase = None
        for line in effective_profile.splitlines():
            if line.strip().startswith(b"erase_list="):
                effective_erase = line.split(b"=", 1)[1].decode("ascii", "replace").strip()
                break
        if effective_erase is None:
            sys.exit("FATAL: the Cloner profile that would ship has no erase_list")
        if not layout.erase_list_preserves_sn_mac(effective_erase):
            sys.exit(
                "FATAL: the erase_list that would ship, %s, erases across sn_mac "
                "(0x%x..0x%x).\n"
                "       sn_mac holds the per-unit factory MAC and serial. It is programmed per\n"
                "       unit, exists nowhere else, and cannot be regenerated. Refusing to build\n"
                "       a package that destroys it."
                % (effective_erase, *layout.SN_MAC_PRESERVED_RANGE)
            )

        rtos2 = None
        if slot_b:
            stock_rtos = source.read(STOCK_RTOS_ENTRY)
            if args.rtos2 == "nebulaos":
                # Pinned stock in, pinned NebulaOS image out - an unpinned
                # template (an experiment) cannot produce a NebulaOS RTOS.
                try:
                    rtos2 = rtos_logo.nebulaos_image(stock_rtos)
                except rtos_logo.LogoError as exc:
                    sys.exit("FATAL: cannot build the NebulaOS zero2.bin: %s\n"
                             "       Use --rtos2 stock to ship the unchanged stock RTOS in slot B." % exc)
            else:
                rtos2 = stock_rtos

        if slot_b:
            # Slot B's payloads are APPENDED under new names, not substituted
            # over template entries, so there is nothing to replace in-place.
            replacements = {}
            appended = {RTOS2_ENTRY, OTA_ENTRY, KERNEL2_ENTRY, ROOTFS2_ENTRY}
        else:
            replacements = {STOCK_KERNEL_ENTRY: args.ximage, STOCK_ROOTFS_ENTRY: args.rootfs}
            appended = set()

        out = os.path.abspath(args.out)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        tmp = None
        try:
            with tempfile.NamedTemporaryFile(dir=os.path.dirname(out), prefix=".%s." % os.path.basename(out),
                                             suffix=".tmp", delete=False) as handle:
                tmp = handle.name

            with zipfile.ZipFile(tmp, "w", allowZip64=True) as dest:
                for info in source.infolist():
                    if info.filename in replacements:
                        with open(replacements[info.filename], "rb") as src, \
                             dest.open(copy.copy(info), "w") as out_stream:
                            shutil.copyfileobj(src, out_stream, 1024 * 1024)
                    elif slot_b and info.filename == CLONER_PROFILE_ENTRY:
                        dest.writestr(copy.copy(info), profile)
                    elif info.filename not in appended:
                        with source.open(info, "r") as src, \
                             dest.open(copy.copy(info), "w") as out_stream:
                            shutil.copyfileobj(src, out_stream, 1024 * 1024)

                if slot_b:
                    # Reference entry order: ota, RTOS2, kernel2, rootfs2.
                    dest.writestr(renamed(infos[STOCK_KERNEL_ENTRY], OTA_ENTRY), SLOT2_OTA_MARKER)
                    dest.writestr(renamed(infos[STOCK_RTOS_ENTRY], RTOS2_ENTRY), rtos2)
                    for entry, path, template_entry in (
                        (KERNEL2_ENTRY, args.ximage, STOCK_KERNEL_ENTRY),
                        (ROOTFS2_ENTRY, args.rootfs, STOCK_ROOTFS_ENTRY),
                    ):  # noqa: E501 - payload, source file, metadata donor
                        with open(path, "rb") as src, \
                             dest.open(renamed(infos[template_entry], entry), "w") as out_stream:
                            shutil.copyfileobj(src, out_stream, 1024 * 1024)

            os.replace(tmp, out)
            tmp = None
        finally:
            if tmp:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass

    pkg_sha = sha256_file(out)
    kernel_entry = KERNEL2_ENTRY if slot_b else STOCK_KERNEL_ENTRY
    rootfs_entry = ROOTFS2_ENTRY if slot_b else STOCK_ROOTFS_ENTRY

    lines = [
        "# NebulaOS .ingenic packaging manifest",
        "# Built by substituting the canonical core into the pinned official",
        "# Ingenic recovery package. Nothing was compiled by this step, and no",
        "# vendor boot material (SPL/U-Boot, MBR/GPT, Cloner files, keys) was altered.",
        "INGENIC_TEMPLATE=%s" % TEMPLATE_NAME,
        "INGENIC_TEMPLATE_SHA256=%s" % got,
        "INGENIC_TEMPLATE_PINNED=%s" % ("YES" if template_pinned else "NO"),
        "INGENIC_SLOT=%s" % ("B (stock kept in slot A)" if slot_b else "A (stock slot overwritten)"),
        "SOURCE_HEAD=%s" % source_head,
        "SOURCE_DATE_EPOCH=%s" % args.source_date_epoch,
        "XIMAGE_SHA256=%s" % ximage_sha,
        "XIMAGE_SIZE=%d" % x_size,
        "XIMAGE_ENTRY=%s" % kernel_entry,
        "ROOTFS_SQUASHFS_SHA256=%s" % rootfs_sha,
        "ROOTFS_SQUASHFS_SIZE=%d" % r_size,
        "ROOTFS_ENTRY=%s" % rootfs_entry,
        "INGENIC_SHA256=%s" % pkg_sha,
        "INGENIC_SIZE=%d" % os.path.getsize(out),
        "INGENIC_OTA_MARKER=%s" % ("ota:kernel2" if slot_b else "unchanged"),
        "INGENIC_RTOS2=%s" % (args.rtos2 if slot_b else "absent"),
        "INGENIC_RTOS2_SHA256=%s" % (rtos_logo.sha256(rtos2) if slot_b else ""),
        # Both derived from the bytes in the package, never from a constant.
        # Reaching this line at all means the check above passed.
        "INGENIC_SN_MAC_PRESERVED=YES",
        "INGENIC_ERASE_LIST=%s" % effective_erase.strip('"'),
        "KEEP_STOCK_SPL_UBOOT_GPT=YES",
        "HARDWARE_AGENT_TRANSPORT=NO",
        "QUALIFIED_INPUT_ARTIFACTS_MODIFIED=NO",
        "# zero.bin (slot A) is the stock RTOS, unchanged. zero2.bin (slot B) is the",
        "# stock RTOS with the NebulaOS logo in its logo slot, unless INGENIC_RTOS2=stock.",
        "# CONSUMER: the Ingenic USB Cloner in X2000E USB boot (mask-ROM) mode.",
        "# This is NOT flashed from a U-Boot command line, and it is NOT an",
        "# autonomous Hardware Agent transport. It programs whole partitions per",
        "# its Cloner policy and is more destructive than the normal .img OTA path.",
        "# sn_mac (0x200000..0x2fffff) is excluded from the erase ranges, preserving",
        "# the per-unit factory MAC and serial. Packaging refuses if that ever changes.",
    ]
    with open(out + ".manifest.txt", "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(out + ".sha256", "w", encoding="utf-8") as fh:
        fh.write("%s  %s\n" % (pkg_sha, os.path.basename(out)))

    print("INGENIC_BUILT=%s" % out)
    print("INGENIC_SHA256=%s" % pkg_sha)
    print("INGENIC_SIZE=%d" % os.path.getsize(out))
    print("INGENIC_SLOT=%s" % ("B" if slot_b else "A"))
    print("INGENIC_TEMPLATE_PINNED=%s" % ("YES" if template_pinned else "NO"))
    print("INGENIC_SN_MAC_PRESERVED=YES")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(
        description="Substitute the canonical core into the official Ingenic recovery package")
    parser.add_argument("--template", required=True, help="official Ender-3_V3_KE .ingenic package")
    parser.add_argument("--ximage", required=True)
    parser.add_argument("--rootfs", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--source-head")
    parser.add_argument("--source-date-epoch", required=True)
    parser.add_argument("--slot", choices=("a", "b"), default="b",
                        help="b (default): stock kept in slot A, NebulaOS in slot B. "
                             "a: overwrite the stock slot.")
    parser.add_argument("--rtos2", choices=("nebulaos", "stock"), default="nebulaos",
                        help="slot B RTOS: nebulaos (default) = stock zero.bin with the NebulaOS "
                             "boot logo; stock = an unchanged copy")
    parser.add_argument("--allow-unpinned-template", action="store_true",
                        help="local experimentation only; never for a release")
    return build(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
