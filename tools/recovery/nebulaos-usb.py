#!/usr/bin/env python3
"""nebulaos-usb - install NebulaOS and switch boot slots over USB recovery.

The backbone of the future end-user flasher (Windows/macOS/Linux): stdlib
Python around the pinned, patched ballaswag/ingenic-usbboot
(manifests/dependencies.conf INGENIC_USBBOOT_*), which talks to the X2000E
boot ROM over libusb. Unlike the Ingenic Cloner's .ingenic, which erases the
whole eMMC except sn_mac, this touches exactly three things:

    the kernel partition of ONE slot   (A: kernel  0xb00000,  B: kernel2 0x1300000)
    the rootfs partition of that slot  (A: rootfs  0x1b00000, B: rootfs2 0x20f00000)
    the OTA boot marker                (ota 0x100000)

Never uboot, sn_mac, rtos/rtos2 or the data partitions. Offsets and capacities
come from tools/emmc/nebulaos_layout.py (VERIFIED against the vendor Cloner
profile and real hardware) and are cross-checked here at start-up.

    sudo python3 nebulaos-usb.py marker
    sudo python3 nebulaos-usb.py set-slot A|B
    sudo python3 nebulaos-usb.py flash A|B --build /var/tmp/nebulaos-build/<sha>/run-<id> [--no-switch]
    sudo python3 nebulaos-usb.py flash A|B --ximage F --rootfs F --ximage-sha256 H --rootfs-sha256 H

flash checks before writing anything: the payload hashes against the build's
attestation (.nebulaos-build-verified) or the given hashes; a MIPS U-Boot
kernel image and a squashfs; both fit their partitions. It writes with
usbboot's per-chunk read-back verification, then reads both partitions back
whole and compares SHA-256 with the payload, and only then points the marker
at the slot (verified by reading the marker's bytes).

The Pad must be in USB recovery mode (MicroUSB to the PC; power off; hold both
buttons next to the port 3 s, release reset first, power on; `lsusb` shows
a108:eaef). u-boot is loaded once per power cycle; a second upload fails
until the next power cycle, so a failed load after a successful one is not an
error. Raw USB access needs root (sudo) on Linux.

exit 0 done and verified | 1 failed or not verified (do not boot) | 64 usage
"""

import argparse
import hashlib
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FW = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(FW, "tools", "emmc"))
import nebulaos_layout as layout  # noqa: E402

SLOTS = {
    "A": {"kernel": "kernel", "rootfs": "rootfs", "marker": b"ota:kernel"},
    "B": {"kernel": "kernel2", "rootfs": "rootfs2", "marker": b"ota:kernel2"},
}
OTA_OFFSET, OTA_DUMP = 0x100000, 0x1000
UIMAGE_MAGIC, MIPS = 0x27051956, 5
SQUASHFS_MAGIC = b"hsqs"
NEVER = ("uboot", "sn_mac", "rtos", "rtos2")


class Fail(Exception):
    pass


def say(msg):
    print(msg, flush=True)


def default_usbboot():
    env = os.environ.get("USBBOOT")
    if env:
        return env
    ws = os.path.dirname(FW)
    return os.path.join(ws, "_tools", "ingenic-usbboot", "usbboot")


def check_layout():
    """The slot targets must be the VERIFIED partitions and stay clear of
    everything this tool never writes."""
    spans = []
    for slot in SLOTS.values():
        for label in (slot["kernel"], slot["rootfs"]):
            off, size = layout.partition_offset(label), layout.partition_size(label)
            spans.append((label, off, off + size))
    for label in NEVER:
        off = layout.partition_offset(label)
        for name, start, end in spans:
            if start <= off < end:
                raise Fail("layout: %s would overlap %s - refusing" % (name, label))
    lo, hi = layout.SN_MAC_PRESERVED_RANGE
    for name, start, end in spans + [("ota", OTA_OFFSET, OTA_OFFSET + OTA_DUMP)]:
        if start <= hi and end > lo:
            raise Fail("layout: %s would touch sn_mac - refusing" % name)
    if layout.partition_offset("ota") != OTA_OFFSET:
        raise Fail("layout: the ota offset disagrees with nebulaos_layout")


class UsbBoot:
    def __init__(self, path):
        if not os.access(path, os.X_OK):
            raise Fail("usbboot not found at %s (set USBBOOT=..., built from the pinned patched "
                       "ingenic-usbboot)" % path)
        self.path = path
        self.cwd = os.path.dirname(path)     # spl.bin / uboot.bin live next to it
        self.loaded = False

    def run(self, args, check=True):
        p = subprocess.run([self.path] + args, cwd=self.cwd, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, universal_newlines=True)
        if check and p.returncode != 0:
            raise Fail("usbboot %s failed:\n%s" % (" ".join(args), p.stdout[-1500:]))
        return p

    def load_uboot(self):
        if self.loaded:
            return
        p = self.run(["--uboot"], check=False)
        if p.returncode != 0:
            # Already running from an earlier call in this power cycle? A
            # short read only works with u-boot up.
            probe = os.path.join(self.cwd, ".nebulaos-usb-probe")
            q = self.run(["-o", hex(OTA_OFFSET), "-s", hex(OTA_DUMP), "--dump-partition", probe],
                         check=False)
            ok = q.returncode == 0 and os.path.exists(probe) and os.path.getsize(probe) == OTA_DUMP
            if os.path.exists(probe):
                os.unlink(probe)
            if ok:
                say("UBOOT=already running")
                self.loaded = True
                return
            raise Fail("u-boot could not be loaded - is the Pad in USB recovery mode "
                       "(lsusb: a108:eaef)? Once u-boot runs, a second load fails until the "
                       "next power cycle.\n%s" % p.stdout[-800:])
        self.loaded = True

    def dump(self, offset, size, path):
        if os.path.exists(path):
            os.unlink(path)
        self.run(["-o", hex(offset), "-s", hex(size), "--dump-partition", path])
        if not os.path.exists(path) or os.path.getsize(path) != size:
            raise Fail("reading 0x%x bytes at 0x%x returned no or short data" % (size, offset))

    def write(self, offset, path):
        size = os.path.getsize(path)
        p = self.run(["-o", hex(offset), "-s", hex(size), "--write-partition", path])
        if "write complete and verified" not in p.stdout:
            raise Fail("write at 0x%x did not report a verified completion:\n%s"
                       % (offset, p.stdout[-800:]))


def sha256(path, length=None):
    h = hashlib.sha256()
    left = length
    with open(path, "rb") as f:
        while left is None or left > 0:
            block = f.read(1 << 20 if left is None else min(1 << 20, left))
            if not block:
                break
            h.update(block)
            if left is not None:
                left -= len(block)
    return h.hexdigest()


def read_marker(usb, tmp):
    path = os.path.join(tmp, "ota.bin")
    usb.dump(OTA_OFFSET, OTA_DUMP, path)
    with open(path, "rb") as f:
        line = f.read(64).split(b"\n", 1)[0].rstrip(b"\0")
    for slot, s in SLOTS.items():
        if line == s["marker"]:
            return slot, line
    return None, line


def set_slot(usb, tmp, want):
    usb.load_uboot()
    now, raw = read_marker(usb, tmp)
    say("MARKER_BEFORE=%s (%r)" % (now or "UNKNOWN", raw[:20]))
    if now is None:
        raise Fail("the marker holds neither ota:kernel nor ota:kernel2 - nothing changed")
    if now != want:
        usb.run(["--swap-ota"])          # toggles; it cannot pick a side
        now, raw = read_marker(usb, tmp)
        say("MARKER_AFTER=%s (%r)" % (now or "UNKNOWN", raw[:20]))
    if now != want:
        raise Fail("the marker reads slot %s, not %s - do not boot" % (now, want))
    say("MARKER=OK slot %s (%s)" % (want, SLOTS[want]["marker"].decode()))


def build_payload(args):
    if args.build:
        att = os.path.join(args.build, ".nebulaos-build-verified")
        facts = {}
        try:
            with open(att) as f:
                for line in f:
                    k, _, v = line.strip().partition("=")
                    facts[k] = v
        except OSError:
            raise Fail("no build attestation at %s" % att)
        if facts.get("BUILD_VERIFIED") != "YES":
            raise Fail("the build at %s is not attested BUILD_VERIFIED=YES" % args.build)
        art = os.path.join(args.build, "artifacts", "buildroot-halley5-v30-image")
        return (os.path.join(art, "xImage"), os.path.join(art, "rootfs.squashfs"),
                facts.get("XIMAGE_SHA256"), facts.get("ROOTFS_SQUASHFS_SHA256"),
                facts.get("SOURCE_HEAD", "unknown"))
    if not (args.ximage and args.rootfs and args.ximage_sha256 and args.rootfs_sha256):
        raise Fail("give --build <run dir>, or --ximage/--rootfs with both --*-sha256")
    return args.ximage, args.rootfs, args.ximage_sha256, args.rootfs_sha256, "unknown"


def check_payload(slot, ximage, rootfs, xsha, rsha):
    s = SLOTS[slot]
    for path, want, label in ((ximage, xsha, s["kernel"]), (rootfs, rsha, s["rootfs"])):
        if not os.path.isfile(path):
            raise Fail("missing %s" % path)
        got = sha256(path)
        if got != want:
            raise Fail("%s hashes %s, expected %s" % (path, got[:16], (want or "?")[:16]))
        cap = layout.partition_size(label)
        if os.path.getsize(path) > cap:
            raise Fail("%s (%d bytes) does not fit %s (%d bytes)"
                       % (path, os.path.getsize(path), label, cap))
    with open(ximage, "rb") as f:
        head = f.read(64)
    if len(head) < 64 or struct.unpack(">I", head[:4])[0] != UIMAGE_MAGIC or head[29] != MIPS:
        raise Fail("%s is not a MIPS U-Boot kernel image" % ximage)
    with open(rootfs, "rb") as f:
        if f.read(4) != SQUASHFS_MAGIC:
            raise Fail("%s is not a squashfs image" % rootfs)
    name = head[32:64].split(b"\0", 1)[0].decode("ascii", "replace")
    say("PAYLOAD_KERNEL=%s (%d bytes) sha256=%s" % (name, os.path.getsize(ximage), xsha))
    say("PAYLOAD_ROOTFS=%d bytes sha256=%s" % (os.path.getsize(rootfs), rsha))


def flash(usb, tmp, slot, ximage, rootfs, xsha, rsha, switch):
    s = SLOTS[slot]
    usb.load_uboot()
    now, _ = read_marker(usb, tmp)
    say("MARKER_NOW=slot %s" % (now or "UNKNOWN"))
    for path, want, label in ((ximage, xsha, s["kernel"]), (rootfs, rsha, s["rootfs"])):
        off = layout.partition_offset(label)
        say("WRITING %s -> %s at 0x%x (%d bytes)" % (os.path.basename(path), label, off,
                                                    os.path.getsize(path)))
        usb.write(off, path)
        back = os.path.join(tmp, label + ".readback")
        usb.dump(off, os.path.getsize(path), back)
        got = sha256(back)
        os.unlink(back)
        if got != want:
            raise Fail("%s reads back as %s, expected %s - do not boot this slot"
                       % (label, got[:16], want[:16]))
        say("VERIFIED %s sha256=%s" % (label, got))
    if switch:
        set_slot(usb, tmp, slot)
    else:
        say("MARKER_UNCHANGED (--no-switch)")


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("marker")
    p = sub.add_parser("set-slot")
    p.add_argument("slot", choices=sorted(SLOTS))
    p = sub.add_parser("flash")
    p.add_argument("slot", choices=sorted(SLOTS))
    p.add_argument("--build")
    p.add_argument("--ximage")
    p.add_argument("--rootfs")
    p.add_argument("--ximage-sha256")
    p.add_argument("--rootfs-sha256")
    p.add_argument("--no-switch", action="store_true")
    ap.add_argument("--usbboot", default=default_usbboot())
    args = ap.parse_args(argv)
    if not args.cmd:
        ap.print_help()
        return 64
    try:
        check_layout()
        with tempfile.TemporaryDirectory(prefix="nebulaos-usb.") as tmp:
            if args.cmd == "flash":
                ximage, rootfs, xsha, rsha, head = build_payload(args)
                say("SOURCE_HEAD=%s TARGET_SLOT=%s" % (head, args.slot))
                check_payload(args.slot, ximage, rootfs, xsha, rsha)
            usb = UsbBoot(args.usbboot)
            if args.cmd == "marker":
                usb.load_uboot()
                now, raw = read_marker(usb, tmp)
                say("MARKER=%s (%r)" % (now or "UNKNOWN", raw[:20]))
            elif args.cmd == "set-slot":
                set_slot(usb, tmp, args.slot)
            else:
                flash(usb, tmp, args.slot, ximage, rootfs, xsha, rsha, not args.no_switch)
        say("RESULT=OK")
        return 0
    except Fail as exc:
        say("RESULT=NOT_OK %s" % exc)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
