# nebulaos_osconfig.network - persistent hostname and DHCP/static IPv4 for
# wlan0 (GUI/service readiness mission, 2026-10-09).
#
# Files (all under the NebulaOS namespace on /usr/data):
#   network/osconfig.json      source of truth (schema 1)
#   network/osconfig.lkg.json  last configuration proven to reach its gateway
#   network/boot.env           scalars for /etc/nebulaos-network.sh (boot)
#
# A live change is: validate -> keep the current files as *.prev -> write the
# new files -> apply through nebulaos-netapply (the same shell library the
# boot uses) -> verify (static: the gateway answers ARP; DHCP: a lease) ->
# commit, or restore *.prev and re-apply. The caller gets the real outcome.
import ipaddress
import os
import re

from . import common
from .common import invalid, OsConfigError

SCHEMA = 1
DEFAULT_HOSTNAME = "nebulaos"
IFACE = "wlan0"

NET_DIR = os.path.join(common.NEBULAOS_ROOT, "network")
CONFIG = os.path.join(NET_DIR, "osconfig.json")
LKG = os.path.join(NET_DIR, "osconfig.lkg.json")
BOOT_ENV = os.path.join(NET_DIR, "boot.env")
BOOT_STATE = os.path.join(common.RUN_DIR, "network", "boot-state")
NETAPPLY = os.environ.get("NEBULAOS_NETAPPLY", "/usr/libexec/nebulaos/nebulaos-netapply")
APPLY_TIMEOUT = 60

_HOSTNAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")


def default_config():
    return {"schema": SCHEMA, "hostname": DEFAULT_HOSTNAME,
            "ipv4": {"mode": "dhcp"}}


# -- validation ----------------------------------------------------------------

def validate_hostname(value):
    if not isinstance(value, str):
        raise invalid("INVALID_HOSTNAME", "hostname must be a string")
    name = value.strip().lower()
    if not _HOSTNAME_RE.match(name):
        raise invalid("INVALID_HOSTNAME",
                      "hostname must be 1-63 characters a-z, 0-9 and '-', "
                      "not starting or ending with '-'")
    if name.isdigit():
        raise invalid("INVALID_HOSTNAME", "hostname must not be all digits")
    if name == "localhost":
        raise invalid("INVALID_HOSTNAME", "hostname must not be 'localhost'")
    return name


def _unicast(value, what):
    try:
        addr = ipaddress.IPv4Address(str(value).strip())
    except (ipaddress.AddressValueError, ValueError):
        raise invalid("INVALID_ADDRESS", "%s is not an IPv4 address" % what)
    if (addr.is_loopback or addr.is_multicast or addr.is_link_local
            or addr.is_unspecified or addr.is_reserved
            or addr == ipaddress.IPv4Address("255.255.255.255")):
        raise invalid("INVALID_ADDRESS", "%s %s is not a usable unicast address"
                      % (what, addr))
    return addr


def validate_ipv4(spec):
    """Returns the normalised ipv4 block or raises an `invalid` error."""
    if not isinstance(spec, dict):
        raise invalid("INVALID_IPV4", "ipv4 settings must be an object")
    mode = spec.get("mode")
    if mode == "dhcp":
        return {"mode": "dhcp"}
    if mode != "static":
        raise invalid("INVALID_MODE", "mode must be 'dhcp' or 'static'")
    address = _unicast(spec.get("address"), "address")
    try:
        prefix = int(spec.get("prefix"))
    except (TypeError, ValueError):
        raise invalid("INVALID_PREFIX", "prefix must be an integer 8-30")
    if not 8 <= prefix <= 30:
        raise invalid("INVALID_PREFIX", "prefix must be between 8 and 30")
    network = ipaddress.IPv4Network("%s/%d" % (address, prefix), strict=False)
    if address in (network.network_address, network.broadcast_address):
        raise invalid("INVALID_ADDRESS",
                      "address is the network or broadcast address of /%d" % prefix)
    gateway = _unicast(spec.get("gateway"), "gateway")
    if gateway not in network:
        raise invalid("INVALID_GATEWAY", "gateway %s is not in %s" % (gateway, network))
    if gateway == address:
        raise invalid("INVALID_GATEWAY", "gateway must differ from the address")
    dns_in = spec.get("dns", [])
    if dns_in is None:
        dns_in = []
    if not isinstance(dns_in, list) or len(dns_in) > 3:
        raise invalid("INVALID_DNS", "dns must be a list of at most 3 addresses")
    dns = [str(_unicast(d, "dns server")) for d in dns_in]
    return {"mode": "static", "address": str(address), "prefix": prefix,
            "gateway": str(gateway), "dns": dns}


def validate_config(cfg):
    if not common.schema_readable(cfg, SCHEMA):
        raise invalid("CONFIG_INVALID", "unsupported configuration schema")
    return {"schema": SCHEMA,
            "hostname": validate_hostname(cfg.get("hostname")),
            "ipv4": validate_ipv4(cfg.get("ipv4"))}


# -- persistence ---------------------------------------------------------------

def load_config():
    """(config, error). A missing file is the default; a corrupt or invalid
    file is reported and the default is used (the file stays for inspection)."""
    raw, error = common.read_json(CONFIG)
    if raw is None:
        return default_config(), error
    try:
        return validate_config(raw), None
    except OsConfigError as exc:
        return default_config(), "%s: %s" % (exc.code, exc.message)


def boot_env_text(cfg):
    ipv4 = cfg["ipv4"]
    pairs = [("NNET_HOSTNAME", cfg["hostname"]), ("NNET_MODE", ipv4["mode"])]
    if ipv4["mode"] == "static":
        netmask = str(ipaddress.IPv4Network("0.0.0.0/%d" % ipv4["prefix"]).netmask)
        pairs += [("NNET_ADDRESS", ipv4["address"]), ("NNET_NETMASK", netmask),
                  ("NNET_GATEWAY", ipv4["gateway"]),
                  ("NNET_DNS", " ".join(ipv4["dns"]))]
    return common.render_env(pairs)


def _write(cfg):
    common.atomic_write_json(CONFIG, cfg)
    common.atomic_write(BOOT_ENV, boot_env_text(cfg))


def _snapshot():
    """Current files, byte for byte, for an exact revert (None = absent)."""
    snap = {}
    for path in (CONFIG, BOOT_ENV):
        try:
            with open(path, "rb") as handle:
                snap[path] = handle.read()
        except OSError:
            snap[path] = None
    return snap


def _restore(snap):
    for path, data in snap.items():
        if data is None:
            try:
                os.unlink(path)
            except OSError:
                pass
        else:
            common.atomic_write(path, data)


# -- live state ----------------------------------------------------------------

def _read_text(path):
    try:
        with open(path) as handle:
            return handle.read().strip()
    except OSError:
        return ""


def live_state():
    state = {"interface": IFACE, "address": None, "prefix": None,
             "gateway": None, "dns": [], "ssid": None,
             "hostname": _read_text("/proc/sys/kernel/hostname") or None}
    rc, out, _ = common.run(["ip", "-4", "-o", "addr", "show", "dev", IFACE], 5)
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)/(\d+)", out) if rc == 0 else None
    if m:
        state["address"], state["prefix"] = m.group(1), int(m.group(2))
    rc, out, _ = common.run(["ip", "-4", "route", "show", "default", "dev", IFACE], 5)
    m = re.search(r"default via (\d+\.\d+\.\d+\.\d+)", out) if rc == 0 else None
    if m:
        state["gateway"] = m.group(1)
    state["dns"] = re.findall(r"^nameserver\s+(\S+)", _read_text("/etc/resolv.conf"),
                              re.MULTILINE)
    rc, out, _ = common.run(["wpa_cli", "-i", IFACE, "status"], 5)
    if rc == 0:
        kv = common.parse_kv(out)
        state["ssid"] = kv.get("ssid")
        state["wpa_state"] = kv.get("wpa_state")
    return state


def status():
    cfg, error = load_config()
    return {
        "config": cfg,
        "config_error": error,
        "last_known_good": common.read_json(LKG)[0],
        "boot_state": _read_text(BOOT_STATE) or None,
        "live": live_state(),
        "mdns_name": "%s.local" % cfg["hostname"],
        "mdns_note": "the .local name follows a hostname change after Moonraker restarts",
    }


# -- changes -------------------------------------------------------------------

def _netapply(verb):
    rc, out, err = common.run([NETAPPLY, verb], APPLY_TIMEOUT)
    return rc, (out + err).strip()


def _apply_and_verify(new_cfg, verb):
    snap = _snapshot()
    _write(new_cfg)
    rc, log = _netapply(verb)
    if rc == 0:
        common.atomic_write_json(LKG, new_cfg)
        return {"result": "APPLIED", "config": new_cfg}
    # Revert: previous files, previous live configuration.
    _restore(snap)
    rrc, rlog = _netapply("apply")
    code = {4: "GATEWAY_UNREACHABLE_REVERTED", 3: "IFUP_FAILED_REVERTED"}.get(
        rc, "APPLY_FAILED_REVERTED")
    if new_cfg["ipv4"]["mode"] == "dhcp" and rc == 3:
        code = "DHCP_FAILED_REVERTED"
    raise OsConfigError(code, "the new network settings did not work and were "
                        "reverted (apply rc=%d)" % rc,
                        apply_log=log[-2000:], revert_rc=rrc,
                        revert_log=rlog[-2000:])


def set_hostname(value):
    name = validate_hostname(value)
    cfg, _ = load_config()
    if cfg["hostname"] == name:
        return {"result": "UNCHANGED", "config": cfg}
    new_cfg = dict(cfg, hostname=name)
    snap = _snapshot()
    _write(new_cfg)
    rc, log = _netapply("hostname")
    if rc != 0:
        _restore(snap)
        _netapply("hostname")
        raise OsConfigError("HOSTNAME_APPLY_FAILED", "could not apply the hostname",
                            apply_log=log[-2000:])
    return {"result": "APPLIED", "config": new_cfg,
            "mdns_restart_required": True}


def set_ipv4(spec):
    ipv4 = validate_ipv4(spec)
    cfg, _ = load_config()
    new_cfg = dict(cfg, ipv4=ipv4)
    return _apply_and_verify(new_cfg, "apply")


def reset():
    """SSH recovery: DHCP + default hostname."""
    return _apply_and_verify(default_config(), "apply")
