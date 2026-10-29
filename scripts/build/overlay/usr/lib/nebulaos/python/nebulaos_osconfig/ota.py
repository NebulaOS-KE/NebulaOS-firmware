# nebulaos_osconfig.ota - NebulaOS system updates over the internet (G79).
# Design: _scratch/run15/G79-ota-design.md; Tim 2026-10-29 (Run 23): NO signing
# key - the printer downloads only over HTTPS from github.com and checks the
# size and sha256 listed in the release record.
#
#   ota status                 the last check and the download (read-only)
#   ota check [--force]        ask the release channel whether a newer
#                              NebulaOS is published (at most once per 24 h
#                              unless forced; never while the printer is busy)
#   ota download               fetch the offered .img (background job) into
#                              the "ota" image source; the install is then
#                              the ordinary `image install --file ota/<name>`
#                              (busy refusal, stop points, trial, rollback)
#   ota discard                delete the downloaded image
#
# Trust: the stable channel is the latest GitHub release of NebulaOS-KE/NebulaOS.
# Every request is HTTPS with certificate checks (the image's CA bundle), to
# github.com / api.github.com and, through redirects, only to GitHub's release
# asset hosts. The release record nebulaos-release.json (tools/release/
# make-release-record.py) names the image, its size and sha256; the image is
# kept only when both match. TLS needs a set clock: before CLOCK_FLOOR nothing
# is fetched.
import fcntl
import hashlib
import json
import os
import re
import subprocess
import time
import urllib.parse

from . import common, image
from .common import invalid, OsConfigError

OTA_DIR = os.path.join(common.NEBULAOS_ROOT, "system", "ota")
CHECK_CACHE = os.path.join(OTA_DIR, "check.json")
DOWNLOAD_DIR = image.OTA_DOWNLOAD_DIR
DOWNLOAD_STATE = os.path.join(common.RUN_DIR, "ota-download", "state.json")
DOWNLOAD_LOCK = os.path.join(common.RUN_DIR, "ota-download", "lock")
VERSION_FILE = os.environ.get("NEBULAOS_VERSION_FILE", "/opt/nebulaos-version.json")
OSCONFIG = os.environ.get("NEBULAOS_OSCONFIG", "/usr/libexec/nebulaos/nebulaos-osconfig")
# Tim 2026-10-29: complete releases are published on NebulaOS-KE/NebulaOS; the
# stable channel is its latest GitHub release.
CHANNEL_URL = os.environ.get("NEBULAOS_OTA_CHANNEL",
                             "https://api.github.com/repos/NebulaOS-KE/NebulaOS/releases/latest")
ASSET_PREFIX = "https://github.com/NebulaOS-KE/NebulaOS/releases/download/"
# GitHub answers an asset URL with a redirect to its storage host.
ALLOWED_HOSTS = ("api.github.com", "github.com", "objects.githubusercontent.com",
                 "release-assets.githubusercontent.com")
RELEASE_ASSET = "nebulaos-release.json"
CHECK_INTERVAL = 24 * 3600
FETCH_TIMEOUT = 20
MAX_RECORD = 64 * 1024
PRODUCT = "NebulaOS-Ender3V3KE"
OTA_SCHEMA = 1
# Builds are dated 2026 on; a clock before this was never set (no NTP yet).
CLOCK_FLOOR = 1767225600          # 2026-01-01
SPACE_MARGIN = 16 * 1024 * 1024

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


# -- the release record ------------------------------------------------------

def parse_record(data):
    """The fields of nebulaos-release.json (raw bytes)."""
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
            and not isinstance(img.get("size"), bool) and 0 < img["size"] <= image.MAX_IMG_BYTES
            and isinstance(img.get("sha256"), str) and _SHA256_RE.match(img["sha256"])):
        raise invalid("OTA_BAD_RECORD", "the image entry is incomplete")
    if not (isinstance(rec.get("source_head"), str) and _SHA1_RE.match(rec["source_head"])):
        raise invalid("OTA_BAD_RECORD", "source_head is not a commit")
    for key in ("min_version", "max_version"):
        if rec.get(key) is not None:
            parse_version(rec[key])
    return rec


def offer(rec, running):
    """(available, reason) for a record and the running version."""
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


# -- HTTPS to GitHub only ------------------------------------------------------

def allowed_url(url):
    try:
        parts = urllib.parse.urlsplit(url)
    except ValueError:
        return False
    return parts.scheme == "https" and parts.hostname in ALLOWED_HOSTS and not parts.username


def _opener():
    import urllib.request

    class GitHubOnly(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            if not allowed_url(newurl):
                raise OsConfigError("OTA_CHANNEL", "the release channel redirected away "
                                    "from GitHub")
            return super().redirect_request(req, fp, code, msg, headers, newurl)
    return urllib.request.build_opener(GitHubOnly)


def _open(url):
    import urllib.request
    if not allowed_url(url):
        raise OsConfigError("OTA_CHANNEL", "not a GitHub HTTPS address: %s" % url)
    req = urllib.request.Request(url, headers={"User-Agent": "NebulaOS-ota",
                                               "Accept": "application/octet-stream, "
                                                         "application/json"})
    return _opener().open(req, timeout=FETCH_TIMEOUT)


def _fetch(url, limit):
    with _open(url) as resp:
        data = resp.read(limit + 1)
    if len(data) > limit:
        raise OsConfigError("OTA_TOO_LARGE", "the release channel sent too much data")
    return data


def _assets(listing):
    """{name: (url, size)} of the release's assets on github.com."""
    try:
        rel = json.loads(listing.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise OsConfigError("OTA_CHANNEL", "the release channel answer is not JSON")
    out = {}
    for a in (rel.get("assets") if isinstance(rel, dict) else None) or []:
        if not isinstance(a, dict):
            continue
        url = a.get("browser_download_url")
        if isinstance(a.get("name"), str) and isinstance(url, str) \
                and url.startswith(ASSET_PREFIX) and allowed_url(url):
            out[a["name"]] = (url, a.get("size"))
    if RELEASE_ASSET not in out:
        raise OsConfigError("OTA_CHANNEL", "the latest release has no NebulaOS record")
    return out


# -- the check ----------------------------------------------------------------

def _download_state():
    state, _ = common.read_json(DOWNLOAD_STATE)
    if state and state.get("state") == "running" and not _download_running():
        state = dict(state, state="failed", error="INTERRUPTED",
                     message="The download stopped; start it again.")
    return state


def downloaded():
    """The downloaded image that matches the last check, or None."""
    cache, _ = common.read_json(CHECK_CACHE)
    img = (cache or {}).get("img")
    if not (cache and cache.get("available") and isinstance(img, dict)):
        return None
    path = os.path.join(DOWNLOAD_DIR, img.get("name", ""))
    try:
        if os.path.getsize(path) != img["size"]:
            return None
    except (OSError, KeyError):
        return None
    return {"file": "ota/" + img["name"], "sha256": img["sha256"], "version": cache["version"]}


def status():
    cache, _ = common.read_json(CHECK_CACHE)
    return {"last": cache or None, "running_version": running_version(),
            "channel": CHANNEL_URL, "download": _download_state(), "downloaded": downloaded()}


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
    if now < CLOCK_FLOOR:
        return dict(base, result="CLOCK_NOT_SET", available=False,
                    message="The printer's clock is not set yet; try again later.")
    try:
        assets = _assets(fetch(CHANNEL_URL, MAX_RECORD))
        rec = parse_record(fetch(assets[RELEASE_ASSET][0], MAX_RECORD))
    except OsConfigError as exc:
        return _save(dict(base, result=exc.code, available=False, message=exc.message))
    except Exception as exc:                 # network: offline, DNS, TLS, timeout, HTTP
        return _save(dict(base, result="OFFLINE", available=False,
                          message="Could not reach the release channel (%s)."
                                  % exc.__class__.__name__))
    asset = assets.get(rec["img"]["name"])
    if asset is None or asset[1] != rec["img"]["size"]:
        return _save(dict(base, result="OTA_BAD_RECORD", available=False,
                          message="The release does not carry the image its record names."))
    available, reason = offer(rec, base["running_version"])
    return _save(dict(base, result=reason, available=available, version=rec["version"],
                      img=dict(rec["img"], url=asset[0]), source_head=rec["source_head"],
                      notes=rec.get("notes_url")))


# -- the download (background job) ----------------------------------------------

def _download_running():
    """True while a download worker holds the lock."""
    os.makedirs(os.path.dirname(DOWNLOAD_LOCK), exist_ok=True)
    fd = os.open(DOWNLOAD_LOCK, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return True
    finally:
        os.close(fd)
    return False


def _dl_state(**fields):
    common.atomic_write_json(DOWNLOAD_STATE, dict(fields, updated=int(time.time())))


def _clear_downloads(keep=None):
    try:
        names = os.listdir(DOWNLOAD_DIR)
    except OSError:
        return
    for name in names:
        if name != keep:
            try:
                os.unlink(os.path.join(DOWNLOAD_DIR, name))
            except OSError:
                pass


def download(now=None):
    now = time.time() if now is None else now
    if _download_running():
        raise invalid("BUSY", "a download is already running")
    cache, _ = common.read_json(CHECK_CACHE)
    if not (cache and cache.get("available") and isinstance(cache.get("img"), dict)):
        raise invalid("OTA_NOTHING_OFFERED", "check for an update first")
    if downloaded():
        return {"result": "ALREADY_DOWNLOADED", "downloaded": downloaded()}
    if now < CLOCK_FLOOR:
        raise invalid("CLOCK_NOT_SET", "the printer's clock is not set yet; try again later")
    common.refuse_if_busy("request")
    os.makedirs(DOWNLOAD_DIR, exist_ok=True)
    st = os.statvfs(DOWNLOAD_DIR)
    if st.f_bavail * st.f_frsize < cache["img"]["size"] + SPACE_MARGIN:
        raise invalid("NO_SPACE", "not enough free space for the download (%d MB needed)"
                      % ((cache["img"]["size"] + SPACE_MARGIN) // 1000000))
    _dl_state(state="running", percent=0, version=cache["version"],
              name=cache["img"]["name"], started=int(now))
    subprocess.Popen([OSCONFIG, "ota", "download-worker"],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
    return {"result": "STARTED"}


def run_download(opener=None):
    """The background download (nebulaos-osconfig ota download-worker)."""
    os.makedirs(os.path.dirname(DOWNLOAD_LOCK), exist_ok=True)
    lock = os.open(DOWNLOAD_LOCK, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(lock)
        return
    cache, _ = common.read_json(CHECK_CACHE)
    img = (cache or {}).get("img") or {}
    base = {"version": (cache or {}).get("version"), "name": img.get("name")}
    part = None
    try:
        if not (cache and cache.get("available") and _IMG_RE.match(img.get("name") or "")):
            raise OsConfigError("OTA_NOTHING_OFFERED", "check for an update first")
        os.makedirs(DOWNLOAD_DIR, exist_ok=True)
        _clear_downloads()
        final = os.path.join(DOWNLOAD_DIR, img["name"])
        part = final + ".part"
        digest, got, shown = hashlib.sha256(), 0, -1
        with (opener or _open)(img["url"]) as resp, open(part, "wb") as out:
            while True:
                block = resp.read(image.CHUNK)
                if not block:
                    break
                got += len(block)
                if got > img["size"]:
                    raise OsConfigError("OTA_DOWNLOAD_BAD", "the download is larger than "
                                        "the release record says")
                digest.update(block)
                out.write(block)
                percent = got * 100 // img["size"]
                if percent != shown:
                    shown = percent
                    _dl_state(state="running", percent=percent, **base)
            out.flush()
            os.fsync(out.fileno())
        if got != img["size"]:
            raise OsConfigError("OTA_DOWNLOAD_BAD", "the download is incomplete")
        if digest.hexdigest() != img["sha256"]:
            raise OsConfigError("OTA_DOWNLOAD_BAD", "the download does not match the release "
                                "record (sha256)")
        os.replace(part, final)
        common.fsync_dir(DOWNLOAD_DIR)
        part = None
        _dl_state(state="finished", percent=100, file="ota/" + img["name"],
                  sha256=img["sha256"], **base)
    except Exception as exc:  # the job must always end in a state the screen can show
        if isinstance(exc, OsConfigError):
            code, message = exc.code, exc.message
        else:
            code, message = "OTA_DOWNLOAD_FAILED", "The download failed (%s: %s)." % (
                exc.__class__.__name__, exc)
        _dl_state(state="failed", error=code, message=message, **base)
    finally:
        if part:
            try:
                os.unlink(part)
            except OSError:
                pass
        os.close(lock)


def discard():
    if _download_running():
        raise invalid("BUSY", "a download is running")
    if image._job_active():
        raise invalid("BUSY", "an image install is running")
    _clear_downloads()
    try:
        os.unlink(DOWNLOAD_STATE)
    except OSError:
        pass
    return {"result": "DISCARDED"}
