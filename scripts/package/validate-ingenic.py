#!/usr/bin/env python3
"""Validate a NebulaOS .ingenic against its canonical core AND its template.

A packaging command that exits 0 proves only that it did not crash. This opens
the finished archive and proves three separate things:

  1. the NebulaOS payloads that went in are the ones that came out, byte for
     byte, compared by SHA-256 against the canonical xImage and rootfs.squashfs
  2. nothing else changed. Every entry the template carried - SPL/U-Boot, the
     MBR/GPT, the per-SoC firmware and DDR descriptors, the Cloner files, the
     security keys - is compared against the template entry by entry. Vendor
     boot material we did not mean to touch must be bit-identical.
  3. the safety properties hold: the erase policy still leaves sn_mac alone,
     the OTA marker selects the intended slot, and in the default slot-B layout
     the stock slot is genuinely untouched.
  4. slot B's zero2.bin is the stock zero.bin except the one boot-logo JPEG
     slot, which holds exactly the pinned NebulaOS logo, and the whole image
     equals its pinned sha256 (or, with --rtos2 stock, equals stock).

(2) is the check that matters most and is the easiest to omit. A package that
embeds the right kernel but silently re-encoded U-Boot is not a package anyone
should put a printer into mask-ROM for.
"""

import argparse
import hashlib
import os
import sys
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
SLOT2_OTA_MARKER = b"ota:kernel2\n\n"
CHUNK = 1024 * 1024

PASS, FAIL = [], []


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
        for chunk in iter(lambda: fh.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_entry(archive, name):
    digest = hashlib.sha256()
    with archive.open(name, "r") as stream:
        for chunk in iter(lambda: stream.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ini_value(data, section, key):
    header = ("[%s]" % section).encode()
    prefix = ("%s=" % key).encode()
    current = b""
    for line in data.splitlines():
        content = line.rstrip(b"\r\n")
        if content.startswith(b"[") and content.endswith(b"]"):
            current = content
        elif current == header and content.startswith(prefix):
            return content[len(prefix):].decode("ascii", "replace").strip()
    return None


def check_rtos2(pkg, tpl, pkg_names, mode):
    """zero2.bin: stock except the logo slot (nebulaos), or stock (stock)."""
    if RTOS2_ENTRY not in pkg_names:
        bad("the package carries %s" % RTOS2_ENTRY)
        return
    stock = tpl.read(STOCK_RTOS_ENTRY)
    rtos2 = pkg.read(RTOS2_ENTRY)
    if mode == "stock":
        if rtos2 == stock:
            ok("zero2.bin is a deliberate copy of the stock RTOS")
        else:
            bad("zero2.bin is a deliberate copy of the stock RTOS")
        return
    try:
        rtos_logo.check_stock(stock)
        ok("the template's zero.bin is the pinned stock RTOS (%s)" % rtos_logo.STOCK_ZERO_SHA256[:16])
    except rtos_logo.LogoError as exc:
        bad("the template's zero.bin is the pinned stock RTOS", str(exc))
        return
    with open(rtos_logo.LOGO_ASSET, "rb") as fh:
        logo = fh.read()
    if rtos_logo.sha256(logo) == rtos_logo.NEBULAOS_LOGO_SHA256:
        ok("the committed NebulaOS logo is the pinned asset")
    else:
        bad("the committed NebulaOS logo is the pinned asset",
            "%s != %s" % (rtos_logo.sha256(logo), rtos_logo.NEBULAOS_LOGO_SHA256))
    try:
        rtos_logo.verify(stock, rtos2, logo)
        ok("zero2.bin equals stock except the 0x%x+%d logo slot, which holds the NebulaOS logo"
           % (rtos_logo.LOGO_SLOT_OFFSET, rtos_logo.LOGO_SLOT_SIZE))
    except rtos_logo.LogoError as exc:
        bad("zero2.bin equals stock except the logo slot, which holds the NebulaOS logo", str(exc))
    got = rtos_logo.sha256(rtos2)
    if got == rtos_logo.NEBULAOS_ZERO_SHA256:
        ok("zero2.bin is the pinned NebulaOS RTOS image (%s)" % got[:16])
    else:
        bad("zero2.bin is the pinned NebulaOS RTOS image",
            "%s != %s" % (got, rtos_logo.NEBULAOS_ZERO_SHA256))


def report():
    print()
    print("INGENIC_VALIDATION_PASS=%d" % len(PASS))
    print("INGENIC_VALIDATION_FAIL=%d" % len(FAIL))
    print("INGENIC_VALIDATED=%s" % ("YES" if not FAIL else "NO"))
    return 0 if not FAIL else 1


def main(argv):
    parser = argparse.ArgumentParser(description="Validate a NebulaOS .ingenic package")
    parser.add_argument("--package", required=True)
    parser.add_argument("--template", required=True, help="the official package it was built from")
    parser.add_argument("--ximage", required=True, help="canonical xImage to compare against")
    parser.add_argument("--rootfs", required=True, help="canonical rootfs.squashfs to compare against")
    parser.add_argument("--slot", choices=("a", "b"), default="b")
    parser.add_argument("--rtos2", choices=("nebulaos", "stock"), default="nebulaos",
                        help="what slot B's zero2.bin must be (as packaged by build-ingenic.py)")
    args = parser.parse_args(argv)

    slot_b = args.slot == "b"
    canonical_x = sha256_file(args.ximage)
    canonical_r = sha256_file(args.rootfs)

    print("=== .ingenic validation: %s ===" % args.package)
    print("CANONICAL_XIMAGE_SHA256=%s" % canonical_x)
    print("CANONICAL_ROOTFS_SHA256=%s" % canonical_r)
    print("SLOT=%s" % args.slot.upper())
    print()

    try:
        pkg = zipfile.ZipFile(args.package, "r")
        tpl = zipfile.ZipFile(args.template, "r")
    except (zipfile.BadZipFile, OSError) as exc:
        bad("the package and template open as ZIP archives", str(exc))
        return report()
    ok("the package opens as a ZIP archive (the Ingenic Cloner container)")

    pkg_names = [i.filename for i in pkg.infolist()]
    tpl_names = [i.filename for i in tpl.infolist()]

    kernel_entry = KERNEL2_ENTRY if slot_b else STOCK_KERNEL_ENTRY
    rootfs_entry = ROOTFS2_ENTRY if slot_b else STOCK_ROOTFS_ENTRY

    # --- 1. the NebulaOS payloads round-trip --------------------------------
    for entry, canonical, label in ((kernel_entry, canonical_x, "xImage"),
                                    (rootfs_entry, canonical_r, "rootfs.squashfs")):
        if entry not in pkg_names:
            bad("the package carries %s" % entry)
            continue
        got = sha256_entry(pkg, entry)
        if got == canonical:
            ok("%s is byte-identical to the canonical %s" % (entry, label))
        else:
            bad("%s is byte-identical to the canonical %s" % (entry, label),
                "package=%s canonical=%s" % (got, canonical))

    # --- 2. nothing else changed -------------------------------------------
    # The heart of the check. Every template entry must survive untouched
    # except the ones we deliberately substituted or rewrote.
    expected_changed = {kernel_entry, rootfs_entry}
    if slot_b:
        expected_changed |= {CLONER_PROFILE_ENTRY}
    expected_new = {OTA_ENTRY, RTOS2_ENTRY, KERNEL2_ENTRY, ROOTFS2_ENTRY} if slot_b else set()

    missing = [n for n in tpl_names if n not in pkg_names]
    if not missing:
        ok("every one of the template's %d entries is still present" % len(tpl_names))
    else:
        bad("every template entry is still present", "missing: %s" % ", ".join(missing[:5]))

    unexpected = [n for n in pkg_names if n not in tpl_names and n not in expected_new]
    if not unexpected:
        ok("the package adds only the %d intended new entries" % len(expected_new))
    else:
        bad("the package adds only the intended new entries",
            "unexpected: %s" % ", ".join(unexpected[:5]))

    drifted = []
    for name in tpl_names:
        if name in expected_changed or name not in pkg_names:
            continue
        if tpl.getinfo(name).file_size != pkg.getinfo(name).file_size:
            drifted.append(name)
            continue
        if sha256_entry(tpl, name) != sha256_entry(pkg, name):
            drifted.append(name)
    if not drifted:
        # Count what was actually compared. Subtracting len(expected_changed)
        # was wrong: for slot B two of those three names do not exist in the
        # template, so the reported figure was 274 when 276 entries had been
        # checked.
        compared = sum(1 for n in tpl_names if n not in expected_changed)
        ok("all %d carried-through vendor entries are bit-identical to the template" % compared)
    else:
        bad("all carried-through vendor entries are bit-identical to the template",
            "drifted: %s" % ", ".join(drifted[:8]))

    # Called out individually because these are the ones that would matter most.
    for entry, what in ((UBOOT_ENTRY, "SPL/U-Boot + MBR/GPT"),
                        ("security/x2000/key.bin", "X2000 security key"),
                        ("firmwares/x2000/uboot.bin", "X2000 U-Boot firmware"),
                        ("firmwares/x2000/spl.bin", "X2000 SPL firmware")):
        if entry in tpl_names and entry in pkg_names and sha256_entry(tpl, entry) == sha256_entry(pkg, entry):
            ok("%s (%s) is unchanged" % (entry, what))
        else:
            bad("%s (%s) is unchanged" % (entry, what))

    # --- 3. slot A is genuinely stock in the default layout -----------------
    if slot_b:
        for entry, what in ((STOCK_KERNEL_ENTRY, "stock kernel"),
                            (STOCK_ROOTFS_ENTRY, "stock rootfs"),
                            (STOCK_RTOS_ENTRY, "stock RTOS")):
            if sha256_entry(tpl, entry) == sha256_entry(pkg, entry):
                ok("slot A's %s is the untouched stock payload" % what)
            else:
                bad("slot A's %s is the untouched stock payload" % what)

        # The NebulaOS payload must NOT have landed in slot A.
        if sha256_entry(pkg, STOCK_KERNEL_ENTRY) != canonical_x:
            ok("the NebulaOS kernel did not land in slot A")
        else:
            bad("the NebulaOS kernel did not land in slot A",
                "slot A holds the NebulaOS kernel - the stock fallback is gone")

        check_rtos2(pkg, tpl, pkg_names, args.rtos2)

        # --- the OTA marker ---
        if OTA_ENTRY in pkg_names:
            marker = pkg.read(OTA_ENTRY)
            if marker == SLOT2_OTA_MARKER:
                ok("the OTA marker is exactly %r (selects slot B)" % SLOT2_OTA_MARKER)
            else:
                bad("the OTA marker is exactly %r (selects slot B)" % SLOT2_OTA_MARKER,
                    "got %r" % marker)
        else:
            bad("the package carries an OTA marker entry")

        # --- the dual-slot Cloner policy ---
        profile = pkg.read(CLONER_PROFILE_ENTRY)
        enabled = {}
        for policy, label in (("policy1", "ota"), ("policy4", "rtos"), ("policy5", "rtos2"),
                              ("policy6", "kernel"), ("policy7", "kernel2"),
                              ("policy8", "rootfs"), ("policy9", "rootfs2")):
            enabled[label] = ini_value(profile, policy, "enabled")
        if all(v == "1" for v in enabled.values()):
            ok("the Cloner profile enables all 7 dual-slot policies (%s)" % ", ".join(sorted(enabled)))
        else:
            bad("the Cloner profile enables all 7 dual-slot policies",
                "; ".join("%s=%s" % (k, v) for k, v in sorted(enabled.items())))

        for policy, want in (("policy7", KERNEL2_ENTRY), ("policy9", ROOTFS2_ENTRY),
                             ("policy1", OTA_ENTRY), ("policy5", RTOS2_ENTRY)):
            got = ini_value(profile, policy, "attribute")
            if got == want:
                ok("%s points at %s" % (policy, want))
            else:
                bad("%s points at %s" % (policy, want), "got %r" % got)

        # The offsets are vendor geometry and must not have moved.
        #
        # An earlier revision used `for ... else:` here with no `break`, so the
        # else clause fired unconditionally and printed "every partition offset
        # is unchanged" directly beneath its own FAIL line. The verdict and exit
        # code were right, but the output contradicted itself and anything
        # grepping for the PASS line was misled. An explicit flag instead.
        offsets_ok = True
        for policy, label in (("policy1", "ota"), ("policy6", "kernel"), ("policy7", "kernel2"),
                              ("policy8", "rootfs"), ("policy9", "rootfs2"), ("policy2", "sn_mac")):
            got = ini_value(profile, policy, "offset")
            want = layout.partition_offset(label)
            if got is None or int(got, 0) != want:
                bad("%s (%s) offset is unchanged at 0x%x" % (policy, label, want), "got %r" % got)
                offsets_ok = False
        if offsets_ok:
            ok("every partition offset in the Cloner profile is unchanged vendor geometry")

    # --- sn_mac preservation: checked on EVERY path ------------------------
    #
    # This block used to sit inside `if slot_b:`. An independent review
    # demonstrated the consequence: a --slot a package carrying a full-device
    # erase_list validated clean. The one irreversible property must not be
    # conditional on which slot mode was used, so it is checked here, against
    # the profile bytes actually inside the package.
    if CLONER_PROFILE_ENTRY in pkg_names:
        shipped = pkg.read(CLONER_PROFILE_ENTRY)
        erase = ini_value(shipped, "mmc", "erase_list")
        if erase and layout.erase_list_preserves_sn_mac(erase):
            ok("the erase policy in the package leaves sn_mac (0x%x..0x%x) untouched: %s"
               % (*layout.SN_MAC_PRESERVED_RANGE, erase))
        else:
            bad("the erase policy in the package leaves sn_mac untouched",
                "erase_list=%r would erase across the per-unit factory MAC/serial, "
                "which cannot be regenerated" % erase)

        # sn_mac's own policy must stay disabled - it is never programmed.
        if ini_value(shipped, "policy2", "enabled") == "0":
            ok("the sn_mac policy remains disabled (never programmed)")
        else:
            bad("the sn_mac policy remains disabled (never programmed)",
                "policy2 enabled=%s" % ini_value(shipped, "policy2", "enabled"))
    else:
        bad("the package carries a Cloner profile to check the erase policy against")

    pkg.close()
    tpl.close()
    return report()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
