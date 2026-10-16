# nebulaos_osconfig.wifi - Wi-Fi networks for wlan0 through wpa_supplicant's
# control socket (Q3, 2026-10-11). Replaces GuppyScreen's direct socket use:
# the GUI and Mainsail both go through machine.nebulaos.wifi.*.
#
#   status    association state and the saved networks
#   scan      a fresh scan (waits for the results)
#   connect   {"ssid", "password"} on stdin - never on a command line. A new
#             network is only saved once it has connected; a wrong password
#             or a timeout removes it again and returns to the previous one
#   forget    remove every saved entry for an SSID
#
# wpa_supplicant owns /usr/data/nebulaos/network/wpa_supplicant.conf
# (update_config=1, SAVE_CONFIG). The passphrase is turned into the 64-hex
# WPA PSK here, so it is never stored in plain text and never quoted into a
# control command. SSIDs are sent hex-encoded for the same reason.
import hashlib
import json
import os
import re
import signal
import socket
import time

from . import common
from .common import invalid, OsConfigError

IFACE = "wlan0"
CTRL_DIR = os.environ.get("NEBULAOS_WPA_CTRL_DIR", "/var/run/wpa_supplicant")
NETAPPLY = os.environ.get("NEBULAOS_NETAPPLY", "/usr/libexec/nebulaos/nebulaos-netapply")
UDHCPC_PIDFILE = os.environ.get("NEBULAOS_UDHCPC_PIDFILE", "/var/run/udhcpc.%s.pid" % IFACE)
ARPING = os.environ.get("NEBULAOS_ARPING", "arping")
SCAN_SECONDS = float(os.environ.get("NEBULAOS_WIFI_SCAN_SECONDS", "10"))
CONNECT_SECONDS = float(os.environ.get("NEBULAOS_WIFI_CONNECT_SECONDS", "30"))
ADDRESS_SECONDS = float(os.environ.get("NEBULAOS_WIFI_ADDRESS_SECONDS", "20"))
MAX_STDIN = 4096


# -- control socket -------------------------------------------------------------

class UnixTransport(object):
    """The wpa_ctrl datagram socket, bound in the run directory."""

    _seq = 0

    def __init__(self):
        UnixTransport._seq += 1
        os.makedirs(common.RUN_DIR, exist_ok=True)
        self.local = os.path.join(common.RUN_DIR, "wpa-osconfig-%d-%d"
                                  % (os.getpid(), UnixTransport._seq))
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            if os.path.exists(self.local):
                os.unlink(self.local)
            self.sock.bind(self.local)
            self.sock.connect(os.path.join(CTRL_DIR, IFACE))
        except OSError:
            self.close()
            raise

    def send(self, data):
        self.sock.settimeout(2.0)
        self.sock.send(data)

    def recv(self, timeout):
        """Bytes, or None on timeout."""
        self.sock.settimeout(max(timeout, 0.001))
        try:
            return self.sock.recv(65536)
        except socket.timeout:
            return None

    def close(self):
        self.sock.close()
        try:
            os.unlink(self.local)
        except OSError:
            pass


# Replaced by the offline tests with an in-process fake.
open_transport = UnixTransport


class Ctrl(object):
    """A wpa_ctrl client: requests, replies and (once attached) events."""

    def __init__(self, timeout=5.0):
        self.timeout = timeout
        self.attached = False
        self.events = []
        try:
            self.t = open_transport()
        except OSError as exc:
            raise OsConfigError("WIFI_UNAVAILABLE",
                                "wpa_supplicant is not running on %s (%s)" % (IFACE, exc))

    def close(self):
        try:
            if self.attached:
                self.t.send(b"DETACH")
        except OSError:
            pass
        self.t.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def request(self, cmd):
        try:
            self.t.send(cmd.encode("utf-8"))
            deadline = time.monotonic() + self.timeout
            while True:
                data = self.t.recv(deadline - time.monotonic())
                if data is None:
                    raise OSError("timed out")
                text = data.decode("utf-8", "replace")
                if text.startswith("<"):        # an event while attached
                    self.events.append(text)
                    continue
                return text
        except OSError as exc:
            raise OsConfigError("WIFI_UNAVAILABLE", "no answer from wpa_supplicant to %s (%s)"
                                % (cmd.split(" ", 1)[0], exc))

    def ok(self, cmd):
        reply = self.request(cmd).strip()
        if reply != "OK":
            raise OsConfigError("WIFI_COMMAND_FAILED", "%s: %s"
                                % (" ".join(cmd.split(" ")[:2]), reply or "no reply"))

    def attach(self):
        self.ok("ATTACH")
        self.attached = True

    def wait_event(self, match, seconds):
        """The first event for which match(text) is truthy, or None."""
        deadline = time.monotonic() + seconds
        while True:
            while self.events:
                ev = self.events.pop(0)
                if match(ev):
                    return ev
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            try:
                data = self.t.recv(left)
            except OSError:
                return None
            if data is None:
                return None
            text = data.decode("utf-8", "replace")
            if text.startswith("<"):
                self.events.append(text)


# -- parsing --------------------------------------------------------------------

_ESC = {"\\": "\\", '"': '"', "n": "\n", "r": "\r", "t": "\t", "e": "\x1b"}


def decode_ssid_text(text):
    """wpa_supplicant's printf_encode() back to bytes."""
    out = bytearray()
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            if nxt == "x" and re.match(r"^[0-9a-fA-F]{2}$", text[i + 2:i + 4]):
                out.append(int(text[i + 2:i + 4], 16))
                i += 4
                continue
            if nxt in _ESC:
                out += _ESC[nxt].encode()
                i += 2
                continue
        out += ch.encode("utf-8")
        i += 1
    return bytes(out)


def ssid_name(raw):
    return raw.decode("utf-8", "replace")


def parse_scan_results(text):
    """Strongest entry per SSID, strongest first. Hidden networks dropped."""
    best = {}
    for line in text.splitlines()[1:]:
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        raw = decode_ssid_text(parts[4])
        if not raw or raw.strip(b"\x00") == b"":
            continue
        try:
            signal = int(parts[2])
        except ValueError:
            continue
        flags = parts[3]
        entry = {"ssid": ssid_name(raw), "signal": signal,
                 "frequency": int(parts[1]) if parts[1].isdigit() else None,
                 "security": security(flags)}
        old = best.get(raw)
        if old is None or signal > old["signal"]:
            best[raw] = entry
    return sorted(best.values(), key=lambda e: -e["signal"])


def security(flags):
    if "WEP" in flags:
        return "wep"
    if "PSK" in flags:
        return "psk"
    if "SAE" in flags:
        return "sae"
    if "EAP" in flags:
        return "eap"
    if "WPA" in flags or "RSN" in flags:
        return "psk"
    return "open"


def decode_network_ssid(value):
    """GET_NETWORK <id> ssid: a quoted string or plain hex."""
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1].encode("utf-8")
    if re.match(r"^([0-9a-fA-F]{2})+$", value):
        return bytes.fromhex(value)
    return value.encode("utf-8")


def saved_networks(ctrl):
    nets = []
    for line in ctrl.request("LIST_NETWORKS").splitlines()[1:]:
        parts = line.split("\t")
        if not parts or not parts[0].isdigit():
            continue
        nid = parts[0]
        raw = decode_network_ssid(ctrl.request("GET_NETWORK %s ssid" % nid))
        flags = parts[3] if len(parts) > 3 else ""
        nets.append({"id": int(nid), "ssid": ssid_name(raw), "raw": raw,
                     "current": "[CURRENT]" in flags,
                     "disabled": "[DISABLED]" in flags})
    return nets


def _public(nets):
    return [{k: v for k, v in n.items() if k != "raw"} for n in nets]


def wpa_status(ctrl):
    kv = common.parse_kv(ctrl.request("STATUS"))
    return {"state": kv.get("wpa_state"), "ssid": kv.get("ssid"),
            "id": int(kv["id"]) if kv.get("id", "").isdigit() else None,
            "address": kv.get("ip_address"), "frequency": kv.get("freq"),
            "key_mgmt": kv.get("key_mgmt")}


def _ipv4():
    rc, out, _ = common.run(["ip", "-4", "-o", "addr", "show", "dev", IFACE], 5)
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out) if rc == 0 else None
    return m.group(1) if m else None


# -- validation -----------------------------------------------------------------

def validate_ssid(value):
    if not isinstance(value, str) or not value:
        raise invalid("INVALID_SSID", "ssid must be a non-empty string")
    raw = value.encode("utf-8")
    if len(raw) > 32:
        raise invalid("INVALID_SSID", "ssid must be at most 32 bytes")
    return raw


def psk_for(raw_ssid, password):
    """64-hex WPA PSK. A 64-hex password is taken as the PSK itself."""
    if not isinstance(password, str):
        raise invalid("INVALID_PASSWORD", "password must be a string")
    if re.match(r"^[0-9a-fA-F]{64}$", password):
        return password.lower()
    data = password.encode("utf-8")
    if not 8 <= len(data) <= 63:
        raise invalid("INVALID_PASSWORD", "a Wi-Fi password has 8 to 63 characters")
    return hashlib.pbkdf2_hmac("sha1", data, raw_ssid, 4096, 32).hex()


def read_stdin_spec(stream):
    raw = stream.read(MAX_STDIN + 1)
    if len(raw) > MAX_STDIN:
        raise invalid("USAGE", "request too large")
    try:
        spec = json.loads(raw or "{}")
    except ValueError:
        raise invalid("USAGE", "stdin is not a JSON object")
    if not isinstance(spec, dict):
        raise invalid("USAGE", "stdin is not a JSON object")
    return spec


# -- verbs ----------------------------------------------------------------------

def status():
    with Ctrl() as ctrl:
        st = wpa_status(ctrl)
        nets = saved_networks(ctrl)
    if not st.get("address"):
        st["address"] = _ipv4()
    return {"interface": IFACE, "status": st, "saved": _public(nets)}


def scan():
    with Ctrl() as ctrl:
        ctrl.attach()
        reply = ctrl.request("SCAN").strip()
        if reply not in ("OK", "FAIL-BUSY"):
            raise OsConfigError("SCAN_FAILED", "wpa_supplicant refused to scan: %s" % reply)
        got = ctrl.wait_event(lambda ev: "CTRL-EVENT-SCAN-RESULTS" in ev, SCAN_SECONDS)
        results = parse_scan_results(ctrl.request("SCAN_RESULTS"))
        nets = saved_networks(ctrl)
        st = wpa_status(ctrl)
    saved = {n["ssid"] for n in nets}
    for entry in results:
        entry["saved"] = entry["ssid"] in saved
        entry["current"] = entry["ssid"] == st.get("ssid") and st.get("state") == "COMPLETED"
    return {"networks": results, "complete": got is not None, "status": st}


def _udhcpc_pid():
    try:
        with open(UDHCPC_PIDFILE) as handle:
            pid = int(handle.read().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def _wait_ipv4(seconds):
    deadline = time.monotonic() + seconds
    while True:
        address = _ipv4()
        if address or time.monotonic() >= deadline:
            return address
        time.sleep(0.5)


def _gateway_answers(gateway, seconds=5):
    for _ in range(max(1, int(seconds))):
        rc, _, _ = common.run([ARPING, "-q", "-c", "1", "-w", "1", "-I", IFACE, gateway], 3)
        if rc == 0:
            return True
    return False


def _readdress(ctrl, target):
    """The address for the network just joined, WITHOUT taking wlan0 down:
    a link bounce makes wpa_supplicant pick a saved network by itself (G20).
    DHCP: release and renew the running udhcpc lease. Static: the configured
    address stays; check that the gateway answers on this network (G5).
    Returns (mode, address, ok, note)."""
    from . import network
    cfg, _ = network.load_config()
    ipv4 = cfg["ipv4"]
    if ipv4["mode"] == "static":
        ok = _gateway_answers(ipv4["gateway"])
        note = None if ok else (
            "the static address %s does not work on this network (gateway %s does not "
            "answer); switch to DHCP under Wi-Fi networks > this network > Static IP"
            % (ipv4["address"], ipv4["gateway"]))
        return "static", _ipv4(), ok, note
    pid = _udhcpc_pid()
    if pid is not None:
        # Release the old network's lease, wait until the address is really
        # gone, then ask the new network for one. Never both at once: pending
        # signals are delivered lowest number first, so USR1 (renew) would run
        # before USR2 (release) and leave wlan0 without an address.
        os.kill(pid, signal.SIGUSR2)
        deadline = time.monotonic() + 3
        while _ipv4() is not None and time.monotonic() < deadline:
            time.sleep(0.2)
        os.kill(pid, signal.SIGUSR1)
    else:
        # No DHCP client running: the full apply path, then make sure the
        # network the user chose is the one wlan0 came back on.
        with common.Lock("network"):
            common.run([NETAPPLY, "apply"], 60)
        if wpa_status(ctrl).get("id") != target:
            ctrl.request("SELECT_NETWORK %d" % target)
            ctrl.wait_event(lambda e: "CTRL-EVENT-CONNECTED" in e, CONNECT_SECONDS)
            ctrl.request("ENABLE_NETWORK all")
    address = _wait_ipv4(ADDRESS_SECONDS)
    note = None if address else "connected, but no address from this network's DHCP server yet"
    return "dhcp", address, address is not None, note


# Events that mean the passphrase was refused. wpa_supplicant marks the
# network WRONG_KEY only after repeated failures; this Wi-Fi chip (BCM43430)
# first reports the failed 4-way handshake and a disconnect with reason 15
# (4-way handshake timeout), so those count too (G21). A disconnect that
# wpa_supplicant itself caused (leaving the old network) does not.
def _wrong_key_event(event, target):
    if "CTRL-EVENT-SSID-TEMP-DISABLED" in event and "id=%d " % target in event + " ":
        return "WRONG_KEY" in event
    if "pre-shared key may be incorrect" in event:
        return True
    if "CTRL-EVENT-DISCONNECTED" in event and "locally_generated=1" not in event:
        return re.search(r"\breason=15\b", event) is not None
    return False


def _prefer(ctrl, target):
    """The network the user chose last wins every later selection: priority 1
    for it, 0 for every other saved network (P9, 2026-10-15). With equal
    priorities wpa_supplicant re-picks the strongest saved network after
    any scan - the screen scans right after connecting - and the printer
    left the network it had just joined. Bounded on purpose: no counting up."""
    for n in saved_networks(ctrl):
        ctrl.request("SET_NETWORK %d priority %d" % (n["id"], 1 if n["id"] == target else 0))


def connect(spec):
    raw = validate_ssid(spec.get("ssid"))
    password = spec.get("password")
    if password in ("", None):
        password = None
    psk = psk_for(raw, password) if password is not None else None
    # G10 (2026-10-16): a hidden network does not appear in the scan; the
    # user types its name, and wpa_supplicant has to probe for it.
    hidden = spec.get("hidden") is True
    with Ctrl() as ctrl:
        before = wpa_status(ctrl)
        nets = saved_networks(ctrl)
        existing = [n for n in nets if n["raw"] == raw]
        sec = None
        for entry in parse_scan_results(ctrl.request("SCAN_RESULTS")):
            if entry["ssid"].encode("utf-8") == raw:
                sec = entry["security"]
        if sec == "sae":
            # G10: checked on ke-dev 2026-10-16 - the BCM43430/1 firmware has
            # no WPA3 (SAE); WPA2/WPA3 mixed networks report PSK too and work.
            raise invalid("UNSUPPORTED_SECURITY",
                          "this network only allows WPA3, which this printer's Wi-Fi does "
                          "not support - set the router to WPA2/WPA3 (mixed) mode")
        if sec in ("wep", "eap"):
            raise invalid("UNSUPPORTED_SECURITY",
                          "this network uses %s security, which the printer cannot join"
                          % sec.upper())
        new_id = None
        if psk is None and existing:
            target = existing[0]["id"]
        else:
            if psk is None and sec != "open" and not (hidden and sec is None):
                raise invalid("PASSWORD_REQUIRED", "this network needs a password")
            reply = ctrl.request("ADD_NETWORK").strip()
            if not reply.isdigit():
                raise OsConfigError("WIFI_COMMAND_FAILED", "could not add the network")
            new_id = target = int(reply)
            try:
                ctrl.ok("SET_NETWORK %d ssid %s" % (target, raw.hex()))
                if hidden:
                    ctrl.ok("SET_NETWORK %d scan_ssid 1" % target)
                if psk is None:
                    ctrl.ok("SET_NETWORK %d key_mgmt NONE" % target)
                else:
                    ctrl.ok("SET_NETWORK %d psk %s" % (target, psk))
            except OsConfigError:
                ctrl.request("REMOVE_NETWORK %d" % target)
                raise
        ctrl.attach()
        ctrl.ok("SELECT_NETWORK %d" % target)
        ev = ctrl.wait_event(
            lambda e: "CTRL-EVENT-CONNECTED" in e or _wrong_key_event(e, target)
            or ("CTRL-EVENT-SSID-TEMP-DISABLED" in e and "id=%d " % target in e + " "),
            CONNECT_SECONDS)
        connected = ev is not None and "CTRL-EVENT-CONNECTED" in ev
        if not connected:
            code = "WRONG_PASSWORD" if ev and _wrong_key_event(ev, target) else "CONNECT_TIMEOUT"
            if new_id is not None:
                ctrl.request("REMOVE_NETWORK %d" % new_id)
            if before.get("id") is not None and before["id"] != new_id:
                ctrl.request("SELECT_NETWORK %d" % before["id"])
            ctrl.request("ENABLE_NETWORK all")
            message = ("the password was not accepted" if code == "WRONG_PASSWORD"
                       else "could not connect within %d s" % CONNECT_SECONDS)
            raise OsConfigError(code, message + "; the previous Wi-Fi network was restored",
                                previous=before.get("ssid"))
        # Connected: drop older entries for the same SSID, keep every other
        # saved network usable, and only now write the configuration.
        if new_id is not None:
            for n in existing:
                ctrl.request("REMOVE_NETWORK %d" % n["id"])
        _prefer(ctrl, target)
        ctrl.request("ENABLE_NETWORK all")
        ctrl.ok("SAVE_CONFIG")
        after = wpa_status(ctrl)
        if before.get("ssid") != after.get("ssid") or before.get("state") != "COMPLETED":
            mode, address, address_ok, note = _readdress(ctrl, target)
        else:
            mode, address, address_ok, note = "unchanged", _wait_ipv4(ADDRESS_SECONDS), True, None
        final = wpa_status(ctrl)
    return {"result": "CONNECTED", "ssid": final.get("ssid") or ssid_name(raw),
            "address": address, "address_mode": mode, "address_ok": bool(address_ok),
            "address_note": note}


def forget(ssid):
    raw = validate_ssid(ssid)
    with Ctrl() as ctrl:
        nets = [n for n in saved_networks(ctrl) if n["raw"] == raw]
        if not nets:
            raise invalid("NOT_SAVED", "no saved network named %s" % ssid)
        for n in nets:
            ctrl.ok("REMOVE_NETWORK %d" % n["id"])
        ctrl.ok("SAVE_CONFIG")
    return {"result": "FORGOTTEN", "ssid": ssid, "removed": len(nets)}
