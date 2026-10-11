"""Validated partition targets: what the flashing layer CAN write, and what a
given operation MAY write.

THE DISTINCTION THIS MODULE EXISTS TO MAKE

Two different questions get confused constantly, and confusing them produces
either an unsafe tool or a uselessly narrow one:

    CAPABILITY  can the flashing layer express a validated, bounds-checked,
                read-back-verified write to this partition at all?
    POLICY      is THIS operation, run by THIS caller, allowed to select it?

The generic layer answers the first question broadly. The device belongs to its
owner, and a recovery tool that cannot rewrite the stock slot is not a recovery
tool. So `kernel`, `rootfs`, `rtos`, `rtos2` and the OTA marker are all
CAPABLE targets: full-device recovery, single-slot repair and both-sides
reinstall are all expressible here.

The developer `install` operation answers the second question narrowly. Its
policy is PRESERVE_STOCK: it selects kernel2, rootfs2 and the marker, and
nothing else. That is a property of that one operation, not a limit of the
backend, and the two must never be conflated - which is why they are separate
objects here rather than one hardcoded allowlist.

WHAT SAFETY IS MADE OF, SINCE IT IS NOT AN ALLOWLIST

  * targets are NAMED, never offsets. There is no API here that accepts a byte
    offset or a block device path, so no caller - trusted or not - can aim a
    write at an arbitrary location.
  * every target's offset and length come from the vendor Cloner geometry in
    tools/emmc/nebulaos_layout.py, which is evidence, not a guess.
  * every write is planned as (target, payload size, payload sha256) and the
    plan is validated against the target's real bounds before anything happens.
  * the payload must fit, and a plan that would run past the end of its
    partition is refused rather than truncated.

THE ONE UNCONDITIONAL REFUSAL

`sn_mac` is NEVER writable, under any policy, including full-device recovery.
It holds the per-unit factory MAC and serial number
(26096911004C14;FCEE11004C14;F005;NEBULA V1.0.0.1 on the reference unit, which
is the address stock's wlan0 actually uses). It is programmed per unit, exists
nowhere else on the device, and cannot be regenerated or bought. Every other
partition can, in principle, be restored from an image; this one cannot, so it
is excluded at the capability layer rather than left to policy. Even Creality's
own Cloner erase policy skips it.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "emmc"))
import nebulaos_layout as layout  # noqa: E402


# --- roles -----------------------------------------------------------------
ROLE_STOCK = "stock"          # Creality's slot 1
ROLE_NEBULAOS = "nebulaos"    # our slot 2
ROLE_BOOT = "boot"            # SPL/U-Boot
ROLE_MARKER = "marker"        # the OTA slot selector
ROLE_IDENTITY = "identity"    # per-unit factory data
ROLE_USERDATA = "userdata"    # the owner's files


class TargetError(Exception):
    """A target or a write plan that this layer will not act on."""


class PartitionTarget:
    """One named, bounds-checked place a validated write can go."""

    __slots__ = ("name", "role", "offset", "size", "device", "writable", "why_not")

    def __init__(self, name, role, offset, size, device, writable=True, why_not=None):
        self.name = name
        self.role = role
        self.offset = offset
        self.size = size
        self.device = device
        self.writable = writable
        self.why_not = why_not

    def plan_write(self, payload_size, payload_sha256):
        """Validate a write of this size to this target. Returns a WritePlan.

        This is the only way to obtain a write plan. There is deliberately no
        constructor that takes an offset.
        """
        if not self.writable:
            raise TargetError(
                "%s is not a writable target: %s" % (self.name, self.why_not))
        if not isinstance(payload_size, int) or payload_size <= 0:
            raise TargetError("payload size for %s must be a positive integer" % self.name)
        if payload_size > self.size:
            raise TargetError(
                "payload is %d bytes but %s is only %d - refusing to truncate or to run "
                "past the end of the partition" % (payload_size, self.name, self.size))
        if not isinstance(payload_sha256, str) or len(payload_sha256) != 64 \
                or any(c not in "0123456789abcdef" for c in payload_sha256):
            raise TargetError("payload sha256 for %s must be 64 lowercase hex characters" % self.name)
        return WritePlan(self, payload_size, payload_sha256)

    def __repr__(self):
        return "PartitionTarget(%s role=%s off=0x%x size=%d writable=%s)" % (
            self.name, self.role, self.offset, self.size, self.writable)


class WritePlan:
    """A validated intent to write one payload to one named target.

    Carries no device path and no offset that a caller supplied - both are
    derived from the target, which came from the vendor geometry.
    """

    __slots__ = ("target", "payload_size", "payload_sha256")

    def __init__(self, target, payload_size, payload_sha256):
        self.target = target
        self.payload_size = payload_size
        self.payload_sha256 = payload_sha256

    def describe(self):
        return ("WRITE_PLAN target=%s role=%s device=%s offset=0x%x capacity=%d "
                "payload_bytes=%d payload_sha256=%s"
                % (self.target.name, self.target.role, self.target.device,
                   self.target.offset, self.target.size,
                   self.payload_size, self.payload_sha256))


# --- the target registry ----------------------------------------------------
#
# Device paths come from the A/B slot model; offsets and sizes from the vendor
# Cloner profile via nebulaos_layout. Both are recorded evidence.
_DEVICE = {
    "ota": "/dev/mmcblk0p1",
    "sn_mac": "/dev/mmcblk0p2",
    "rtos": "/dev/mmcblk0p3",
    "rtos2": "/dev/mmcblk0p4",
    "kernel": "/dev/mmcblk0p5",
    "kernel2": "/dev/mmcblk0p6",
    "rootfs": "/dev/mmcblk0p7",
    "rootfs2": "/dev/mmcblk0p8",
    "rootfs_data": "/dev/mmcblk0p9",
    "userdata": "/dev/mmcblk0p10",
}

_ROLE = {
    "ota": ROLE_MARKER,
    "sn_mac": ROLE_IDENTITY,
    "rtos": ROLE_STOCK,
    "rtos2": ROLE_NEBULAOS,
    "kernel": ROLE_STOCK,
    "kernel2": ROLE_NEBULAOS,
    "rootfs": ROLE_STOCK,
    "rootfs2": ROLE_NEBULAOS,
    "rootfs_data": ROLE_USERDATA,
    "userdata": ROLE_USERDATA,
}

# The single capability-level refusal. See the module docstring.
_NEVER_WRITABLE = {
    "sn_mac": "it holds the per-unit factory MAC and serial number, which cannot be "
              "regenerated or recovered from any image",
}


def _build_registry():
    targets = {}
    for name, device in _DEVICE.items():
        try:
            offset = layout.partition_offset(name)
        except KeyError:
            # rootfs_data and userdata sit past where the vendor Cloner profile
            # stops, because the Cloner never programs them. They are real
            # partitions and are named here for completeness, but without a
            # recorded offset they cannot be planned against.
            offset = None
        try:
            size = layout.partition_size(name)
        except KeyError:
            size = None

        why = _NEVER_WRITABLE.get(name)
        writable = why is None and offset is not None and size is not None
        if why is None and offset is None:
            why = ("its offset has never been captured - the vendor Cloner profile stops "
                   "at rootfs2 because the Cloner never programs the data partitions")
        targets[name] = PartitionTarget(
            name=name, role=_ROLE[name], offset=offset, size=size,
            device=device, writable=writable, why_not=why)
    return targets


_TARGETS = _build_registry()


def resolve(name):
    """Look up a target by name. The ONLY way to obtain one."""
    try:
        return _TARGETS[name]
    except KeyError:
        raise TargetError(
            "unknown partition target %r. Known targets: %s. This layer addresses "
            "partitions by name only - there is no API that accepts a raw offset or a "
            "block device path." % (name, ", ".join(sorted(_TARGETS))))


def all_targets():
    return dict(_TARGETS)


def capability_report():
    """What the generic flashing layer can and cannot express.

    Deliberately reports on the STOCK side too, because "can this tool write
    stock" is a question with a real answer and that answer is yes.
    """
    lines = []
    for name in sorted(_TARGETS):
        t = _TARGETS[name]
        lines.append("TARGET=%s role=%s device=%s writable=%s%s"
                     % (t.name, t.role, t.device, "YES" if t.writable else "NO",
                        "" if t.writable else " reason=%s" % t.why_not))
    stock = all(_TARGETS[n].writable for n in ("kernel", "rootfs"))
    nebula = all(_TARGETS[n].writable for n in ("kernel2", "rootfs2"))
    lines.append("GENERIC_FLASH_CAPABILITY_STOCK=%s" % ("YES" if stock else "NO"))
    lines.append("GENERIC_FLASH_CAPABILITY_NEBULAOS=%s" % ("YES" if nebula else "NO"))
    lines.append("GENERIC_FLASH_CAPABILITY_MARKER=%s" % ("YES" if _TARGETS["ota"].writable else "NO"))
    lines.append("GENERIC_FLASH_CAPABILITY_SN_MAC=NO")
    return "\n".join(lines)


# --- policies ---------------------------------------------------------------

class Policy:
    """Which targets one operation may select.

    A policy narrows capability. It can never widen it: select() consults the
    target's own `writable` flag first, so no policy can authorise a write to
    sn_mac.
    """

    def __init__(self, name, allowed, description):
        self.name = name
        self.allowed = frozenset(allowed)
        self.description = description

    def select(self, target_name):
        target = resolve(target_name)
        if not target.writable:
            raise TargetError(
                "policy %s cannot select %s: %s (this is a capability refusal, not a "
                "policy one - no policy can override it)"
                % (self.name, target_name, target.why_not))
        if target_name not in self.allowed:
            raise TargetError(
                "policy %s does not permit writing %s (role=%s). Permitted: %s. "
                "The flashing layer is CAPABLE of this target; this operation is not "
                "authorised for it."
                % (self.name, target_name, target.role, ", ".join(sorted(self.allowed))))
        return target

    def writes_stock(self):
        return any(resolve(n).role == ROLE_STOCK for n in self.allowed)

    def report(self, prefix="POLICY"):
        """Machine-readable, with a caller-chosen prefix.

        The developer install reports itself as DEV_INSTALL_POLICY /
        DEV_INSTALL_WRITES_STOCK, which is the vocabulary the release contract
        uses, while a recovery tool reports under its own. Same object, same
        facts, named for the operation asking.
        """
        return "\n".join([
            "%s=%s" % (prefix, self.name),
            "%s_DESCRIPTION=%s" % (prefix, self.description),
            "%s_ALLOWED_TARGETS=%s" % (prefix, ",".join(sorted(self.allowed))),
            "%s_WRITES_STOCK=%s" % (prefix, "YES" if self.writes_stock() else "NO"),
        ])


# The developer install policy. Narrow ON PURPOSE, and narrow HERE rather than
# in the backend, so that the backend stays usable by the recovery tooling this
# project will grow later.
DEV_PRESERVE_STOCK = Policy(
    "PRESERVE_STOCK",
    allowed={"kernel2", "rootfs2", "ota"},
    description=("developer install: write the NebulaOS slot and the boot marker, "
                 "leave Creality's slot 1 intact as the way back"),
)

# Expressible, and deliberately not used by `install`. Named so that the
# capability is demonstrable rather than hypothetical, and so the tests can
# prove the backend is not artificially slot-2-only.
RECOVERY_STOCK_SIDE = Policy(
    "RECOVERY_STOCK_SIDE",
    allowed={"kernel", "rootfs", "rtos", "ota"},
    description="repair or reinstall Creality's slot 1",
)

RECOVERY_BOTH_SIDES = Policy(
    "RECOVERY_BOTH_SIDES",
    allowed={"kernel", "rootfs", "rtos", "kernel2", "rootfs2", "rtos2", "ota"},
    description="full-device reinstall of both slots, preserving per-unit identity",
)


# The rtos-logo / rtos-logo-restore operations: the NebulaOS RTOS copy and
# nothing else. Not part of DEV_PRESERVE_STOCK - an install never writes rtos2 -
# and never rtos (p3), which SPL loads for Creality's slot.
RTOS2_ONLY = Policy(
    "RTOS2_ONLY",
    allowed={"rtos2"},
    description=("NebulaOS boot logo: write the NebulaOS slot's RTOS image (rtos2) only; "
                 "Creality's rtos and both slots' kernels and rootfs are untouched"),
)


POLICIES = {p.name: p for p in (DEV_PRESERVE_STOCK, RECOVERY_STOCK_SIDE, RECOVERY_BOTH_SIDES,
                                RTOS2_ONLY)}


def policy(name):
    try:
        return POLICIES[name]
    except KeyError:
        raise TargetError("unknown policy %r. Known: %s" % (name, ", ".join(sorted(POLICIES))))
