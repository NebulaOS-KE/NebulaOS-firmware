#!/usr/bin/env python3
"""tools/recovery/nebulaos-usb.py against a fake usbboot whose "eMMC" is a
sparse file - never a device. Proves: only the chosen slot's kernel/rootfs and
the marker change; payload hashes, formats and sizes are checked before any
write; read-back mismatches refuse to switch; u-boot is loaded once.

Run: python3 tests/nebulaos-usb-tests.py
"""
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile

FW = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(FW, "tools", "recovery", "nebulaos-usb.py")
PASS = FAIL = 0

FAKE = r'''#!/usr/bin/env python3
import os, sys
st = os.environ["FAKE_STATE"]
emmc = os.path.join(st, "emmc.bin")
log = open(os.path.join(st, "calls"), "a")
log.write(" ".join(sys.argv[1:]) + "\n")
a = sys.argv[1:]
def opt(n):
    return int(a[a.index(n) + 1], 16)
if a == ["--uboot"]:
    flag = os.path.join(st, "uboot")
    if os.path.exists(flag):
        print("Could not open USB device"); sys.exit(1)
    open(flag, "w").close(); print("u-boot loaded"); sys.exit(0)
if not os.path.exists(os.path.join(st, "uboot")):
    print("Could not open USB device"); sys.exit(1)
if "--dump-partition" in a:
    off, size = opt("-o"), opt("-s")
    with open(emmc, "rb") as f:
        f.seek(off); data = f.read(size)
    if os.environ.get("FAKE_CORRUPT_READ") and size > 0x1000:
        data = b"X" + data[1:]
    open(a[a.index("--dump-partition") + 1], "wb").write(data); sys.exit(0)
if "--write-partition" in a:
    off, size = opt("-o"), opt("-s")
    fails = os.path.join(st, "write-fails")
    n = int(open(fails).read()) if os.path.exists(fails) else int(os.environ.get("FAKE_WRITE_FAILS", "0"))
    if n > 0:
        open(fails, "w").write(str(n - 1))
        print("Request 0x12 failed, only transfered: -7"); sys.exit(1)
    open(fails, "w").write("0")
    data = open(a[a.index("--write-partition") + 1], "rb").read()
    if len(data) != size:
        print("does not match requested length"); sys.exit(1)
    with open(emmc, "r+b") as f:
        f.seek(off); f.write(data)
    print("write complete and verified: all %d bytes" % size); sys.exit(0)
if a == ["--swap-ota"]:
    with open(emmc, "r+b") as f:
        f.seek(0x100000); cur = f.read(64).split(b"\n")[0]
        new = b"ota:kernel" if cur == b"ota:kernel2" else b"ota:kernel2"
        f.seek(0x100000); f.write(new + b"\n\n" + b"\0" * (64 - len(new) - 2))
    sys.exit(0)
print("unknown args"); sys.exit(2)
'''


def check(name, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
    else:
        FAIL += 1
        print("FAIL: %s %s" % (name, detail))


def setup():
    t = tempfile.mkdtemp(prefix="nebulaos-usb-tests.")
    st = os.path.join(t, "state")
    os.makedirs(st)
    with open(os.path.join(st, "emmc.bin"), "wb") as f:
        f.truncate(0x20F00000 + 600 * 1048576)
        f.seek(0x100000)
        f.write(b"ota:kernel2\n\n")
        for off, fill in ((0x0, b"U"), (0x200000, b"S"), (0x300000, b"R"), (0x700000, b"Q")):
            f.seek(off)
            f.write(fill * 4096)
    usb = os.path.join(t, "usbboot")
    open(usb, "w").write(FAKE)
    os.chmod(usb, 0o755)
    run = os.path.join(t, "run")
    art = os.path.join(run, "artifacts", "buildroot-halley5-v30-image")
    os.makedirs(art)
    head = bytearray(64)
    struct.pack_into(">I", head, 0, 0x27051956)
    head[29] = 5
    head[32:50] = b"Linux-6.6.157-rt79"
    xi = bytes(head) + os.urandom(3 * 1048576 + 77)
    rf = b"hsqs" + os.urandom(5 * 1048576 + 13)
    open(os.path.join(art, "xImage"), "wb").write(xi)
    open(os.path.join(art, "rootfs.squashfs"), "wb").write(rf)
    open(os.path.join(run, ".nebulaos-build-verified"), "w").write(
        "BUILD_VERIFIED=YES\nSOURCE_HEAD=%s\nXIMAGE_SHA256=%s\nROOTFS_SQUASHFS_SHA256=%s\n"
        % ("a" * 40, hashlib.sha256(xi).hexdigest(), hashlib.sha256(rf).hexdigest()))
    return t, st, usb, run, xi, rf


def tool(usb, st, *args, env=None):
    e = dict(os.environ, FAKE_STATE=st)
    e.update(env or {})
    p = subprocess.run([sys.executable, TOOL, "--usbboot", usb] + list(args), env=e,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    return p.returncode, p.stdout


def region(st, off, size):
    with open(os.path.join(st, "emmc.bin"), "rb") as f:
        f.seek(off)
        return f.read(size)


def untouched(st):
    return (region(st, 0x0, 4096) == b"U" * 4096 and region(st, 0x200000, 4096) == b"S" * 4096
            and region(st, 0x300000, 4096) == b"R" * 4096 and region(st, 0x700000, 4096) == b"Q" * 4096)


# 1. flash slot A from a running-B marker: A's partitions get the payload, marker -> A
t, st, usb, run, xi, rf = setup()
try:
    rc, out = tool(usb, st, "flash", "A", "--build", run)
    check("flash A succeeds", rc == 0 and "RESULT=OK" in out, out[-600:])
    check("kernel at 0xb00000", region(st, 0xB00000, len(xi)) == xi)
    check("rootfs at 0x1b00000", region(st, 0x1B00000, len(rf)) == rf)
    check("marker now ota:kernel", region(st, 0x100000, 12) == b"ota:kernel\n\n")
    check("slot B untouched", region(st, 0x1300000, 16) == b"\0" * 16 and region(st, 0x20F00000, 16) == b"\0" * 16)
    check("uboot, sn_mac, rtos, rtos2 untouched", untouched(st))
    calls = open(os.path.join(st, "calls")).read().splitlines()
    check("u-boot loaded exactly once", calls.count("--uboot") == 1, str(calls))
    # 2. set-slot B, then again (idempotent: no second swap)
    rc, out = tool(usb, st, "set-slot", "B")
    check("set-slot B", rc == 0 and region(st, 0x100000, 13) == b"ota:kernel2\n\n", out[-300:])
    n = open(os.path.join(st, "calls")).read().count("--swap-ota")
    rc, out = tool(usb, st, "set-slot", "B")
    check("set-slot B again does not swap", rc == 0 and open(os.path.join(st, "calls")).read().count("--swap-ota") == n)
    rc, out = tool(usb, st, "marker")
    check("marker reads B", "MARKER=B" in out, out[-200:])
finally:
    shutil.rmtree(t, ignore_errors=True)

# 3. a payload that does not match its attestation is refused before any USB call
t, st, usb, run, xi, rf = setup()
try:
    art = os.path.join(run, "artifacts", "buildroot-halley5-v30-image")
    open(os.path.join(art, "xImage"), "ab").write(b"tampered")
    rc, out = tool(usb, st, "flash", "B", "--build", run)
    check("hash mismatch refused", rc == 1 and "expected" in out, out[-300:])
    check("no USB call before the payload is proven", not os.path.exists(os.path.join(st, "calls")))
finally:
    shutil.rmtree(t, ignore_errors=True)

# 4. non-MIPS kernel and non-squashfs rootfs refused
for what in ("kernel", "rootfs"):
    t, st, usb, run, xi, rf = setup()
    try:
        art = os.path.join(run, "artifacts", "buildroot-halley5-v30-image")
        if what == "kernel":
            bad = bytearray(xi); bad[29] = 2; path = os.path.join(art, "xImage"); key = "XIMAGE_SHA256"
        else:
            bad = bytearray(rf); bad[:4] = b"XXXX"; path = os.path.join(art, "rootfs.squashfs"); key = "ROOTFS_SQUASHFS_SHA256"
        open(path, "wb").write(bytes(bad))
        att = open(os.path.join(run, ".nebulaos-build-verified")).read().splitlines()
        att = [l if not l.startswith(key) else "%s=%s" % (key, hashlib.sha256(bad).hexdigest()) for l in att]
        open(os.path.join(run, ".nebulaos-build-verified"), "w").write("\n".join(att) + "\n")
        rc, out = tool(usb, st, "flash", "B", "--build", run)
        check("bad %s refused" % what, rc == 1 and ("MIPS" in out or "squashfs" in out), out[-300:])
    finally:
        shutil.rmtree(t, ignore_errors=True)

# 5. a read-back mismatch never switches the marker
t, st, usb, run, xi, rf = setup()
try:
    rc, out = tool(usb, st, "flash", "A", "--build", run, env={"FAKE_CORRUPT_READ": "1"})
    check("read-back mismatch fails", rc == 1 and "reads back" in out, out[-300:])
    check("marker unchanged after a failed verify", region(st, 0x100000, 13) == b"ota:kernel2\n\n")
finally:
    shutil.rmtree(t, ignore_errors=True)

# 6. --no-switch writes but leaves the marker; an unattested build is refused
t, st, usb, run, xi, rf = setup()
try:
    rc, out = tool(usb, st, "flash", "A", "--build", run, "--no-switch")
    check("--no-switch", rc == 0 and region(st, 0x100000, 13) == b"ota:kernel2\n\n" and region(st, 0xB00000, len(xi)) == xi, out[-300:])
    open(os.path.join(run, ".nebulaos-build-verified"), "w").write("BUILD_VERIFIED=NO\n")
    rc, out = tool(usb, st, "flash", "A", "--build", run)
    check("unattested build refused", rc == 1 and "BUILD_VERIFIED" in out, out[-300:])
finally:
    shutil.rmtree(t, ignore_errors=True)

# 7. a transient USB timeout during a write is retried (ke-dev 2026-10-15)
t, st, usb, run, xi, rf = setup()
try:
    rc, out = tool(usb, st, "flash", "A", "--build", run,
                   env={"FAKE_WRITE_FAILS": "2", "NEBULAOS_USB_PAUSE": "0"})
    check("transient write failures are retried", rc == 0 and out.count("RETRY write") == 2
          and region(st, 0xB00000, len(xi)) == xi and region(st, 0x100000, 12) == b"ota:kernel\n\n", out[-500:])
finally:
    shutil.rmtree(t, ignore_errors=True)
t, st, usb, run, xi, rf = setup()
try:
    rc, out = tool(usb, st, "flash", "A", "--build", run,
                   env={"FAKE_WRITE_FAILS": "9", "NEBULAOS_USB_PAUSE": "0"})
    check("persistent write failure gives up and never switches", rc == 1
          and region(st, 0x100000, 13) == b"ota:kernel2\n\n", out[-300:])
finally:
    shutil.rmtree(t, ignore_errors=True)

print("nebulaos-usb-tests: PASS=%d FAIL=%d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
