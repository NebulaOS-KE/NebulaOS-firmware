"""The proofs: that Stock is a usable way out (PRESERVE_STOCK), that the running
NebulaOS slot is the way back (INACTIVE_SLOT, since NebulaOS may occupy both
slots - nebulaos_slots), and that an install really landed in the slot it was
meant for.

THE STOCK WAY-OUT PROOF

Setting the marker to ota:kernel while NebulaOS is running is the point of no
easy return. After the reboot, the only way to continue - or to undo anything -
is through the stock slot. If stock turns out to be unreachable, or its
credentials are wrong, or there is nowhere to stage the payload, the printer is
sitting on Creality's firmware with no automated path back, and the human has to
recover it by hand.

So every fact that the Stock half of the install depends on is checked BEFORE
the marker is touched, from NebulaOS, while retreat is still free. A missing
proof is a refusal, not a warning.

REAL PART-1 VERIFICATION

Checking that services are up is not verification that a specific build was
installed; a printer running last week's image also has services up. Part 1
compares the BYTES on the device against the exact artifacts that were supposed
to land, by hashing the same prefix length at the same partitions, and only then
looks at health.

And it reports PART1_INSTALL_VERIFIED, never HARDWARE_QUALIFIED. Part 1 proves
an image is installed and the system came up. Qualification means motion,
heating, calibration and printing, which are Part 2 and are not attempted here.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nebulaos_device as device  # noqa: E402
import nebulaos_marker as marker  # noqa: E402
import nebulaos_slots as slots    # noqa: E402


class Check:
    __slots__ = ("name", "ok", "detail", "fatal")

    def __init__(self, name, ok, detail="", fatal=True):
        self.name = name
        self.ok = ok
        self.detail = detail
        self.fatal = fatal

    def line(self):
        return "%s  %s%s" % ("PASS" if self.ok else ("FAIL" if self.fatal else "WARN"),
                             self.name, ("  -- " + self.detail) if self.detail else "")


class ProofResult:
    def __init__(self, title):
        self.title = title
        self.checks = []

    def add(self, name, ok, detail="", fatal=True):
        self.checks.append(Check(name, ok, detail, fatal))
        return ok

    def ok(self):
        return all(c.ok for c in self.checks if c.fatal)

    def failures(self):
        return [c for c in self.checks if c.fatal and not c.ok]

    def render(self):
        lines = ["=== %s ===" % self.title]
        lines += [c.line() for c in self.checks]
        lines.append("")
        lines.append("%s_PASS=%d" % (self.title.upper().replace(" ", "_"),
                                     sum(1 for c in self.checks if c.ok)))
        lines.append("%s_FAIL=%d" % (self.title.upper().replace(" ", "_"), len(self.failures())))
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# Stock way-out proof
# ---------------------------------------------------------------------------

def stock_wayout_proof(session, profile, payload_bytes_needed):
    """Everything the Stock half depends on, checked from NebulaOS.

    `session` is the CURRENT NebulaOS session. All of this is read-only.
    """
    result = ProofResult("stock wayout proof")

    facts = session.stock_wayout_facts()

    result.add("the stock kernel partition exists",
               facts.get("stock_kernel") == "present",
               "slot 1 kernel must be present to boot into")
    result.add("the stock rootfs partition exists",
               facts.get("stock_rootfs") == "present",
               "slot 1 rootfs must be present to boot into")

    # Everything below is read from slot 1's own rootfs, mounted read-only.
    result.add("the stock rootfs (p7) could be mounted read-only for inspection",
               facts.get("stock_mount") == "mounted",
               "a stock rootfs that cannot be inspected cannot be proven usable")

    # A stock rootfs with no root entry in its shadow file is one we cannot log
    # into, which makes it useless as a way out even though it boots.
    try:
        shadow_hits = int(facts.get("shadow", "0"))
    except ValueError:
        shadow_hits = 0
    result.add("the stock rootfs carries a root account",
               shadow_hits > 0,
               "root entries in stock's /etc/shadow: %d" % shadow_hits)

    try:
        ssh_init = int(facts.get("stock_ssh_init", "0"))
    except ValueError:
        ssh_init = 0
    ssh_bin = facts.get("stock_ssh_binary") == "1"
    result.add("stock has an SSH daemon to come back on",
               ssh_init > 0 and ssh_bin,
               "in stock's rootfs: %d SSH init script(s), daemon binary %s"
               % (ssh_init, "present" if ssh_bin else "ABSENT"))

    result.add("stock has a Wi-Fi configuration to rejoin the network with",
               facts.get("wpa_conf") == "present",
               "/usr/data/wpa_supplicant.conf (the file stock's wpa_supplicant runs with) "
               "must hold an ssid; without it stock boots with no network and cannot be reached")

    # The enrolled profile must already know how to talk to stock. Discovering
    # that after the reboot is discovering it too late.
    try:
        has_key = bool(profile.host_key(device.OS_STOCK))
    except Exception:
        has_key = False
    result.add("a stock SSH host key is pinned in the device profile", has_key,
               "strict host-key checking needs the stock key enrolled in advance")

    try:
        has_cred = bool(profile.credential(device.OS_STOCK))
    except Exception:
        has_cred = False
    result.add("a stock credential is enrolled", has_cred,
               "the stock root password differs from NebulaOS's")

    addresses = profile.address_history(device.OS_STOCK)
    result.add("at least one stock address is known", bool(addresses),
               "rediscovery needs somewhere to look: %s"
               % (", ".join(addresses) if addresses else "none recorded"))

    try:
        free = int(facts.get("free_kib", "0")) * 1024
    except ValueError:
        free = 0
    result.add("the shared staging area has room for the payload",
               free >= payload_bytes_needed,
               "%d bytes free, %d needed" % (free, payload_bytes_needed))

    return result


# ---------------------------------------------------------------------------
# Way-back proof for the INACTIVE_SLOT path
# ---------------------------------------------------------------------------

def inactive_slot_wayback_proof(session, state, plan, payload_bytes_needed):
    """The INACTIVE_SLOT path never boots Creality: the way back is the
    NebulaOS slot that is running now, which this path never writes. So the
    proof is about THAT slot and about the target being the other one.

    `state` is a SlotState read in this session; `plan` the InstallPlan made
    from it. Read-only; the live root is re-read here, not taken from `state`.
    """
    result = ProofResult("way back proof")
    r, t = plan.running_slot, plan.target_slot
    root = session.active_root()
    result.add("the running slot is still slot %d (root=%s)" % (r, slots.SLOTS[r].root),
               root == slots.SLOTS[r].root, "root=%s, re-read from /proc/cmdline" % root)
    result.add("the running system is NebulaOS", session.which_os() == device.OS_NEBULAOS)
    result.add("slot %d, the way back, holds NebulaOS" % r,
               state.holds.get(r) == slots.HOLDS_NEBULAOS, state.evidence.get(r, ""))
    result.add("the target is the OTHER slot", t == slots.other(r) and t != r,
               "target slot %s, running slot %s" % (t, r))
    names = sorted(plan.policy.allowed - {"ota"})
    result.add("the install policy cannot select the running slot",
               not (set(names) & {slots.SLOTS[r].kernel, slots.SLOTS[r].rootfs}),
               "%s may write %s" % (plan.policy.name, ", ".join(names)))
    state_now, why = marker.parse(session.read_marker_block())
    result.add("the marker selects the running slot %d until the new slot is verified" % r,
               marker.SLOT_OF.get(state_now) == r, "%s (%s)" % (state_now, why))
    try:
        free = int(session.free_space("/usr/data"))
    except (TypeError, ValueError):
        free = 0
    result.add("the staging area has room for the payload",
               free >= payload_bytes_needed, "%d bytes free, %d needed" % (free, payload_bytes_needed))
    return result


def idle_proof(session):
    """The printer must be doing nothing before a slot switch."""
    result = ProofResult("idle proof")
    state = session.idle_state()
    result.add("the printer is idle", state.is_idle(), state.why_not_idle())
    result.add("no print is running", not state.printing)
    result.add("no print is paused", not state.paused,
               "a paused job would be lost by a slot switch")
    hot = {k: v for k, v in state.heater_targets.items() if float(v) != 0.0}
    result.add("every heater target is zero", not hot,
               ("non-zero: %s" % hot) if hot else "all targets at 0")
    return result


# ---------------------------------------------------------------------------
# Part 1 install verification
# ---------------------------------------------------------------------------

def observe_mcu_restore(session):
    """-> one of not_attempted | performed | performed_but_mcu_absent.

    Read from the device rather than assumed. "performed" is not a success
    claim: it says the guard ran, which means the MCU was overwritten and had to
    be rebuilt, which is a worse outcome than never having been touched.
    """
    mcu = session.mcu_state()
    try:
        count = int(mcu.get("mcu_guard_restore", "unknown"))
    except ValueError:
        # The guard's per-boot verdict could not be read. That is not evidence
        # of "no restore", so it is reported as unknown and fails PART1.
        return "unknown"
    if count == 0:
        return "not_attempted"
    return "performed" if mcu.get("mcu_serial") else "performed_but_mcu_absent"


def part1_verify(session, expected_ximage_sha, expected_ximage_size,
                 expected_rootfs_sha, expected_rootfs_size,
                 expected_source_head, profile=None, expected_boot_id_changed_from=None,
                 expected_slot=None):
    """Prove the exact build is installed and running. Read-only.

    `expected_slot` is the slot the build must be running from (1 or 2). An
    install states it; a standalone `verify` passes None and the slot is the
    one the device is running from, whichever that is - since 2026-10-14
    NebulaOS may run from either slot.
    """
    result = ProofResult("part1 install verification")

    # --- the right printer ------------------------------------------------
    if profile is not None:
        identity = session.probe_identity()
        ok, why = profile.identity_matches(identity)
        result.add("this is the enrolled printer", ok, why)

    # --- running the right slot -------------------------------------------
    root = session.active_root()
    running_slot = slots.slot_of_root(root)
    slot_n = expected_slot or running_slot
    slot = slots.SLOTS.get(slot_n)
    result.add("root is the NebulaOS slot",
               slot is not None and root == slot.root,
               "root=%s (expected %s, slot %s)" % (root, slot.root if slot else "slot 1 or 2",
                                                   slot_n or "unknown"))

    running_os = session.which_os()
    result.add("the running OS is NebulaOS", running_os == device.OS_NEBULAOS,
               "detected %s" % running_os)

    if expected_boot_id_changed_from:
        now = session.boot_id()
        result.add("the device actually rebooted",
                   bool(now) and now != expected_boot_id_changed_from,
                   "boot_id %s -> %s" % (expected_boot_id_changed_from[:8], (now or "?")[:8]))

    # --- the marker selects us --------------------------------------------
    try:
        block = session.read_marker_block()
        state, why = marker.parse(block)
        result.add("the OTA marker selects the NebulaOS slot",
                   slot is not None and state == slot.marker,
                   "%s (%s; expected %s)" % (state, why, slot.marker if slot else "a known slot"))
    except Exception as exc:
        result.add("the OTA marker selects the NebulaOS slot", False, str(exc)[:160])

    # --- THE BYTES --------------------------------------------------------
    # This is what makes it verification rather than a health check.
    kname = slot.kernel if slot else "the running slot's kernel"
    rname = slot.rootfs if slot else "the running slot's rootfs"
    try:
        if slot is None:
            raise device.DeviceError("the running slot is unknown (root=%s)" % root)
        got = session.region_sha256(slot.kernel, expected_ximage_size)
        result.add("%s holds exactly the expected xImage" % kname,
                   got == expected_ximage_sha,
                   "device %s vs expected %s" % (got[:16], expected_ximage_sha[:16]))
    except Exception as exc:
        result.add("%s holds exactly the expected xImage" % kname, False, str(exc)[:160])

    try:
        if slot is None:
            raise device.DeviceError("the running slot is unknown (root=%s)" % root)
        got = session.region_sha256(slot.rootfs, expected_rootfs_size)
        result.add("%s holds exactly the expected rootfs.squashfs" % rname,
                   got == expected_rootfs_sha,
                   "device %s vs expected %s" % (got[:16], expected_rootfs_sha[:16]))
    except Exception as exc:
        result.add("%s holds exactly the expected rootfs.squashfs" % rname, False, str(exc)[:160])

    # --- health -----------------------------------------------------------
    health = session.service_health()
    for service in ("klipper", "moonraker", "nginx", "screen"):
        result.add("%s is running" % service, health.get(service) == "running",
                   health.get(service, "unknown"))
    result.add("the local Moonraker endpoint answers",
               health.get("moonraker_http") == "200",
               "HTTP %s" % health.get("moonraker_http", "none"))
    result.add("the local web endpoint answers",
               health.get("web_http") in ("200", "301", "302"),
               "HTTP %s" % health.get("web_http", "none"))

    idle = session.idle_state()
    result.add("Klipper reached ready", idle.klippy_state == "ready",
               "klippy_state=%s" % idle.klippy_state)

    # --- MCU --------------------------------------------------------------
    mcu = session.mcu_state()
    result.add("the MCU is present", bool(mcu.get("mcu_serial")),
               "Klipper reports mcu_version=%s (UART /dev/ttyS1 %s)"
               % (mcu.get("mcu_serial") or "none", mcu.get("mcu_uart", "unknown")))

    # THE MCU COST OF THIS INSTALL.
    #
    # The happy path deliberately boots Creality's slot, whose updater can
    # reflash the GD32 with stock firmware - the exact reason Phase 1.8B removed
    # every AUTOMATIC route into stock. NebulaOS's S50 guard gets ONE bounded
    # restore attempt on the way back.
    #
    # So there are three outcomes, not two, and they are reported separately:
    #   no restore needed       -> the updater did not act; best case
    #   restore ran and worked  -> recovered, but the MCU was overwritten
    #   restore ran and failed  -> the printer is running stock MCU firmware
    #
    # PART1_INSTALL_VERIFIED=YES on a printer whose MCU is running Creality's
    # firmware would be a false pass, so any restore at all fails the check.
    restored = mcu.get("mcu_guard_restore", "unknown")
    try:
        restored_n = int(restored)
    except ValueError:
        restored_n = None          # unreadable verdict: fail closed, never pass
    result.add("the MCU guard performed no automatic restore", restored_n == 0,
               "MCU guard restore this boot: %s (MCU_RESTORE_RESULT=%s) - a restore means "
               "stock's updater overwrote the qualified MCU build; 'unknown' means the "
               "guard's per-boot state could not be read, which is not a pass"
               % (restored, mcu.get("mcu_restore_result", "unknown")))

    # A restore that did not happen is not the same as a guard that PASSED: the
    # guard records not_attempted on paths where it evaluated nothing at all
    # (helper missing, python missing, no output). Its own verdict must be PASS.
    guard = mcu.get("mcu_guard_result", "unknown")
    result.add("the MCU guard verdict for this boot is PASS", guard == "PASS",
               "MCU_GUARD_RESULT=%s (WARN/FAIL/unknown mean the MCU identity was not proven)"
               % guard)

    # (No PART1 check on /usr/data/.mcu_updated: nothing in stock or NebulaOS
    # produces that file, so it could never fail. Stock's updater is judged
    # from its own log while stock runs, during install; its effect on the MCU
    # is caught here by the MCU guard verdict, which must be PASS.)

    return result


def render_part1(result, source_head, mcu_restore_result="not_attempted"):
    """The verdict, with the distinction the project cares about spelled out.

    `mcu_restore_result` is OBSERVED and passed in. An earlier revision printed
    MCU_RESTORE_RESULT=not_attempted unconditionally, which was a claim rather
    than a reading - and false on exactly the runs where it mattered most.
    """
    lines = [result.render(), ""]
    verified = result.ok()
    lines.append("PART1_SOURCE_HEAD=%s" % source_head)
    lines.append("PART1_INSTALL_VERIFIED=%s" % ("YES" if verified else "NO"))
    lines.append("MCU_RESTORE_RESULT=%s" % mcu_restore_result)
    lines.append("HARDWARE_QUALIFIED=NO")
    lines.append("# Part 1 proves an exact image is installed and the system came up.")
    lines.append("# Motion, heating, calibration and printing are Part 2 and were not attempted.")
    if not verified:
        lines.append("")
        lines.append("# Failing checks:")
        for check in result.failures():
            lines.append("#   %s -- %s" % (check.name, check.detail))
    return "\n".join(lines)
