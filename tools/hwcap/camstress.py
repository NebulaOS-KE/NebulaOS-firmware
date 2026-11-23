# #27 USB/camera trigger search: every recorded freeze had a USB camera
# attached, and the same print that froze twice ran clean with USB unplugged.
# usage: camstress.py MODE SECONDS     MODE: steady cycle
#   steady  one viewer on the ustreamer MJPEG stream the whole time
#   cycle   viewer 180 s on, 90 s off: the idle controller pauses the stream
#           after ~60 s without a viewer (camera, hub and root port runtime-
#           suspend) and the next viewer resumes it, as when a browser tab
#           opens and closes
# Both: CPU1 runs a klippy-like Python load, and a USB stick (if present) is
# read with direct I/O, read only. A line every 10 s; a freeze shows as the
# lines stopping. Nothing moves or heats.
import os, random, socket, sys, time

MODE, SECS = sys.argv[1], int(sys.argv[2])
END = time.monotonic() + SECS
PORT = 8080


def say(msg):
    print("CAM %s t=%.0f %s" % (MODE, time.monotonic() - END + SECS, msg), flush=True)


PARENT = os.getpid()


def alive():  # helpers stop when the time is up or the main process is gone
    return time.monotonic() < END and os.getppid() == PARENT


def child(fn):
    pid = os.fork()
    if pid == 0:
        try:
            fn()
        finally:
            os._exit(0)
    return pid


def load():  # klippy-like: floats, dicts, lists on CPU1
    os.sched_setaffinity(0, {1})
    d = {}
    while alive():
        x = 0.0
        for i in range(2000):
            x += (i * 1.000123) / (i + 1.5)
            d[i % 257] = [x, i, str(i)]


def stick():  # direct reads from the USB stick, read only
    if not os.path.exists("/dev/sda"):
        return
    import mmap
    fd = os.open("/dev/sda", os.O_RDONLY | os.O_DIRECT)
    size = os.lseek(fd, 0, os.SEEK_END)
    buf = mmap.mmap(-1, 1 << 20)
    while alive():
        n = random.choice((4096, 65536, 1 << 20))
        os.preadv(fd, [memoryview(buf)[:n]], random.randrange(0, max(size - n, 1)) & ~4095)
        time.sleep(0.02)


def view(seconds):  # one MJPEG viewer for `seconds`; returns (bytes, frames)
    stop = min(time.monotonic() + seconds, END)
    got = frames = 0
    last = time.monotonic()
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
        s.sendall(b"GET /stream HTTP/1.0\r\nHost: localhost\r\n\r\n")
        while time.monotonic() < stop:
            b = s.recv(65536)
            if not b:
                say("stream closed by server")
                break
            got += len(b)
            frames += b.count(b"--boundarydonotcross")
            if time.monotonic() - last >= 10:
                last = time.monotonic()
                say("viewing bytes=%d frames=%d" % (got, frames))
        s.close()
    except OSError as e:
        say("stream error %s" % e)
        time.sleep(5)
    return got, frames


print("CAM start mode=%s seconds=%d stick=%s" % (MODE, SECS, os.path.exists("/dev/sda")), flush=True)
kids = [child(load), child(stick)]
cycles = 0
while time.monotonic() < END:
    if MODE == "steady":
        view(END - time.monotonic())
    else:
        got, frames = view(180)
        cycles += 1
        say("cycle=%d viewer off after bytes=%d frames=%d" % (cycles, got, frames))
        off = min(time.monotonic() + 90, END)
        while time.monotonic() < off:
            time.sleep(10)
            say("no viewer")
for k in kids:
    os.kill(k, 9)
    os.waitpid(k, 0)
print("CAM done mode=%s cycles=%d" % (MODE, cycles), flush=True)
