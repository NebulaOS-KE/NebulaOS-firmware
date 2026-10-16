# nebulaos_osconfig.image - install a system image (NebulaOS or Creality .img)
# into the slot that is NOT running, from the touchscreen (on-printer image
# updates, human decisions 2026-10-14):
#
#   - NebulaOS may occupy both A/B slots; an install always writes the
#     inactive slot (kernel + rootfs) and then switches the OTA marker to it.
#     The running slot is never written. The RTOS partitions are never written.
#   - Sources: USB sticks and config/firmware/os (Mainsail upload). OTA later.
#   - Integrity checks only (no signing): the Creality OTA envelope (7z, the
#     chained per-chunk MD5 scheme, declared sizes and MD5s), a MIPS uImage
#     kernel and a squashfs rootfs that fit their partitions, and a read-back
#     of the written partitions.
#   - Older versions may be installed. Creality images are accepted.
#   - One automatic fallback after an install: the new slot boots as a trial;
#     S99nebulaos-image-trial confirms it, or switches back once.
#
#   image list                      .img files from the sources
#   image check --file ID           open the package, report what it holds
#   image install --file ID --sha256 HEX   start the install (background job)
#   image status                    the running/last job, slots, last result
#   image ack                       the screen showed the last result
#
# The format is the one scripts/package/build-img.py writes and Creality's own
# updater reads: an encrypted 7z holding <top>/ota_v<ver>/ with ota_update.in,
# and per payload <name>.NNNN.<md5 of the previous chunk, or of the whole
# payload for chunk 0000> plus ota_md5_<name>.<md5> listing the chunk MD5s.
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import time

from . import common, system
from .common import invalid, OsConfigError

SEVENZA = os.environ.get("NEBULAOS_7ZA", "/usr/bin/7za")
# The published F005 envelope password (mkpasswd -m md5 "F005C3_7e_bz" -S
# cxswfile, see scripts/package/build-img.py): a format detail, not a secret.
ENVELOPE_PASSWORD = "$1$cxswfile$ZFd0RWFYkJQugbtKVGL9y0"
UPLOAD_DIR = os.environ.get("NEBULAOS_IMAGE_UPLOAD_DIR", "/opt/printer_data/uploads/system-image")  # G62
USB_DIR = os.environ.get("NEBULAOS_MCU_USB_DIR", "/opt/printer_data/gcodes/USB")
USB_DEPTH = 2
MAX_ENTRIES = 2000
WORK_PARENT = os.environ.get("NEBULAOS_IMAGE_WORK", os.path.join(common.NEBULAOS_ROOT, "system", "image-work"))
JOB_DIR = os.path.join(common.RUN_DIR, "image-update")
JOB_STATE = os.path.join(JOB_DIR, "state.json")
TRIAL = os.environ.get("NEBULAOS_IMAGE_TRIAL", os.path.join(common.NEBULAOS_ROOT, "system", "image-update-trial.json"))
LAST = os.environ.get("NEBULAOS_IMAGE_LAST", os.path.join(common.NEBULAOS_ROOT, "system", "image-update-last.json"))
DEV_DIR = os.environ.get("NEBULAOS_DEV_DIR", "/dev")
SYS_BLOCK = os.environ.get("NEBULAOS_SYS_BLOCK", "/sys/class/block")
PROC_MOUNTS = os.environ.get("NEBULAOS_PROC_MOUNTS", "/proc/mounts")
SLOT_SWAP = os.environ.get("NEBULAOS_SLOT_SWAP", "/usr/libexec/nebulaos/nebulaos-slot-swap")
REBOOT = os.environ.get("NEBULAOS_REBOOT", "/sbin/reboot")
OSCONFIG = os.environ.get("NEBULAOS_OSCONFIG", "/usr/libexec/nebulaos/nebulaos-osconfig")
MOONRAKER_INFO = os.environ.get("NEBULAOS_MOONRAKER_INFO", "http://127.0.0.1:7125/server/info")
PROC_DIR = os.environ.get("NEBULAOS_PROC_DIR", "/proc")
TRIAL_SECONDS = int(os.environ.get("NEBULAOS_IMAGE_TRIAL_SECONDS", "300"))
TRIAL_POLL = float(os.environ.get("NEBULAOS_IMAGE_TRIAL_POLL", "5"))
CHUNK = 1048576
# G46/G48: what each slot and file holds, beyond the kernel name.
ROOT_DIR = os.environ.get("NEBULAOS_ROOT_DIR", "/")
MOUNT = os.environ.get("NEBULAOS_MOUNT", "/bin/mount")
UMOUNT = os.environ.get("NEBULAOS_UMOUNT", "/bin/umount")
IDENTITY_CACHE = os.path.join(common.RUN_DIR, "image-identity.json")
SEED_MANIFEST_REL = "opt/nebulaos-seeds/seed-manifest.json"
CREALITY_INFO_REL = "etc/ota_info"
BUILD_RECORD = "nebulaos-build.json"      # in an .img's payload dir (build-img.py)
MAX_IMG_BYTES = 1024 * 1024 * 1024

# docs/A_B_SLOT_MODEL.md: the SPL loads kernel/rootfs of slot B when the
# marker is "ota:kernel2", else slot A.
SLOTS = {
    "A": {"kernel": "mmcblk0p5", "rootfs": "mmcblk0p7", "kernel_name": "kernel",
          "rootfs_name": "rootfs", "marker": "ota:kernel"},
    "B": {"kernel": "mmcblk0p6", "rootfs": "mmcblk0p8", "kernel_name": "kernel2",
          "rootfs_name": "rootfs2", "marker": "ota:kernel2"},
}
UIMAGE_MAGIC = 0x27051956
SQUASHFS_MAGIC = b"hsqs"


def other_slot(slot):
    return {"A": "B", "B": "A"}.get(slot)


# -- what a kernel / slot holds ----------------------------------------------------

def uimage_name(head):
    """(name, arch) from a 64-byte U-Boot image header, or (None, None)."""
    if len(head) < 64 or struct.unpack(">I", head[:4])[0] != UIMAGE_MAGIC:
        return None, None
    name = head[32:64].split(b"\x00", 1)[0].decode("ascii", "replace")
    return name, head[29]


def system_kind(kernel_name):
    """'nebulaos' | 'creality' | 'unknown' from the kernel image's name:
    NebulaOS runs the 6.6 RT kernel, Creality's KE firmware 4.4."""
    if not kernel_name:
        return "unknown"
    if re.match(r"^Linux-6\.", kernel_name):
        return "nebulaos"
    if re.match(r"^Linux-4\.4\.", kernel_name):
        return "creality"
    return "unknown"


def _read_head(dev, size=64):
    try:
        with open(os.path.join(DEV_DIR, dev), "rb") as handle:
            return handle.read(size)
    except OSError:
        return b""


def root_identity(root):
    """What a mounted rootfs says about itself: {"build", "date"} from a
    NebulaOS build record, {"version"} from Creality's /etc/ota_info, {}."""
    try:
        with open(os.path.join(root, SEED_MANIFEST_REL)) as handle:
            man = json.load(handle)
        head = str(man.get("firmware_head") or "")
        if re.match(r"^[0-9a-f]{7,40}$", head):
            return {"build": head[:7], "date": str(man.get("build_date") or "")[:10]}
    except (OSError, ValueError, AttributeError):
        pass
    try:
        with open(os.path.join(root, CREALITY_INFO_REL), errors="replace") as handle:
            for line in handle.read(4096).splitlines():
                key, _, value = line.partition("=")
                if key.strip() == "ota_version" and value.strip():
                    return {"version": value.strip()[:40]}
    except OSError:
        pass
    return {}


def _rootfs_id(dev):
    """A squashfs superblock's magic, mkfs time and size - changes with every
    image written into the partition; "" when it holds no squashfs."""
    head = _read_head(dev, 48)
    if len(head) < 48 or head[:4] != SQUASHFS_MAGIC:
        return ""
    return head[8:12].hex() + head[40:48].hex()


def _job_active():
    job, _ = common.read_json(JOB_STATE)
    return bool(job) and job.get("state") in ("running", "restarting")


def _mounted_identity(dev):
    """Mount the other slot's rootfs read-only for a moment and read it."""
    point = os.path.join(common.RUN_DIR, "image-slot-ro")
    try:
        os.makedirs(point, exist_ok=True)
    except OSError:
        return None
    rc, _, _ = common.run([MOUNT, "-t", "squashfs", "-o", "ro", os.path.join(DEV_DIR, dev), point], 30)
    if rc != 0:
        return None
    try:
        return root_identity(point)
    finally:
        common.run([UMOUNT, point], 30)


def slot_identity(slot, running, may_mount):
    """{"build","date"} | {"version"} | {} for a slot, cached on its rootfs
    superblock. The running slot reads its own root; the other slot is
    mounted read-only - only when may_mount and no install is writing it."""
    dev = SLOTS[slot]["rootfs"]
    key = _rootfs_id(dev)
    if not key:
        return {}
    cache, _ = common.read_json(IDENTITY_CACHE)
    cache = cache if isinstance(cache, dict) else {}
    hit = cache.get(slot)
    if isinstance(hit, dict) and hit.get("key") == key:
        return hit.get("identity") or {}
    if slot == running:
        ident = root_identity(ROOT_DIR)
    elif may_mount and not _job_active():
        ident = _mounted_identity(dev)
        if ident is None:
            return {}
    else:
        return {}
    cache[slot] = {"key": key, "identity": ident}
    try:
        os.makedirs(common.RUN_DIR, exist_ok=True)
        common.atomic_write_json(IDENTITY_CACHE, cache)
    except Exception:  # a cache is never required
        pass
    return ident


def slots_info(may_mount=False):
    running = system.boot_slot()
    out = {"running": running}
    for slot, p in SLOTS.items():
        name, _ = uimage_name(_read_head(p["kernel"]))
        out[slot] = {"kernel": name, "system": system_kind(name)}
        out[slot].update(slot_identity(slot, running, may_mount))
    return out


def slot_bootable(slot):
    """False when the slot's kernel partition was read and holds no U-Boot
    image - e.g. after an install into it failed (run_job blanks the header
    then). True when it holds one, or cannot be read here at all."""
    head = _read_head(SLOTS[slot]["kernel"])
    if len(head) < 64:
        return True
    return uimage_name(head)[0] is not None


def _blank_kernel(dev):
    """Make a half-written slot unbootable on purpose: the bootloader has no
    way back from a kernel that cannot mount its system."""
    try:
        with open(os.path.join(DEV_DIR, dev), "r+b", buffering=0) as out:
            out.write(b"\x00" * 64)
            os.fsync(out.fileno())
        return True
    except OSError:
        return False


# -- sources ---------------------------------------------------------------------

def _scan(root, depth):
    found, seen = [], [0]

    def walk(rel, level):
        try:
            names = sorted(os.listdir(os.path.join(root, rel) if rel else root))
        except OSError:
            return
        for name in names:
            seen[0] += 1
            if seen[0] > MAX_ENTRIES or name.startswith("."):
                continue
            sub = os.path.join(rel, name) if rel else name
            try:
                st = os.lstat(os.path.join(root, sub))
            except OSError:
                continue
            if stat.S_ISDIR(st.st_mode):
                if level < depth:
                    walk(sub, level + 1)
            elif stat.S_ISREG(st.st_mode) and name.lower().endswith(".img"):
                found.append((sub, st))
    walk("", 0)
    return found


def _usb_mounts():
    try:
        names = sorted(os.listdir(USB_DIR))
    except OSError:
        return []
    return [n for n in names if not n.startswith(".")
            and os.path.isdir(os.path.join(USB_DIR, n))
            and not os.path.islink(os.path.join(USB_DIR, n))]


def list_files():
    files = []
    for rel, st in _scan(UPLOAD_DIR, 0):
        files.append({"id": "upload/" + rel, "source": "upload", "name": rel,
                      "size": st.st_size, "mtime": int(st.st_mtime)})
    mounts = _usb_mounts()
    for dev in mounts:
        for rel, st in _scan(os.path.join(USB_DIR, dev), USB_DEPTH):
            files.append({"id": "usb/%s/%s" % (dev, rel), "source": "usb", "name": rel,
                          "device": dev, "size": st.st_size, "mtime": int(st.st_mtime)})
    for f in files:
        f.update(file_identity(f["id"], f["size"], f["mtime"]))
    return {"files": files, "usb": mounts, "upload_dir": UPLOAD_DIR,
            "slots": slots_info(may_mount=True)}


def resolve(file_id):
    if not isinstance(file_id, str) or not file_id or "\x00" in file_id:
        raise invalid("INVALID_FILE", "no file given")
    parts = file_id.split("/")
    if ".." in parts or "" in parts:
        raise invalid("INVALID_FILE", "not a file from the list")
    if parts[0] == "upload" and len(parts) == 2:
        root, rel = UPLOAD_DIR, parts[1]
    elif parts[0] == "usb" and len(parts) >= 3:
        root, rel = os.path.join(USB_DIR, parts[1]), "/".join(parts[2:])
    else:
        raise invalid("INVALID_FILE", "not a file from the list")
    path = os.path.join(root, rel)
    real_root = os.path.realpath(root)
    if os.path.commonpath([os.path.realpath(path), real_root]) != real_root:
        raise invalid("INVALID_FILE", "not a file from the list")
    try:
        st = os.lstat(path)
    except OSError:
        raise invalid("FILE_GONE", "the file is no longer there (USB stick removed?)")
    if not stat.S_ISREG(st.st_mode):
        raise invalid("INVALID_FILE", "not a regular file")
    if st.st_size > MAX_IMG_BYTES:
        raise invalid("INVALID_IMAGE", "too large to be a KE system image")
    return path


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


# -- the package -------------------------------------------------------------------

def _7za(args, timeout):
    if not os.access(SEVENZA, os.X_OK):
        raise OsConfigError("NO_7ZA", "7-Zip is not installed in this image")
    return common.run([SEVENZA] + args + ["-p" + ENVELOPE_PASSWORD, "-y"], timeout)


def list_members(path):
    """Paths inside the archive (7za -slt listing)."""
    rc, out, err = _7za(["l", "-slt", path], 120)
    if rc != 0:
        raise invalid("INVALID_IMAGE", "not a KE update package (7-Zip could not open it)")
    return [line[len("Path = "):].strip() for line in out.splitlines()
            if line.startswith("Path = ")][1:]      # the first Path is the archive


def _member_head(path, member, size=64):
    """The first bytes of one member, streamed (7za x -so) and cut off there."""
    if not os.access(SEVENZA, os.X_OK):
        raise OsConfigError("NO_7ZA", "7-Zip is not installed in this image")
    proc = subprocess.Popen([SEVENZA, "x", "-so", path, member, "-p" + ENVELOPE_PASSWORD, "-y"],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)
    try:
        head = proc.stdout.read(size)
    finally:
        proc.kill()
        proc.wait()
    return head


def parse_update_in(text):
    """ota_update.in -> {"version", "images": {type: {name, size, md5}}}."""
    out = {"version": None, "images": {}}
    current = {}
    for line in text.splitlines() + [""]:
        line = line.strip()
        if not line:
            if current.get("img_type"):
                try:
                    size = int(current.get("img_size", ""))
                except ValueError:
                    size = -1
                out["images"][current["img_type"]] = {
                    "name": current.get("img_name", ""), "size": size,
                    "md5": current.get("img_md5", "").lower()}
            current = {}
            continue
        if "=" in line:
            key, value = line.split("=", 1)
            if key == "ota_version":
                out["version"] = value
            else:
                current[key] = value
    return out


def layout_of(members):
    """(payload dir, ota_update.in path) from the member list, or raises."""
    updates = [m for m in members if re.match(r"^[^/]+/ota_v[^/]+/ota_update\.in$", m)]
    if len(updates) != 1:
        raise invalid("INVALID_IMAGE", "not a KE update package (no ota_update.in)")
    return os.path.dirname(updates[0]), updates[0]


def chunk_names(members, payload_dir, name):
    """Chunk members of one payload, in index order, with the MD5 each name
    carries (whole payload for 0000, the previous chunk after that)."""
    pat = re.compile(r"^%s/%s\.(\d{4})\.([0-9a-f]{32})$" % (re.escape(payload_dir), re.escape(name)))
    chunks = []
    for m in members:
        hit = pat.match(m)
        if hit:
            chunks.append((int(hit.group(1)), hit.group(2), m))
    chunks.sort()
    if not chunks or [c[0] for c in chunks] != list(range(len(chunks))):
        raise invalid("INVALID_IMAGE", "the %s data in the package is incomplete" % name)
    return chunks


def describe(path):
    """Open the package, without unpacking the payloads."""
    members = list_members(path)
    payload_dir, update_in = layout_of(members)
    rc, out, _ = _7za(["x", "-so", path, update_in], 120)
    if rc != 0:
        raise invalid("INVALID_IMAGE", "ota_update.in could not be read")
    upd = parse_update_in(out)
    for kind in ("kernel", "rootfs"):
        rec = upd["images"].get(kind)
        if not rec or rec["size"] <= 0 or not re.match(r"^[0-9a-f]{32}$", rec["md5"]):
            raise invalid("INVALID_IMAGE", "the package has no valid %s record" % kind)
        chunks = chunk_names(members, payload_dir, rec["name"])
        if chunks[0][1] != rec["md5"]:
            raise invalid("INVALID_IMAGE", "the %s chunk chain does not match its record" % kind)
        if len(chunks) != (rec["size"] + CHUNK - 1) // CHUNK:
            raise invalid("INVALID_IMAGE", "the %s chunk count does not match its size" % kind)
    build = _build_record(path, members, payload_dir)
    kname, arch = uimage_name(_member_head(path, chunk_names(members, payload_dir,
                                                         upd["images"]["kernel"]["name"])[0][2]))
    return {"version": upd["version"], "images": upd["images"], "payload_dir": payload_dir,
            "members": members, "kernel_name": kname, "kernel_arch": arch,
            "system": system_kind(kname), "build": build}


def _build_record(path, members, payload_dir):
    """{"build", "date"} from a NebulaOS .img's build record, else {}."""
    member = "%s/%s" % (payload_dir, BUILD_RECORD)
    if member not in members:
        return {}
    rc, out, _ = _7za(["x", "-so", path, member], 120)
    try:
        rec = json.loads(out) if rc == 0 else {}
        head = str(rec.get("firmware_head") or "")
    except (ValueError, AttributeError):
        return {}
    if not re.match(r"^[0-9a-f]{7,40}$", head):
        return {}
    return {"build": head[:7], "date": str(rec.get("build_date") or "")[:10]}


def file_identity(file_id, size, mtime):
    """{"version"} plus {"build","date"} for a listed .img, from its
    ota_update.in and build record - cached on id, size and mtime. {} when
    it cannot be opened (check says why)."""
    key = "%s|%d|%d" % (file_id, size, mtime)
    cache, _ = common.read_json(IDENTITY_CACHE)
    cache = cache if isinstance(cache, dict) else {}
    files = cache.get("files") if isinstance(cache.get("files"), dict) else {}
    if key in files:
        return files[key]
    ident = {}
    try:
        path = resolve(file_id)
        members = list_members(path)
        payload_dir, update_in = layout_of(members)
        rc, out, _ = _7za(["x", "-so", path, update_in], 120)
        if rc == 0:
            version = parse_update_in(out)["version"]
            if version:
                ident["version"] = version[:40]
        ident.update(_build_record(path, members, payload_dir))
    except OsConfigError:
        return {}
    files[key] = ident
    cache["files"] = dict(list(files.items())[-50:])
    try:
        os.makedirs(common.RUN_DIR, exist_ok=True)
        common.atomic_write_json(IDENTITY_CACHE, cache)
    except Exception:
        pass
    return ident


def check(file_id):
    path = resolve(file_id)
    info = describe(path)
    slots = slots_info(may_mount=True)
    sizes = {k: _partition_bytes(SLOTS["A"][k]) for k in ("kernel", "rootfs")}
    for kind in ("kernel", "rootfs"):
        if sizes[kind] and info["images"][kind]["size"] > sizes[kind]:
            raise invalid("INVALID_IMAGE", "the %s does not fit its partition" % kind)
    return {"result": "OK", "file": file_id, "sha256": sha256_file(path),
            "size": os.path.getsize(path), "version": info["version"],
            "kernel_size": info["images"]["kernel"]["size"],
            "rootfs_size": info["images"]["rootfs"]["size"],
            "has_rtos": "rtos" in info["images"], "slots": slots,
            "target": other_slot(slots["running"]),
            "system": info["system"], "kernel": info["kernel_name"],
            "build": info["build"].get("build"), "date": info["build"].get("date")}


# -- partitions ---------------------------------------------------------------------

def _partition_bytes(dev):
    try:
        with open(os.path.join(SYS_BLOCK, dev, "size")) as handle:
            return int(handle.read().strip()) * 512
    except (OSError, ValueError):
        return None


def _partition_name(dev):
    try:
        with open(os.path.join(SYS_BLOCK, dev, "uevent")) as handle:
            for line in handle:
                if line.startswith("PARTNAME="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return None


def _mounted_devices():
    try:
        with open(PROC_MOUNTS) as handle:
            return {line.split()[0] for line in handle if line.strip()}
    except OSError:
        return set()


def target_partitions(running):
    """The inactive slot's kernel and rootfs devices - refused unless every
    fact agrees: a known running slot, the other slot's partition names, and
    nothing of it mounted."""
    target = other_slot(running)
    if target is None:
        raise OsConfigError("SLOT_UNKNOWN", "cannot tell which slot is running; nothing written")
    t = SLOTS[target]
    for part, expect in ((t["kernel"], t["kernel_name"]), (t["rootfs"], t["rootfs_name"])):
        got = _partition_name(part)
        if got != expect:
            raise OsConfigError("PARTITION_MISMATCH", "%s is %r, expected %r; nothing written"
                                % (part, got, expect))
        if os.path.join("/dev", part) in _mounted_devices():
            raise OsConfigError("TARGET_MOUNTED", "%s is mounted; nothing written" % part)
    running_root = SLOTS[running]["rootfs"]
    if running_root in (t["kernel"], t["rootfs"]):   # pragma: no cover - table invariant
        raise OsConfigError("TARGET_IS_RUNNING", "refusing to write the running slot")
    return target, t


# -- the job --------------------------------------------------------------------------

def _state(**fields):
    os.makedirs(JOB_DIR, exist_ok=True)
    fields["updated"] = int(time.time())
    common.atomic_write_json(JOB_STATE, fields)


def _md5_file(path, length=None):
    digest = hashlib.md5()
    left = length
    with open(path, "rb") as handle:
        while left is None or left > 0:
            block = handle.read(CHUNK if left is None else min(CHUNK, left))
            if not block:
                break
            digest.update(block)
            if left is not None:
                left -= len(block)
    return digest.hexdigest()


def _write_payload(work, payload_dir, rec, dev, label, progress, share):
    """Verify the chunk chain against ota_md5_<name>.<md5> while writing the
    chunks to the partition, then read the partition back."""
    name, size, whole = rec["name"], rec["size"], rec["md5"]
    base = os.path.join(work, payload_dir)
    lists = [f for f in os.listdir(base) if f == "ota_md5_%s.%s" % (name, whole)]
    if not lists:
        raise OsConfigError("INVALID_IMAGE", "the %s checksum list is missing" % name)
    with open(os.path.join(base, lists[0])) as handle:
        sums = [s.strip().lower() for s in handle if s.strip()]
    count = (size + CHUNK - 1) // CHUNK
    if len(sums) != count:
        raise OsConfigError("INVALID_IMAGE", "the %s checksum list has the wrong length" % name)
    devpath = os.path.join(DEV_DIR, dev)
    previous = whole
    total = hashlib.md5()
    with open(devpath, "r+b", buffering=0) as out:
        for index in range(count):
            chunk_file = os.path.join(base, "%s.%04d.%s" % (name, index, previous))
            try:
                with open(chunk_file, "rb") as handle:
                    data = handle.read(CHUNK + 1)
            except OSError:
                raise OsConfigError("INVALID_IMAGE", "%s chunk %d is missing" % (name, index))
            want = CHUNK if index < count - 1 else size - CHUNK * (count - 1)
            got = hashlib.md5(data).hexdigest()
            if len(data) != want or got != sums[index]:
                raise OsConfigError("INVALID_IMAGE", "%s chunk %d is damaged" % (name, index))
            if index == 0:
                if label == "kernel":
                    kname, arch = uimage_name(data[:64])
                    if kname is None or arch != 5:
                        raise OsConfigError("INVALID_IMAGE", "the kernel is not a MIPS kernel for this board")
                elif data[:4] != SQUASHFS_MAGIC:
                    raise OsConfigError("INVALID_IMAGE", "the system part is not a squashfs image")
            total.update(data)
            out.seek(index * CHUNK)
            out.write(data)
            previous = got
            progress(share[0] + (share[1] - share[0]) * (index + 1) // count)
        os.fsync(out.fileno())
    if total.hexdigest() != whole:
        raise OsConfigError("INVALID_IMAGE", "%s does not match its checksum" % name)
    if _md5_file(devpath, size) != whole:
        raise OsConfigError("WRITE_VERIFY_FAILED", "%s read back differently from the partition" % name)


def run_job(file_id, sha256):
    """The background install (nebulaos-osconfig image worker)."""
    started = int(time.time())
    base = {"file": file_id, "started": started}
    work = None
    touched = None      # the kernel partition, once writing has started

    def progress(percent, phase="writing"):
        _state(state="running", phase=phase, percent=percent, **base)

    try:
        progress(1, "checking")
        path = resolve(file_id)
        if sha256_file(path) != sha256:
            raise OsConfigError("FILE_CHANGED", "the file changed since it was checked")
        running = system.boot_slot()
        target, parts = target_partitions(running)
        info = describe(path)
        sizes = {k: info["images"][k]["size"] for k in ("kernel", "rootfs")}
        for kind, dev in (("kernel", parts["kernel"]), ("rootfs", parts["rootfs"])):
            cap = _partition_bytes(dev)
            if cap is not None and sizes[kind] > cap:
                raise OsConfigError("INVALID_IMAGE", "the %s does not fit %s" % (kind, dev))
        os.makedirs(WORK_PARENT, exist_ok=True)
        need = os.path.getsize(path) + sum(sizes.values()) + 64 * CHUNK
        st = os.statvfs(WORK_PARENT)
        if st.f_bavail * st.f_frsize < need:
            raise OsConfigError("NO_SPACE", "not enough free space to unpack the image "
                                "(%d MB needed)" % (need // 1000000))
        work = os.path.join(WORK_PARENT, "job-%d" % started)
        progress(5, "unpacking")
        rc, _, err = _7za(["x", "-o" + work, path, info["payload_dir"] + "/*"], 1800)
        if rc != 0:
            raise OsConfigError("INVALID_IMAGE", "the package could not be unpacked")
        touched = parts["kernel"]
        _write_payload(work, info["payload_dir"], info["images"]["kernel"], parts["kernel"],
                       "kernel", progress, (30, 35))
        _write_payload(work, info["payload_dir"], info["images"]["rootfs"], parts["rootfs"],
                       "rootfs", progress, (35, 95))
        progress(96, "switching")
        kname, _ = uimage_name(_read_head(parts["kernel"]))
        kind = system_kind(kname)
        # The fallback check runs from NebulaOS's own init (S99nebulaos-image-trial).
        # Creality's firmware never runs it, so a Creality image gets no trial:
        # going back from there is flashing a NebulaOS .img with Creality's updater.
        if kind != "creality":
            common.atomic_write_json(TRIAL, {"from": running, "to": target, "file": file_id,
                                             "version": info["version"], "system": kind,
                                             "started": started})
        else:
            try:
                os.unlink(TRIAL)
            except OSError:
                pass
        rc, out, err = common.run([SLOT_SWAP, target], 30)
        if rc != 0:
            try:
                os.unlink(TRIAL)
            except OSError:
                pass
            touched = None      # fully written and verified: it may still be swapped to
            raise OsConfigError("SLOT_SWAP_FAILED", "the new slot is written but could not be "
                                "selected; the printer stays on the current version")
        _state(state="restarting", phase="restarting", percent=100, target=target,
               system=kind, version=info["version"], **base)
        common.run([REBOOT], 30)
    except Exception as exc:  # the job must always end in a state the screen can show
        if isinstance(exc, OsConfigError):
            code, message = exc.code, exc.message
        else:
            code, message = "INTERNAL", "%s: %s" % (type(exc).__name__, exc)
        cleared = bool(touched) and _blank_kernel(touched)
        _state(state="failed", phase="failed", error=code, message=message,
               target_cleared=cleared, **base)
    finally:
        if work:
            shutil.rmtree(work, ignore_errors=True)


def install(file_id, sha256):
    if not isinstance(sha256, str) or not re.match(r"^[0-9a-f]{64}$", sha256 or ""):
        raise invalid("INVALID_FILE", "the file must be checked first")
    current, _ = common.read_json(JOB_STATE)
    if current and current.get("state") in ("running", "restarting"):
        raise invalid("BUSY", "an image install is already running")
    resolve(file_id)
    target_partitions(system.boot_slot())     # refuse early, before the job starts
    _state(state="running", phase="starting", percent=0, file=file_id, started=int(time.time()))
    subprocess.Popen([OSCONFIG, "image", "worker", "--file", file_id, "--sha256", sha256],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
    return {"result": "STARTED", "applies": "the printer restarts into the new version"}


def status():
    job, _ = common.read_json(JOB_STATE)
    last, _ = common.read_json(LAST)
    trial, _ = common.read_json(TRIAL)
    return {"job": job, "last": last if last and not last.get("acknowledged") else None,
            "trial": trial, "slots": slots_info()}


def ack():
    last, _ = common.read_json(LAST)
    if last and not last.get("acknowledged"):
        last["acknowledged"] = True
        common.atomic_write_json(LAST, last)
    return {"result": "ACKNOWLEDGED"}


# -- the one-time fallback after an install (S99nebulaos-image-trial) -----------------

def _klipper_ready():
    import urllib.request
    try:
        with urllib.request.urlopen(MOONRAKER_INFO, timeout=4) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace"))
        return data.get("result", {}).get("klippy_state") == "ready"
    except Exception:
        return False


def _gui_running():
    try:
        pids = [p for p in os.listdir(PROC_DIR) if p.isdigit()]
    except OSError:
        return False
    for pid in pids:
        try:
            with open(os.path.join(PROC_DIR, pid, "comm")) as handle:
                if handle.read().strip() == "guppyscreen":
                    return True
        except OSError:
            continue
    return False


def _record(trial, result, note=None):
    common.atomic_write_json(LAST, {
        "result": result, "note": note, "file": trial.get("file"),
        "version": trial.get("version"), "system": trial.get("system"),
        "from": trial.get("from"), "to": trial.get("to"),
        "at": int(time.time()), "acknowledged": False})


def trial():
    """First boot after an install: confirm the new slot, or go back ONCE."""
    t, _ = common.read_json(TRIAL)
    if not t:
        return {"result": "NO_TRIAL"}
    running = system.boot_slot()
    if running != t.get("to"):
        # Not on the new slot: it never started, or the switch was undone.
        _record(t, "NOT_STARTED", "the printer is still on slot %s" % running)
        os.unlink(TRIAL)
        return {"result": "NOT_STARTED"}
    deadline = time.monotonic() + TRIAL_SECONDS
    while True:
        if _klipper_ready() and _gui_running():
            _record(t, "CONFIRMED")
            os.unlink(TRIAL)
            return {"result": "CONFIRMED"}
        if time.monotonic() >= deadline:
            break
        time.sleep(TRIAL_POLL)
    # Remove the trial BEFORE switching back: whatever happens next, this
    # fallback can never run a second time.
    os.unlink(TRIAL)
    _record(t, "ROLLED_BACK", "Klipper or the screen did not come up within %d s"
            % TRIAL_SECONDS)
    rc, _, _ = common.run([SLOT_SWAP, t.get("from", "")], 30)
    if rc != 0:
        _record(t, "ROLLBACK_FAILED", "the previous slot could not be selected")
        return {"result": "ROLLBACK_FAILED"}
    common.run([REBOOT], 30)
    return {"result": "ROLLED_BACK"}
