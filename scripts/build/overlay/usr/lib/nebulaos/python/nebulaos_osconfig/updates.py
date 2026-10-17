# nebulaos_osconfig.updates - G73 (2026-10-17): is a pending app update
# installable on this printer?
#
# Moonraker's update_manager installs Klipper and Moonraker updates with
# `pip install -U -r <requirements>` against the NebulaOS package index
# (ready-made packages only - there is no compiler on the printer), and a
# Klipper update that changes klippy/chelper also needs a matching
# c_helper.so (G72). When the index has not caught up yet (it builds daily),
# the update fails and is rolled back. This check says so BEFORE the update
# button is pressed. Advisory only: it never blocks an update.
#
#   readiness         the last result (read-only, cached file)
#   check-readiness   run the check now and store it [--if-changed]
#
# Rules (architecture review 2026-10-17):
#   - the target commit is Moonraker's own remote_hash; no ref guessing
#   - no `git fetch` and no other write to the app repositories (Moonraker
#     owns fetching) - only `git show <remote_hash>:<file>` / ls-tree
#   - never started while update_manager is busy (pip in the same venv) or
#     printing; an update started DURING a check overlaps it (pip --dry-run
#     only reads the venv), which is accepted
#   - read-only git: show, ls-tree, cat-file - never fetch
#   - pip runs as Moonraker runs it: the app's own venv, `--dry-run`, the
#     index from /etc/pip.conf, temporary files on /usr/data (not RAM)
import json
import os
import re
import shutil
import tempfile
import time
import urllib.request

from . import common

MOONRAKER = os.environ.get("NEBULAOS_MOONRAKER_BASE", "http://127.0.0.1:7125")
STATE = os.path.join(common.NEBULAOS_ROOT, "updates", "readiness.json")
PIP_CONF = os.environ.get("NEBULAOS_PIP_CONF", "/etc/pip.conf")
CHELPER_LIB = os.environ.get("NEBULAOS_CHELPER_LIB", "/etc/nebulaos-chelper-preflight.sh")
CHELPER_URL_FILE = os.environ.get("NEBULAOS_CHELPER_URL_FILE", "/usr/share/nebulaos/chelper-index.url")
# Per app; with both pending plus the helper lookup the whole check stays
# under the [nebulaos] component's READINESS_TIMEOUT (1800 s).
PIP_TIMEOUT = 720
# --if-changed still re-checks a result that was not a clear yes, or is old:
# the index catches up daily and a network hiccup must not stick.
RECHECK_SECONDS = 6 * 3600

# The requirement files Moonraker's update_manager installs (its
# update_manager/common.py), and the venv each app runs from.
APPS = {
    "moonraker": ("scripts/moonraker-requirements.txt", "moonraker"),
    "klipper": ("scripts/klippy-requirements.txt", "klipper"),
}


def _get(path, timeout=10):
    with urllib.request.urlopen(MOONRAKER + path, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))["result"]


def _printing():
    if os.path.exists(os.path.join(common.RUN_DIR, "print-active")):
        return True
    try:
        state = _get("/printer/objects/query?print_stats=state", 5)["status"]["print_stats"]["state"]
    except Exception:
        return False
    return state in ("printing", "paused")


def _index_url():
    try:
        with open(PIP_CONF) as handle:
            for line in handle:
                m = re.match(r"\s*index-url\s*=\s*(\S+)", line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return None


def _git(repo, *args):
    rc, out, _ = common.run(["git", "-C", repo] + list(args), 60)
    return out if rc == 0 else None


def _chelper(repo, target):
    """unchanged | cached | available | missing | unknown, plus the hash."""
    script = ('. "$1"; t=$(chelper_source_hash_git "$2" "$3") || exit 1; '
              'c=$(chelper_source_hash "$2") || exit 1; i=$(chelper_abi_id); '
              'echo "$t $c $i $NEBULAOS_CHELPER_CACHE"')
    rc, out, _ = common.run(["sh", "-c", script, "sh", CHELPER_LIB, repo, target], 120)
    parts = out.split() if rc == 0 else []
    if len(parts) != 4:
        return "unknown", None
    want, have, abi_id, cache = parts
    if want == have:
        return "unchanged", want
    if os.path.isfile(os.path.join(cache, abi_id, want, "c_helper.so")):
        return "cached", want
    try:
        with open(CHELPER_URL_FILE) as handle:
            url = handle.read().strip()
    except OSError:
        return "unknown", want
    rc, out, _ = common.run(["curl", "-fsSL", "--max-time", "60",
                             "%s/%s/index" % (url.rstrip("/"), abi_id)], 90)
    if rc != 0:
        return "unknown", want
    listed = any(line.split()[:1] == [want] for line in out.splitlines())
    return ("available" if listed else "missing"), want


def _packages(name, repo, target, index_url):
    """ok | missing | unknown, and pip's last words when not ok."""
    req_path, env = APPS[name]
    text = _git(repo, "show", "%s:%s" % (target, req_path))
    if text is None:
        return "unknown", "cannot read %s at %s" % (req_path, target[:7])
    python = os.path.join(common.NEBULAOS_ROOT, "envs", env, "bin", "python")
    if not os.path.exists(python):
        return "unknown", "no venv at %s" % python
    tmp_root = os.path.join(common.NEBULAOS_ROOT, "tmp")
    os.makedirs(tmp_root, exist_ok=True)
    work = tempfile.mkdtemp(prefix="readiness-", dir=tmp_root)
    try:
        reqs = os.path.join(work, "requirements.txt")
        with open(reqs, "w") as handle:
            handle.write("".join(l + "\n" for l in text.splitlines()
                                 if not l.strip().startswith("--find-links")))
        env_vars = dict(os.environ, TMPDIR=work, PIP_DISABLE_PIP_VERSION_CHECK="1")
        rc, out, err = common.run(
            [python, "-m", "pip", "install", "--dry-run", "--no-cache-dir", "--quiet",
             "--report", os.path.join(work, "report.json"), "--only-binary=:all:",
             "--index-url", index_url, "-U", "-r", reqs], PIP_TIMEOUT, env=env_vars)
        if rc == 0:
            return "ok", ""
        last = [l for l in (err or out).splitlines() if l.strip()][-2:]
        if rc == 124:
            return "unknown", "pip timed out"
        missing = any("No matching distribution" in l or "Could not find a version" in l
                      for l in (err or "").splitlines())
        return ("missing" if missing else "unknown"), " ".join(last)[:300]
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _message(apps):
    blocked = [n for n, a in apps.items() if a.get("ready") is False]
    if not apps:
        return "No Klipper or Moonraker update pending."
    unknown = [n for n, a in apps.items() if a.get("ready") is None]
    if not blocked and unknown:
        return ("Could not check whether the pending %s update can be installed (%s)."
                % (" and ".join(n.capitalize() for n in sorted(unknown)),
                   "; ".join(apps[n].get("detail") or apps[n].get("helper", "") for n in sorted(unknown))))
    if not blocked:
        return "The pending update can be installed."
    names = " and ".join(n.capitalize() for n in sorted(blocked))
    return ("%s update: the NebulaOS package index does not have everything this "
            "version needs yet (it is built daily). Installing now would fail and "
            "be rolled back - wait a day and check again." % names)


def readiness():
    obj, error = common.read_json(STATE)
    if obj is None:
        return {"result": "UNKNOWN", "message": error or "Not checked yet.", "apps": {}}
    return obj


def check(if_changed=False):
    try:
        status = _get("/machine/update/status")
    except Exception as exc:
        return {"result": "UNAVAILABLE", "message": "Moonraker's update status is not available (%s)" % exc}
    if status.get("busy"):
        return {"result": "BUSY", "message": "An update is running; checked afterwards."}
    if _printing():
        return {"result": "PRINTING", "message": "Not checked while printing."}
    info = status.get("version_info", {})
    targets = {}
    for name in APPS:
        v = info.get(name) or {}
        remote, current = v.get("remote_hash"), v.get("current_hash")
        if remote and current and remote != current:
            targets[name] = remote
    previous, _ = common.read_json(STATE)
    if (if_changed and previous and previous.get("targets") == targets
            and previous.get("result") in ("READY", "NO_UPDATES")
            and time.time() - previous.get("checked_epoch", 0) < RECHECK_SECONDS):
        return {"result": "UNCHANGED", "message": previous.get("message", "")}
    index_url = _index_url()
    apps = {}
    for name, target in sorted(targets.items()):
        repo = os.path.join(common.NEBULAOS_ROOT, "apps", name)
        entry = {"target": target}
        if _git(repo, "cat-file", "-e", target + "^{commit}") is None:
            entry.update(packages="unknown", detail="target commit not fetched yet")
        elif not index_url:
            entry.update(packages="unknown", detail="no package index in %s" % PIP_CONF)
        else:
            entry["packages"], entry["detail"] = _packages(name, repo, target, index_url)
        if name == "klipper":
            entry["helper"], entry["helper_source_hash"] = _chelper(repo, target)
        bad = entry["packages"] == "missing" or entry.get("helper") == "missing"
        good = entry["packages"] == "ok" and entry.get("helper", "unchanged") in ("unchanged", "cached", "available")
        entry["ready"] = False if bad else (True if good else None)
        apps[name] = entry
    if not apps:
        result = "NO_UPDATES"
    elif any(a["ready"] is False for a in apps.values()):
        result = "NOT_READY"
    elif all(a["ready"] for a in apps.values()):
        result = "READY"
    else:
        result = "UNKNOWN"
    out = {"result": result, "targets": targets, "apps": apps, "message": _message(apps),
           "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "checked_epoch": int(time.time())}
    common.atomic_write_json(STATE, out)
    return out
