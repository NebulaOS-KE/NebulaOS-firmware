# #27 trigger search: hammer ONE hardware operation on CPU0 while CPU1 runs a
# klippy-like Python load (both hardware threads busy, as while printing).
# usage: smtstress.py MODE SECONDS     MODE: cacheflush tlb spawn pingpong dma load
# A line every 10 s; a freeze shows as the lines stopping. Nothing moves or
# heats; the only device access is reading the eMMC (and a USB stick if
# present) in dma mode, read-only.
import ctypes, mmap, os, random, sys, time

MODE, SECS = sys.argv[1], int(sys.argv[2])
END = time.monotonic() + SECS
libc = ctypes.CDLL(None, use_errno=True)


def pin(cpu):
    os.sched_setaffinity(0, {cpu})


def load(tag):  # klippy-like: floats, dicts, lists, small syscalls
    pin(1)
    n, d, last = 0, {}, time.monotonic()
    while time.monotonic() < END:
        x = 0.0
        for i in range(2000):
            x += (i * 1.000123) / (i + 1.5)
            d[i % 257] = [x, i, str(i)]
        n += 1
        if time.monotonic() - last >= 10:
            last = time.monotonic()
            print("SMT %s load t=%.0f iters=%d" % (tag, last - END + SECS, n), flush=True)


def hammer_cacheflush():  # MIPS cacheflush(2): L1 writeback/invalidate, small (hit) and large (index) ranges
    buf = mmap.mmap(-1, 1 << 20)
    addr = ctypes.addressof(ctypes.c_char.from_buffer(buf))
    fn = getattr(libc, "cacheflush", None)
    ops = 0
    while time.monotonic() < END:
        for n in (4096, 65536, 1 << 20):
            buf[0:n:4096] = b"x" * len(range(0, n, 4096))
            if fn is not None:
                fn(ctypes.c_void_p(addr), n, 3)  # BCACHE
            else:
                libc.syscall(4147, ctypes.c_void_p(addr), n, 3)  # __NR_cacheflush (o32)
            ops += 1
        yield ops


def hammer_tlb():  # map, touch every page, drop the pages (TLB invalidates), unmap
    ops = 0
    while time.monotonic() < END:
        m = mmap.mmap(-1, 4 << 20)
        for off in range(0, 4 << 20, 4096):
            m[off] = 1
        m.madvise(mmap.MADV_DONTNEED)
        for off in range(0, 4 << 20, 16384):
            m[off] = 2
        m.close()
        ops += 1
        yield ops


def hammer_spawn():  # program starts, like the heartbeat and load-log scripts
    ops = 0
    null = os.open("/dev/null", os.O_WRONLY)
    fa = [(os.POSIX_SPAWN_DUP2, null, 1), (os.POSIX_SPAWN_DUP2, null, 2)]
    while time.monotonic() < END:
        for argv in (["/bin/true"], ["/bin/cat", "/proc/loadavg"],
                     ["/bin/sh", "-c", "cat /proc/[0-9]*/stat | awk '{s+=$14} END {print s}'"]):
            pid = os.posix_spawn(argv[0], argv, os.environ, file_actions=fa)
            os.waitpid(pid, 0)
            ops += 1
        yield ops


def hammer_dma():  # direct (DMA) reads from the eMMC and a USB stick: cache invalidates on every read
    devs = [d for d in ("/dev/mmcblk0", "/dev/sda") if os.path.exists(d)]
    if not devs:
        print("SMT dma: no block device", flush=True)
        return
    fds = [os.open(d, os.O_RDONLY | os.O_DIRECT) for d in devs]
    sizes = [os.lseek(fd, 0, os.SEEK_END) for fd in fds]
    buf = mmap.mmap(-1, 1 << 20)
    ops = 0
    while time.monotonic() < END:
        for fd, size in zip(fds, sizes):
            n = random.choice((4096, 65536, 1 << 20))
            off = random.randrange(0, max(size - n, 1)) & ~4095
            os.preadv(fd, [memoryview(buf)[:n]], off)
            ops += 1
        yield ops


def pingpong():  # cross-thread wakeups (IPIs): a byte back and forth between CPU0 and CPU1
    a_r, a_w = os.pipe()
    b_r, b_w = os.pipe()
    if os.fork() == 0:
        os.close(a_w)
        os.close(b_r)
        try:
            pin(1)
            while os.read(a_r, 1):
                os.write(b_w, b"y")
        finally:
            os._exit(0)
    os.close(a_r)
    os.close(b_w)
    pin(0)
    ops, last = 0, time.monotonic()
    while time.monotonic() < END:
        os.write(a_w, b"x")
        if not os.read(b_r, 1):
            print("SMT pingpong: partner gone", flush=True)
            break
        ops += 1
        if time.monotonic() - last >= 10:
            last = time.monotonic()
            print("SMT pingpong t=%.0f roundtrips=%d" % (last - END + SECS, ops), flush=True)
    os.close(a_w)
    os.wait()


HAMMERS = {"cacheflush": hammer_cacheflush, "tlb": hammer_tlb, "spawn": hammer_spawn, "dma": hammer_dma}
print("SMT start mode=%s seconds=%d pid=%d" % (MODE, SECS, os.getpid()), flush=True)
if MODE == "pingpong":
    pingpong()
elif MODE == "load":
    load("load-only")
else:
    if os.fork() == 0:
        load(MODE)
        os._exit(0)
    pin(0)
    last, ops = time.monotonic(), 0
    for ops in HAMMERS[MODE]():
        if time.monotonic() - last >= 10:
            last = time.monotonic()
            print("SMT %s t=%.0f ops=%d" % (MODE, last - END + SECS, ops), flush=True)
    os.wait()
print("SMT done mode=%s" % MODE, flush=True)
