# nebulaos_osconfig.ota - NebulaOS system updates over the internet (G79),
# stage S2: the trust anchor, the signed release record and the check.
# Design: _scratch/run15/G79-ota-design.md (v2, after the architecture review).
#
#   ota status                 the last check (cached, read-only)
#   ota check [--force]        ask the release channel whether a newer
#                              NebulaOS is published (at most once per 24 h
#                              unless forced; never while the printer is busy)
#
# Not here yet (later stages): the download (S3), the "ota" install source
# (S4), the screen and Mainsail (S5). Nothing in this module writes a slot.
#
# Trust: a release is described by nebulaos-release.json, signed OFFLINE with
# the project owner's Ed25519 key (tools/release/sign-release.py). The printer
# trusts only the public keys in the read-only image keyring
# (/usr/share/nebulaos/ota-keys/*.pem) - no runtime key chaining, rotation is
# an image release with overlapping keys. The signature is checked over the
# RAW bytes with the shipped OpenSSL (pkeyutl -rawin) BEFORE the JSON is
# parsed. An image without keys (every build today) never offers an update.
import json
import os
import re
import subprocess
import tempfile
import time

from . import common
from .common import invalid, OsConfigError

KEYRING = os.environ.get("NEBULAOS_OTA_KEYRING", "/usr/share/nebulaos/ota-keys")
OPENSSL = os.environ.get("NEBULAOS_OPENSSL", "/usr/bin/openssl")
OTA_DIR = os.path.join(common.NEBULAOS_ROOT, "system", "ota")
CHECK_CACHE = os.path.join(OTA_DIR, "check.json")
VERSION_FILE = os.environ.get("NEBULAOS_VERSION_FILE", "/opt/nebulaos-version.json")
# Open question for Tim (design: release repo + key owner). The stable channel
# is the latest GitHub release of the end-user repository.
CHANNEL_URL = os.environ.get("NEBULAOS_OTA_CHANNEL",
                             "https://api.github.com/repos/coreflake1/NebulaOS/releases/latest")
RELEASE_ASSET = "nebulaos-release.json"
CHECK_INTERVAL = 24 * 3600
FETCH_TIMEOUT = 20
MAX_RECORD = 64 * 1024
PRODUCT = "NebulaOS-Ender3V3KE"
OTA_SCHEMA = 1
# Builds are dated 2026 on; a clock before this was never set (no NTP yet).
CLOCK_FLOOR = 1767225600          # 2026-01-01

_VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_SHA1_RE = re.compile(r"^[0-9a-f]{40}$")
_IMG_RE = re.compile(r"^NebulaOS-Ender3V3KE-[0-9A-Za-z.+-]{1,64}\.img$")


# -- versions ---------------------------------------------------------------

def parse_version(text):
    m = _VERSION_RE.match(text or "")
    if not m:
        raise invalid("OTA_BAD_VERSION", "not a version x.y.z: %r" % (text,))
    return tuple(int(x) for x in m.groups())


def running_version():
    raw, _ = common.read_json(VERSION_FILE)
    v = (raw or {}).get("version")
    try:
        parse_version(v)
    except OsConfigError:
        return None
    return v


# -- the signed record -------------------------------------------------------

def keyring():
    try:
        names = sorted(n for n in os.listdir(KEYRING) if n.endswith(".pem"))
    except OSError:
        return []
    return [os.path.join(KEYRING, n) for n in names]


def verify_signature(data, signature, keys=None):
    """The name of the keyring key that signed `data` (raw bytes), or None.
    Ed25519 through the shipped OpenSSL; nothing is parsed before this."""
    keys = keyring() if keys is None else keys
    if not keys or not signature:
        return None
    with tempfile.TemporaryDirectory(prefix="nebulaos-ota-") as tmp:
        dpath, spath = os.path.join(tmp, "data"), os.path.join(tmp, "sig")
        with open(dpath, "wb") as handle:
            handle.write(data)
        with open(spath, "wb") as handle:
            handle.write(signature)
        for key in keys:
            rc, _, _ = common.run([OPENSSL, "pkeyutl", "-verify", "-pubin", "-inkey", key,
                                   "-rawin", "-in", dpath, "-sigfile", spath], 20)
            if rc == 0:
                return os.path.basename(key)
    return None


def parse_record(data):
    """The fields of a VERIFIED nebulaos-release.json (raw bytes)."""
    try:
        rec = json.loads(data.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise invalid("OTA_BAD_RECORD", "the release record is not JSON")
    if not isinstance(rec, dict):
        raise invalid("OTA_BAD_RECORD", "the release record is not an object")
    if rec.get("ota_schema") != OTA_SCHEMA:
        raise invalid("OTA_BAD_RECORD", "unsupported ota_schema %r" % (rec.get("ota_schema"),))
    if rec.get("product") != PRODUCT or rec.get("channel") != "stable":
        raise invalid("OTA_BAD_RECORD", "not a stable %s release" % PRODUCT)
    parse_version(rec.get("version"))
    img = rec.get("img")
    if not (isinstance(img, dict) and isinstance(img.get("name"), str)
            and _IMG_RE.match(img["name"]) and isinstance(img.get("size"), int)
            and not isinstance(img.get("size"), bool) and 0 < img["size"] <= 1 << 30
            and isinstance(img.get("sha256"), str) and _SHA256_RE.match(img["sha256"])):
        raise invalid("OTA_BAD_RECORD", "the image entry is incomplete")
    if not (isinstance(rec.get("source_head"), str) and _SHA1_RE.match(rec["source_head"])):
        raise invalid("OTA_BAD_RECORD", "source_head is not a commit")
    for key in ("min_version", "max_version"):
        if rec.get(key) is not None:
            parse_version(rec[key])
    return rec


def offer(rec, running):
    """(available, reason) for a verified record and the running version."""
    if running is None:
        return False, "RUNNING_VERSION_UNKNOWN"
    have, new = parse_version(running), parse_version(rec["version"])
    if new <= have:
        return False, "UP_TO_DATE"
    if rec.get("min_version") and have < parse_version(rec["min_version"]):
        return False, "NOT_FROM_THIS_VERSION"
    if rec.get("max_version") and have > parse_version(rec["max_version"]):
        return False, "NOT_FROM_THIS_VERSION"
    return True, "AVAILABLE"


# -- the check ----------------------------------------------------------------

def _fetch(url, limit):
    import urllib.request
    req = urllib.request.Request(url, headers={"User-Agent": "NebulaOS-ota",
                                               "Accept": "application/octet-stream, "
                                                         "application/json"})
    with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT) as resp:
        data = resp.read(limit + 1)
    if len(data) > limit:
        raise OsConfigError("OTA_TOO_LARGE", "the release channel sent too much data")
    return data


def _asset_urls(listing):
    try:
        rel = json.loads(listing.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise OsConfigError("OTA_CHANNEL", "the release channel answer is not JSON")
    urls = {}
    for a in rel.get("assets") or []:
        if isinstance(a, dict) and a.get("name") in (RELEASE_ASSET, RELEASE_ASSET + ".sig"):
            urls[a["name"]] = a.get("browser_download_url")
    if not urls.get(RELEASE_ASSET) or not urls.get(RELEASE_ASSET + ".sig"):
        raise OsConfigError("OTA_CHANNEL", "the latest release has no signed NebulaOS record")
    return urls[RELEASE_ASSET], urls[RELEASE_ASSET + ".sig"]


def status():
    cache, _ = common.read_json(CHECK_CACHE)
    return {"last": cache or None, "keys": [os.path.basename(k) for k in keyring()],
            "running_version": running_version(), "channel": CHANNEL_URL}


def _save(result):
    os.makedirs(OTA_DIR, exist_ok=True)
    common.atomic_write_json(CHECK_CACHE, result)
    return result


def check(force=False, fetch=None, now=None):
    now = time.time() if now is None else now
    fetch = fetch or _fetch
    if not force:
        cache, _ = common.read_json(CHECK_CACHE)
        if cache and 0 <= now - cache.get("checked_at", 0) < CHECK_INTERVAL:
            return dict(cache, result="CACHED")
    common.refuse_if_busy("request")
    base = {"checked_at": int(now), "running_version": running_version()}
    if not keyring():
        return _save(dict(base, result="NO_KEYS", available=False,
                          message="System updates over the internet are not enabled "
                                  "on this build."))
    if now < CLOCK_FLOOR:
        return dict(base, result="CLOCK_NOT_SET", available=False,
                    message="The printer's clock is not set yet; try again later.")
    try:
        rec_url, sig_url = _asset_urls(fetch(CHANNEL_URL, MAX_RECORD))
        data = fetch(rec_url, MAX_RECORD)
        sig = fetch(sig_url, 1024)
    except OsConfigError as exc:
        return _save(dict(base, result=exc.code, available=False, message=exc.message))
    except Exception as exc:                 # network: offline, DNS, timeout, HTTP
        return _save(dict(base, result="OFFLINE", available=False,
                          message="Could not reach the release channel (%s)."
                                  % exc.__class__.__name__))
    signer = verify_signature(data, sig)
    if signer is None:
        return _save(dict(base, result="SIGNATURE_REFUSED", available=False,
                          message="The release record is not signed by a NebulaOS key."))
    try:
        rec = parse_record(data)
    except OsConfigError as exc:
        return _save(dict(base, result=exc.code, available=False, message=exc.message))
    available, reason = offer(rec, base["running_version"])
    return _save(dict(base, result=reason, available=available, version=rec["version"],
                      img=rec["img"], source_head=rec["source_head"], signer=signer,
                      notes=rec.get("notes_url")))
