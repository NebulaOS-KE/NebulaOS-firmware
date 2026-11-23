# #27 MCU link soak: debug_nop bursts + debug_ping for SECONDS (nothing moves or heats)
import sys, time
sys.path.insert(0, "/etc/nebulaos")
import mcu_application_identify as app
S = int(sys.argv[1])
def up():
    return open("/proc/uptime").read().split()[0]
def action(sr):
    t0 = last = time.monotonic(); n = p = 0
    ping = "debug_ping data=" + "a5" * 40
    print("SOAK_START s=%d %s" % (S, sr.stats(sr.reactor.monotonic())), flush=True)
    while time.monotonic() < t0 + S:
        for _ in range(2000):
            sr.send("debug_nop")
        n += 2000
        for _ in range(20):
            sr.send_with_response(ping, "pong")
        p += 20
        if time.monotonic() - last >= 60:
            last = time.monotonic()
            print("SOAK t=%.0f nop=%d ping=%d up=%s %s" % (last - t0, n, p, up(), sr.stats(sr.reactor.monotonic())), flush=True)
    return ["SOAK_DONE t=%.0f nop=%d ping=%d" % (time.monotonic() - t0, n, p)]
for l in app.run_connected("/dev/ttyS1", 230400, action, timeout=10.0, klippy_lib_path="/opt/klipper/klippy"):
    print(l, flush=True)
