#!/usr/bin/env python3
# G91 step 1 and 4: the shared busy check, offline.
#
# One fake Moonraker (HTTP) and one fake Klippy (its API socket, JSON + 0x03)
# stand in for the printer. Every scenario is asked three ways and must get
# the same answer:
#   - nebulaos_osconfig.common.busy_state (Python; the [nebulaos] component
#     and the osconfig verbs),
#   - /usr/libexec/nebulaos/nebulaos-busy (its CLI for shell callers),
#   - /etc/nebulaos-busy.sh nebulaos_busy_fast (the fast shell variant of the
#     restart/recovery profiles: the supervisorctl shim, the update
#     supervisor).
# Scenarios S19-S27 of the design (_scratch/run16/G91-update-design.md) plus
# the profile table, the memguard marker rule (R3) and the shim gate (step 4:
# klipper only, Klippy dead -> allowed, timing).
#
# Usage: python3 tests/nebulaos-busy-tests.py
import http.server
import importlib
import json
import os
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import warnings

warnings.simplefilter("ignore", ResourceWarning)

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OVERLAY = os.path.join(REPO, "scripts", "build", "overlay")
PYLIB = os.path.join(OVERLAY, "usr", "lib", "nebulaos", "python")
BUSY_CLI = os.path.join(OVERLAY, "usr", "libexec", "nebulaos", "nebulaos-busy")
BUSY_LIB = os.path.join(OVERLAY, "etc", "nebulaos-busy.sh")
SHIM = os.path.join(OVERLAY, "usr", "bin", "supervisorctl")
FAST_PROFILES = ("restart", "recovery", "screen")


def unix_sockets_allowed():
    try:
        socket.socket(socket.AF_UNIX, socket.SOCK_STREAM).close()
        return True
    except OSError:
        return False


# Where AF_UNIX sockets are not allowed (the development sandbox), the fake
# Klippy is emulated one level up: in-process for the Python check, and as
# the interpreter of the shell variant's socket snippet (NB_PYTHON). On a
# normal host the real socket path runs end to end.
UNIX_SOCKETS = unix_sockets_allowed()
FAKE_SNIPPET = """#!/usr/bin/env python3
import json, os, sys, time
state, timeout = os.environ["FAKE_KLIPPY_STATE"], float(sys.argv[-1])
if not os.path.exists(state):
    print("NOT_READY"); sys.exit(0)
st = json.load(open(state))
mode = st["mode"]
if mode == "hang":
    time.sleep(timeout); print("UNKNOWN")
elif mode == "error":
    print("UNKNOWN")
elif mode != "ready":
    print("NOT_READY")
else:
    print(json.dumps({"result": {"status": st["status"]}}, separators=(",", ":")))
"""
ALL_PROFILES = ("request", "point_of_no_return", "git", "restart", "recovery", "screen")


def dead_pid():
    pid = 4000000
    while os.path.exists("/proc/%d" % pid):
        pid += 1
    return pid


class Moonraker(object):
    """GET /server/info, /printer/objects/query, /machine/update/status."""

    def __init__(self):
        self.klippy_state = "ready"
        self.status = {}
        self.query_fails = False
        self.um_busy = False
        self.hang = 0
        self.posts = []
        self.post_hang = 0
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                try:
                    self.answer()
                except (BrokenPipeError, ConnectionResetError):
                    pass                    # the client gave up (a timeout test)

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length).decode()
                if fake.post_hang:
                    time.sleep(fake.post_hang)
                fake.posts.append((self.path, self.headers.get("Content-Type"), body))
                try:
                    data = b'{"result": {"result": "SENT"}}'
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def answer(self):
                if fake.hang:
                    time.sleep(fake.hang)
                path, _, query = self.path.partition("?")
                if path == "/server/info":
                    body = {"klippy_state": fake.klippy_state,
                            "klippy_connected": fake.klippy_state != "disconnected"}
                elif path == "/machine/update/status":
                    body = {"busy": fake.um_busy, "version_info": {}}
                elif path == "/printer/objects/query":
                    if fake.query_fails or fake.klippy_state != "ready":
                        self.send_response(503)
                        self.end_headers()
                        self.wfile.write(b'{"error": {"message": "Klippy Disconnected"}}')
                        return
                    asked = [kv.split("=")[0] for kv in query.split("&") if kv]
                    status = {k: v for k, v in fake.status.items() if k in asked}
                    for k in asked:
                        status.setdefault(k, {})
                    body = {"eventtime": 1.0, "status": status}
                else:
                    self.send_response(404)
                    self.end_headers()
                    return
                data = json.dumps({"result": body}).encode()   # spaced, as Moonraker
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class EmulatedKlippy(object):
    """The same fake without a socket (see UNIX_SOCKETS)."""

    def __init__(self, path, state_file):
        self.path, self.state_file = path, state_file
        self.mode, self.status = "ready", {}

    def save(self):
        with open(self.state_file, "w") as fh:
            json.dump({"mode": self.mode, "status": self.status}, fh)

    def patch(self, common):
        fake = self

        def request(method, params, timeout):
            if fake.mode == "hang":
                time.sleep(timeout)
                raise socket.timeout("timed out")
            if fake.mode == "error":
                raise ValueError("Klippy error")
            if method == "info":
                return {"state": fake.mode}
            return {"status": {k: fake.status.get(k, {}) for k in params["objects"]}}
        common.klippy_socket_request = request
        common._socket_alive = lambda: True

    def close(self):
        if os.path.exists(self.state_file):
            os.unlink(self.state_file)


class Klippy(object):
    """Klippy's API socket: info + objects/query; modes ready, startup,
    shutdown, hang, error."""

    def __init__(self, path):
        self.path = path
        self.mode = "ready"
        self.status = {}
        fake = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                data = b""
                while True:
                    while b"\x03" not in data:
                        block = self.request.recv(4096)
                        if not block:
                            return
                        data += block
                    raw, data = data.split(b"\x03", 1)
                    req = json.loads(raw)
                    if fake.mode == "hang":
                        time.sleep(3)
                        return
                    if fake.mode == "error":
                        reply = {"id": req["id"], "error": {"message": "boom"}}
                    elif req["method"] == "info":
                        reply = {"id": req["id"], "result": {
                            "state": "ready" if fake.mode == "ready" else fake.mode}}
                    else:
                        objs = req["params"]["objects"]
                        status = {k: fake.status.get(k, {}) for k in objs}
                        reply = {"id": req["id"], "result": {"eventtime": 1.0, "status": status}}
                    self.request.sendall(json.dumps(reply).encode() + b"\x03")

        class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
            daemon_threads = True

        self.server = Server(path, Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        if os.path.exists(self.path):
            os.unlink(self.path)


class BusyTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.run_dir = os.path.join(self.tmp, "run")
        os.makedirs(os.path.join(self.run_dir, "memguard"))
        self.sock = os.path.join(self.tmp, "klippy.sock")
        self.pidfile = os.path.join(self.tmp, "klippy.pid")
        self.mr = Moonraker()
        self.klippy = None
        self.klippy_alive(True)
        self.base = self.mr.url
        for k in ("http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy",
                  "ALL_PROXY"):
            os.environ.pop(k, None)
        os.environ["no_proxy"] = os.environ["NO_PROXY"] = "*"
        self.env_common()

    def tearDown(self):
        self.mr.close()
        if self.klippy:
            self.klippy.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- fixtures ---------------------------------------------------------------

    def env_common(self):
        os.environ.update({
            "NEBULAOS_ROOT": os.path.join(self.tmp, "data"),
            "NEBULAOS_OSCONFIG_RUN": self.run_dir,
            "NEBULAOS_CMDLINE": os.path.join(self.tmp, "cmdline"),
            "NEBULAOS_MOONRAKER_BASE": self.base,
            "NEBULAOS_KLIPPY_SOCK": self.sock,
            "NEBULAOS_KLIPPY_PIDFILE": self.pidfile,
            "NEBULAOS_BUSY_TIMEOUT": "1",
        })
        if PYLIB not in sys.path:
            sys.path.insert(0, PYLIB)
        for name in list(sys.modules):
            if name.startswith("nebulaos_osconfig"):
                del sys.modules[name]
        self.c = importlib.import_module("nebulaos_osconfig.common")

    def moonraker_down(self):
        self.base = "http://127.0.0.1:9"
        self.env_common()

    def klippy_alive(self, alive):
        with open(self.pidfile, "w") as fh:
            fh.write("%d\n" % (os.getpid() if alive else dead_pid()))

    def klippy_socket(self, mode="ready", status=None):
        if self.klippy is None:
            self.klippy = (Klippy(self.sock) if UNIX_SOCKETS else
                           EmulatedKlippy(self.sock, os.path.join(self.tmp, "klippy-fake.json")))
        self.klippy.mode = mode
        self.klippy.status = status or {}
        if not UNIX_SOCKETS:
            self.klippy.save()

    def marker(self, name, on=True):
        path = os.path.join(self.run_dir, name)
        if on:
            open(path, "w").close()
        elif os.path.exists(path):
            os.unlink(path)

    def shell_env(self):
        env = dict(os.environ)
        env.update({"NEBULAOS_RUN_DIR": self.run_dir, "NB_MOONRAKER": self.base,
                    "NB_KLIPPY_PIDFILE": self.pidfile, "NB_KLIPPY_SOCK": self.sock,
                    "NB_TIMEOUT": "1", "NEBULAOS_OSCONFIG_PYTHONPATH": PYLIB})
        # BusyBox wget (the printer's) never retries; GNU wget retries a
        # timed-out request 20 times. Model the printer.
        wbin = os.path.join(self.tmp, "wbin")
        if not os.path.exists(wbin):
            os.makedirs(wbin)
            real = shutil.which("wget")
            with open(os.path.join(wbin, "wget"), "w") as fh:
                fh.write('#!/bin/sh\nexec %s --tries=1 "$@"\n' % real)
            os.chmod(os.path.join(wbin, "wget"), 0o755)
        env["PATH"] = wbin + os.pathsep + env.get("PATH", "")
        if not UNIX_SOCKETS:
            fake = os.path.join(self.tmp, "fakepy")
            if not os.path.exists(fake):
                with open(fake, "w") as fh:
                    fh.write(FAKE_SNIPPET)
                os.chmod(fake, 0o755)
            env.update({"NB_PYTHON": fake,
                        "FAKE_KLIPPY_STATE": os.path.join(self.tmp, "klippy-fake.json")})
        return env

    def emulated(self):
        return not UNIX_SOCKETS and self.klippy is not None

    # -- the three ways to ask ----------------------------------------------------

    def py(self, profile, holder=None):
        if self.emulated():
            self.klippy.patch(self.c)
        return self.c.busy_state(profile, holder)["reason"]

    def cli(self, profile, holder=None):
        argv = [sys.executable, BUSY_CLI, "--profile", profile]
        if holder:
            argv += ["--holder", holder]
        p = subprocess.run(argv, capture_output=True, text=True, env=self.shell_env(), timeout=30)
        lines = dict(l.split("=", 1) for l in p.stdout.splitlines() if "=" in l)
        reason = None if lines.get("BUSY") == "no" else lines.get("BUSY")
        self.assertEqual(p.returncode, 0 if reason is None else 1, p.stdout + p.stderr)
        return reason

    def fast(self, profile):
        p = subprocess.run(["sh", "-c", '. "$1"; nebulaos_busy_fast "$2"', "sh", BUSY_LIB, profile],
                           capture_output=True, text=True, env=self.shell_env(), timeout=30)
        out = p.stdout.strip()
        self.assertEqual(p.returncode, 0 if out else 1, p.stdout + p.stderr)
        return out or None

    def expect(self, want, profiles=ALL_PROFILES, cli=True):
        """want: a reason for every profile, or a dict profile -> reason."""
        for profile in profiles:
            w = want.get(profile) if isinstance(want, dict) else want
            self.assertEqual(self.py(profile), w, "python %s" % profile)
            if profile in FAST_PROFILES:
                self.assertEqual(self.fast(profile), w, "shell %s" % profile)
        if cli and not self.emulated():        # the CLI is its own process
            profile = "request" if "request" in profiles else profiles[0]
            w = want.get(profile) if isinstance(want, dict) else want
            self.assertEqual(self.cli(profile), w, "cli %s" % profile)

    def status(self, **objs):
        self.mr.status = objs

    # -- Klippy ready: the print, activity and calibration reasons ------------------

    def test_idle_is_not_busy(self):
        self.status(print_stats={"state": "standby"}, idle_timeout={"state": "Idle"},
                    extruder={"target": 0.0}, heater_bed={"target": 0.0})
        self.expect(None)

    def test_printing_and_paused(self):
        self.status(print_stats={"state": "printing"})
        self.expect("PRINTING")
        self.status(print_stats={"state": "paused"})
        self.expect("PAUSED")
        self.status(print_stats={"state": "complete"})
        self.expect(None)

    def test_active_sources(self):
        # R4: heater target, idle_timeout "Printing", a PLR resume
        for status in ({"extruder": {"target": 215.0}}, {"heater_bed": {"target": 60}},
                       {"idle_timeout": {"state": "Printing"}},
                       {"nebulaos_power_loss_recovery": {"resume_in_progress": True}}):
            self.status(print_stats={"state": "standby"}, **status)
            self.expect("ACTIVE", cli=False)
        self.status(nebulaos_power_loss_recovery={"resume_in_progress": False,
                                                  "candidate_pending": True})
        self.expect(None, cli=False)          # a pending resume offer is not busy

    def test_memguard_recent_activity_marker(self):
        # N6: idle_timeout dropped to Ready 0.5 s after the queue drained -
        # memguard's last 3 samples still say active.
        self.status(print_stats={"state": "standby"})
        self.marker("klipper-active")
        self.expect("ACTIVE", cli=False)

    def test_calibrating(self):
        # a "busy" boolean in the three calibration modules; a missing field
        # (extensions without it) is not calibrating
        for obj in ("nebulaos_calibration", "nebulaos_load_cell_calibration", "nebulaos_bed_tram"):
            self.status(print_stats={"state": "standby"}, **{obj: {"busy": True}})
            self.expect({"request": "CALIBRATING", "point_of_no_return": "CALIBRATING",
                         "git": "CALIBRATING", "restart": None, "recovery": None}, cli=False)
        self.status(print_stats={"state": "standby"}, nebulaos_bed_tram={"active": True})
        self.expect(None, cli=False)
        self.klippy_socket("ready", {"nebulaos_calibration": {"busy": True}})
        self.assertEqual(self.c.BUSY_OBJECTS["nebulaos_calibration"], ["busy"])

    def test_update_manager_busy(self):
        self.mr.um_busy = True
        self.expect({"request": "UPDATING", "point_of_no_return": "UPDATING", "git": None,
                     "restart": None, "recovery": None})

    def test_low_memory(self):
        self.marker("memguard/deny-maintenance")
        self.expect({"request": "LOW_MEMORY", "point_of_no_return": "LOW_MEMORY",
                     "git": "LOW_MEMORY", "restart": None, "recovery": None})

    def test_order_first_reason_wins(self):
        self.status(print_stats={"state": "paused"}, extruder={"target": 200.0},
                    nebulaos_calibration={"busy": True})
        self.mr.um_busy = True
        self.marker("memguard/deny-maintenance")
        self.expect("PAUSED")

    def test_messages(self):
        self.status(print_stats={"state": "printing"})
        st = self.c.busy_state("request")
        self.assertEqual(st, {"busy": True, "reason": "PRINTING", "profile": "request",
                              "message": "Not possible while a print is running.",
                              "klippy": "ready"})
        self.assertEqual(set(self.c.BUSY_MESSAGES), set(self.c.BUSY_REASONS))

    # -- the maintenance lock (P6, R1) ---------------------------------------------

    def test_maintenance_lock_and_holder(self):
        lock = self.c.MaintenanceLock("image-1").acquire()
        try:
            self.assertEqual(self.py("request"), "UPDATING")
            self.assertEqual(self.py("git"), "UPDATING")
            self.assertIsNone(self.py("point_of_no_return", holder="image-1"))
            self.assertEqual(self.py("point_of_no_return", holder="other"), "UPDATING")
            self.assertEqual(self.cli("request"), "UPDATING")
            self.assertIsNone(self.cli("point_of_no_return", holder="image-1"))
            for profile in FAST_PROFILES:          # a rollback outranks an update
                self.assertIsNone(self.py(profile))
                self.assertIsNone(self.fast(profile))
            with self.assertRaises(self.c.Refused) as cm:
                self.c.MaintenanceLock("second").acquire()
            self.assertEqual(cm.exception.code, "UPDATING")
        finally:
            lock.release()
        self.assertIsNone(self.py("request"))
        with self.c.MaintenanceLock("third"):
            self.assertEqual(self.c.lock_holder(self.c.MAINTENANCE_LOCK), "third")
        self.assertIsNone(self.c.lock_holder(self.c.MAINTENANCE_LOCK))

    def test_lock_dies_with_its_process(self):
        # tmpfs + flock: a killed holder never leaves a stale lock
        code = ("import sys,time; sys.path.insert(0, %r); "
                "from nebulaos_osconfig import common; "
                "common.MaintenanceLock('child').acquire(); print('held', flush=True); "
                "time.sleep(30)" % PYLIB)
        p = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, text=True,
                             env=dict(os.environ))
        try:
            self.assertEqual(p.stdout.readline().strip(), "held")
            self.assertEqual(self.py("request"), "UPDATING")
        finally:
            p.kill()
            p.wait()
        self.assertIsNone(self.py("request"))

    def test_mcu_flash_lock(self):
        import fcntl
        os.makedirs(os.path.dirname(self.c.MCU_FLASH_LOCK), exist_ok=True)
        fd = os.open(self.c.MCU_FLASH_LOCK, os.O_RDWR | os.O_CREAT)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            self.assertEqual(self.py("request"), "UPDATING")
            self.assertIsNone(self.py("recovery"))
        finally:
            os.close(fd)
        self.assertIsNone(self.py("request"))

    # -- reachability: S19-S27, N1, N3, R3 ------------------------------------------

    def test_s19_klippy_error_or_shutdown_is_not_busy(self):
        for state in ("error", "shutdown"):
            self.mr.klippy_state = state
            self.expect(None)

    def test_s27_klippy_crashed_mid_print_marker_overridden(self):
        # R3: memguard's sticky print-active marker never outlives a positive
        # "Klippy not ready".
        self.marker("print-active")
        self.marker("klipper-active")
        self.mr.klippy_state = "shutdown"
        self.expect(None)
        self.mr.klippy_state = "disconnected"       # N1: confirmed on the Klippy side
        self.klippy_alive(False)
        self.expect(None)

    def test_n1_moonraker_not_connected_asks_the_klippy_socket(self):
        for state in ("disconnected", "startup"):
            self.mr.klippy_state = state
            self.klippy_socket("ready", {"print_stats": {"state": "printing"}})
            self.expect("PRINTING")
            self.klippy_socket("startup")
            self.expect(None)

    def test_s20_klippy_alive_state_unreadable(self):
        # Moonraker down, Klippy runs but does not answer: UNKNOWN for the
        # request-type profiles and the screen; recovery only with the marker;
        # restart never (G95: a hung Klipper can always be restarted, even
        # with memguard's print marker set - only a live answer refuses).
        self.moonraker_down()
        self.klippy_socket("hang")
        self.expect({"request": "UNKNOWN", "point_of_no_return": "UNKNOWN", "git": "UNKNOWN",
                     "restart": None, "recovery": None, "screen": "UNKNOWN"})
        self.assertEqual(self.c.BUSY_MESSAGES["UNKNOWN"],
                         "Printer state unknown - not possible right now.")
        self.marker("print-active")
        self.marker("klipper-active")
        self.expect({"request": "PRINTING", "restart": None, "recovery": "PRINTING",
                     "screen": "PRINTING"},
                    profiles=("request", "restart", "recovery", "screen"), cli=False)

    def test_ready_klippy_query_fails(self):
        # N3: a failed query against a live, ready Klippy; G95: restart is
        # allowed then, even with the print marker
        self.mr.query_fails = True
        self.expect({"request": "UNKNOWN", "point_of_no_return": "UNKNOWN", "git": "UNKNOWN",
                     "restart": None, "recovery": None, "screen": "UNKNOWN"})
        self.marker("print-active")
        for profile in ("recovery", "screen"):
            self.assertEqual(self.py(profile), "PRINTING")
            self.assertEqual(self.fast(profile), "PRINTING")
        self.assertIsNone(self.py("restart"))
        self.assertIsNone(self.fast("restart"))

    def test_s25_moonraker_broken_klippy_socket_decides(self):
        # an app update broke Moonraker: the Klippy socket says idle -> the
        # supervisor may roll Moonraker back
        self.moonraker_down()
        self.klippy_socket("ready", {"print_stats": {"state": "standby"}})
        self.expect(None)
        self.klippy_socket("ready", {"print_stats": {"state": "printing"}})
        self.expect("PRINTING")
        self.klippy_socket("ready", {"extruder": {"target": 210.0}})
        self.expect("ACTIVE", cli=False)
        self.klippy_socket("error")
        self.expect({"request": "UNKNOWN", "restart": None, "recovery": None,
                     "screen": "UNKNOWN"},
                    profiles=("request", "restart", "recovery", "screen"), cli=False)

    def test_s26_no_moonraker_no_klippy(self):
        # a new image whose Moonraker never starts and Klippy is not running
        self.moonraker_down()
        self.klippy_alive(False)
        self.marker("print-active")
        self.expect(None)
        self.klippy_alive(True)                     # alive, but no socket yet
        self.expect(None)

    # -- the CLI contract -------------------------------------------------------------

    def test_cli_usage_and_output(self):
        env = self.shell_env()
        p = subprocess.run([sys.executable, BUSY_CLI, "--profile", "bogus"], capture_output=True,
                           text=True, env=env)
        self.assertEqual(p.returncode, 64)
        self.status(print_stats={"state": "printing"})
        p = subprocess.run([sys.executable, BUSY_CLI], capture_output=True, text=True, env=env)
        self.assertEqual((p.returncode, p.stdout.splitlines()[:2]),
                         (1, ["BUSY=PRINTING", "MESSAGE=Not possible while a print is running."]))
        self.status()
        p = subprocess.run([sys.executable, BUSY_CLI, "--profile", "restart"], capture_output=True,
                           text=True, env=env)
        self.assertEqual((p.returncode, p.stdout.splitlines()[0]), (0, "BUSY=no"))

    def test_cli_refuse_and_lock_exec(self):
        # G91 step 6: the CLI tools' gate (nebulaos-mcu, nebulaos-recover,
        # flash-spare-slot.sh re-exec themselves through it)
        env = self.shell_env()
        self.status(print_stats={"state": "printing"})
        p = subprocess.run([sys.executable, BUSY_CLI, "--refuse"], capture_output=True, text=True,
                           env=env)
        self.assertEqual((p.returncode, p.stdout), (3, ""))
        self.assertEqual(p.stderr, "NebulaOS refused: Not possible while a print is running. "
                                   "(PRINTING)\n")
        out = os.path.join(self.tmp, "ran")
        cmd = [sys.executable, BUSY_CLI, "--lock", "tool", "--exec", "sh", "-c",
               'echo "$NEBULAOS_MAINTENANCE_HOLDER" > "$1"; "$2" "$3" --profile request; '
               'echo "rc=$?" >> "$1"', "sh", out, sys.executable, BUSY_CLI]
        p = subprocess.run(cmd, capture_output=True, text=True, env=env)
        self.assertEqual(p.returncode, 3)
        self.assertFalse(os.path.exists(out))                  # nothing ran
        self.status(print_stats={"state": "standby"})
        p = subprocess.run(cmd, capture_output=True, text=True, env=env)
        self.assertEqual(p.returncode, 0, p.stderr)
        holder, rc = open(out).read().split()
        self.assertTrue(holder.startswith("tool-"))
        self.assertEqual(rc, "rc=1")             # the lock was held while CMD ran
        self.assertIsNone(self.c.lock_holder(self.c.MAINTENANCE_LOCK))   # and died with it
        lock = self.c.MaintenanceLock("image-9").acquire()
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, env=env)
            self.assertEqual(p.returncode, 3)
            self.assertIn("Another update is running. (UPDATING)", p.stderr)
        finally:
            lock.release()
        p = subprocess.run([sys.executable, BUSY_CLI, "--lock", "x"], capture_output=True,
                           text=True, env=env)
        self.assertEqual(p.returncode, 64)

    def test_osconfig_verb(self):
        cli = importlib.import_module("nebulaos_osconfig.cli")
        import io
        self.status(print_stats={"state": "paused"})
        out, old = io.StringIO(), sys.stdout
        sys.stdout = out
        try:
            rc = cli.main(["system", "busy", "--profile", "git"])
        finally:
            sys.stdout = old
        reply = json.loads(out.getvalue())
        self.assertEqual((rc, reply["ok"], reply["busy"], reply["reason"], reply["profile"]),
                         (0, True, True, "PAUSED", "git"))

    # -- step 4: the supervisorctl shim ------------------------------------------------

    def shim(self, action, service):
        initd = os.path.join(self.tmp, "init.d")
        os.makedirs(initd, exist_ok=True)
        calls = os.path.join(self.tmp, "init.calls")
        for name in ("S55klipper", "S58nebulascreen"):
            path = os.path.join(initd, name)
            with open(path, "w") as fh:
                fh.write('#!/bin/sh\necho "%s $1" >> "%s"\n' % (name, calls))
            os.chmod(path, 0o755)
        if os.path.exists(calls):
            os.unlink(calls)
        env = self.shell_env()
        env.update({"NEBULAOS_BUSY_LIB": BUSY_LIB, "SUPERVISORCTL_INITD": initd})
        env.pop("NB_TIMEOUT")                       # the shim's own budget
        t0 = time.monotonic()
        p = subprocess.run(["sh", SHIM, action, service], capture_output=True, text=True,
                           env=env, timeout=30)
        took = time.monotonic() - t0
        ran = open(calls).read().split() if os.path.exists(calls) else []
        return p.returncode, p.stderr, ran, took

    def test_shim_refuses_klipper_restart_while_printing(self):
        self.status(print_stats={"state": "printing"})
        for action in ("restart", "stop"):
            rc, err, ran, took = self.shim(action, "klipper")
            self.assertEqual(rc, 1)
            self.assertIn("NebulaOS refused: %s klipper - Not possible while a print is running. "
                          "(PRINTING)" % action, err)
            self.assertEqual(ran, [])                   # refused BEFORE stop
            self.assertLess(took, 2.0)
        rc, err, ran, took = self.shim("restart", "nebulascreen")   # never gated (RC1)
        self.assertEqual((rc, ran), (0, ["S58nebulascreen", "restart"]))
        rc, err, ran, took = self.shim("start", "klipper")          # start is not gated
        self.assertEqual((rc, ran), (0, ["S55klipper", "start"]))

    def test_g98_shim_refusal_posts_a_console_line(self):
        # G98: a refused Klipper restart also reaches Mainsail's console
        # through the [nebulaos] component (best effort, never blocks)
        self.status(print_stats={"state": "printing"})
        rc, err, ran, took = self.shim("restart", "klipper")
        self.assertEqual((rc, ran), (1, []))
        self.assertEqual(len(self.mr.posts), 1)
        path, ctype, body = self.mr.posts[0]
        self.assertEqual((path, ctype), ("/machine/nebulaos/system/notify_refused",
                                         "application/json"))
        self.assertEqual(json.loads(body),
                         {"message": "restart klipper - Not possible while a print is running."})
        self.mr.posts.clear()
        self.status(print_stats={"state": "standby"})            # allowed: no line
        self.assertEqual(self.shim("restart", "klipper")[0], 0)
        self.assertEqual(self.mr.posts, [])
        self.status(print_stats={"state": "paused"})             # the relay hangs
        self.mr.post_hang = 3
        rc, err, ran, took = self.shim("stop", "klipper")
        self.assertEqual((rc, ran), (1, []))
        self.assertIn("(PAUSED)", err)
        self.assertLess(took, 3.0)
        self.mr.post_hang = 0

    def test_g107_shim_one_console_line_per_reason(self):
        # G107: repeated refusals (Moonraker retries, an update's restart, a
        # double click) are all refused, but the console line goes out once
        # per reason per window; another reason gets its own line.
        self.status(print_stats={"state": "printing"})
        for action in ("restart", "restart", "stop", "restart"):
            rc, err, ran, took = self.shim(action, "klipper")
            self.assertEqual((rc, ran), (1, []))
            self.assertIn("(PRINTING)", err)
        self.assertEqual(len(self.mr.posts), 1)
        stamp = os.path.join(self.run_dir, "refusal-notify", "svc-klipper-PRINTING")
        self.assertTrue(open(stamp).read().strip().isdigit())
        self.status(print_stats={"state": "paused"})
        self.assertEqual(self.shim("restart", "klipper")[0], 1)
        self.assertEqual(self.shim("restart", "klipper")[0], 1)
        self.assertEqual(len(self.mr.posts), 2)
        # after the window, the next refusal shows again
        self.status(print_stats={"state": "printing"})
        with open(stamp, "w") as fh:
            fh.write("%d\n" % (int(time.time()) - 61))
        self.assertEqual(self.shim("restart", "klipper")[0], 1)
        self.assertEqual(len(self.mr.posts), 3)
        # a stamp from the future (clock went back) never silences
        with open(stamp, "w") as fh:
            fh.write("%d\n" % (int(time.time()) + 3600))
        self.assertEqual(self.shim("restart", "klipper")[0], 1)
        self.assertEqual(len(self.mr.posts), 4)

    def test_shim_paused_and_active(self):
        self.status(print_stats={"state": "paused"})
        self.assertEqual(self.shim("restart", "klipper")[0], 1)
        self.status(heater_bed={"target": 55.0})
        rc, err, ran, _ = self.shim("restart", "klipper")
        self.assertEqual(rc, 1)
        self.assertIn("(ACTIVE)", err)
        self.status(nebulaos_calibration={"busy": True})    # not in the restart profile
        self.assertEqual(self.shim("restart", "klipper")[0], 0)

    def test_shim_klippy_dead_restart_allowed(self):
        # v3.6 note 1 / S19: a crashed Klippy can always be restarted
        self.marker("print-active")
        self.mr.klippy_state = "shutdown"
        rc, err, ran, took = self.shim("restart", "klipper")
        self.assertEqual((rc, ran), (0, ["S55klipper", "restart"]))
        self.mr.klippy_state = "disconnected"
        self.klippy_alive(False)
        rc, err, ran, took = self.shim("restart", "klipper")
        self.assertEqual((rc, ran), (0, ["S55klipper", "restart"]))
        self.assertLess(took, 2.0)
        self.moonraker_down()                              # Moonraker gone too
        rc, err, ran, took = self.shim("restart", "klipper")
        self.assertEqual((rc, ran), (0, ["S55klipper", "restart"]))
        self.assertLess(took, 2.0)

    def test_shim_idle_allowed(self):
        self.status(print_stats={"state": "standby"})
        rc, err, ran, took = self.shim("restart", "klipper")
        self.assertEqual((rc, ran, err), (0, ["S55klipper", "restart"], ""))
        self.assertLess(took, 2.0)

    def test_g95_shim_hung_klippy_restart_allowed_within_budget(self):
        # G95 (Tim 2026-10-22): a hung/unresponsive Klipper must ALWAYS be
        # restartable from Mainsail. A check that gets no answer from a live
        # Klippy allows the restart - even with memguard's print marker set -
        # and the worst case stays inside the budget (Moonraker kills the shim
        # at 6 s).
        self.marker("print-active")
        self.mr.query_fails = True                         # Moonraker: ready, query errors
        rc, err, ran, took = self.shim("restart", "klipper")
        self.assertEqual((rc, ran, err), (0, ["S55klipper", "restart"], ""))
        self.mr.query_fails = False
        self.mr.hang = 3                                   # Moonraker does not answer
        self.klippy_socket("hang")                         # nor does Klippy
        rc, err, ran, took = self.shim("restart", "klipper")
        self.assertEqual((rc, ran), (0, ["S55klipper", "restart"]))
        self.assertLess(took, 2.5)
        rc, err, ran, took = self.shim("stop", "klipper")
        self.assertEqual((rc, ran), (0, ["S55klipper", "stop"]))
        self.mr.hang = 0

    def test_g95_marker_refuses_only_while_klippy_answers(self):
        # the memguard print marker still refuses while Klippy answers (its
        # live reply may lag the print start by a poll)
        self.status(print_stats={"state": "standby"})
        self.marker("print-active")
        rc, err, ran, took = self.shim("restart", "klipper")
        self.assertEqual((rc, ran), (1, []))
        self.assertIn("(PRINTING)", err)


if __name__ == "__main__":
    unittest.main()
