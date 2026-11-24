# #27 framebuffer write-combining stress: SECONDS of large writes (and some
# reads) into the last third of /dev/fb0's mapping, the off-screen frame of
# the triple buffer. The mapping's cache mode comes from the kernel's
# ingenicfb_mmap (test build 3: CCA 1 write-combining; test build 4:
# ingenicfb.fb_cca, default 0 as stock). Nothing else is touched.
import mmap, os, sys, time
S = int(sys.argv[1]); TAG = sys.argv[2] if len(sys.argv) > 2 else ""
g = "/sys/class/graphics/fb0/"
stride = int(open(g + "stride").read())
yv = int(open(g + "virtual_size").read().split(",")[1])
fd = os.open("/dev/fb0", os.O_RDWR)
m = mmap.mmap(fd, stride * yv)
off = stride * (yv - yv // 3)
n = stride * (yv // 3)
pats = [bytes([i]) * n for i in (0x00, 0x5a, 0xa5, 0xff)]
t0 = last = time.monotonic(); w = r = 0
while time.monotonic() < t0 + S:
    for p in pats:
        m[off:off + n] = p
        w += 1
    m[off:off + 65536]
    r += 1
    if time.monotonic() - last >= 60:
        last = time.monotonic()
        print("FBWC%s t=%.0f writes=%d reads=%d bytes=%d" % (TAG, last - t0, w, r, w * n), flush=True)
print("FBWC%s done t=%.0f writes=%d" % (TAG, time.monotonic() - t0, w), flush=True)
