"""The transaction journal and the host lock.

THE JOURNAL IS ADVISORY. REALITY WINS.

This is the single most important thing about it. The journal records what the
installer BELIEVED was happening. The printer records what actually happened.
When they disagree, the device is right and the journal is stale - it was
written by a process that may have been killed between deciding to act and
acting, or before it could record that it had.

So nothing here is ever used as a substitute for observation. Before any
destructive resume, the caller re-observes device identity, which OS is running,
the active root, the boot id, the marker, slot-2 state and hashes, the staged
payload hashes and the flash lock - and then reconciles. The journal's job is to
say "a transaction was open, here is what it was for", which turns an
unexplained ARMED marker into a known one.

WHY IT IS KEYED THE WAY IT IS

    device id + control commit C + product commit X + xImage sha + rootfs sha

A transaction is only resumable if all five still hold. A different X, or a
rebuilt X whose artifacts differ, is a different transaction that happens to
involve the same printer, and resuming into it would install something nobody
asked for.

ATOMIC WRITES

Every update is written to a temporary file in the same directory, fsynced, then
renamed over the target. A journal truncated by a crash mid-write is worse than
no journal: it reads as a valid record of a state that was never reached.

THE HOST LOCK

One installer per device per host. Taken with O_EXCL so the check and the claim
are one operation - a "does the lock exist" test followed by a create is a race
with exactly the window that matters. The lock records pid and boot id so a lock
left by a crashed process can be recognised as stale rather than blocking
forever, and staleness is decided by whether that pid is still alive, not by an
age heuristic.

The device-side flash lock is separate and lives on the printer
(DeviceSession.acquire_flash_lock). Two hosts cannot see each other's host
locks, so the device-side one is what actually prevents two machines writing at
once. Both exist because they fail differently: the host lock gives a clean
local error, the device lock is the real mutual exclusion.
"""

import errno
import os
import time

DEFAULT_STATE_HOME = os.path.join(
    os.path.expanduser("~"), ".local", "state", "nebulaos-hardware")
ENV_STATE_HOME = "NEBULAOS_HARDWARE_STATE"

# The transaction states. Ordered as the install walks them, which is also the
# order in which a resume reasons about "how far did we get".
SAFE_NEBULAOS = "SAFE_NEBULAOS"
PRECHECKED = "PRECHECKED"
ARMED_STOCK = "ARMED_STOCK"
REBOOTING_TO_STOCK = "REBOOTING_TO_STOCK"
STOCK_RUNNING = "STOCK_RUNNING"
FLASHING = "FLASHING"
FLASH_VERIFIED = "FLASH_VERIFIED"
ARMED_NEBULAOS = "ARMED_NEBULAOS"
REBOOTING_TO_NEBULAOS = "REBOOTING_TO_NEBULAOS"
NEBULAOS_RUNNING = "NEBULAOS_RUNNING"
# The INACTIVE_SLOT path (nebulaos_slots): NebulaOS keeps running while the
# other slot is written. Separate from FLASHING/FLASH_VERIFIED on purpose: those
# are stock-window states (Creality running, a power cycle dangerous), these
# are not - the marker still selects the running NebulaOS slot throughout.
SLOT_FLASHING = "SLOT_FLASHING"
SLOT_FLASH_VERIFIED = "SLOT_FLASH_VERIFIED"
CLOSE_BACKWARD = "CLOSE_BACKWARD"
FAILED_NEEDS_ATTENTION = "FAILED_NEEDS_ATTENTION"
DONE = "DONE"

ALL_STATES = (
    SAFE_NEBULAOS, PRECHECKED, ARMED_STOCK, REBOOTING_TO_STOCK, STOCK_RUNNING,
    FLASHING, FLASH_VERIFIED, SLOT_FLASHING, SLOT_FLASH_VERIFIED, ARMED_NEBULAOS,
    REBOOTING_TO_NEBULAOS, NEBULAOS_RUNNING, CLOSE_BACKWARD, FAILED_NEEDS_ATTENTION, DONE,
)

# States in which the printer is armed to boot Creality's slot. A power cycle
# here auto-flashes the MCU, so they are named as a set rather than compared
# one at a time at call sites.
ARMED_FOR_STOCK_STATES = frozenset({ARMED_STOCK, REBOOTING_TO_STOCK})

# States during which the device is running stock and a power cycle is dangerous.
STOCK_WINDOW_STATES = frozenset({
    ARMED_STOCK, REBOOTING_TO_STOCK, STOCK_RUNNING, FLASHING, FLASH_VERIFIED,
})

TERMINAL_STATES = frozenset({DONE, FAILED_NEEDS_ATTENTION})

# States that PROVE the device is back on NebulaOS with the marker on NebulaOS.
# Only these (or a read-back-verified disarm, mark_disarmed) clear the danger
# record below. CLOSE_BACKWARD does NOT: it is entered before a disarm is tried.
SAFE_PROVEN_STATES = frozenset({SAFE_NEBULAOS, NEBULAOS_RUNNING, DONE})

# Sticky field. A refusal advances the journal to FAILED_NEEDS_ATTENTION, and
# an earlier revision thereby ERASED the fact that the printer was armed for,
# or running, stock - so `status` answered "safe to power cycle" in exactly the
# state where that advice destroys the MCU. The last stock-window state is
# remembered here until the device is proven safe again.
DANGER_FIELD = "LAST_STOCK_WINDOW_STATE"


class JournalError(Exception):
    pass


class LockError(Exception):
    pass


def state_home():
    return os.environ.get(ENV_STATE_HOME) or DEFAULT_STATE_HOME


def _ensure_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass
    return path


def _atomic_write(path, text):
    directory = os.path.dirname(path)
    tmp = os.path.join(directory, ".%s.tmp.%d" % (os.path.basename(path), os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        # fsync the directory too, so the rename itself is durable.
        dfd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class Transaction:
    """One install attempt against one device, for one exact product build."""

    KEY_FIELDS = ("DEVICE_ID", "CONTROL_COMMIT", "PRODUCT_HEAD",
                  "XIMAGE_SHA256", "ROOTFS_SHA256")

    def __init__(self, path, fields, history):
        self.path = path
        self.fields = fields
        self.history = history

    # -- construction ------------------------------------------------------
    @classmethod
    def path_for(cls, device_id):
        return os.path.join(_ensure_dir(os.path.join(state_home(), "transactions")),
                            "%s.journal" % device_id)

    @classmethod
    def open(cls, device_id):
        """Load an existing transaction, or None."""
        path = cls.path_for(device_id)
        if not os.path.exists(path):
            return None
        fields, history = {}, []
        with open(path, "r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("HISTORY="):
                    history.append(line.split("=", 1)[1])
                elif "=" in line:
                    k, _, v = line.partition("=")
                    fields[k.strip()] = v.strip()
        if not fields:
            raise JournalError("journal at %s has no fields - refusing to guess at it" % path)
        return cls(path, fields, history)

    @classmethod
    def begin(cls, device_id, control_commit, product_head, ximage_sha, rootfs_sha):
        path = cls.path_for(device_id)
        fields = {
            "JOURNAL_VERSION": "1",
            "DEVICE_ID": device_id,
            "CONTROL_COMMIT": control_commit,
            "PRODUCT_HEAD": product_head,
            "XIMAGE_SHA256": ximage_sha,
            "ROOTFS_SHA256": rootfs_sha,
            "STATE": SAFE_NEBULAOS,
            "STARTED_AT": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        txn = cls(path, fields, [])
        txn._record("begin transaction in state %s" % SAFE_NEBULAOS)
        return txn

    # -- state -------------------------------------------------------------
    @property
    def state(self):
        return self.fields.get("STATE", "")

    def matches(self, device_id, control_commit, product_head, ximage_sha, rootfs_sha):
        """All five key fields, or it is a different transaction."""
        want = dict(zip(self.KEY_FIELDS,
                        (device_id, control_commit, product_head, ximage_sha, rootfs_sha)))
        for key, value in want.items():
            if self.fields.get(key) != value:
                return False, ("journal %s=%s but this request states %s"
                               % (key, self.fields.get(key), value))
        return True, "journal key fields match this request exactly"

    def advance(self, new_state, note=""):
        if new_state not in ALL_STATES:
            raise JournalError("unknown transaction state %r" % new_state)
        previous = self.state
        if new_state in STOCK_WINDOW_STATES:
            self.fields[DANGER_FIELD] = new_state
        elif new_state in SAFE_PROVEN_STATES:
            self.fields.pop(DANGER_FIELD, None)
        self.fields["STATE"] = new_state
        self.fields["UPDATED_AT"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self._record("%s -> %s%s" % (previous, new_state, (": " + note) if note else ""))
        return self

    def mark_disarmed(self, detail=""):
        """The marker was physically re-read as NebulaOS while NebulaOS runs."""
        self.fields.pop(DANGER_FIELD, None)
        self._record("disarm verified%s" % ((": " + detail) if detail else ""))

    @property
    def danger_state(self):
        """The state that decides power-cycle safety: the live state while it is
        itself a stock-window state, else the remembered one (if any)."""
        if self.state in STOCK_WINDOW_STATES:
            return self.state
        return self.fields.get(DANGER_FIELD, "")

    @property
    def power_cycle_dangerous(self):
        return self.danger_state in STOCK_WINDOW_STATES

    @property
    def armed_for_stock(self):
        return self.danger_state in STOCK_WINDOW_STATES

    def note(self, text):
        self._record("note: %s" % text)

    def record(self, fields, note=""):
        """Remember observed facts (the install path, the slot state) for
        `status`, which never contacts the device. Advisory like the rest:
        reported as LAST OBSERVED, never used to skip a check."""
        for key, value in fields.items():
            if key in self.KEY_FIELDS or key in ("STATE", "JOURNAL_VERSION", DANGER_FIELD):
                raise JournalError("record() cannot set %s" % key)
            self.fields[key] = str(value)
        self._record("observed: %s" % (note or ", ".join("%s=%s" % kv for kv in sorted(fields.items()))))

    def _record(self, entry):
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.history.append("%s %s" % (stamp, entry))
        self._flush()

    def _flush(self):
        lines = ["# NebulaOS hardware transaction journal",
                 "# ADVISORY ONLY. The device is authoritative; this records intent.",
                 "# Keyed by device + control commit + product commit + both artifact hashes.",
                 ""]
        for key in ("JOURNAL_VERSION", "DEVICE_ID", "CONTROL_COMMIT", "PRODUCT_HEAD",
                    "XIMAGE_SHA256", "ROOTFS_SHA256", "STATE", "STARTED_AT", "UPDATED_AT"):
            if key in self.fields:
                lines.append("%s=%s" % (key, self.fields[key]))
        for key in sorted(self.fields):
            if key not in ("JOURNAL_VERSION", "DEVICE_ID", "CONTROL_COMMIT", "PRODUCT_HEAD",
                           "XIMAGE_SHA256", "ROOTFS_SHA256", "STATE", "STARTED_AT", "UPDATED_AT"):
                lines.append("%s=%s" % (key, self.fields[key]))
        lines.append("")
        # Bounded: a journal is a record, not a log file.
        for entry in self.history[-200:]:
            lines.append("HISTORY=%s" % entry)
        _atomic_write(self.path, "\n".join(lines) + "\n")

    def close(self, final_state, note=""):
        if final_state not in TERMINAL_STATES:
            raise JournalError("close() takes a terminal state, got %r" % final_state)
        self.advance(final_state, note)

    def describe(self):
        return "\n".join([
            "TRANSACTION_STATE=%s" % self.state,
            "TRANSACTION_DEVICE_ID=%s" % self.fields.get("DEVICE_ID", ""),
            "TRANSACTION_CONTROL_COMMIT=%s" % self.fields.get("CONTROL_COMMIT", ""),
            "TRANSACTION_PRODUCT_HEAD=%s" % self.fields.get("PRODUCT_HEAD", ""),
            "TRANSACTION_XIMAGE_SHA256=%s" % self.fields.get("XIMAGE_SHA256", ""),
            "TRANSACTION_ROOTFS_SHA256=%s" % self.fields.get("ROOTFS_SHA256", ""),
            # In every stock-window state the marker selects Creality's slot
            # (it is only moved back to NebulaOS at ARMED_NEBULAOS), so a power
            # cycle boots stock and its updater may reflash the MCU.
            "TRANSACTION_ARMED_FOR_STOCK=%s" % ("YES" if self.armed_for_stock else "NO"),
            "TRANSACTION_POWER_CYCLE_DANGEROUS=%s"
            % ("YES" if self.power_cycle_dangerous else "NO"),
            "TRANSACTION_LAST_STOCK_WINDOW_STATE=%s" % (self.danger_state or "none"),
            "TRANSACTION_STARTED_AT=%s" % self.fields.get("STARTED_AT", ""),
            "TRANSACTION_UPDATED_AT=%s" % self.fields.get("UPDATED_AT", ""),
        ] + ["TRANSACTION_LAST_OBSERVED_%s=%s" % (key, self.fields[key])
             for key in sorted(self.fields)
             if key.startswith(("SLOT_", "INSTALL_"))])


class HostLock:
    """One installer per device per host.

    Not a substitute for the device-side flash lock: two different hosts cannot
    see each other's. This one turns "two agents in one workspace" from a race
    into a clean refusal.
    """

    def __init__(self, device_id):
        self.device_id = device_id
        self.path = os.path.join(_ensure_dir(os.path.join(state_home(), "locks")),
                                 "%s.lock" % device_id)
        self.held = False

    def _boot_id(self):
        try:
            with open("/proc/sys/kernel/random/boot_id", "r") as fh:
                return fh.read().strip()
        except OSError:
            return ""

    def acquire(self):
        """-> (ok, holder_description). O_EXCL: check and claim are one step."""
        payload = "PID=%d\nBOOT_ID=%s\nACQUIRED_AT=%s\n" % (
            os.getpid(), self._boot_id(),
            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        try:
            fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except OSError as exc:
            if exc.errno != errno.EEXIST:
                raise LockError("cannot take the host lock for %s: %s" % (self.device_id, exc))
            holder, stale = self._inspect()
            if not stale:
                return False, holder
            # Stale: the recorded pid is gone. Reclaim by replacing atomically.
            _atomic_write(self.path, payload)
            self.held = True
            return True, "reclaimed a stale lock (%s)" % holder
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
        self.held = True
        return True, "acquired"

    def _inspect(self):
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                fields = dict(l.split("=", 1) for l in fh.read().splitlines() if "=" in l)
        except OSError:
            return "unreadable lock file", False
        pid = fields.get("PID", "").strip()
        boot = fields.get("BOOT_ID", "").strip()
        desc = "pid %s since %s" % (pid or "?", fields.get("ACQUIRED_AT", "?").strip())
        # A lock from a previous boot cannot have a live holder.
        if boot and boot != self._boot_id():
            return desc + " (from a previous boot)", True
        if pid.isdigit():
            try:
                os.kill(int(pid), 0)
                return desc, False
            except ProcessLookupError:
                return desc + " (process gone)", True
            except PermissionError:
                # Alive, owned by someone else.
                return desc, False
        return desc + " (no usable pid)", True

    def release(self):
        if not self.held:
            return False
        try:
            os.unlink(self.path)
        except OSError:
            pass
        self.held = False
        return True

    def __enter__(self):
        ok, holder = self.acquire()
        if not ok:
            raise LockError(
                "another installer holds the host lock for %s (%s). Two installers writing one "
                "printer is the failure this prevents." % (self.device_id, holder))
        return self

    def __exit__(self, *exc):
        self.release()
        return False
