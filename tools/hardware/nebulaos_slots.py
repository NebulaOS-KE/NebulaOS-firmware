"""The A/B slot state of a printer, and which install path that state permits.

WHY THIS EXISTS (human decision, 2026-10-14)

Until then the model was fixed: slot 1 (kernel p5, rootfs p7, marker
"ota:kernel") was Creality's and slot 2 (kernel2 p6, rootfs2 p8, marker
"ota:kernel2") was NebulaOS's. NebulaOS may now occupy EITHER or BOTH slots:
the on-printer updater installs an image into whichever slot is not running
and points the marker at it, so after one on-printer update the printer can run
NebulaOS from slot 1 with an older NebulaOS in slot 2 - or hold Creality in
either slot if its owner installed a Creality image.

So nothing here may assume "slot 1 is stock". Every decision is made from what
the device says NOW:

    which slot is running   the root= the kernel was given (/proc/cmdline)
    which slot boots next   the marker bytes in p1 (nebulaos_marker)
    what each slot holds    the running slot: the running OS itself;
                            the other slot: its rootfs, inspected read-only
                            ON THE DEVICE (nebulaos_device.slot_facts_script)

WHAT "HOLDS" MEANS, AND WHY IT FAILS CLOSED

The other slot's rootfs is classified by the same structural markers
nebulaos_device.which_os uses for the running system - files only one of the
two images has, never a version string or a hostname:

    NebulaOS   /etc/ota_marker.sh and the directory /opt/nebulaos
    Creality   the directory /etc/ota_bin

and cross-checked against the kernel partition's uImage header, whose name is
the kernel release (NebulaOS ships Linux 6.x, Creality's KE firmware 4.4):

    nebulaos   NebulaOS markers only, and the kernel does not say otherwise
    creality   Creality markers only, and the kernel does not say otherwise
    empty      no squashfs superblock at the start of the rootfs partition, or
               no uImage header on the kernel partition: nothing bootable
    unknown    anything else - a mount that failed, both or neither marker,
               a kernel that contradicts its rootfs (a half-written slot)

"unknown" is never treated as "probably fine to overwrite" and never as
"probably bootable".

THE INSTALL PATHS (plan_install)

    PRESERVE_STOCK  NebulaOS runs from slot 2, Creality is in slot 1, and the
                    owner has not said the other slot may be overwritten:
                    software reboot to Creality, write slot 2, verify, select
                    slot 2, reboot (the original path, unchanged).
    INACTIVE_SLOT   NebulaOS runs from slot N; write the OTHER slot directly
                    from the running NebulaOS, verify, select it, reboot into
                    it. The running slot is the way back and is never written.
                    Taken when the other slot holds NebulaOS, or when the owner
                    has said the other slot is expendable (Creality, empty or
                    unknown content) via the human-owned profile key
                    INSTALL_OTHER_SLOT=expendable.

The permission to destroy a Creality system is EXPLICIT: a profile key a human
writes, never inferred from the device's state, and absent means preserve.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nebulaos_marker as marker   # noqa: E402
import nebulaos_target as targets  # noqa: E402

HOLDS_NEBULAOS = "nebulaos"
HOLDS_CREALITY = "creality"
HOLDS_EMPTY = "empty"
HOLDS_UNKNOWN = "unknown"

PATH_PRESERVE_STOCK = "PRESERVE_STOCK"
PATH_INACTIVE_SLOT = "INACTIVE_SLOT"

# The human-owned profile key, and its values. Read by DeviceProfile.
OTHER_SLOT_KEY = "INSTALL_OTHER_SLOT"
OTHER_SLOT_PRESERVE = "preserve"
OTHER_SLOT_EXPENDABLE = "expendable"

SQUASHFS_MAGIC_HEX = "68737173"     # "hsqs", little-endian squashfs 4 superblock
UIMAGE_MAGIC_HEX = "27051956"


class Slot:
    __slots__ = ("number", "kernel", "rootfs", "root", "marker", "rtos")

    def __init__(self, number, kernel, rootfs, root, marker_state, rtos):
        self.number = number
        self.kernel = kernel
        self.rootfs = rootfs
        self.root = root
        self.marker = marker_state
        self.rtos = rtos


# Partition names are the target registry's (nebulaos_target), devices the A/B
# slot model's. SPL picks kernel, rootfs AND rtos per slot from the marker.
SLOTS = {
    1: Slot(1, "kernel", "rootfs", targets.resolve("rootfs").device, marker.KERNEL, "rtos"),
    2: Slot(2, "kernel2", "rootfs2", targets.resolve("rootfs2").device, marker.KERNEL2, "rtos2"),
}


class SlotError(Exception):
    """A slot state from which the requested operation will not proceed."""


def slot_of_root(root):
    """-> 1 | 2 | None for a resolved root= device."""
    for n, slot in SLOTS.items():
        if root == slot.root:
            return n
    return None


def other(n):
    return {1: 2, 2: 1}.get(n)


def kernel_kind(name):
    """-> nebulaos | creality | unknown from a uImage name ('Linux-6.6.18-rt23')."""
    name = name or ""
    if name.startswith("Linux-6."):
        return HOLDS_NEBULAOS
    if name.startswith("Linux-4.4."):
        return HOLDS_CREALITY
    return HOLDS_UNKNOWN


def classify(facts, n):
    """-> (holds, evidence) for slot `n` from slot_facts() output. Pure."""
    p = "slot%d_" % n
    kmagic = facts.get(p + "kernel_magic", "")
    kname = facts.get(p + "kernel_name", "")
    rmagic = facts.get(p + "rootfs_magic", "")
    inspected = facts.get(p + "inspect", "")
    neb = facts.get(p + "nebulaos_markers") == "1"
    cre = facts.get(p + "creality_markers") == "1"
    kkind = kernel_kind(kname)

    if inspected == "running":
        # The live root, inspected in place. Same markers, same rules.
        pass
    elif rmagic != SQUASHFS_MAGIC_HEX:
        return HOLDS_EMPTY, ("no squashfs superblock at the start of %s (first bytes %s): "
                             "nothing bootable" % (SLOTS[n].rootfs, rmagic or "unreadable"))
    elif inspected != "mounted":
        return HOLDS_UNKNOWN, ("%s has a squashfs superblock but could not be mounted read-only "
                               "for inspection (%s)" % (SLOTS[n].rootfs, inspected or "no result"))
    if kmagic != UIMAGE_MAGIC_HEX:
        if inspected == "running":
            return HOLDS_UNKNOWN, ("the running slot's kernel partition %s has no uImage header (%s)"
                                   % (SLOTS[n].kernel, kmagic or "unreadable"))
        return HOLDS_EMPTY, ("no uImage header on %s (%s): SPL has no kernel to boot"
                             % (SLOTS[n].kernel, kmagic or "unreadable"))
    if neb and cre:
        return HOLDS_UNKNOWN, "the rootfs carries BOTH the NebulaOS and the Creality markers"
    if not neb and not cre:
        return HOLDS_UNKNOWN, "the rootfs carries neither the NebulaOS nor the Creality markers"
    holds = HOLDS_NEBULAOS if neb else HOLDS_CREALITY
    if kkind not in (HOLDS_UNKNOWN, holds):
        return HOLDS_UNKNOWN, ("the rootfs is %s but the kernel header says %r (%s) - a mixed or "
                               "half-written slot" % (holds, kname, kkind))
    return holds, "%s markers in %s (%s), kernel %r" % (
        holds, SLOTS[n].rootfs, "running root" if inspected == "running" else "mounted read-only",
        kname or "unnamed")


class SlotState:
    """Everything about the slots, read from the device in one go. Read-only."""

    def __init__(self, running_os, active_root, marker_state, marker_reason, facts):
        self.running_os = running_os
        self.active_root = active_root
        self.running_slot = slot_of_root(active_root)
        self.marker_state = marker_state
        self.marker_reason = marker_reason
        self.marker_slot = marker.SLOT_OF.get(marker_state)
        self.facts = dict(facts or {})
        self.holds = {}
        self.evidence = {}
        for n in SLOTS:
            self.holds[n], self.evidence[n] = classify(self.facts, n)
        # The running slot holds what is running: it booted, and which_os
        # identified it structurally with the same markers. Its own facts are
        # reported beside that, and a disagreement is reported, not hidden.
        if self.running_slot is not None:
            n = self.running_slot
            running_holds = {"nebulaos": HOLDS_NEBULAOS, "stock": HOLDS_CREALITY}.get(
                running_os, HOLDS_UNKNOWN)
            agree = self.holds[n] == running_holds
            self.evidence[n] = "running %s from root=%s; its own facts %s (%s)" % (
                running_os, active_root, "agree" if agree else "say %s" % self.holds[n],
                self.evidence[n])
            self.holds[n] = running_holds

    def nebulaos_slots(self):
        return [n for n in sorted(SLOTS) if self.holds[n] == HOLDS_NEBULAOS]

    def next_boot_holds(self):
        return self.holds.get(self.marker_slot, HOLDS_UNKNOWN) if self.marker_slot else HOLDS_UNKNOWN

    def firmware_head(self, n):
        return self.facts.get("slot%d_firmware_head" % n, "")

    def describe(self):
        lines = [
            "SLOT_RUNNING=%s" % (self.running_slot or "unknown"),
            "SLOT_RUNNING_ROOT=%s" % (self.active_root or "unknown"),
            "SLOT_RUNNING_OS=%s" % self.running_os,
            "SLOT_MARKER_SELECTS=%s" % (self.marker_slot or "unknown"),
            "SLOT_NEXT_BOOT_HOLDS=%s" % self.next_boot_holds(),
        ]
        for n in sorted(SLOTS):
            lines.append("SLOT_%d_HOLDS=%s" % (n, self.holds[n]))
            lines.append("SLOT_%d_KERNEL=%s" % (n, self.facts.get("slot%d_kernel_name" % n) or "unknown"))
            if self.holds[n] == HOLDS_NEBULAOS:
                lines.append("SLOT_%d_FIRMWARE_HEAD=%s" % (n, self.firmware_head(n) or "unknown"))
            lines.append("SLOT_%d_EVIDENCE=%s" % (n, self.evidence[n]))
        lines.append("SLOT_NEBULAOS_IN=%s" % (",".join(str(n) for n in self.nebulaos_slots()) or "none"))
        return "\n".join(lines)

    def journal_fields(self):
        """The facts worth remembering offline, for `status`."""
        fields = {
            "SLOT_RUNNING": str(self.running_slot or "unknown"),
            "SLOT_MARKER_SELECTS": str(self.marker_slot or "unknown"),
        }
        for n in sorted(SLOTS):
            fields["SLOT_%d_HOLDS" % n] = self.holds[n]
        return fields


def read_slot_state(session):
    """Read the whole slot state through the closed DeviceSession vocabulary."""
    running = session.which_os()
    root = session.active_root()
    state, reason = marker.parse(session.read_marker_block())
    facts = session.slot_facts()
    return SlotState(running, root, state, reason, facts)


class InstallPlan:
    __slots__ = ("path", "running_slot", "target_slot", "policy", "overwrites", "reason")

    def __init__(self, path, running_slot, target_slot, policy, overwrites, reason):
        self.path = path
        self.running_slot = running_slot
        self.target_slot = target_slot
        self.policy = policy
        self.overwrites = overwrites
        self.reason = reason

    def describe(self):
        return "\n".join([
            "DEV_INSTALL_PATH=%s" % self.path,
            "DEV_INSTALL_SOURCE_SLOT=%s" % self.running_slot,
            "DEV_INSTALL_TARGET_SLOT=%s" % self.target_slot,
            "DEV_INSTALL_TARGET_HOLDS_NOW=%s" % self.overwrites,
            "DEV_INSTALL_OVERWRITES_CREALITY=%s"
            % ("YES" if self.overwrites == HOLDS_CREALITY else "NO"),
            "DEV_INSTALL_WAY_BACK=%s" % (
                "slot %d (the running NebulaOS; never written)" % self.running_slot
                if self.path == PATH_INACTIVE_SLOT
                else "slot 1 (Creality; never written, booted to write slot 2)"),
            "DEV_INSTALL_PATH_REASON=%s" % self.reason,
        ])


def plan_install(state, other_slot_policy):
    """Decide the install path from a SlotState of a printer RUNNING NEBULAOS.

    `other_slot_policy` is the human's word from the profile
    (OTHER_SLOT_PRESERVE or OTHER_SLOT_EXPENDABLE), already resolved for the
    install mode. -> InstallPlan, or raise SlotError naming what would allow it.
    """
    r = state.running_slot
    if r is None:
        raise SlotError("cannot tell which slot NebulaOS runs from (root=%s is neither %s nor %s)"
                        % (state.active_root, SLOTS[1].root, SLOTS[2].root))
    if state.holds[r] != HOLDS_NEBULAOS:
        raise SlotError("slot %d is running but does not classify as NebulaOS (%s)"
                        % (r, state.evidence[r]))
    o = other(r)
    holds = state.holds[o]
    expendable = other_slot_policy == OTHER_SLOT_EXPENDABLE

    if holds == HOLDS_NEBULAOS:
        return InstallPlan(PATH_INACTIVE_SLOT, r, o, targets.inactive_slot_policy(o), holds,
                           "slot %d holds NebulaOS (%s); the running slot %d is the way back"
                           % (o, state.firmware_head(o) or "version unknown", r))
    if holds == HOLDS_CREALITY and not expendable and r == 2:
        return InstallPlan(PATH_PRESERVE_STOCK, r, 2, targets.DEV_PRESERVE_STOCK, state.holds[2],
                           "Creality is in slot 1 and %s=%s: it is preserved and used as the "
                           "way through" % (OTHER_SLOT_KEY, other_slot_policy))
    if expendable:
        return InstallPlan(PATH_INACTIVE_SLOT, r, o, targets.inactive_slot_policy(o), holds,
                           "slot %d holds %s and the device profile says %s=%s; the running "
                           "slot %d is the way back" % (o, holds, OTHER_SLOT_KEY,
                                                        OTHER_SLOT_EXPENDABLE, r))
    if holds == HOLDS_CREALITY:
        raise SlotError(
            "NebulaOS runs from slot 1 and Creality is in slot 2. Updating NebulaOS here means "
            "writing slot 2, which destroys that Creality system, and this agent does not boot "
            "Creality from slot 2 to write slot 1. To allow overwriting it, the human who owns "
            "this printer sets %s=%s in its device profile." % (OTHER_SLOT_KEY, OTHER_SLOT_EXPENDABLE))
    raise SlotError(
        "slot %d holds %s (%s). The install overwrites only a slot it identifies as NebulaOS, "
        "unless the human who owns this printer sets %s=%s in its device profile."
        % (o, holds, state.evidence[o], OTHER_SLOT_KEY, OTHER_SLOT_EXPENDABLE))
