"""The developer install: NebulaOS -> Stock -> flash -> NebulaOS, as a state machine.

THE OPERATION, AND WHY IT GOES THROUGH STOCK AT ALL

NebulaOS lives in slot 2. A running system cannot overwrite the partitions it is
executing from - an earlier version of this project tried, landed a write on the
live rootfs, and needed a manual power cycle to recover. So installing a new
NebulaOS means booting something else first, and the only something else is
Creality's slot 1.

That makes stock a dependency of the install, which is why so much of this file
is about proving stock will work BEFORE committing to it.

THE DANGEROUS WINDOW

From the moment the marker is set to ota:kernel until the moment a verified
NebulaOS is running again, the printer is either about to boot stock or is
booting stock. Booting stock is survivable; POWER-CYCLING into stock is what
lets its MCU updater reflash the GD32 with Creality firmware, destroying the
qualified MCU build. This project can perform a software reboot and cannot
perform a power cycle, so the window is survivable by construction - but the
journal and the output both say POWER_CYCLE_DANGEROUS=YES throughout it, because
a human pulling the plug at the wrong moment is the remaining risk.

ARMED, AND DISARMING

"ARMED_STOCK" means: NebulaOS is still running, and the marker says boot stock.
It is a real, recoverable state, and every failure that happens in it must undo
it - set the marker back to kernel2, flush, read the bytes back, confirm. A
failure that leaves the marker armed turns the next unrelated reboot into an
unplanned trip to stock.

A resumed transaction that finds NebulaOS running with the marker on stock
disarms FIRST, before considering anything else. It does not continue forward on
the assumption that it must have meant to.

ONCE SLOT 2 IS VERIFIED, THE MARKER IS THE NEXT THING

Not log collection, not a status report, not a health check. The device is
sitting on stock with a freshly written NebulaOS slot; the single most valuable
next byte is the one that points the bootloader back at it. Everything else can
happen after.

NEBULAOS IN EITHER OR BOTH SLOTS (2026-10-14)

Since the human decision of 2026-10-14 NebulaOS may occupy slot 1 too, so the
install first reads the whole slot state (nebulaos_slots) and picks one of two
paths from it:

    PRESERVE_STOCK  NebulaOS runs from slot 2 and Creality is in slot 1, which
                    the owner has not released: everything above, unchanged.
    INACTIVE_SLOT   NebulaOS runs from slot N and the other slot holds NebulaOS,
                    or the owner set INSTALL_OTHER_SLOT=expendable: the other
                    slot is written directly from the running NebulaOS (the
                    flash helper re-resolves the live root right before it
                    writes and refuses it), verified, the marker is pointed at
                    it, and the printer reboots into it. Creality is never
                    booted, so there is no stock window, no MCU exposure and no
                    POWER_CYCLE_DANGEROUS state; until the marker moves, a power
                    cycle simply boots the running slot again.

Anything else - an unknown running slot, an unidentifiable other slot without
the owner's permission, Creality in slot 2 while NebulaOS runs from slot 1 -
is refused before anything is written, naming the profile key a human can set.

REALITY WINS

The journal says what a previous process intended. Every decision here is made
from what the device says now: which OS is running, what the active root is,
what the boot id is, what the marker bytes are, what the slot hashes are. The
journal is consulted to understand an in-progress transaction, never to skip a
check.
"""

import hashlib
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nebulaos_device as device      # noqa: E402
import nebulaos_journal as journal    # noqa: E402
import nebulaos_marker as marker      # noqa: E402
import nebulaos_slots as slots        # noqa: E402
import nebulaos_target as targets     # noqa: E402
import nebulaos_verify as verify      # noqa: E402


class InstallError(Exception):
    """An install that stopped. Carries the state it stopped in."""

    def __init__(self, message, state=None, disarmed=None):
        super().__init__(message)
        self.state = state
        self.disarmed = disarmed


class Artifacts:
    """The exact product build being installed."""

    def __init__(self, source_head, ximage_path, rootfs_path, manifest_path,
                 ximage_sha, ximage_size, rootfs_sha, rootfs_size):
        self.source_head = source_head
        self.ximage_path = ximage_path
        self.rootfs_path = rootfs_path
        self.manifest_path = manifest_path
        self.ximage_sha = ximage_sha
        self.ximage_size = ximage_size
        self.rootfs_sha = rootfs_sha
        self.rootfs_size = rootfs_size

    def total_bytes(self):
        return self.ximage_size + self.rootfs_size

    def describe(self):
        return "\n".join([
            "PRODUCT_HEAD=%s" % self.source_head,
            "PRODUCT_XIMAGE_SHA256=%s" % self.ximage_sha,
            "PRODUCT_XIMAGE_SIZE=%d" % self.ximage_size,
            "PRODUCT_ROOTFS_SHA256=%s" % self.rootfs_sha,
            "PRODUCT_ROOTFS_SIZE=%d" % self.rootfs_size,
        ])


class InstallResult:
    def __init__(self):
        self.lines = []
        self.state = journal.SAFE_NEBULAOS
        self.part1 = None
        self.disarmed = False
        self.ok = False

    def say(self, text):
        self.lines.append(text)

    def render(self):
        out = list(self.lines)
        out.append("")
        out.append("INSTALL_FINAL_STATE=%s" % self.state)
        out.append("INSTALL_DISARM_PERFORMED=%s" % ("YES" if self.disarmed else "NO"))
        out.append("PART1_INSTALL_VERIFIED=%s" % ("YES" if self.ok else "NO"))
        out.append("HARDWARE_QUALIFIED=NO")
        return "\n".join(out)


class Installer:
    """Drives one install. Talks to the device only through DeviceSession.

    `session_factory(which_os, address) -> DeviceSession` is the single seam
    between this logic and the transport. Production passes an SSH factory;
    tests pass one backed by a simulator. Nothing else in this class knows which
    it got, which is what makes every adversarial path testable offline.
    """

    # Bounded waits. Injected clock/sleep so tests do not actually sleep.
    REBOOT_GONE_TIMEOUT = 120
    REBOOT_BACK_TIMEOUT = 300

    def __init__(self, device_id, profile, control_set, artifacts, session_factory,
                 policy=None, txn=None, sleep=time.sleep, now=time.time):
        self.device_id = device_id
        self.profile = profile
        self.control = control_set
        self.artifacts = artifacts
        self.session_factory = session_factory
        # The policy is decided from the device's slot state once connected
        # (nebulaos_slots.plan_install). PRESERVE_STOCK until then: it is what
        # the "already running stock" path writes.
        self.policy = policy or targets.DEV_PRESERVE_STOCK
        self._policy_forced = policy is not None
        self.plan = None
        self.slot_state = None
        # The marker of the slot NebulaOS runs from: what a disarm restores.
        self._home_marker = marker.KERNEL2
        # The slot the new build must be running from at the end.
        self._expected_slot = 2
        self.txn = txn
        self.sleep = sleep
        self.now = now
        self.result = InstallResult()
        # Fail closed until stock's own updater log has been read on stock.
        self._stock_updater_acted = True

    # -- helpers -----------------------------------------------------------
    def _say(self, text):
        self.result.say(text)

    def _stale_own_lock(self, holder):
        """A device lock held by this device id whose host pid no longer exists."""
        dev, _, pid = (holder or "").rpartition(":")
        if dev != self.device_id or not pid.isdigit() or int(pid) == os.getpid():
            return False
        try:
            os.kill(int(pid), 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            return False
        return False

    def _advance(self, state, note=""):
        self.result.state = state
        if self.txn:
            self.txn.advance(state, note)
        self._say("STATE=%s%s" % (state, ("  (%s)" % note) if note else ""))

    def _connect(self, which_os, addresses=None):
        """Find the printer and prove it is ours before returning a session.

        Tries each candidate address in turn. An address that answers but is the
        wrong machine is not a fallback - it is the exact thing this refuses.
        """
        import nebulaos_profile as profiles
        candidates = addresses or profiles.candidate_addresses(self.profile, which_os)
        if not candidates:
            raise InstallError(
                "no known address for this printer while it runs %s. Rediscovery searches only "
                "the addresses a human enrolled - it does not scan." % which_os,
                state=self.result.state)

        problems = []
        for address in candidates:
            if not profiles.is_private_ipv4(address):
                problems.append("%s is not an RFC1918 address" % address)
                continue
            try:
                session = self.session_factory(which_os, address)
            except Exception as exc:
                problems.append("%s: %s" % (address, str(exc)[:120]))
                continue
            try:
                identity = session.probe_identity()
                ok, why = self.profile.identity_matches(identity)
                if not ok:
                    session.close()
                    problems.append("%s: %s" % (address, why))
                    continue
                self._say("CONNECTED=%s os=%s identity=matched" % (address, which_os))
                return session, address
            except Exception as exc:
                try:
                    session.close()
                except Exception:
                    pass
                problems.append("%s: %s" % (address, str(exc)[:120]))

        raise InstallError(
            "could not reach the enrolled printer as %s. Tried: %s"
            % (which_os, "; ".join(problems)), state=self.result.state)

    def _read_marker(self, session):
        block = session.read_marker_block()
        state, why = marker.parse(block)
        self._say("OTA_MARKER=%s (%s)" % (state, why))
        return state, why

    def _set_marker_verified(self, session, want):
        """Set the marker and prove it landed, by reading the physical bytes back.

        A marker write that is not read back is a marker write that might not
        have happened. This is the operation the whole slot dance depends on.
        """
        session.write_marker(want)
        block = session.read_marker_block()
        ok, why = marker.verify_readback(want, block)
        self._say("OTA_MARKER_WRITE=%s readback_ok=%s (%s)" % (want, "YES" if ok else "NO", why))
        return ok, why

    def _disarm(self, session, reason):
        """NebulaOS is running and the marker says stock. Put it back.

        Returns True only when the marker has been physically re-read as the
        running NebulaOS slot's marker (kernel2 on the PRESERVE_STOCK path).
        Anything less is reported as a dangerous state rather than quietly
        tolerated.
        """
        self._say("DISARMING=YES reason=%s" % reason)
        self._advance(journal.CLOSE_BACKWARD, "disarming: %s" % reason)
        try:
            ok, why = self._set_marker_verified(session, self._home_marker)
        except Exception as exc:
            self._say("DISARM_FAILED=YES detail=%s" % str(exc)[:200])
            return False
        self.result.disarmed = ok
        if not ok:
            self._say("DISARM_FAILED=YES detail=%s" % why)
        elif self.txn:
            # Advisory record only: the physically re-read marker is the
            # authority. A journal that cannot be written (the very failure some
            # callers are recovering from) must not turn a verified disarm into
            # an escaping exception.
            try:
                self.txn.mark_disarmed(reason)
            except Exception as exc:
                self._say("JOURNAL_DISARM_RECORD_FAILED=YES detail=%s" % str(exc)[:120])
        return ok

    def _wait_for_reboot(self, which_os, previous_boot_id, addresses=None):
        """Wait for the device to go away and come back as `which_os`.

        The proof that a reboot happened is a CHANGED boot id, not that a
        connection succeeded - a connection can succeed because the device never
        went down at all.
        """
        deadline = self.now() + self.REBOOT_BACK_TIMEOUT
        last = ""
        while self.now() < deadline:
            try:
                session, address = self._connect(which_os, addresses)
            except InstallError as exc:
                last = str(exc)[:160]
                self.sleep(5)
                continue
            try:
                now_boot = session.boot_id()
                if previous_boot_id and now_boot == previous_boot_id:
                    last = "boot_id unchanged (%s) - the device has not rebooted yet" % now_boot[:8]
                    session.close()
                    self.sleep(5)
                    continue
                running = session.which_os()
                if running != which_os:
                    last = "running %s, waiting for %s" % (running, which_os)
                    session.close()
                    self.sleep(5)
                    continue
                self._say("REBOOT_OBSERVED=YES os=%s boot_id=%s->%s"
                          % (which_os, (previous_boot_id or "?")[:8], (now_boot or "?")[:8]))
                return session, address
            except Exception as exc:
                last = str(exc)[:160]
                try:
                    session.close()
                except Exception:
                    pass
                self.sleep(5)
        raise InstallError(
            "the device did not come back as %s within %ds. Last: %s"
            % (which_os, self.REBOOT_BACK_TIMEOUT, last), state=self.result.state)

    # -- the phases --------------------------------------------------------
    def _precheck_on_nebulaos(self, session):
        """Everything that must be true before the marker is touched."""
        self._say("")
        self._say("--- preconditions, checked while retreat is still free ---")
        self._say("MCU_CONSEQUENCE=this install boots Creality's slot, whose updater may reflash "
                  "the GD32 MCU with stock firmware. NebulaOS's guard gets ONE bounded restore "
                  "attempt on the way back; PART1 requires that restore to be confirmed.")

        root = session.active_root()
        self._say("ACTIVE_ROOT=%s" % root)
        if root != "/dev/mmcblk0p8":
            raise InstallError(
                "NebulaOS should be running from /dev/mmcblk0p8 but root=%s. Refusing to plan a "
                "slot switch from an unexpected root." % root, state=self.result.state)

        idle = verify.idle_proof(session)
        self._say(idle.render())
        state = session.idle_state()
        # A dev printer whose Moonraker is broken can never prove idle, and the
        # broken image is usually why it is being reflashed. Unreadable is not
        # hot: proceed in dev mode unless a print or a real non-zero target is seen.
        unreadable_only = (set(state.heater_targets) == {"unreadable"}
                           and not state.printing and not state.paused)
        if not idle.ok() and unreadable_only and self.profile.install_mode() == "dev":
            self._say("IDLE_PROOF_OVERRIDE=DEV (Moonraker unreachable; no print or hot "
                      "heater observed)")
        elif not idle.ok():
            raise InstallError(
                "the printer is not idle: %s. A slot switch during a job loses the job, and a hot "
                "heater with no firmware to manage it is worse."
                % session.idle_state().why_not_idle(), state=self.result.state)

        wayout = verify.stock_wayout_proof(session, self.profile, self.artifacts.total_bytes())
        self._say(wayout.render())
        if not wayout.ok():
            raise InstallError(
                "the Stock way-out proof failed: %s. Refusing to set the stock marker - after the "
                "reboot, stock is the only way to continue or to undo anything."
                % "; ".join(c.name for c in wayout.failures()), state=self.result.state)
        return True

    def _stage(self, session):
        """Put the payload and the control helpers on the device, and hash them there.

        Helper bytes come from the control commit's git objects, never from the
        working tree. The payload comes from the attested build.
        """
        self._say("")
        self._say("--- staging ---")
        staged = {}
        for name, path in (("xImage", self.artifacts.ximage_path),
                           ("rootfs.squashfs", self.artifacts.rootfs_path),
                           ("build-manifest.txt", self.artifacts.manifest_path)):
            got = session.stage_file(path, name)
            staged[name] = got
            self._say("STAGED=%s sha256=%s" % (name, got))

        self._stage_helpers(session)
        return self._check_staged_payload(session, staged)

    def _stage_helpers(self, session):
        """Put the privileged helpers on the device, from C's git objects.

        Called from BOTH entry paths. The bytes never come from the working
        tree, and the device's own hash of what arrived is compared against the
        control commit's.
        """
        import tempfile
        for control_path in self.control.paths_of_kind("on-device"):
            name = os.path.basename(control_path)
            with tempfile.TemporaryDirectory(prefix=".nebulaos-helper.") as tmpdir:
                tmp = os.path.join(tmpdir, name)
                self.control.write_helper(control_path, tmp)
                got = session.stage_file(tmp, name)
            expected = self.control.helper_sha256(control_path)
            if got != expected:
                raise InstallError(
                    "helper %s arrived on the device as %s but the control commit says %s"
                    % (name, got[:16], expected[:16]), state=self.result.state)
            self._say("STAGED_HELPER=%s sha256=%s (from control commit %s)"
                      % (name, got, self.control.commit[:12]))
        return True

    def _check_staged_payload(self, session, staged):
        if staged.get("xImage") != self.artifacts.ximage_sha:
            raise InstallError("staged xImage hashes %s on the device, expected %s"
                               % (staged.get("xImage"), self.artifacts.ximage_sha),
                               state=self.result.state)
        if staged.get("rootfs.squashfs") != self.artifacts.rootfs_sha:
            raise InstallError("staged rootfs.squashfs hashes %s on the device, expected %s"
                               % (staged.get("rootfs.squashfs"), self.artifacts.rootfs_sha),
                               state=self.result.state)
        return staged

    def _flash_on_stock(self, session):
        """The Stock window. Short on purpose."""
        self._say("")
        self._say("--- stock window: POWER_CYCLE_DANGEROUS=YES ---")

        root = session.active_root()
        self._say("ACTIVE_ROOT=%s" % root)
        if root != "/dev/mmcblk0p7":
            raise InstallError(
                "expected to be running stock from /dev/mmcblk0p7 but root=%s" % root,
                state=journal.STOCK_RUNNING)

        # Stock's updater has already run by the time this session exists (it
        # is a boot-time init script). Its own log, on stock's tmpfs, is the
        # evidence; anything but a recorded handshake failure is treated as
        # "the updater may have acted" - fail closed.
        mcu_before = session.mcu_state()
        stock_update = mcu_before.get("stock_mcu_update", "unknown")
        self._say("STOCK_MCU_UPDATE=%s" % stock_update)
        self._stock_updater_acted = stock_update != "did_not_act"

        # Re-hash on the device. The payload was staged before a reboot; between
        # then and now the device ran a different OS.
        for name, want in (("xImage", self.artifacts.ximage_sha),
                           ("rootfs.squashfs", self.artifacts.rootfs_sha)):
            got = session.staged_sha256(name)
            self._say("RESTAGED_CHECK=%s sha256=%s" % (name, got))
            if got != want:
                raise InstallError(
                    "staged %s now hashes %s, expected %s - the payload changed across the reboot"
                    % (name, got[:16], want[:16]), state=journal.STOCK_RUNNING)

        # RE-VERIFY THE HELPER, for the same reason the payload is re-hashed
        # above. The payload was staged before a reboot and the reasoning was
        # "between then and now the device ran a different OS" - that applies
        # with more force to the privileged code than to the data.
        for control_path in self.control.paths_of_kind("on-device"):
            name = os.path.basename(control_path)
            got = session.staged_sha256(name)
            want = self.control.helper_sha256(control_path)
            self._say("HELPER_RECHECK=%s sha256=%s" % (name, got))
            if got != want:
                raise InstallError(
                    "the on-device helper %s hashes %s but control commit %s says %s. Refusing "
                    "to execute a privileged helper whose bytes are not the reviewed ones."
                    % (name, got[:16] or "<absent>", self.control.commit[:12], want[:16]),
                    state=journal.STOCK_RUNNING)

        owner = "%s:%d" % (self.device_id, os.getpid())
        got_lock, holder = session.acquire_flash_lock(owner)
        if not got_lock and self._stale_own_lock(holder):
            # An earlier installer of THIS device on this host died (e.g. a dropped
            # SSH session) without releasing the device-side lock. The host-side
            # transaction lock already guarantees we are the only installer here.
            self._say("FLASH_LOCK_RECLAIMED=%s (holder process no longer running)" % holder)
            session.release_flash_lock(holder)
            got_lock, holder = session.acquire_flash_lock(owner)
        if not got_lock:
            raise InstallError(
                "the device-side flash lock is held by %s. Two installers writing one printer is "
                "exactly what this prevents." % holder, state=journal.STOCK_RUNNING)

        try:
            plans = [
                self.policy.select("kernel2").plan_write(
                    self.artifacts.ximage_size, self.artifacts.ximage_sha),
                self.policy.select("rootfs2").plan_write(
                    self.artifacts.rootfs_size, self.artifacts.rootfs_sha),
            ]
            for plan in plans:
                self._say(plan.describe())

            self._advance(journal.FLASHING, "writing the NebulaOS slot")
            ok, report = session.apply_write_plans(plans, "build-manifest.txt")
            self._say(report.strip()[-2000:] if report else "")
            if not ok:
                raise InstallError(
                    "the flash helper reported failure. The marker still selects stock and slot 2 "
                    "must be treated as damaged - refusing to boot it.",
                    state=journal.FLASHING)

            # Verify the BYTES, not the exit code.
            for target_name, want, size in (
                    ("kernel2", self.artifacts.ximage_sha, self.artifacts.ximage_size),
                    ("rootfs2", self.artifacts.rootfs_sha, self.artifacts.rootfs_size)):
                got = session.region_sha256(target_name, size)
                self._say("FLASH_VERIFY=%s sha256=%s expected=%s" % (target_name, got, want))
                if got != want:
                    raise InstallError(
                        "%s verifies as %s, expected %s. Refusing to select a damaged slot."
                        % (target_name, got[:16], want[:16]), state=journal.FLASHING)
        finally:
            session.release_flash_lock(owner)

        self._advance(journal.FLASH_VERIFIED, "slot 2 written and verified")

        # IMMEDIATELY. Nothing between the verification and this.
        ok, why = self._set_marker_verified(session, marker.KERNEL2)
        if not ok:
            raise InstallError(
                "slot 2 is good but the marker could not be set to kernel2 (%s). NOT rebooting: "
                "a reboot now returns to stock with a freshly written NebulaOS slot that nothing "
                "points at." % why, state=journal.FLASH_VERIFIED)
        self._advance(journal.ARMED_NEBULAOS, "marker set to kernel2 and read back")

        updater_acted = self._stock_updater_acted
        if updater_acted:
            self._say("STOCK_MCU_UPDATER_ACTED=YES")
        return updater_acted

    # -- entry point -------------------------------------------------------
    def run(self):
        """Install, from wherever the device currently is."""
        self._say(self.artifacts.describe())
        self._say(self.control.describe())
        self._say("")

        session, address = self._connect_either()
        running = session.which_os()
        self._say("DEVICE_RUNNING_OS=%s" % running)

        try:
            if running == device.OS_NEBULAOS:
                state = self._read_slots(session)
                if state == "OTHER_NEBULAOS_SLOT_SELECTED":
                    state, _ = self._read_marker(session)
                if marker.is_armed_for_stock(state) and self._home_marker == marker.KERNEL2:
                    # A resumed or crashed transaction. Disarm FIRST.
                    self._say("")
                    self._say("--- found NebulaOS running with the marker on stock: ARMED_STOCK ---")
                    self._advance(journal.ARMED_STOCK, "discovered on connect")
                    if not self._disarm(session, "resumed transaction found the device armed"):
                        raise InstallError(
                            "found the device armed for stock and could not disarm it. Do not power "
                            "cycle. Resolve the marker by hand before anything else.",
                            state=journal.FAILED_NEEDS_ATTENTION)
                    self._say("DISARMED=YES - restarting the install from a safe state")
                    state, _ = self._read_marker(session)

                if state != self._home_marker:
                    raise InstallError(
                        "the marker is %s while NebulaOS runs from slot %s. Refusing to proceed "
                        "from an indeterminate marker - the next boot target cannot be predicted."
                        % (state, self.slot_state.running_slot if self.slot_state else "?"),
                        state=journal.FAILED_NEEDS_ATTENTION)

                self._choose_path()
                if self.plan.path == slots.PATH_INACTIVE_SLOT:
                    updater_acted = self._install_inactive_slot(session)
                else:
                    updater_acted = self._install_from_nebulaos(session)
            elif running == device.OS_STOCK:
                self._check_slot2_from_stock(session)
                self._say(self.policy.report(prefix="DEV_INSTALL_POLICY"))
                self._say("")
                self._say("--- device is already running stock: entering the stock window ---")
                self._advance(journal.STOCK_RUNNING, "device was already on stock")
                # Stage THIS build's payload here too (2026-10-15): this path
                # assumed it only resumes an interrupted install whose payload
                # is already on the device. ke-dev was simply on stock (USB
                # recovery after a failed NebulaOS boot); the re-hash then met
                # the previous install's xImage and refused - correctly, but
                # it could never install from here. Staging the same bytes
                # again on a resume is harmless; the re-hash still guards them.
                self._stage(session)
                updater_acted = self._install_from_stock(session)
            else:
                raise InstallError(
                    "could not identify the running OS. Refusing to act on an unidentified system.",
                    state=journal.FAILED_NEEDS_ATTENTION)
        finally:
            try:
                session.close()
            except Exception:
                pass

        return self._close_forward(updater_acted)

    # -- the slot state and the path ---------------------------------------
    def _record(self, fields, note=""):
        """Advisory journal record for `status`. Never fatal: the device is the
        authority, and a journal that cannot be written must not stop a safe
        state transition."""
        if not self.txn:
            return
        try:
            self.txn.record(fields, note)
        except Exception as exc:                   # noqa: BLE001 - advisory only
            self._say("JOURNAL_RECORD_FAILED=YES detail=%s" % str(exc)[:120])

    def _read_slots(self, session):
        """Read and report the slot state; settle which marker means "home".

        -> the marker state as it should be read by run(). When the marker
        selects the OTHER slot and that slot is NebulaOS (or anything but
        Creality), it is pointed back at the running slot here, read back,
        before any decision: an install must never start with the marker on
        the slot it is about to overwrite. Marker-on-Creality keeps the original
        ARMED_STOCK handling in run().
        """
        state = slots.read_slot_state(session)
        self.slot_state = state
        self._say("")
        self._say("--- slot state ---")
        self._say(state.describe())
        self._record(state.journal_fields(), "slot state on connect")
        r = state.running_slot
        if r is None:
            raise InstallError(
                "cannot tell which slot NebulaOS runs from: root=%s. Refusing to plan a slot "
                "switch from an unexpected root." % state.active_root, state=self.result.state)
        self._home_marker = slots.SLOTS[r].marker
        self._expected_slot = slots.other(r)
        self._say("OTA_MARKER=%s (%s)" % (state.marker_state, state.marker_reason))
        o = state.marker_slot
        if o is None or o == r:
            return state.marker_state
        if state.holds[o] == slots.HOLDS_CREALITY:
            if r != 2:
                # NebulaOS in slot 1, the marker on Creality in slot 2. The
                # original ARMED_STOCK path is written for slot 2 only; disarm
                # here with the same rules.
                self._say("--- found NebulaOS (slot 1) running with the marker on Creality "
                          "(slot 2): ARMED_STOCK ---")
                self._advance(journal.ARMED_STOCK, "discovered on connect")
                if not self._disarm(session, "resumed state found the device armed"):
                    raise InstallError(
                        "found the device armed for Creality and could not disarm it. Do not "
                        "power cycle. Resolve the marker by hand before anything else.",
                        state=journal.FAILED_NEEDS_ATTENTION)
                return "OTHER_NEBULAOS_SLOT_SELECTED"
            return state.marker_state
        self._say("MARKER_SELECTS_OTHER_SLOT=%d holds=%s - pointing it back at the running slot %d "
                  "before anything is written" % (o, state.holds[o], r))
        ok, why = self._set_marker_verified(session, self._home_marker)
        if not ok:
            raise InstallError(
                "the marker selects slot %d (%s) and could not be pointed back at the running slot "
                "%d (%s). Refusing to write anything." % (o, state.holds[o], r, why),
                state=journal.FAILED_NEEDS_ATTENTION)
        if self.txn:
            # Physically re-read as the running NebulaOS slot: the same fact a
            # disarm records, so an older stock-window danger record is cleared.
            try:
                self.txn.mark_disarmed("marker pointed back at the running slot %d" % r)
            except Exception as exc:               # noqa: BLE001 - advisory only
                self._say("JOURNAL_DISARM_RECORD_FAILED=YES detail=%s" % str(exc)[:120])
        return "OTHER_NEBULAOS_SLOT_SELECTED"

    def _check_slot2_from_stock(self, session):
        """The "already running stock" path writes slot 2, NebulaOS's original
        home, as it always has: empty, unknown (an interrupted install) and
        NebulaOS content there are expected. A second Creality system in slot 2
        is not overwritten without the owner's INSTALL_OTHER_SLOT=expendable.
        The probe is informational otherwise: if it cannot be read, the stock
        window's own checks (root, hashes, the helper's preflight) still apply."""
        try:
            state = slots.read_slot_state(session)
        except Exception as exc:                   # noqa: BLE001 - reported, not fatal
            self._say("SLOT_STATE=UNREADABLE (%s)" % str(exc)[:160])
            return
        self.slot_state = state
        self._say("")
        self._say("--- slot state ---")
        self._say(state.describe())
        self._record(state.journal_fields(), "slot state on connect (stock)")
        if state.running_slot == 1 and state.holds[2] == slots.HOLDS_CREALITY:
            try:
                other_policy, note = self.profile.effective_other_slot_policy()
            except Exception as exc:
                raise InstallError(str(exc), state=journal.STOCK_RUNNING)
            if other_policy != slots.OTHER_SLOT_EXPENDABLE:
                raise InstallError(
                    "Creality is running from slot 1 and slot 2 holds Creality too (%s). This "
                    "install would overwrite it; the human who owns this printer sets %s=%s to "
                    "allow that (%s)." % (state.evidence[2], slots.OTHER_SLOT_KEY,
                                          slots.OTHER_SLOT_EXPENDABLE, note),
                    state=journal.STOCK_RUNNING)

    def _choose_path(self):
        try:
            other_policy, note = self.profile.effective_other_slot_policy()
        except Exception as exc:                   # ProfileError: a bad value refuses
            raise InstallError(str(exc), state=journal.SAFE_NEBULAOS)
        self._say("")
        self._say("--- install path ---")
        self._say("DEV_INSTALL_OTHER_SLOT_POLICY=%s (%s)" % (other_policy, note))
        try:
            plan = slots.plan_install(self.slot_state, other_policy)
        except slots.SlotError as exc:
            self._say("DEV_INSTALL_PATH=REFUSED")
            raise InstallError(str(exc), state=journal.SAFE_NEBULAOS)
        if self._policy_forced and plan.policy is not self.policy:
            raise InstallError(
                "this installer was constructed for policy %s but the device's slot state calls "
                "for %s" % (self.policy.name, plan.policy.name), state=journal.SAFE_NEBULAOS)
        self.plan = plan
        self.policy = plan.policy
        self._expected_slot = plan.target_slot
        self._say(plan.describe())
        self._say(self.policy.report(prefix="DEV_INSTALL_POLICY"))
        self._record({"INSTALL_PATH": plan.path, "INSTALL_SOURCE_SLOT": plan.running_slot,
                      "INSTALL_TARGET_SLOT": plan.target_slot,
                      "INSTALL_TARGET_HELD": plan.overwrites}, "install path %s" % plan.path)
        return plan

    def _install_inactive_slot(self, session):
        """INACTIVE_SLOT: write the slot NebulaOS is not running from, from NebulaOS.

        No Creality boot, no stock window. The running slot is the way back and
        is never selected by the policy; the marker stays on it until the new
        slot's bytes are verified, then moves to the new slot and is read back,
        then a software reboot.
        """
        plan = self.plan
        r, t = plan.running_slot, plan.target_slot
        target = slots.SLOTS[t]
        self._say("")
        self._say("--- preconditions (INACTIVE_SLOT: slot %d writes slot %d) ---" % (r, t))
        self._say("MCU_CONSEQUENCE=none - Creality is not booted on this path, so its MCU updater "
                  "never runs")
        self._say("POWER_CYCLE_DANGEROUS=NO (the marker selects the running slot %d until slot %d "
                  "is written and verified)" % (r, t))

        idle = verify.idle_proof(session)
        self._say(idle.render())
        state_now = session.idle_state()
        unreadable_only = (set(state_now.heater_targets) == {"unreadable"}
                           and not state_now.printing and not state_now.paused)
        if not idle.ok() and unreadable_only and self.profile.install_mode() == "dev":
            self._say("IDLE_PROOF_OVERRIDE=DEV (Moonraker unreachable; no print or hot "
                      "heater observed)")
        elif not idle.ok():
            raise InstallError(
                "the printer is not idle: %s. Writing a slot and rebooting during a job loses "
                "the job." % state_now.why_not_idle(), state=journal.SAFE_NEBULAOS)

        wayback = verify.inactive_slot_wayback_proof(
            session, self.slot_state, plan, self.artifacts.total_bytes())
        self._say(wayback.render())
        if not wayback.ok():
            raise InstallError(
                "the way-back proof failed: %s. Nothing was written."
                % "; ".join(c.name for c in wayback.failures()), state=journal.SAFE_NEBULAOS)

        self._stage(session)
        self._advance(journal.PRECHECKED, "identity, idle, way-back and payload all proven")

        owner = "%s:%d" % (self.device_id, os.getpid())
        got_lock, holder = session.acquire_flash_lock(owner)
        if not got_lock and self._stale_own_lock(holder):
            self._say("FLASH_LOCK_RECLAIMED=%s (holder process no longer running)" % holder)
            session.release_flash_lock(holder)
            got_lock, holder = session.acquire_flash_lock(owner)
        if not got_lock:
            raise InstallError(
                "the device-side flash lock is held by %s. Two installers writing one printer is "
                "exactly what this prevents." % holder, state=journal.SAFE_NEBULAOS)

        try:
            # Right before the write: the live root, from /proc/cmdline, again.
            # The flash helper does the same on the device, twice.
            root = session.active_root()
            self._say("ACTIVE_ROOT_RECHECK=%s" % root)
            if root != slots.SLOTS[r].root or root == target.root:
                raise InstallError(
                    "the live root is now %s, not slot %d's %s. Refusing to write slot %d."
                    % (root, r, slots.SLOTS[r].root, t), state=journal.SAFE_NEBULAOS)
            idle_now = session.idle_state()
            if idle_now.printing or idle_now.paused or not (
                    idle_now.is_idle() or set(idle_now.heater_targets) == {"unreadable"}
                    and self.profile.install_mode() == "dev"):
                raise InstallError("the printer became busy before the write (%s)"
                                   % idle_now.why_not_idle(), state=journal.SAFE_NEBULAOS)

            plans = [
                self.policy.select(target.kernel).plan_write(
                    self.artifacts.ximage_size, self.artifacts.ximage_sha),
                self.policy.select(target.rootfs).plan_write(
                    self.artifacts.rootfs_size, self.artifacts.rootfs_sha),
            ]
            for p in plans:
                self._say(p.describe())

            self._advance(journal.SLOT_FLASHING, "writing slot %d from NebulaOS slot %d" % (t, r))
            ok, report = session.apply_write_plans(plans, "build-manifest.txt")
            self._say(report.strip()[-2000:] if report else "")
            if not ok:
                raise InstallError(
                    "the flash helper reported failure. The marker still selects the running slot "
                    "%d; slot %d must be treated as damaged and is not selected." % (r, t),
                    state=journal.SAFE_NEBULAOS)
            for name, want, size in ((target.kernel, self.artifacts.ximage_sha,
                                      self.artifacts.ximage_size),
                                     (target.rootfs, self.artifacts.rootfs_sha,
                                      self.artifacts.rootfs_size)):
                got = session.region_sha256(name, size)
                self._say("FLASH_VERIFY=%s sha256=%s expected=%s" % (name, got, want))
                if got != want:
                    raise InstallError(
                        "%s verifies as %s, expected %s. The marker still selects the running "
                        "slot %d; refusing to select a damaged slot." % (name, got[:16], want[:16], r),
                        state=journal.SAFE_NEBULAOS)
        finally:
            session.release_flash_lock(owner)

        self._advance(journal.SLOT_FLASH_VERIFIED, "slot %d written and verified" % t)

        try:
            ok, why = self._set_marker_verified(session, target.marker)
        except Exception as exc:
            ok, why = False, "the marker write raised: %s" % str(exc)[:160]
        if not ok:
            # Point it home again; a marker that is neither is the one state
            # where the next boot cannot be predicted.
            try:
                home_ok, home_why = self._set_marker_verified(session, self._home_marker)
            except Exception as exc:
                home_ok, home_why = False, str(exc)[:160]
            if home_ok:
                raise InstallError(
                    "slot %d is written and verified but the marker could not be set to it (%s). "
                    "The marker was put back on the running slot %d and read back; nothing was "
                    "rebooted." % (t, why, r), state=journal.SAFE_NEBULAOS)
            raise InstallError(
                "slot %d is written and verified but the marker could not be set to it (%s), and "
                "putting it back on slot %d did not verify either (%s). The next boot target is "
                "not known: do not reboot; read the marker with `diagnose`."
                % (t, why, r, home_why), state=journal.FAILED_NEEDS_ATTENTION)
        self._advance(journal.ARMED_NEBULAOS, "marker set to slot %d (%s) and read back"
                      % (t, target.marker))

        boot_before = session.boot_id()
        session.reboot()
        self._advance(journal.REBOOTING_TO_NEBULAOS, "software reboot into slot %d" % t)
        self._pending_reboot = (device.OS_NEBULAOS, boot_before)
        return False

    def _connect_either(self):
        """Find the printer without yet knowing which OS it is running."""
        import nebulaos_profile as profiles
        problems = []
        for which in (device.OS_NEBULAOS, device.OS_STOCK):
            try:
                session, address = self._connect(which)
                return session, address
            except InstallError as exc:
                problems.append(str(exc)[:200])
        raise InstallError("could not reach the printer as NebulaOS or as stock. %s"
                           % " | ".join(problems), state=self.result.state)

    def _install_from_nebulaos(self, session):
        self._precheck_on_nebulaos(session)
        self._stage(session)
        self._advance(journal.PRECHECKED, "identity, idle, way-out and payload all proven")

        boot_before = session.boot_id()

        # write_ota_marker("ota:kernel") on the device fires the PLR tombstone.
        #
        # Wrapped, because the dangerous case is not "it returned False" - it is
        # "it raised". An SSH drop AFTER conv=fsync has already committed the
        # bytes leaves the device physically armed for stock while this process
        # believes it never got that far. Letting that exception propagate would
        # skip the disarm entirely; the next run would recover it via the
        # ARMED_STOCK path, but only if a human re-runs instead of power-cycling,
        # and a power cycle into stock is what costs the MCU.
        try:
            ok, why = self._set_marker_verified(session, marker.KERNEL)
        except Exception as exc:
            self._say("MARKER_WRITE_RAISED=YES detail=%s" % str(exc)[:200])
            self._disarm(session, "the stock marker write raised; the bytes may have landed")
            raise InstallError(
                "the stock marker write failed with an exception (%s). A disarm was attempted "
                "because the write may still have committed. Do NOT power cycle: if the marker "
                "is on stock, a power cycle boots Creality's slot and reflashes the MCU."
                % str(exc)[:160], state=journal.CLOSE_BACKWARD)
        if not ok:
            self._say("MARKER_WRITE_FAILED=YES - NOT rebooting")
            disarmed = self._disarm(session, "the stock marker write did not verify")
            if disarmed:
                raise InstallError(
                    "could not set the marker to stock (%s). The device was not rebooted, and "
                    "the marker was re-read as NebulaOS." % why, state=journal.SAFE_NEBULAOS)
            # The write did not verify, but neither did the disarm: the marker
            # state is unknown and may select stock. Never report that as safe.
            raise InstallError(
                "could not set the marker to stock (%s), and the disarm did NOT verify either - "
                "the marker may still select stock. Do NOT power cycle: booting Creality's slot "
                "reflashes the MCU. Re-run install, which disarms on connect, or fix the marker "
                "by hand." % why, state=journal.FAILED_NEEDS_ATTENTION)
        # ===================== THE ARMED WINDOW ==========================
        #
        # From here until the reboot is issued, the marker says stock and
        # NebulaOS is still running. EVERY exit from this region must disarm,
        # so the whole region is one guarded block rather than a sequence of
        # individually-wrapped calls.
        #
        # An independent review demonstrated why that distinction matters. An
        # earlier revision wrapped only the marker write, leaving two unguarded
        # raises inside the window: the post-arm idle_state() (which raises on
        # any non-zero rc or timeout, i.e. on a dropped SSH session) and the
        # journal advance (ENOSPC, missing state dir). Both were reproduced
        # against the simulator and both left ARMED_AND_NOT_DISARMED=True.
        # Neither was an InstallError either, so the operator got a Python
        # traceback instead of the "do NOT power cycle" text - in the one state
        # where that text is the whole point.
        try:
            self._advance(journal.ARMED_STOCK, "marker=kernel, read back, PLR tombstone fired")
            self._say("POWER_CYCLE_DANGEROUS=YES")

            # Last look before the point of no easy return.
            idle = session.idle_state()
            dev_unreadable = (set(idle.heater_targets) == {"unreadable"}
                              and not idle.printing and not idle.paused
                              and self.profile.install_mode() == "dev")
            if dev_unreadable:
                self._say("IDLE_RECHECK_OVERRIDE=DEV (Moonraker unreachable; no print or "
                          "hot heater observed)")
            elif not idle.is_idle():
                raise InstallError(
                    "the printer became busy after arming (%s)" % idle.why_not_idle(),
                    state=journal.CLOSE_BACKWARD)

            session.reboot()
            self._advance(journal.REBOOTING_TO_STOCK, "software reboot issued")
        except BaseException as exc:
            # BaseException on purpose: a KeyboardInterrupt or a SystemExit here
            # leaves a printer armed for stock just as surely as an IOError does.
            self._say("ARMED_WINDOW_FAILURE=%s" % type(exc).__name__)
            disarmed = self._disarm(session, "a failure inside the armed window: %s"
                                    % str(exc)[:120])
            try:
                session.close()
            except Exception:
                pass
            if isinstance(exc, InstallError) and disarmed:
                raise InstallError(
                    "%s. The marker was put back to NebulaOS and read back, so the device is no "
                    "longer armed for stock." % exc, state=journal.CLOSE_BACKWARD)
            raise InstallError(
                "a failure inside the armed window (%s: %s). Disarm %s. %s"
                % (type(exc).__name__, str(exc)[:160],
                   "succeeded - the marker is back on NebulaOS" if disarmed
                   else "FAILED - the marker may still select stock",
                   "" if disarmed else
                   "Do NOT power cycle: booting Creality's slot reflashes the MCU. Re-run "
                   "install, which disarms on connect, or fix the marker by hand."),
                state=journal.CLOSE_BACKWARD if disarmed else journal.FAILED_NEEDS_ATTENTION)
        finally:
            try:
                session.close()
            except Exception:
                pass
        # ================== END OF THE ARMED WINDOW ======================

        stock_session, _ = self._wait_for_reboot(device.OS_STOCK, boot_before)
        self._advance(journal.STOCK_RUNNING, "rediscovered as stock, identity re-proven")
        try:
            return self._install_from_stock(stock_session)
        finally:
            try:
                stock_session.close()
            except Exception:
                pass

    def _install_from_stock(self, session):
        # Stage the control helpers HERE TOO.
        #
        # An independent review found that this path - "the device was already
        # running stock when we connected" - never staged anything, so
        # apply_write_plans executed whatever bytes happened to be sitting at
        # /usr/data/nebulaos-hwagent/flash-spare-slot.sh. That is a shared,
        # non-root-owned data partition: a prior control commit, a prior project,
        # or anything else that can write there. The whole point of reading
        # helpers from C's git objects was defeated on exactly the path that
        # skipped the read.
        self._stage_helpers(session)
        updater_acted = self._flash_on_stock(session)
        boot_before = session.boot_id()
        session.reboot()
        self._advance(journal.REBOOTING_TO_NEBULAOS, "software reboot issued from stock")
        self._pending_reboot = (device.OS_NEBULAOS, boot_before)
        return updater_acted

    def _close_forward(self, updater_acted):
        which, boot_before = getattr(self, "_pending_reboot", (device.OS_NEBULAOS, ""))
        try:
            session, address = self._wait_for_reboot(which, boot_before)
        except InstallError as exc:
            if self.plan is None or self.plan.path != slots.PATH_INACTIVE_SLOT:
                raise
            raise InstallError(
                "%s. The marker selects the new slot %d; the previous NebulaOS in slot %d was not "
                "touched. If slot %d does not boot, pointing the marker back at slot %d (%s) "
                "returns to the previous NebulaOS - Creality is not involved."
                % (exc, self.plan.target_slot, self.plan.running_slot, self.plan.target_slot,
                   self.plan.running_slot, slots.SLOTS[self.plan.running_slot].marker),
                state=exc.state)
        self._advance(journal.NEBULAOS_RUNNING, "rediscovered as NebulaOS")
        try:
            device.wait_for_boot_done(session, self._say, self.sleep, self.now)
            try:
                after = slots.read_slot_state(session)
                self._say("")
                self._say("--- slot state after the install ---")
                self._say(after.describe())
                self._record(after.journal_fields(), "slot state after the install")
            except Exception as exc:               # noqa: BLE001 - reported; PART1 decides
                self._say("SLOT_STATE_AFTER=UNREADABLE (%s)" % str(exc)[:160])
            result = verify.part1_verify(
                session,
                self.artifacts.ximage_sha, self.artifacts.ximage_size,
                self.artifacts.rootfs_sha, self.artifacts.rootfs_size,
                self.artifacts.source_head, profile=self.profile,
                expected_boot_id_changed_from=boot_before, expected_slot=self._expected_slot)
            mcu_restore = verify.observe_mcu_restore(session)
            self._say("")
            self._say(verify.render_part1(result, self.artifacts.source_head,
                                          mcu_restore_result=mcu_restore))
            self.result.part1 = result
            verified = result.ok()
            if updater_acted:
                # Close forward regardless - the device must end up on NebulaOS -
                # but the install is not verified.
                self._say("")
                self._say("PART1_INSTALL_VERIFIED=NO")
                self._say("# Stock's MCU updater appears to have acted during the window. The "
                          "install completed and the device is back on NebulaOS, but the MCU is "
                          "not the one that was qualified.")
                verified = False
            self.result.ok = verified
            self._advance(journal.DONE if verified else journal.FAILED_NEEDS_ATTENTION,
                          "part1 verified" if verified else "part1 verification failed")
        finally:
            try:
                session.close()
            except Exception:
                pass
        return self.result
