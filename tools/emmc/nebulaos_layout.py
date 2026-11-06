"""The Ender-3 V3 KE eMMC layout, with per-fact provenance.

WHERE THESE NUMBERS COME FROM

The vendor's own Ingenic Cloner profile, inside the official recovery package:

    configs/x2000/x2000e_mmc0_lpddr2_linux.cfg
    in Ender-3_V3_KE_1.1.0.12.ingenic
    (pinned by content in manifests/dependencies.conf)

Its [policy0..policy9] sections name every partition and its absolute byte
offset outright:

    uboot   0x0        ota     0x100000   sn_mac  0x200000
    rtos    0x300000   rtos2   0x700000   kernel  0xb00000
    kernel2 0x1300000  rootfs  0x1b00000  rootfs2 0x20f00000

That is a stronger source than anything this project had before, and it
corroborates an independent one. The two slot capacities derived from those
offsets equal, exactly, the constants scripts/flash-spare-slot.sh has enforced
against real hardware since long before this module existed:

    0x1300000 - 0xb00000  = 8388608     == KERNEL_PART_BYTES
    0x20f00000 - 0x1b00000 = 524288000  == ROOTFS_PART_BYTES

Two unrelated sources agreeing to the byte is what makes these VERIFIED rather
than merely plausible. assert_agrees_with_flash_script() below re-derives that
agreement from the shell script's own text, so the two copies cannot drift apart
silently.

WHAT IS STILL NOT KNOWN

The eMMC's total capacity, and therefore the size of userdata; the exact size of
rootfs_data (the docs say "300 MB", which is prose); every partition type GUID;
and which of the ten recorded PARTUUIDs belongs to which partition. None of that
is needed to write slot 2, which is the only thing this project writes.

sn_mac IS THE ONE THAT CANNOT BE UNDONE

/dev/mmcblk0p2 holds the per-unit factory MAC and serial number. A bounded
read on the reference unit returned

    26090000000001;FCEE11000001;F005;NEBULA V1.0.0.1;;;;;

and stock's wlan0 uses exactly fc:ee:11:00:00:01. The value is programmed per
unit, exists nowhere else on the device, and cannot be regenerated. The vendor's
own erase policy deliberately skips it, and erase_list_preserves_sn_mac() exists
so that no package this project builds can close that gap.

SCOPE OF THIS MODULE

It is a fact table and two small helpers. An earlier revision also carried a GPT
parser and a GPT builder, written for a raw-disk-image approach that was
abandoned once the real .img format turned out to be the Creality OTA package.
Both were left behind, referenced by nothing, and one of them documented
behaviour that no longer existed. They have been removed rather than kept "in
case": dead code that describes a design the project rejected is worse than no
code at all.
"""

import os
import re

VERIFIED = "VERIFIED_FROM_HARDWARE"
DECLARED = "DECLARED_UNVERIFIED"


class LayoutFact:
    """One statement about the layout, carrying how we know it."""

    __slots__ = ("name", "value", "provenance", "source")

    def __init__(self, name, value, provenance, source):
        self.name = name
        self.value = value
        self.provenance = provenance
        self.source = source

    def __repr__(self):
        return "LayoutFact(%s=%r %s)" % (self.name, self.value, self.provenance)


# Absolute byte offsets, straight from the vendor Cloner profile. Kept as a
# first-class table rather than derived from sizes: a size list cannot express
# the 1 MiB uboot region before ota, and getting that wrong shifts everything
# after it.
PARTITION_OFFSETS = (
    LayoutFact("uboot", 0x0, VERIFIED, "x2000e_mmc0_lpddr2_linux.cfg policy0"),
    LayoutFact("ota", 0x100000, VERIFIED, "x2000e_mmc0_lpddr2_linux.cfg policy1"),
    LayoutFact("sn_mac", 0x200000, VERIFIED, "x2000e_mmc0_lpddr2_linux.cfg policy2"),
    LayoutFact("rtos", 0x300000, VERIFIED, "x2000e_mmc0_lpddr2_linux.cfg policy4"),
    LayoutFact("rtos2", 0x700000, VERIFIED, "x2000e_mmc0_lpddr2_linux.cfg policy5"),
    LayoutFact("kernel", 0xB00000, VERIFIED, "x2000e_mmc0_lpddr2_linux.cfg policy6"),
    LayoutFact("kernel2", 0x1300000, VERIFIED, "x2000e_mmc0_lpddr2_linux.cfg policy7"),
    LayoutFact("rootfs", 0x1B00000, VERIFIED, "x2000e_mmc0_lpddr2_linux.cfg policy8"),
    LayoutFact("rootfs2", 0x20F00000, VERIFIED, "x2000e_mmc0_lpddr2_linux.cfg policy9"),
)

_OFFSET = {f.name: f.value for f in PARTITION_OFFSETS}

# Capacities. The four that matter are DERIVED from the offsets above rather
# than restated, so there is one source of truth and no opportunity for a typo
# to disagree with the evidence.
KERNEL_PART_BYTES = _OFFSET["kernel2"] - _OFFSET["kernel"]      # 8388608
ROOTFS_PART_BYTES = _OFFSET["rootfs2"] - _OFFSET["rootfs"]      # 524288000

PARTITION_SIZES = (
    LayoutFact("ota", _OFFSET["sn_mac"] - _OFFSET["ota"], VERIFIED,
               "cloner profile: 0x200000 - 0x100000"),
    # sn_mac's PARTITION is 1 MiB by the gap to rtos, but its programmed CONTENT
    # is 1024 bytes - the figure a live bounded read actually returned. The
    # content size is the useful one and the one recorded here.
    LayoutFact("sn_mac", 1024, VERIFIED,
               "NEBULAOS_WIFI_CAMERA_RT_LIVE_QUALIFICATION_REPORT.md: 1024 bytes read live"),
    LayoutFact("rtos", _OFFSET["rtos2"] - _OFFSET["rtos"], VERIFIED,
               "cloner profile: 0x700000 - 0x300000"),
    LayoutFact("rtos2", _OFFSET["kernel"] - _OFFSET["rtos2"], VERIFIED,
               "cloner profile: 0xb00000 - 0x700000"),
    LayoutFact("kernel", KERNEL_PART_BYTES, VERIFIED,
               "cloner profile offsets; equals flash-spare-slot.sh KERNEL_PART_BYTES"),
    LayoutFact("kernel2", KERNEL_PART_BYTES, VERIFIED,
               "cloner profile offsets; equals flash-spare-slot.sh KERNEL_PART_BYTES"),
    LayoutFact("rootfs", ROOTFS_PART_BYTES, VERIFIED,
               "cloner profile offsets; equals flash-spare-slot.sh ROOTFS_PART_BYTES"),
    LayoutFact("rootfs2", ROOTFS_PART_BYTES, VERIFIED,
               "cloner profile offsets; equals flash-spare-slot.sh ROOTFS_PART_BYTES"),
    # The Cloner profile stops at rootfs2 because the Cloner never programs the
    # data partitions, so these two remain prose-derived.
    LayoutFact("rootfs_data", 300 * 1024 * 1024, DECLARED,
               "docs say '300 MB'; exact bytes never captured"),
    LayoutFact("userdata", 6 * 1024 * 1024 * 1024, DECLARED,
               "docs say '~6 GB'; eMMC capacity never captured"),
)

# The vendor's full-erase policy, and the hole in it that preserves per-unit
# identity. Any erase range this project emits is checked against this.
VENDOR_ERASE_LIST = "0x0,0x1fffff;0x300000,0xffffffff;"
SN_MAC_PRESERVED_RANGE = (0x200000, 0x2FFFFF)


def partition_offset(label):
    """Absolute byte offset of a partition, from the vendor Cloner profile."""
    try:
        return _OFFSET[label]
    except KeyError:
        raise KeyError("no recorded offset for partition %r (have: %s)"
                       % (label, ", ".join(sorted(_OFFSET))))


def partition_size(label):
    for fact in PARTITION_SIZES:
        if fact.name == label:
            return fact.value
    raise KeyError("no recorded size for partition %r" % label)


def erase_list_preserves_sn_mac(erase_list):
    """True if `erase_list` leaves the whole sn_mac region untouched.

    Parses the Cloner's own "start,end;start,end;" syntax and checks that no
    range intersects sn_mac. This is the single check standing between a
    recovery flash and a printer whose factory identity is gone for good, so it
    FAILS CLOSED: anything it cannot parse is treated as not-provably-safe,
    because it is not.
    """
    lo, hi = SN_MAC_PRESERVED_RANGE
    for chunk in erase_list.strip().strip('"').split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        start_s, sep, end_s = chunk.partition(",")
        if not sep:
            return False
        try:
            start, end = int(start_s.strip(), 0), int(end_s.strip(), 0)
        except ValueError:
            return False
        if start <= hi and end >= lo:
            return False
    return True


def assert_agrees_with_flash_script(path=None):
    """Re-derive the cross-source agreement instead of asserting it in a comment.

    scripts/flash-spare-slot.sh carries its own KERNEL_PART_BYTES and
    ROOTFS_PART_BYTES. It runs ON the device, in shell, and cannot import this
    module, so that duplication is structural rather than careless - but a
    duplication nobody checks is one that drifts. This reads the shell script's
    own text and compares.

    Returns a list of human-readable agreement lines; raises ValueError on any
    disagreement.
    """
    if path is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "..", "scripts", "flash-spare-slot.sh")
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()

    notes = []
    for name, ours in (("KERNEL_PART_BYTES", KERNEL_PART_BYTES),
                       ("ROOTFS_PART_BYTES", ROOTFS_PART_BYTES)):
        match = re.search(r"^%s=(\d+)" % name, text, re.M)
        if not match:
            raise ValueError("%s not found in %s" % (name, path))
        theirs = int(match.group(1))
        if theirs != ours:
            raise ValueError(
                "%s disagrees: this module derives %d from the vendor Cloner offsets, "
                "flash-spare-slot.sh says %d" % (name, ours, theirs))
        notes.append("%s=%d agrees (vendor offsets and flash-spare-slot.sh)" % (name, ours))
    return notes
