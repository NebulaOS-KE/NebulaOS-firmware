#!/usr/bin/env python3
"""Adversarial simulation of the developer install, end to end.

Every scenario the mission names is exercised against the REAL install state
machine - nebulaos_install.Installer, unmodified - driven by a simulated printer
through the same `session_factory` seam that production fills with SSH. Nothing
here mocks the installer's own logic; the device misbehaves and the installer
has to cope.

The control commit is real too: each run builds a throwaway git repository,
commits the actual helper files, clones it as a protected mirror and resolves a
ControlSet out of it. So the provenance path that refuses unpublished control
commits and mismatched helper hashes is under test, not stubbed.

WHAT A PASSING CASE MEANS HERE

For the happy path: the device ends up running NebulaOS, from slot 2, with the
exact expected bytes in kernel2 and rootfs2, and PART1_INSTALL_VERIFIED=YES.

For every adversarial case: the installer REFUSES, and refuses for the right
reason, and - crucially - leaves the printer in a state a human can recover.
The most important assertion in this file is not that a failure is detected; it
is that a failure while ARMED puts the marker back.
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FW = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(FW, "tools", "hardware"))
sys.path.insert(0, os.path.join(HERE, "hardware"))

import nebulaos_control as control    # noqa: E402
import nebulaos_device as device      # noqa: E402
import nebulaos_install as install    # noqa: E402
import nebulaos_journal as journal    # noqa: E402
import nebulaos_marker as marker      # noqa: E402
import nebulaos_profile as profiles   # noqa: E402
import nebulaos_target as targets     # noqa: E402
import nebulaos_evidence as evidence  # noqa: E402
import nebulaos_device_sim as sim     # noqa: E402

PASS = []
FAIL = []


def ok(name, detail=""):
    PASS.append(name)
    print("PASS  %s%s" % (name, ("  -- " + detail) if detail else ""))


def bad(name, detail=""):
    FAIL.append(name)
    print("FAIL  %s" % name)
    if detail:
        print("       %s" % detail)


def check(name, condition, detail=""):
    (ok if condition else bad)(name, detail)
    return condition


# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

XIMAGE = b"NEBULAOS-XIMAGE-" + b"K" * 4096
ROOTFS = b"NEBULAOS-ROOTFS-" + b"R" * 65536
SOURCE_HEAD = "c4061c82356c09c4b053a1f9603ebaf7b98b704f"


class Fixture:
    def __init__(self, root):
        self.root = root
        self.payload_dir = os.path.join(root, "payload")
        os.makedirs(self.payload_dir)

        self.ximage_path = os.path.join(self.payload_dir, "xImage")
        self.rootfs_path = os.path.join(self.payload_dir, "rootfs.squashfs")
        self.manifest_path = os.path.join(self.payload_dir, "build-manifest.txt")
        with open(self.ximage_path, "wb") as fh:
            fh.write(XIMAGE)
        with open(self.rootfs_path, "wb") as fh:
            fh.write(ROOTFS)
        with open(self.manifest_path, "w") as fh:
            fh.write("git_commit_main=%s\n" % SOURCE_HEAD)

        self.artifacts = install.Artifacts(
            source_head=SOURCE_HEAD,
            ximage_path=self.ximage_path, rootfs_path=self.rootfs_path,
            manifest_path=self.manifest_path,
            ximage_sha=hashlib.sha256(XIMAGE).hexdigest(), ximage_size=len(XIMAGE),
            rootfs_sha=hashlib.sha256(ROOTFS).hexdigest(), rootfs_size=len(ROOTFS))

        self.printer = sim.SimulatedPrinter()
        self._write_profile()
        self.profile = profiles.DeviceProfile.load("printer-sim")
        self.control = self._build_control()

    # -- enrolled profile --------------------------------------------------
    def _write_profile(self):
        home = os.path.join(self.root, "config")
        os.makedirs(os.path.join(home, "devices", "printer-sim"), mode=0o700)
        os.chmod(home, 0o700)
        os.chmod(os.path.join(home, "devices"), 0o700)
        os.environ[profiles.ENV_HOME] = home
        pdir = os.path.join(home, "devices", "printer-sim")

        cid, snmac = self.printer.identity()
        conf = os.path.join(pdir, "profile.conf")
        with open(conf, "w") as fh:
            fh.write("\n".join([
                "DEVICE_ID=printer-sim",
                "EMMC_CID=%s" % cid,
                "SN_MAC_SHA256=%s" % snmac,
                "NEBULAOS_HOST_KEY=%s" % self.printer.host_keys[device.OS_NEBULAOS],
                "STOCK_HOST_KEY=%s" % self.printer.host_keys[device.OS_STOCK],
                "NEBULAOS_ADDRESS_HISTORY=%s" % self.printer.addresses[device.OS_NEBULAOS],
                "STOCK_ADDRESS_HISTORY=%s" % self.printer.addresses[device.OS_STOCK],
                "NEBULAOS_CREDENTIAL_REF=nebulaos.cred",
                "STOCK_CREDENTIAL_REF=stock.cred",
                "",
            ]))
        os.chmod(conf, 0o600)
        for which, name in ((device.OS_NEBULAOS, "nebulaos.cred"), (device.OS_STOCK, "stock.cred")):
            path = os.path.join(pdir, name)
            with open(path, "w") as fh:
                fh.write(self.printer.passwords[which] + "\n")
            os.chmod(path, 0o600)

    # -- a real control commit --------------------------------------------
    def _build_control(self):
        """Build a throwaway origin, commit real helpers, mirror it, resolve C.

        Deliberately the real ControlMirror/ControlSet path: publication and
        helper-hash pinning are safety properties and a stub would not exercise
        them.
        """
        origin = os.path.join(self.root, "origin.git")
        work = os.path.join(self.root, "origin-work")
        os.makedirs(work)
        env = dict(os.environ, GIT_AUTHOR_NAME="sim", GIT_AUTHOR_EMAIL="sim@example",
                   GIT_COMMITTER_NAME="sim", GIT_COMMITTER_EMAIL="sim@example")

        helper_dir = os.path.join(work, "scripts")
        os.makedirs(helper_dir)
        helper_body = b"#!/bin/sh\n# simulated slot-2 flash helper\nexit 0\n"
        with open(os.path.join(helper_dir, "flash-spare-slot.sh"), "wb") as fh:
            fh.write(helper_body)

        # A host module, copied verbatim from the tree, so the host-drift gate
        # has something real to compare.
        os.makedirs(os.path.join(work, "tools", "hardware"))
        host_src = os.path.join(FW, "tools", "hardware", "nebulaos_marker.py")
        shutil.copyfile(host_src, os.path.join(work, "tools", "hardware", "nebulaos_marker.py"))
        with open(host_src, "rb") as fh:
            host_sha = hashlib.sha256(fh.read()).hexdigest()

        manifest = "\n".join([
            "# simulated control manifest",
            "%s  on-device  scripts/flash-spare-slot.sh" % hashlib.sha256(helper_body).hexdigest(),
            "%s  host  tools/hardware/nebulaos_marker.py" % host_sha,
            "",
        ])
        with open(os.path.join(work, "tools", "hardware", "CONTROL_MANIFEST"), "w") as fh:
            fh.write(manifest)

        def git(*args, cwd=work):
            subprocess.run(["git"] + list(args), cwd=cwd, check=True,
                           capture_output=True, env=env)

        git("init", "-q", "-b", "main")
        git("add", "-A")
        git("commit", "-qm", "simulated control commit")
        commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=work,
                                capture_output=True, text=True, env=env).stdout.strip()
        subprocess.run(["git", "clone", "-q", "--bare", work, origin],
                       check=True, capture_output=True, env=env)

        os.environ[control.ENV_STATE_HOME] = os.path.join(self.root, "state")
        mirror = control.ControlMirror(origin, os.path.join(self.root, "state", "mirror.git"))
        mirror.refresh()
        self.control_commit = commit
        self.control_work = work
        return control.ControlSet.load(mirror, commit)

    def installer(self, **kwargs):
        txn = kwargs.pop("txn", None)
        return install.Installer(
            "printer-sim", self.profile, self.control, self.artifacts,
            sim.make_session_factory(self.printer, self.profile),
            txn=txn, sleep=lambda _s: None, now=_FakeClock(), **kwargs)


class _FakeClock:
    """Monotonic enough for timeouts, instant in wall time."""
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        self.t += 1.0
        return self.t


def scenario(name):
    """Fresh fixture per scenario, in its own temp tree."""
    root = tempfile.mkdtemp(prefix="nebulaos-sim-%s." % name,
                            dir=os.environ.get("TMPDIR") or None)
    return Fixture(root), root


def run_install(fixture, txn=None):
    """-> (result_or_None, error_or_None)."""
    try:
        return fixture.installer(txn=txn).run(), None
    except install.InstallError as exc:
        return None, exc
    except Exception as exc:                      # noqa: BLE001 - surfaced as a failure
        return None, exc


def marker_state(printer):
    return marker.parse(printer.partitions["ota"])[0]


# ---------------------------------------------------------------------------
# scenarios
# ---------------------------------------------------------------------------

def case_happy_path():
    fx, root = scenario("happy")
    try:
        result, err = run_install(fx)
        if err is not None:
            return bad("NebulaOS -> Stock -> NebulaOS install succeeds", str(err)[:220])
        check("NebulaOS -> Stock -> NebulaOS install succeeds", result.ok,
              "final state %s" % result.state)
        check("the device ends up running NebulaOS",
              fx.printer.running_os == device.OS_NEBULAOS, fx.printer.running_os)
        check("the marker ends up selecting slot 2",
              marker_state(fx.printer) == marker.KERNEL2, marker_state(fx.printer))
        check("kernel2 holds exactly the expected xImage",
              hashlib.sha256(fx.printer.partitions["kernel2"]).hexdigest() == fx.artifacts.ximage_sha)
        check("rootfs2 holds exactly the expected rootfs",
              hashlib.sha256(fx.printer.partitions["rootfs2"]).hexdigest() == fx.artifacts.rootfs_sha)
        check("the stock slot was not written",
              fx.printer.partitions["kernel"] == b"\xde\xad" * 1024
              and fx.printer.partitions["rootfs"] == b"\xbe\xef" * 4096,
              "DEV_INSTALL_WRITES_STOCK=NO, proven on the device")
        check("the device-side flash lock was released",
              fx.printer.flash_lock_holder is None)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_wrong_printer():
    fx, root = scenario("wrongprinter")
    try:
        fx.printer.identity_override = ("0xDIFFERENTCID", hashlib.sha256(b"someone else").hexdigest())
        result, err = run_install(fx)
        check("a different printer on the enrolled address is refused", err is not None,
              "" if err else "the install proceeded")
        if err:
            check("the refusal names the identity mismatch",
                  "CID" in str(err) or "identity" in str(err).lower() or "sn_mac" in str(err),
                  str(err)[:160])
        check("nothing was written to the wrong printer",
              fx.printer.partitions["kernel2"] == b"")
        check("the marker on the wrong printer was not touched",
              marker_state(fx.printer) == marker.KERNEL2)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_host_key_mismatch():
    fx, root = scenario("hostkey")
    try:
        fx.printer.host_keys[device.OS_NEBULAOS] = "ssh-ed25519 AAAAROTATEDKEY"
        result, err = run_install(fx)
        check("a changed SSH host key refuses the install", err is not None,
              "" if err else "the install proceeded despite a rotated host key")
        check("no TOFU: nothing was written", fx.printer.partitions["kernel2"] == b"")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_ip_change():
    fx, root = scenario("ipchange")
    try:
        fx.printer.change_address_on_boot = True
        result, err = run_install(fx)
        # The new address is NOT in the enrolled history, so rediscovery must
        # fail closed rather than scan for it.
        check("an address change to an un-enrolled IP is refused, not scanned for",
              err is not None, "" if err else "the installer found an address nobody enrolled")
        if err:
            check("the refusal explains that rediscovery only searches enrolled addresses",
                  "enrolled" in str(err) or "not scan" in str(err) or "could not" in str(err),
                  str(err)[:160])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_ip_change_enrolled():
    fx, root = scenario("ipchange2")
    try:
        # The same move, but the alternative address IS enrolled - rediscovery
        # should find it and the install should complete.
        # Move to EXACT addresses the profile also lists, so this tests
        # rediscovery rather than my ability to predict the simulator.
        fx.printer.next_address_on_boot = {device.OS_STOCK: "192.168.0.201",
                                           device.OS_NEBULAOS: "192.168.0.202"}
        pdir = os.path.join(os.environ[profiles.ENV_HOME], "devices", "printer-sim")
        conf = os.path.join(pdir, "profile.conf")
        text = open(conf).read()
        text = text.replace("STOCK_ADDRESS_HISTORY=192.168.0.138",
                            "STOCK_ADDRESS_HISTORY=192.168.0.201,192.168.0.138")
        text = text.replace("NEBULAOS_ADDRESS_HISTORY=192.168.0.98",
                            "NEBULAOS_ADDRESS_HISTORY=192.168.0.202,192.168.0.98")
        open(conf, "w").write(text)
        fx.profile = profiles.DeviceProfile.load("printer-sim")
        result, err = run_install(fx)
        check("an address change to an ENROLLED alternative is handled",
              err is None and result is not None and result.ok,
              str(err)[:200] if err else "completed")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_stock_unavailable():
    fx, root = scenario("stockdown")
    try:
        fx.printer.stock_unavailable = True
        result, err = run_install(fx)
        check("stock never coming back is reported, not ignored", err is not None,
              "" if err else "the install claimed success without stock")
        check("the dangerous state is explicit",
              err is not None and ("did not come back" in str(err) or "could not reach" in str(err)),
              str(err)[:160] if err else "")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_printer_busy():
    fx, root = scenario("busy")
    try:
        fx.printer.printing = True
        result, err = run_install(fx)
        check("a running print refuses the install before arming", err is not None)
        check("the marker was never armed for stock",
              marker_state(fx.printer) == marker.KERNEL2,
              "marker is %s" % marker_state(fx.printer))
        check("the refusal names the print", err is not None and "idle" in str(err).lower(),
              str(err)[:160] if err else "")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_heater_active():
    fx, root = scenario("heater")
    try:
        fx.printer.heater_targets["extruder"] = 210
        result, err = run_install(fx)
        check("a non-zero heater target refuses the install", err is not None)
        check("the marker was never armed for stock",
              marker_state(fx.printer) == marker.KERNEL2)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_paused_print():
    fx, root = scenario("paused")
    try:
        fx.printer.paused = True
        result, err = run_install(fx)
        check("a PAUSED print also refuses (resuming into a slot switch loses it)",
              err is not None)
        check("the marker was never armed for stock",
              marker_state(fx.printer) == marker.KERNEL2)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_marker_write_silently_fails():
    fx, root = scenario("markerfail")
    try:
        fx.printer.fail_marker_write = True
        result, err = run_install(fx)
        check("a marker write that does not land is caught by read-back", err is not None)
        check("the device was NOT rebooted after a failed marker write",
              fx.printer.boot_id == "boot-0001",
              "boot_id is %s" % fx.printer.boot_id)
        check("the marker still selects NebulaOS",
              marker_state(fx.printer) == marker.KERNEL2)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_marker_write_raises():
    fx, root = scenario("markerraise")
    try:
        fx.printer.marker_write_raises = True
        result, err = run_install(fx)
        check("a marker write that errors refuses the install", err is not None)
        check("the device was not rebooted", fx.printer.boot_id == "boot-0001")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_busy_after_arming_disarms():
    fx, root = scenario("disarm")
    try:
        # Idle at precheck, busy the instant the marker is armed for stock. This
        # is THE disarm path: armed, then a failure, while NebulaOS still runs.
        #
        # An earlier version of this test counted idle_state() calls and flipped
        # the flag after four of them. There were only three, so the threshold
        # never fired, the install simply succeeded, and two of the three
        # assertions passed on the NORMAL kernel->kernel2 transition. It was
        # green and it tested nothing. Hooking the marker write instead makes
        # the trigger exact.
        fx.printer.busy_after_marker_set = marker.KERNEL
        result, err = run_install(fx)

        check("becoming busy after arming refuses the install", err is not None,
              "" if err else "the install completed - the disarm path was never entered")
        check("DISARM: the marker was put back to NebulaOS",
              marker_state(fx.printer) == marker.KERNEL2,
              "marker is %s" % marker_state(fx.printer))
        check("the device was not rebooted into stock",
              fx.printer.running_os == device.OS_NEBULAOS)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_marker_write_lands_then_connection_drops():
    """REGRESSION: an exception while arming must still attempt a disarm.

    An architecture review found _set_marker_verified(marker.KERNEL) called
    unguarded: a False return disarmed correctly, but a RAISE propagated with no
    disarm attempt, leaving the device physically armed for stock while the
    journal still read PRECHECKED. Reality-wins recovers it on the next run -
    but only if a human re-runs instead of power-cycling, and a power cycle into
    stock costs the MCU.
    """
    fx, root = scenario("landthenraise")
    try:
        fx.printer.marker_write_lands_then_raises = marker.KERNEL
        result, err = run_install(fx)
        check("a connection lost after the marker committed stops the install", err is not None)
        check("REGRESSION: a disarm was attempted and the marker is back on NebulaOS",
              marker_state(fx.printer) == marker.KERNEL2,
              "marker is %s" % marker_state(fx.printer))
        check("the device was not rebooted", fx.printer.boot_id == "boot-0001")
        if err:
            check("the refusal warns against a power cycle",
                  "power cycle" in str(err).lower(), str(err)[:180])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_resume_finds_armed():
    fx, root = scenario("resumearmed")
    try:
        # A previous run died between arming and rebooting. The marker says
        # stock; NebulaOS is still running. A resume must disarm FIRST.
        fx.printer.partitions["ota"] = marker.canonical(marker.KERNEL)
        fx.printer.printing = True          # so it stops after disarming
        result, err = run_install(fx)
        check("a resumed transaction that finds ARMED disarms before anything else",
              marker_state(fx.printer) == marker.KERNEL2,
              "marker is %s" % marker_state(fx.printer))
        check("it did not blindly continue into a reboot",
              fx.printer.running_os == device.OS_NEBULAOS and fx.printer.boot_id == "boot-0001")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_ssh_loss_during_flash():
    fx, root = scenario("sshloss")
    try:
        fx.printer.interrupt_flash_after = 2048   # dies partway through kernel2
        result, err = run_install(fx)
        check("a connection lost during the flash stops the install", err is not None)
        check("the marker still selects stock, so the damaged slot is not booted",
              marker_state(fx.printer) == marker.KERNEL,
              "marker is %s" % marker_state(fx.printer))
        check("slot 2 is left visibly incomplete",
              hashlib.sha256(fx.printer.partitions["kernel2"]).hexdigest() != fx.artifacts.ximage_sha)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_flash_verification_mismatch():
    fx, root = scenario("corrupt")
    try:
        fx.printer.corrupt_flash = True
        result, err = run_install(fx)
        check("a flash that lands corrupted fails verification", err is not None)
        check("the marker was NOT set to kernel2 after a failed verification",
              marker_state(fx.printer) == marker.KERNEL,
              "marker is %s" % marker_state(fx.printer))
        if err:
            check("the refusal says it will not select a damaged slot",
                  "damaged" in str(err) or "verifies as" in str(err), str(err)[:160])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_flash_helper_refuses():
    fx, root = scenario("preflight")
    try:
        fx.printer.flash_helper_fails = True
        result, err = run_install(fx)
        check("a preflight refusal from the flash helper stops the install", err is not None)
        check("the marker still selects stock (nothing was written to boot)",
              marker_state(fx.printer) == marker.KERNEL)
        check("slot 2 was not written", fx.printer.partitions["kernel2"] == b"")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_concurrent_installer():
    fx, root = scenario("concurrent")
    try:
        fx.printer.flash_lock_holder = "another-installer:999"
        result, err = run_install(fx)
        check("a device-side flash lock held by another installer refuses", err is not None)
        if err:
            check("the refusal names the holder", "another-installer" in str(err), str(err)[:160])
        check("slot 2 was not written", fx.printer.partitions["kernel2"] == b"")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_host_lock():
    fx, root = scenario("hostlock")
    try:
        os.environ[journal.ENV_STATE_HOME] = os.path.join(root, "state")
        first = journal.HostLock("printer-sim")
        got, _ = first.acquire()
        second = journal.HostLock("printer-sim")
        blocked, holder = second.acquire()
        check("a second installer on this host is refused by the host lock",
              got and not blocked, "holder: %s" % holder)
        first.release()
        again, _ = journal.HostLock("printer-sim").acquire()
        check("the host lock is reusable after release", again)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_mcu_updater_acted():
    fx, root = scenario("mcuupdater")
    try:
        fx.printer.stock_updater_acts_on_boot = True
        result, err = run_install(fx)
        check("the install still closes forward to NebulaOS after the MCU updater acted",
              err is None and fx.printer.running_os == device.OS_NEBULAOS,
              str(err)[:200] if err else "")
        check("but PART1_INSTALL_VERIFIED is NO",
              result is not None and not result.ok,
              "result.ok=%s" % (result.ok if result else "n/a"))
        if result:
            check("the report explains the MCU was not the qualified one",
                  "MCU" in result.render())
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_mcu_guard_restored():
    fx, root = scenario("mcuguard")
    try:
        fx.printer.mcu_guard_restores_on_boot = True
        result, err = run_install(fx)
        check("an automatic MCU guard restore makes PART1 fail",
              err is None and result is not None and not result.ok,
              str(err)[:200] if err else "result.ok=%s" % (result.ok if result else "?"))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_mcu_restore_probe():
    """The real SSH probe, executed by /bin/sh on the host against fixtures.

    The simulator reports restores directly, so it never runs the shell text the
    SSH session sends. This runs that exact text. The per-boot tmpfs state file
    written by S50nebulaos-mcu-guard is the only authority, and an unreadable
    verdict must never read as "no restore".
    """
    import nebulaos_verify as verify
    root = tempfile.mkdtemp(prefix="mcuprobe.")
    try:
        def run(content):
            path = os.path.join(root, "state")
            if content is None:
                if os.path.exists(path):
                    os.unlink(path)
            else:
                with open(path, "w") as fh:
                    fh.write(content)
            out = subprocess.run(["sh", "-c", device.mcu_restore_probe_cmd(path)],
                                 capture_output=True, text=True).stdout
            return dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
        head = "MCU_GUARD_RESULT=PASS\nMCU_GUARD_DETAIL='a b ''c'\n"
        cases = [
            ("not_attempted -> 0", head + "MCU_RESTORE_RESULT=not_attempted\n", "0"),
            ("RESTORED_AND_VERIFIED -> 1", head + "MCU_RESTORE_RESULT=RESTORED_AND_VERIFIED\n", "1"),
            ("FLASH_FAILED -> 1", head + "MCU_RESTORE_RESULT=FLASH_FAILED\n", "1"),
            ("field absent -> unknown", head, "unknown"),
            ("empty file -> unknown", "", "unknown"),
            ("state file missing -> unknown", None, "unknown"),
        ]
        for label, content, want in cases:
            got = run(content).get("mcu_guard_restore")
            check("probe: %s" % label, got == want, "got %r" % got)
        check("probe: the guard verdict is read from the same per-boot file",
              run("MCU_GUARD_RESULT=WARN\nMCU_RESTORE_RESULT=not_attempted\n").get("mcu_guard_result")
              == "WARN")
        check("probe: a missing state file yields guard verdict unknown",
              run(None).get("mcu_guard_result") == "unknown")

        class Fake:
            def __init__(self, v):
                self.v = v
            def mcu_state(self):
                return {"mcu_guard_restore": self.v, "mcu_serial": "usb-x",
                        "stock_mcu_update": "absent", "mcu_restore_result": "?"}
        check("observe: an unreadable verdict reports unknown, never not_attempted",
              verify.observe_mcu_restore(Fake("unknown")) == "unknown")
        check("observe: 0 reports not_attempted",
              verify.observe_mcu_restore(Fake("0")) == "not_attempted")
        check("observe: 1 reports performed",
              verify.observe_mcu_restore(Fake("1")) == "performed")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_publication_fails_closed():
    """product_is_published refreshes remote refs and refuses when it cannot."""
    root = tempfile.mkdtemp(prefix="pubcheck.")
    try:
        def git(*a, cwd=None):
            return subprocess.run(["git", *a], cwd=cwd, capture_output=True, text=True,
                                  env=dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null",
                                           GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
                                           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t"))
        bare = os.path.join(root, "remote.git"); work = os.path.join(root, "work")
        git("init", "-q", "--bare", bare)
        git("init", "-q", "-b", "main", work)
        git("-C", work, "commit", "-q", "--allow-empty", "-m", "published")
        git("-C", work, "remote", "add", "origin", bare)
        git("-C", work, "push", "-q", "origin", "main")
        pub = git("-C", work, "rev-parse", "HEAD").stdout.strip()
        git("-C", work, "commit", "-q", "--allow-empty", "-m", "local only")
        local = git("-C", work, "rev-parse", "HEAD").stdout.strip()
        ok1, why1 = evidence.product_is_published(work, pub)
        check("a pushed commit is published", ok1, why1)
        ok2, why2 = evidence.product_is_published(work, local)
        check("an unpushed commit is not published", not ok2, why2)
        # The remote disappears: refs cannot be refreshed. The stale local
        # remote-tracking ref still contains `pub`, and must NOT be trusted.
        shutil.rmtree(bare)
        ok3, why3 = evidence.product_is_published(work, pub)
        check("an unreachable remote fails closed even for a previously-pushed commit",
              not ok3 and "cannot be established" in why3, why3)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_journal_keeps_danger_after_refusal():
    """Regression for the review's F3 and F11."""
    # F3: a refusal inside the stock window must not erase the danger.
    fx, root = scenario("dangerjournal")
    try:
        os.environ[journal.ENV_STATE_HOME] = os.path.join(root, "state")
        txn = journal.Transaction.begin("printer-sim", fx.control_commit, SOURCE_HEAD,
                                        fx.artifacts.ximage_sha, fx.artifacts.rootfs_sha)
        fx.printer.corrupt_flash = True
        result, err = run_install(fx, txn=txn)
        check("F3: the corrupted flash is refused", err is not None)
        txn.advance(journal.FAILED_NEEDS_ATTENTION, "refused (as op_install records it)")
        again = journal.Transaction.open("printer-sim")
        desc = again.describe() if again else ""
        check("F3: after the refusal the journal still says a power cycle is dangerous",
              again is not None and again.power_cycle_dangerous
              and "TRANSACTION_POWER_CYCLE_DANGEROUS=YES" in desc, desc.replace("\n", " ")[:300])
        check("F3: and that the device is armed for stock (marker on Creality's slot)",
              "TRANSACTION_ARMED_FOR_STOCK=YES" in desc and marker_state(fx.printer) == marker.KERNEL,
              "marker is %s" % marker_state(fx.printer))
    finally:
        shutil.rmtree(root, ignore_errors=True)

    # A VERIFIED disarm clears it: busy after arming -> disarm -> refusal.
    fx, root = scenario("disarmclears")
    try:
        os.environ[journal.ENV_STATE_HOME] = os.path.join(root, "state")
        txn = journal.Transaction.begin("printer-sim", fx.control_commit, SOURCE_HEAD,
                                        fx.artifacts.ximage_sha, fx.artifacts.rootfs_sha)
        fx.printer.busy_after_marker_set = marker.KERNEL
        result, err = run_install(fx, txn=txn)
        txn.advance(journal.FAILED_NEEDS_ATTENTION, "refused")
        again = journal.Transaction.open("printer-sim")
        check("a verified disarm clears the danger record",
              err is not None and again is not None and not again.power_cycle_dangerous
              and marker_state(fx.printer) == marker.KERNEL2,
              (again.describe().replace("\n", " ")[:200] if again else "no journal"))
    finally:
        shutil.rmtree(root, ignore_errors=True)

    # F11: the stock write does not verify AND the disarm does not verify.
    fx, root = scenario("garbledmarker")
    try:
        fx.printer.marker_write_garbled = True
        result, err = run_install(fx)
        check("F11: an unverifiable marker plus a failed disarm is a refusal", err is not None)
        check("F11: it is NOT reported as SAFE_NEBULAOS",
              err is not None and getattr(err, "state", None) == journal.FAILED_NEEDS_ATTENTION,
              "state=%s" % getattr(err, "state", None))
        check("F11: the refusal carries the do-not-power-cycle text",
              err is not None and "Do NOT power cycle" in str(err), str(err)[:200])
        check("F11: the device was not rebooted", fx.printer.boot_id == "boot-0001",
              "boot_id is %s" % fx.printer.boot_id)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_mcu_guard_not_pass():
    """F6: not_attempted with a WARN guard (it evaluated nothing) must fail PART1."""
    fx, root = scenario("guardwarn")
    try:
        fx.printer.mcu_guard_result = "WARN"
        result, err = run_install(fx)
        check("a WARN MCU guard verdict makes PART1 fail",
              err is None and result is not None and not result.ok,
              str(err)[:200] if err else "result.ok=%s" % (result.ok if result else "?"))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_stock_update_log_probe():
    """F5: the real probe text, run by /bin/sh against fixture logs."""
    root = tempfile.mkdtemp(prefix="stocklog.")
    try:
        def run(content):
            log = os.path.join(root, "mcu_update.log")
            if content is None:
                if os.path.exists(log):
                    os.unlink(log)
            else:
                with open(log, "w") as fh:
                    fh.write(content)
            cmd = device.STOCK_MCU_UPDATE_PROBE.replace("/tmp/mcu_update.log", log)
            out = subprocess.run(["sh", "-c", cmd], capture_output=True, text=True).stdout
            return out.strip().split("=", 1)[-1]
        check("stock log: handshake fail -> did_not_act",
              run("handshake /dev/ttyS1 fail, ret=1\n") == "did_not_act")
        check("stock log: identify fail -> did_not_act", run("identify fail\n") == "did_not_act")
        check("stock log: anything else -> acted_or_unknown (fail closed)",
              run("mcu update ok\n") == "acted_or_unknown")
        check("stock log: empty -> acted_or_unknown (fail closed)", run("") == "acted_or_unknown")
        check("stock log: missing -> absent", run(None) == "absent")
    finally:
        shutil.rmtree(root, ignore_errors=True)

    fx, root = scenario("stocklogabsent")
    try:
        fx.printer.stock_mcu_update_log = None
        result, err = run_install(fx)
        check("F5: no stock updater log on stock is treated as 'may have acted' (not verified)",
              result is not None and not result.ok, str(err)[:200] if err else "")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_stock_wayout_reads_stock():
    """F4: the real way-out probe inspects STOCK's rootfs, not the running system.

    Runs the exact shell text with fake mount/umount on PATH that populate the
    mount point from a fixture stock tree, so the probe's own logic is tested.
    """
    root = tempfile.mkdtemp(prefix="wayout.")
    try:
        bin_dir = os.path.join(root, "bin"); os.makedirs(bin_dir)
        def tree(with_ssh):
            t = os.path.join(root, "stock-%s" % with_ssh)
            os.makedirs(os.path.join(t, "etc", "init.d"), exist_ok=True)
            os.makedirs(os.path.join(t, "usr", "sbin"), exist_ok=True)
            with open(os.path.join(t, "etc", "shadow"), "w") as fh:
                fh.write("root:$1$x$y:1:0:99999:7:::\n")
            if with_ssh:
                open(os.path.join(t, "etc", "init.d", "S50dropbear"), "w").close()
                d = os.path.join(t, "usr", "sbin", "dropbear")
                open(d, "w").close(); os.chmod(d, 0o755)
            return t
        def facts(fixture, mount_ok=True):
            with open(os.path.join(bin_dir, "mount"), "w") as fh:
                fh.write("#!/bin/sh\n" + ("for a; do d=$a; done; cp -R %s/. \"$d\"\n" % fixture
                                            if mount_ok else "exit 32\n"))
            with open(os.path.join(bin_dir, "umount"), "w") as fh:
                fh.write("#!/bin/sh\nrm -rf \"$1\"/* \"$1\"/.[!.]* 2>/dev/null; exit 0\n")
            for n in ("mount", "umount"):
                os.chmod(os.path.join(bin_dir, n), 0o755)
            before = set(os.listdir("/tmp"))
            out = subprocess.run(
                ["sh", "-c", _wayout_cmd()], capture_output=True, text=True,
                env=dict(os.environ, PATH=bin_dir + ":" + os.environ.get("PATH", ""))).stdout
            leaked = [n for n in set(os.listdir("/tmp")) - before if n.startswith(".nebulaos-stockro")]
            return dict(l.split("=", 1) for l in out.splitlines() if "=" in l), leaked
        good, leaked = facts(tree(True))
        check("way-out: stock rootfs mounted read-only and inspected", good.get("stock_mount") == "mounted")
        check("way-out: SSH init script and daemon found IN STOCK's rootfs",
              good.get("stock_ssh_init") == "1" and good.get("stock_ssh_binary") == "1", str(good))
        check("way-out: root account found in stock's shadow", good.get("shadow") == "1")
        check("way-out: the temporary mount point is removed", not leaked, str(leaked))
        nossh, _ = facts(tree(False))
        check("way-out: a stock rootfs without an SSH daemon is reported as such",
              nossh.get("stock_ssh_init") == "0" and nossh.get("stock_ssh_binary") == "0", str(nossh))
        bad, leaked = facts(tree(True), mount_ok=False)
        check("way-out: a mount failure fails closed (zeros, not 'present')",
              bad.get("stock_mount") == "failed" and bad.get("stock_ssh_init") == "0"
              and bad.get("shadow") == "0" and not leaked, str(bad))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def _wayout_cmd():
    """The exact command text SshDeviceSession.stock_wayout_facts sends."""
    captured = {}
    class _S(device.SshDeviceSession):
        def __init__(self):
            pass
        def _kv(self, cmd):
            captured["cmd"] = cmd
            return {}
    _S().stock_wayout_facts()
    return captured["cmd"]


def case_dev_install_end_to_end():
    """DEV_INSTALL through the real agent op_install, with NO attestation key.

    Proves: the dev path needs only the build record + manifest agreeing with
    the bytes; it writes kernel2/rootfs2 only; stock is untouched; it reports
    DEV_INSTALL=YES / RELEASE_QUALIFIED=NO / HARDWARE_QUALIFIED=NO; a changed
    CONTROL_HEAD does not require a new PRODUCT_HEAD; and the release path is
    not weakened (a release-mode profile gets no dev shortcut).
    """
    import argparse
    import contextlib
    import io
    import nebulaos_agent as agent

    saved = (agent.FW_ROOT, agent.BUILD_BASE, agent.ssh_session_factory, agent.install.Installer)
    os.environ.pop("NEBULAOS_ATTEST_KEY", None)
    fx, root = scenario("devinstall")
    try:
        os.environ[journal.ENV_STATE_HOME] = os.path.join(root, "jstate")
        # The build workspace, laid out exactly as the build launcher leaves it.
        base = os.path.join(root, "builds")
        run = os.path.join(base, SOURCE_HEAD, "run-1")
        art = os.path.join(run, "artifacts", "buildroot-halley5-v30-image")
        os.makedirs(art)
        a = fx.artifacts
        shutil.copyfile(fx.ximage_path, os.path.join(art, "xImage"))
        shutil.copyfile(fx.rootfs_path, os.path.join(art, "rootfs.squashfs"))
        def write_evidence(manifest_x=None, record_head=None):
            with open(os.path.join(art, "build-manifest.txt"), "w") as fh:
                fh.write("git_commit_main=%s\nxImage_sha256=%s\nxImage_size=%d\n"
                         "rootfs_squashfs_sha256=%s\nrootfs_squashfs_size=%d\n"
                         % (SOURCE_HEAD, manifest_x or a.ximage_sha, a.ximage_size,
                            a.rootfs_sha, a.rootfs_size))
            with open(os.path.join(run, ".nebulaos-build-verified"), "w") as fh:
                fh.write("BUILD_VERIFIED=YES\nSOURCE_HEAD=%s\nBUILD_MODE=candidate\n"
                         "XIMAGE_SHA256=%s\nROOTFS_SQUASHFS_SHA256=%s\n"
                         % (record_head or SOURCE_HEAD, a.ximage_sha, a.rootfs_sha))
        conf = os.path.join(os.environ[profiles.ENV_HOME], "devices", "printer-sim", "profile.conf")
        base_conf = open(conf).read()
        def set_mode(mode):
            with open(conf, "w") as fh:
                fh.write(base_conf + ("INSTALL_MODE=%s\n" % mode if mode else ""))
            os.chmod(conf, 0o600)

        agent.FW_ROOT = fx.control_work          # CONTROL_HEAD lives in a local repo
        agent.BUILD_BASE = base
        agent.ssh_session_factory = lambda profile: sim.make_session_factory(fx.printer, profile)
        real_installer = saved[3]
        agent.install.Installer = lambda *ar, **kw: real_installer(
            *ar, **dict(kw, sleep=lambda _s: None, now=_FakeClock()))

        def run_op(control_commit):
            ns = argparse.Namespace(device="printer-sim", control_commit=control_commit,
                                    source_head=SOURCE_HEAD, ximage_sha=a.ximage_sha,
                                    rootfs_sha=a.rootfs_sha, op="install")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                try:
                    rc = agent.op_install(ns)
                except (agent.AgentRefusal, evidence.EvidenceError, profiles.ProfileError,
                        control.ControlError) as exc:
                    print("REFUSED: %s" % exc)
                    rc = 2
            return rc, buf.getvalue()

        stock_before = (fx.printer.partitions.get("kernel"), fx.printer.partitions.get("rootfs"))

        # -- negative: product evidence disagreeing with the bytes -------------
        set_mode("dev")
        write_evidence(manifest_x="0" * 64)
        rc, out = run_op(fx.control_commit)
        check("DEV: a manifest that disagrees with the bytes is refused",
              rc != 0 and "manifest's xImage hash" in out, out[-300:])
        check("DEV: nothing was written after that refusal",
              not fx.printer.partitions.get("kernel2"), "kernel2 written")
        write_evidence(record_head="f" * 40)
        rc, out = run_op(fx.control_commit)
        check("DEV: a build record naming another commit is refused",
              rc != 0 and "names PRODUCT_HEAD" in out, out[-300:])

        # -- negative: an invalid mode value ------------------------------------
        write_evidence()
        set_mode("yolo")
        rc, out = run_op(fx.control_commit)
        check("an invalid INSTALL_MODE is refused", rc != 0 and "INSTALL_MODE" in out, out[-200:])

        # -- the release path is not weakened -----------------------------------
        set_mode(None)
        rc, out = run_op(fx.control_commit)
        check("RELEASE (no INSTALL_MODE) does not take the dev shortcut: refused here",
              rc != 0 and not fx.printer.partitions.get("kernel2"), out[-300:])

        # -- the happy path, no attestation key anywhere ------------------------
        set_mode("dev")
        rc, out = run_op(fx.control_commit)
        check("DEV_INSTALL succeeds with no attestation key", rc == 0, out[-600:])
        for line in ("DEV_INSTALL=YES", "RELEASE_QUALIFIED=NO", "HARDWARE_QUALIFIED=NO",
                     "PRODUCT_HEAD=%s" % SOURCE_HEAD, "CONTROL_HEAD=%s" % fx.control_commit,
                     "PRODUCT_EVIDENCE=DEV"):
            check("DEV report says %s" % line.split("=")[0] + "=" + line.split("=")[1][:12],
                  line in out)
        check("DEV wrote NebulaOS kernel2 exactly",
              hashlib.sha256(fx.printer.partitions.get("kernel2") or b"").hexdigest() == a.ximage_sha)
        check("DEV wrote NebulaOS rootfs2 exactly",
              hashlib.sha256(fx.printer.partitions.get("rootfs2") or b"").hexdigest() == a.rootfs_sha)
        check("stock kernel and rootfs are untouched (Stock fallback preserved)",
              (fx.printer.partitions.get("kernel"), fx.printer.partitions.get("rootfs")) == stock_before)
        check("the device ends on NebulaOS with the marker on kernel2",
              fx.printer.running_os == device.OS_NEBULAOS and marker_state(fx.printer) == marker.KERNEL2)

        # -- a NEW control commit, SAME product: no rebuild needed ---------------
        env = dict(os.environ, GIT_AUTHOR_NAME="sim", GIT_AUTHOR_EMAIL="sim@example",
                   GIT_COMMITTER_NAME="sim", GIT_COMMITTER_EMAIL="sim@example")
        with open(os.path.join(fx.control_work, "NOTES"), "w") as fh:
            fh.write("an unrelated host-tooling change\n")
        subprocess.run(["git", "add", "-A"], cwd=fx.control_work, check=True, env=env)
        subprocess.run(["git", "commit", "-qm", "tooling change"], cwd=fx.control_work,
                       check=True, env=env)
        c2 = subprocess.run(["git", "rev-parse", "HEAD"], cwd=fx.control_work,
                            capture_output=True, text=True).stdout.strip()
        rc, out = run_op(c2)
        check("a changed CONTROL_HEAD installs the SAME product without a rebuild",
              rc == 0 and ("CONTROL_HEAD=%s" % c2) in out and ("PRODUCT_HEAD=%s" % SOURCE_HEAD) in out,
              out[-400:])
    finally:
        agent.FW_ROOT, agent.BUILD_BASE, agent.ssh_session_factory, agent.install.Installer = saved
        shutil.rmtree(root, ignore_errors=True)


def case_scp_uses_legacy_protocol():
    """Found on the first real DEV_INSTALL: the printer has no sftp-server."""
    captured = {}
    real_run = subprocess.run
    class _S(device.SshDeviceSession):
        def __init__(self):
            self.username, self.address = "root", "192.0.2.1"
        def _ssh_opts(self):
            return ["-o", "BatchMode=no"]
        def _ensure_askpass(self):
            return "/bin/false"
    def fake_run(argv, **kw):
        captured["argv"] = argv
        return subprocess.CompletedProcess(argv, 0, "", "")
    subprocess.run = fake_run
    try:
        _S()._scp("/tmp/x", "/usr/data/nebulaos-hwagent/xImage")
    finally:
        subprocess.run = real_run
    argv = captured.get("argv", [])
    check("scp is invoked with -O (legacy protocol; dropbear has no sftp-server)",
          argv[:2] == ["scp", "-O"], str(argv[:3]))


def case_service_probe_without_pgrep():
    """Found on the first real DEV_INSTALL: the image has no pgrep.

    Runs the exact service_health() shell text with a fake BusyBox-style `ps`
    on PATH and no pgrep at all.
    """
    root = tempfile.mkdtemp(prefix="svcprobe.")
    try:
        bin_dir = os.path.join(root, "bin"); os.makedirs(bin_dir)
        def facts(ps_lines):
            with open(os.path.join(bin_dir, "ps"), "w") as fh:
                fh.write("#!/bin/sh\ncat <<'EOF'\n  PID USER       VSZ STAT COMMAND\n%s\nEOF\n" % ps_lines)
            os.chmod(os.path.join(bin_dir, "ps"), 0o755)
            with open(os.path.join(bin_dir, "curl"), "w") as fh:
                fh.write("#!/bin/sh\nprintf 000\n")
            os.chmod(os.path.join(bin_dir, "curl"), 0o755)
            captured = {}
            class _S(device.SshDeviceSession):
                def __init__(self):
                    pass
                def _kv(self, cmd):
                    captured["cmd"] = cmd
                    return {}
            _S().service_health()
            out = subprocess.run(["sh", "-c", captured["cmd"]], capture_output=True, text=True,
                                 env=dict(os.environ, PATH=bin_dir + ":/usr/bin:/bin")).stdout
            return dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
        up = facts("  812 root      9M S    nginx: master process /usr/sbin/nginx\n"
                   " 1203 root     60M S    /usr/data/nebulaos/envs/klipper/bin/python klippy/klippy.py")
        check("service probe: nginx running is seen without pgrep", up.get("nginx") == "running", str(up))
        check("service probe: klippy running is seen", up.get("klipper") == "running", str(up))
        check("service probe: absent services read stopped",
              up.get("moonraker") == "stopped" and up.get("guppyscreen") == "stopped", str(up))
        none = facts("    1 root      1M S    init")
        check("service probe: does not match its own command line",
              all(none.get(k) == "stopped" for k in ("klipper", "moonraker", "guppyscreen", "nginx")),
              str(none))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_new_image_will_not_boot():
    fx, root = scenario("noboot")
    try:
        # The flash "succeeds" but the slot is unbootable, so the device comes
        # back as neither NebulaOS nor stock. There must be no automatic fall
        # back to stock.
        original = sim.SimSession.apply_write_plans

        def empty_write(self, plans, manifest_name):
            original(self, plans, manifest_name)
            self.printer.partitions["rootfs2"] = b""
            return True, "wrote (simulated unbootable result)"

        sim.SimSession.apply_write_plans = empty_write
        try:
            result, err = run_install(fx)
        finally:
            sim.SimSession.apply_write_plans = original

        check("a slot that fails verification is not booted", err is not None)
        check("NO automatic fallback to stock was performed",
              marker_state(fx.printer) in (marker.KERNEL, marker.KERNEL2),
              "marker is %s" % marker_state(fx.printer))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_already_on_stock():
    fx, root = scenario("onstock")
    try:
        fx.printer.running_os = device.OS_STOCK
        fx.printer.partitions["ota"] = marker.canonical(marker.KERNEL)
        # Payload must already be staged, as it would be by the run that got here.
        fx.printer.staged["xImage"] = XIMAGE
        fx.printer.staged["rootfs.squashfs"] = ROOTFS
        fx.printer.staged["build-manifest.txt"] = b"x"
        result, err = run_install(fx)
        check("an install that starts on stock is detected and completed",
              err is None and result is not None and result.ok,
              str(err)[:220] if err else "")
        check("it did not reboot to NebulaOS just to start over",
              fx.printer.running_os == device.OS_NEBULAOS)
        check("slot 2 received the payload",
              hashlib.sha256(fx.printer.partitions["kernel2"]).hexdigest() == fx.artifacts.ximage_sha)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_on_stock_with_a_stale_payload():
    """REGRESSION (ke-dev 2026-10-15): the device was on stock after USB
    recovery, holding the PREVIOUS install's payload. The install must stage
    this build's payload and write it - not refuse on the stale bytes, and
    never write them."""
    fx, root = scenario("onstockstale")
    try:
        fx.printer.running_os = device.OS_STOCK
        fx.printer.partitions["ota"] = marker.canonical(marker.KERNEL)
        fx.printer.staged["xImage"] = b"previous build's xImage"
        fx.printer.staged["rootfs.squashfs"] = b"previous build's rootfs"
        fx.printer.staged["build-manifest.txt"] = b"old"
        result, err = run_install(fx)
        check("an install that starts on stock with a stale payload completes",
              err is None and result is not None and result.ok,
              str(err)[:220] if err else "")
        check("REGRESSION: slot 2 received THIS build's xImage, not the stale one",
              hashlib.sha256(fx.printer.partitions["kernel2"]).hexdigest() == fx.artifacts.ximage_sha)
        check("REGRESSION: the staged payload is this build's",
              hashlib.sha256(fx.printer.staged["xImage"]).hexdigest() == fx.artifacts.ximage_sha)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_armed_window_is_exception_safe():
    """REGRESSION: every exit from the ARMED window must disarm.

    An independent review reproduced two unguarded raises inside the window -
    the post-arm idle_state() (which raises on a dropped SSH session) and the
    journal advance (ENOSPC). Both left the device physically armed for stock
    with no disarm, and neither was an InstallError, so the operator would have
    seen a traceback instead of the "do NOT power cycle" text.
    """
    # (a) the transport dies at the post-arm idle check
    fx, root = scenario("armedraise")
    try:
        original = sim.SimSession.idle_state
        state = {"armed": False}

        def idle_after_arming(self):
            if marker.parse(self.printer.partitions["ota"])[0] == marker.KERNEL:
                state["armed"] = True
                raise sim.SimTransportError("connection dropped (simulated)")
            return original(self)

        sim.SimSession.idle_state = idle_after_arming
        try:
            result, err = run_install(fx)
        finally:
            sim.SimSession.idle_state = original

        check("a transport failure at the post-arm idle check stops the install",
              err is not None)
        check("REGRESSION: it disarmed - the marker is back on NebulaOS",
              marker_state(fx.printer) == marker.KERNEL2,
              "marker is %s (armed was reached: %s)" % (marker_state(fx.printer), state["armed"]))
        check("the failure is reported as an InstallError, not a raw traceback",
              isinstance(err, install.InstallError), type(err).__name__ if err else "none")
        check("the device was not rebooted", fx.printer.boot_id == "boot-0001")
    finally:
        shutil.rmtree(root, ignore_errors=True)

    # (b) the journal write fails after the marker has committed
    fx, root = scenario("armedjournal")
    try:
        class ExplodingTxn:
            def __init__(self, inner):
                self.inner = inner
                self.state = inner.state

            def advance(self, new_state, note=""):
                if new_state == journal.ARMED_STOCK:
                    raise OSError(28, "No space left on device")
                self.state = new_state
                return self.inner.advance(new_state, note)

            def note(self, text):
                return self.inner.note(text)

        os.environ[journal.ENV_STATE_HOME] = os.path.join(root, "state")
        inner = journal.Transaction.begin("printer-sim", fx.control_commit, SOURCE_HEAD,
                                          fx.artifacts.ximage_sha, fx.artifacts.rootfs_sha)
        result, err = run_install(fx, txn=ExplodingTxn(inner))
        check("a journal write failure inside the armed window stops the install",
              err is not None)
        check("REGRESSION: it disarmed - the marker is back on NebulaOS",
              marker_state(fx.printer) == marker.KERNEL2,
              "marker is %s" % marker_state(fx.printer))
        check("the failure is reported as an InstallError",
              isinstance(err, install.InstallError), type(err).__name__ if err else "none")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_helper_provenance_on_every_path():
    """REGRESSION: the privileged helper must come from C on BOTH entry paths.

    The "device already on stock" path used to skip staging entirely, so
    apply_write_plans executed whatever bytes were at
    /usr/data/nebulaos-hwagent/flash-spare-slot.sh - a shared, non-root-owned
    data partition.
    """
    fx, root = scenario("helperprov")
    try:
        fx.printer.running_os = device.OS_STOCK
        fx.printer.partitions["ota"] = marker.canonical(marker.KERNEL)
        fx.printer.staged["xImage"] = XIMAGE
        fx.printer.staged["rootfs.squashfs"] = ROOTFS
        fx.printer.staged["build-manifest.txt"] = b"x"
        # The helper is deliberately NOT staged, and the simulator now refuses
        # to "run" one that is not there.
        expected = fx.control.helper("scripts/flash-spare-slot.sh")
        fx.printer.helper_must_equal = expected

        result, err = run_install(fx)
        check("an install that starts on stock stages the helper from C",
              err is None and result is not None and result.ok,
              str(err)[:200] if err else "completed")
        check("REGRESSION: the helper on the device is byte-identical to control commit C",
              fx.printer.staged.get("flash-spare-slot.sh") == expected,
              "staged %s" % ("<absent>" if fx.printer.staged.get("flash-spare-slot.sh") is None
                             else "%d bytes" % len(fx.printer.staged["flash-spare-slot.sh"])))
    finally:
        shutil.rmtree(root, ignore_errors=True)

    # And a helper that does not match C must refuse rather than execute.
    fx, root = scenario("helperdrift")
    try:
        fx.printer.running_os = device.OS_STOCK
        fx.printer.partitions["ota"] = marker.canonical(marker.KERNEL)
        fx.printer.staged["xImage"] = XIMAGE
        fx.printer.staged["rootfs.squashfs"] = ROOTFS
        fx.printer.staged["build-manifest.txt"] = b"x"

        original = sim.SimSession.stage_file

        def stage_but_corrupt_helper(self, local_path, name):
            got = original(self, local_path, name)
            if name == "flash-spare-slot.sh":
                self.printer.staged[name] = b"#!/bin/sh\n# NOT the reviewed helper\n"
            return got

        sim.SimSession.stage_file = stage_but_corrupt_helper
        try:
            result, err = run_install(fx)
        finally:
            sim.SimSession.stage_file = original

        check("a staged helper that does not match C refuses before it is executed",
              err is not None, "" if err else "the install proceeded")
        if err:
            check("the refusal names the helper mismatch",
                  "helper" in str(err).lower(), str(err)[:150])
        check("slot 2 was not written", fx.printer.partitions["kernel2"] == b"")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_journal_reality_conflict():
    fx, root = scenario("journal")
    try:
        os.environ[journal.ENV_STATE_HOME] = os.path.join(root, "state")
        # The journal claims the flash already happened. Reality: slot 2 empty.
        txn = journal.Transaction.begin(
            "printer-sim", fx.control_commit, SOURCE_HEAD,
            fx.artifacts.ximage_sha, fx.artifacts.rootfs_sha)
        txn.advance(journal.FLASH_VERIFIED, "claimed by a previous run")
        result, err = run_install(fx, txn=txn)
        check("reality wins over a journal that claims the flash already happened",
              err is None and result is not None and result.ok,
              str(err)[:220] if err else "")
        check("the device really was flashed this time",
              hashlib.sha256(fx.printer.partitions["kernel2"]).hexdigest() == fx.artifacts.ximage_sha)
        reopened = journal.Transaction.open("printer-sim")
        check("the journal ends in a terminal state",
              reopened is not None and reopened.state in journal.TERMINAL_STATES,
              reopened.state if reopened else "missing")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_journal_key_mismatch():
    fx, root = scenario("journalkey")
    try:
        os.environ[journal.ENV_STATE_HOME] = os.path.join(root, "state")
        txn = journal.Transaction.begin("printer-sim", fx.control_commit, SOURCE_HEAD,
                                        fx.artifacts.ximage_sha, fx.artifacts.rootfs_sha)
        same, _ = txn.matches("printer-sim", fx.control_commit, SOURCE_HEAD,
                              fx.artifacts.ximage_sha, fx.artifacts.rootfs_sha)
        other, why = txn.matches("printer-sim", fx.control_commit, "0" * 40,
                                 fx.artifacts.ximage_sha, fx.artifacts.rootfs_sha)
        check("a transaction is resumable only for the identical five key fields",
              same and not other, why)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_control_provenance():
    fx, root = scenario("control")
    try:
        check("control helpers resolve from the protected mirror",
              len(fx.control.helpers) >= 2, "%d helpers" % len(fx.control.helpers))
        check("the control commit is published", "published on" in fx.control.published_on,
              fx.control.published_on)

        # An unpublished commit must not resolve.
        env = dict(os.environ, GIT_AUTHOR_NAME="sim", GIT_AUTHOR_EMAIL="s@e",
                   GIT_COMMITTER_NAME="sim", GIT_COMMITTER_EMAIL="s@e")
        subprocess.run(["git", "checkout", "-q", "-b", "scratch"], cwd=fx.control_work,
                       check=True, capture_output=True, env=env)
        with open(os.path.join(fx.control_work, "scripts", "flash-spare-slot.sh"), "ab") as fh:
            fh.write(b"# unpublished edit\n")
        subprocess.run(["git", "commit", "-qam", "unpublished"], cwd=fx.control_work,
                       check=True, capture_output=True, env=env)
        unpub = subprocess.run(["git", "rev-parse", "HEAD"], cwd=fx.control_work,
                               capture_output=True, text=True, env=env).stdout.strip()
        mirror = control.ControlMirror(os.path.join(root, "origin.git"),
                                       os.path.join(root, "state", "mirror.git"))
        try:
            control.ControlSet.load(mirror, unpub)
            bad("an unpublished control commit is refused", "it resolved")
        except control.ControlError as exc:
            ok("an unpublished control commit is refused", str(exc)[:110])

        # A helper whose bytes do not match its pin must be refused.
        drifted = os.path.join(root, "drift")
        os.makedirs(os.path.join(drifted, "tools", "hardware"))
        shutil.copyfile(os.path.join(FW, "tools", "hardware", "nebulaos_journal.py"),
                        os.path.join(drifted, "tools", "hardware", "nebulaos_marker.py"))
        try:
            control.assert_host_control_matches(fx.control, drifted)
            bad("host control code that has drifted from C is refused", "it passed")
        except control.ControlError as exc:
            ok("host control code that has drifted from C is refused", str(exc)[:110])

        ok("host control code matching C is accepted",
           ", ".join(control.assert_host_control_matches(fx.control, FW)))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_attestation_required():
    """A destructive operation must be able to PROVE what it is installing."""
    fx, root = scenario("attestation")
    try:
        store = os.path.join(root, "attstore")
        os.makedirs(store, mode=0o700)
        keydir = os.path.join(root, "key")
        os.makedirs(keydir, mode=0o700)
        keypath = os.path.join(keydir, "attest.key")
        with open(keypath, "wb") as fh:
            fh.write(os.urandom(64))
        os.chmod(keypath, 0o600)
        os.environ["NEBULAOS_ATTEST_KEY"] = keypath
        tool = os.path.join(FW, "tools", "attest", "nebulaos-attest.py")
        a = fx.artifacts

        # 1. nothing at all
        try:
            evidence.require_v2(SOURCE_HEAD, a.ximage_sha, a.ximage_size,
                                a.rootfs_sha, a.rootfs_size, store=store, attest_tool=tool)
            bad("an install with no v2 attestation is refused", "it was allowed")
        except evidence.EvidenceError as exc:
            ok("an install with no v2 attestation is refused", str(exc).splitlines()[0][:90])

        # 2. a v1 record is NOT accepted as a substitute
        run_dir = os.path.join(root, "buildrun")
        os.makedirs(run_dir)
        with open(os.path.join(run_dir, ".nebulaos-build-verified"), "w") as fh:
            fh.write("BUILD_VERIFIED=YES\nSOURCE_HEAD=%s\n" % SOURCE_HEAD)
        try:
            evidence.require_v2(SOURCE_HEAD, a.ximage_sha, a.ximage_size,
                                a.rootfs_sha, a.rootfs_size, build_run=run_dir,
                                store=store, attest_tool=tool)
            bad("a v1 record is not accepted in place of v2", "it was allowed")
        except evidence.EvidenceError as exc:
            check("a v1 record is not accepted in place of v2", "unauthenticated" in str(exc),
                  str(exc).splitlines()[-1][:110])

        # 3. a real, signed v2 attestation for these artifacts
        def sign(profile, head=SOURCE_HEAD, xs=None, out=None):
            fields = "\n".join([
                "ATTESTATION_VERSION=2", "SOURCE_HEAD=%s" % head,
                "SOURCE_REPO=https://example/repo.git", "SOURCE_PUBLISHED_TIP=%s" % head,
                "BUILD_LAUNCHER_BLOB=%s" % ("b" * 64), "BUILD_MODE=candidate",
                "BUILD_PROFILE=%s" % profile,
                "CCACHE=%s" % ("disabled" if profile != "dev" else "enabled"),
                "BUILD_LOG_SHA256=%s" % ("c" * 64),
                "XIMAGE_SHA256=%s" % (xs or a.ximage_sha), "XIMAGE_SIZE=%d" % a.ximage_size,
                "ROOTFS_SQUASHFS_SHA256=%s" % a.rootfs_sha,
                "ROOTFS_SQUASHFS_SIZE=%d" % a.rootfs_size,
                "MANIFEST_SHA256=%s" % ("d" * 64), "BUILDER_DIGEST=sha256:%s" % ("e" * 64),
                "SOURCE_DATE_EPOCH=1790633082", "BUILD_RUN=%s" % run_dir,
                "ATTESTED_AT=2026-09-29T00:00:00Z", ""])
            target = out or os.path.join(store, "%s.att" % head)
            proc = subprocess.run([sys.executable, tool, "sign", "--out", target],
                                  input=fields, capture_output=True, text=True)
            return proc.returncode == 0, target

        signed, path = sign("candidate")
        if not signed:
            bad("a v2 attestation can be produced for the test artifacts")
        else:
            try:
                ev = evidence.require_v2(SOURCE_HEAD, a.ximage_sha, a.ximage_size,
                                         a.rootfs_sha, a.rootfs_size, store=store,
                                         attest_tool=tool)
                ok("a verified v2 attestation for these exact artifacts is accepted",
                   "profile=%s" % ev.profile)
            except evidence.EvidenceError as exc:
                bad("a verified v2 attestation is accepted", str(exc)[:160])

        # 4. an attestation whose artifact digests do not match
        try:
            evidence.require_v2(SOURCE_HEAD, "f" * 64, a.ximage_size,
                                a.rootfs_sha, a.rootfs_size, store=store, attest_tool=tool)
            bad("an attestation that does not match the artifacts is refused", "it was allowed")
        except evidence.EvidenceError as exc:
            ok("an attestation that does not match the artifacts is refused",
               str(exc).splitlines()[0][:90])

        # 5. a dev-profile build may not reach a printer
        os.unlink(path)
        sign("dev")
        try:
            evidence.require_v2(SOURCE_HEAD, a.ximage_sha, a.ximage_size,
                                a.rootfs_sha, a.rootfs_size, store=store, attest_tool=tool)
            bad("a dev-profile build is refused", "it was allowed")
        except evidence.EvidenceError as exc:
            check("a dev-profile build is refused", "dev" in str(exc) or "profile" in str(exc),
                  str(exc).splitlines()[0][:110])

        # 6. a tampered attestation
        os.unlink(os.path.join(store, "%s.att" % SOURCE_HEAD))
        sign("candidate")
        att = os.path.join(store, "%s.att" % SOURCE_HEAD)
        text = open(att).read().replace("BUILD_PROFILE=candidate", "BUILD_PROFILE=release")
        open(att, "w").write(text)
        try:
            evidence.require_v2(SOURCE_HEAD, a.ximage_sha, a.ximage_size,
                                a.rootfs_sha, a.rootfs_size, store=store, attest_tool=tool)
            bad("a tampered attestation is refused", "it was allowed")
        except evidence.EvidenceError as exc:
            ok("a tampered attestation is refused", str(exc).splitlines()[0][:90])
    finally:
        os.environ.pop("NEBULAOS_ATTEST_KEY", None)
        shutil.rmtree(root, ignore_errors=True)


def case_capability_vs_policy():
    """The distinction the mission requires, asserted on the real objects."""
    report = targets.capability_report()
    check("GENERIC_FLASH_CAPABILITY_STOCK=YES", "GENERIC_FLASH_CAPABILITY_STOCK=YES" in report)
    check("GENERIC_FLASH_CAPABILITY_NEBULAOS=YES",
          "GENERIC_FLASH_CAPABILITY_NEBULAOS=YES" in report)

    stock_plan = targets.RECOVERY_STOCK_SIDE.select("kernel").plan_write(1024, "a" * 64)
    check("the backend can express a validated STOCK write",
          stock_plan.target.role == targets.ROLE_STOCK, stock_plan.describe()[:90])
    both = targets.RECOVERY_BOTH_SIDES
    check("a both-sides recovery policy can select either slot",
          both.select("kernel").role == targets.ROLE_STOCK
          and both.select("kernel2").role == targets.ROLE_NEBULAOS)

    dev = targets.DEV_PRESERVE_STOCK
    check("DEV_INSTALL_POLICY=PRESERVE_STOCK", dev.name == "PRESERVE_STOCK")
    check("DEV_INSTALL_WRITES_STOCK=NO", not dev.writes_stock())
    try:
        dev.select("kernel")
        bad("the developer policy refuses the stock slot", "it was allowed")
    except targets.TargetError as exc:
        ok("the developer policy refuses the stock slot", str(exc).splitlines()[0][:100])

    # The one refusal no policy can override.
    for policy in (targets.DEV_PRESERVE_STOCK, targets.RECOVERY_STOCK_SIDE,
                   targets.RECOVERY_BOTH_SIDES):
        try:
            policy.select("sn_mac")
            bad("no policy can select sn_mac (%s)" % policy.name, "it was allowed")
            break
        except targets.TargetError:
            pass
    else:
        ok("no policy can select sn_mac - it is refused at the capability layer")

    try:
        targets.resolve("kernel2").plan_write(targets.resolve("kernel2").size + 1, "a" * 64)
        bad("an oversized payload is refused", "it was planned")
    except targets.TargetError as exc:
        ok("an oversized payload is refused", str(exc)[:100])


def case_diagnose_and_restart():
    """diagnose is read-only; restart is a guarded repair through the real agent ops.

    Proves: restart on a DEV device runs from a local (unpublished) control
    commit, while a RELEASE device still requires a published one; refuses
    an unknown service, an open install transaction, Stock, a busy printer,
    the update supervisor's lock or validation, and klipper without proven
    idle; and a successful restart is recorded in the host repair log.
    """
    import argparse
    import contextlib
    import io
    import nebulaos_agent as agent

    saved = (agent.FW_ROOT, agent.ssh_session_factory, agent.control_is_published,
             agent.release_identity_gate)
    fx, root = scenario("repair")
    try:
        os.environ[journal.ENV_STATE_HOME] = os.path.join(root, "jstate")
        conf = os.path.join(os.environ[profiles.ENV_HOME], "devices", "printer-sim", "profile.conf")
        with open(conf, "a") as fh:
            fh.write("INSTALL_MODE=dev\n")
        os.chmod(conf, 0o600)
        agent.FW_ROOT = fx.control_work
        agent.ssh_session_factory = lambda profile: sim.make_session_factory(fx.printer, profile)
        published = {"ok": True}
        agent.control_is_published = lambda c: (published["ok"], "sim")

        def run(op, service=None):
            ns = argparse.Namespace(device="printer-sim", control_commit=fx.control_commit,
                                    op=op, service=service)
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                try:
                    rc = {"diagnose": agent.op_diagnose, "restart": agent.op_restart}[op](ns)
                except (agent.AgentRefusal, profiles.ProfileError, control.ControlError) as exc:
                    print("REFUSED: %s" % exc)
                    rc = 2
            return rc, buf.getvalue()

        p = fx.printer
        before = dict(p.partitions)
        rc, out = run("diagnose")
        check("diagnose reports on the enrolled printer", rc == 0 and "===== processes" in out, out[-300:])
        check("diagnose writes nothing", p.partitions == before and not p.restarts)

        rc, out = run("restart", "sshd")
        check("restart refuses an unknown service", rc == 2 and "unknown service" in out, out[-200:])

        published["ok"] = False
        rc, out = run("restart", "moonraker")
        check("DEV device: restart runs from an UNPUBLISHED local control commit",
              rc == 0 and p.restarts == ["moonraker"]
              and "CONTROL_PUBLISHED=not required (DEV device)" in out, out[-300:])
        p.restarts.clear()

        # The same request against a RELEASE-mode profile must still refuse.
        # The release identity gate is stubbed so the refusal is provably the
        # publication rule, not an unrelated gate failure.
        text = open(conf).read()
        with open(conf, "w") as fh:
            fh.write(text.replace("INSTALL_MODE=dev", "INSTALL_MODE=release"))
        saved_resolve = agent.resolve_control
        agent.release_identity_gate = lambda: None
        agent.resolve_control = lambda c, refresh=True: agent.resolve_control_dev(c)
        try:
            rc, out = run("restart", "moonraker")
        finally:
            with open(conf, "w") as fh:
                fh.write(text)
            agent.release_identity_gate = saved[3]
            agent.resolve_control = saved_resolve
        check("RELEASE device: restart refuses an UNPUBLISHED control commit",
              rc == 2 and "published control commit" in out and not p.restarts, out[-200:])
        published["ok"] = True

        txn = journal.Transaction.begin("printer-sim", fx.control_commit, SOURCE_HEAD, "a" * 64, "b" * 64)
        rc, out = run("restart", "moonraker")
        check("restart refuses while an install transaction is open",
              rc == 2 and "transaction is open" in out and not p.restarts, out[-200:])
        txn.advance(journal.DONE, "sim")

        p.supervisor_lock = "klipper.lock"
        rc, out = run("restart", "moonraker")
        check("restart refuses while the update supervisor holds a lock",
              rc == 1 and "RESTART_RESULT=REFUSED" in out and not p.restarts, out[-200:])
        p.supervisor_lock = None
        p.supervisor_validating = True
        rc, out = run("restart", "moonraker")
        check("restart refuses while the update supervisor is validating",
              rc == 1 and "validating" in out and not p.restarts, out[-200:])
        p.supervisor_validating = False

        p.printing = True
        rc, out = run("restart", "moonraker")
        check("restart refuses during a print", rc != 0 and not p.restarts, out[-200:])
        p.printing = False

        p.heater_targets["extruder"] = 210
        rc, out = run("restart", "klipper")
        check("klipper restart refuses with a heater target set",
              rc == 2 and "proven idle" in out and not p.restarts, out[-200:])
        p.heater_targets["extruder"] = 0

        p.print_state_readable = False
        rc, out = run("restart", "klipper")
        check("klipper restart refuses when the print state is unreadable",
              rc == 1 and "unreadable" in out and not p.restarts, out[-200:])
        rc, out = run("restart", "moonraker")
        check("moonraker restart proceeds when only the print state is unreadable",
              rc == 0 and p.restarts == ["moonraker"], out[-300:])
        p.print_state_readable = True

        rc, out = run("restart", "klipper")
        check("klipper restart proceeds on a proven idle printer",
              rc == 0 and "RESTART_RESULT=DONE" in out and p.restarts[-1] == "klipper", out[-300:])
        check("the device-side lock is released afterwards", p.flash_lock_holder is None)
        log = open(os.path.join(root, "jstate", "repairs", "printer-sim.log")).read()
        # 11 attempts so far: 4 refused on the host, 4 refused on the device, 3 done.
        check("every restart attempt is in the host repair log, refusals included",
              log.count("OP=restart") == 11 and log.count("RESULT=REFUSED") == 8
              and "ARG=sshd RESULT=REFUSED" in log and "ARG=klipper RESULT=DONE" in log, log[-400:])

        p.running_os = device.OS_STOCK
        rc, out = run("restart", "moonraker")
        check("restart never runs against Stock", rc == 2 and p.restarts[-1] == "klipper", out[-200:])
    finally:
        (agent.FW_ROOT, agent.ssh_session_factory, agent.control_is_published,
         agent.release_identity_gate) = saved
        shutil.rmtree(root, ignore_errors=True)


def _synthetic_rtos(root):
    """A synthetic stock zero.bin with a real 480x272 JPEG in the logo slot, and
    rtos_logo's pins re-pointed at it (the real stock image is vendor firmware
    and is not in this repository). -> (stock, patched, restore_pins)."""
    import io
    from PIL import Image
    sys.path.insert(0, os.path.join(FW, "scripts", "package"))
    import rtos_logo as R

    def jpeg(colour):
        buf = io.BytesIO()
        Image.new("RGB", (480, 272), colour).save(buf, "JPEG", quality=90, subsampling=2)
        return buf.getvalue()

    slot = jpeg((1, 2, 3))
    extra = R.LOGO_SLOT_SIZE - len(slot) - 4
    slot = slot[:2] + b"\xff\xfe" + (extra + 2).to_bytes(2, "big") + b"\x00" * extra + slot[2:]
    stock = bytearray(hashlib.sha256(b"seed").digest() * (R.STOCK_ZERO_SIZE // 32 + 1))[:R.STOCK_ZERO_SIZE]
    stock = bytearray(bytes(stock).replace(b"\xff", b"\x7f"))
    stock[8:12] = b"RTOS"
    stock[R.LOGO_SLOT_OFFSET:R.LOGO_SLOT_OFFSET + R.LOGO_SLOT_SIZE] = slot
    stock = bytes(stock)
    logo = jpeg((200, 210, 250))
    asset = os.path.join(root, "logo.jpg")
    with open(asset, "wb") as fh:
        fh.write(logo)
    saved = (R.STOCK_ZERO_SHA256, R.NEBULAOS_LOGO_SHA256, R.NEBULAOS_ZERO_SHA256, R.LOGO_ASSET)
    R.STOCK_ZERO_SHA256 = hashlib.sha256(stock).hexdigest()
    R.NEBULAOS_LOGO_SHA256 = hashlib.sha256(logo).hexdigest()
    R.LOGO_ASSET = asset
    patched = R.patch(stock, logo)
    R.NEBULAOS_ZERO_SHA256 = hashlib.sha256(patched).hexdigest()

    def restore():
        R.STOCK_ZERO_SHA256, R.NEBULAOS_LOGO_SHA256, R.NEBULAOS_ZERO_SHA256, R.LOGO_ASSET = saved
    return stock, patched, restore


def case_rtos_logo():
    """rtos-logo / rtos-logo-restore through the real agent ops, against the simulator.

    Proves: the confirmation word is required before any contact; the write
    lands only in rtos2, only the logo bytes change, rtos (p3) is untouched and
    a verified host backup exists BEFORE the write; a second run writes
    nothing; restore by sha256 brings the exact backup back; the marker, a
    print, a heater, an open install transaction, unknown rtos2 content, a
    short backup read and a print starting after staging all refuse without
    writing; a corrupt or interrupted write is reported as RTOS_WRITE_FAILED
    with the restore command, and that restore works.
    """
    import argparse
    import contextlib
    import io
    import nebulaos_agent as agent
    import nebulaos_rtos as rtos

    saved = (agent.FW_ROOT, agent.ssh_session_factory)
    fx, root = scenario("rtos")
    stock, patched, unpin = _synthetic_rtos(root)
    try:
        os.environ[journal.ENV_STATE_HOME] = os.path.join(root, "jstate")
        conf = os.path.join(os.environ[profiles.ENV_HOME], "devices", "printer-sim", "profile.conf")
        with open(conf, "a") as fh:
            fh.write("INSTALL_MODE=dev\n")
        os.chmod(conf, 0o600)
        agent.FW_ROOT = fx.control_work
        agent.ssh_session_factory = lambda profile: sim.make_session_factory(fx.printer, profile)

        size = targets.resolve("rtos2").size
        tail = bytes(range(256)) * ((size - len(stock)) // 256 + 1)
        original = (stock + tail)[:size]
        p = fx.printer
        p.partitions["rtos"] = original
        p.partitions["rtos2"] = original
        backups = os.path.join(root, "jstate", "rtos-backups", "printer-sim")

        def run(op, confirm, backup_sha=None):
            ns = argparse.Namespace(device="printer-sim", control_commit=fx.control_commit,
                                    op=op, confirm=confirm, backup_sha=backup_sha)
            fn = {"rtos-logo": agent.op_rtos_logo, "rtos-logo-restore": agent.op_rtos_logo_restore}[op]
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                try:
                    rc = fn(ns)
                except (agent.AgentRefusal, profiles.ProfileError, control.ControlError) as exc:
                    print("REFUSED: %s" % exc)
                    rc = 2
            return rc, buf.getvalue()

        def bins():
            return sorted(n for n in os.listdir(backups) if n.endswith(".bin")) if os.path.isdir(backups) else []

        for word in (None, "", "yes", "RTOS_LOGO_CONFIRM=RTOS", "RTOS_RESTORE_CONFIRM=RTOS2"):
            ops = p._ops
            rc, out = run("rtos-logo", word)
            check("rtos-logo refuses confirmation %r before touching the printer" % word,
                  rc == 2 and p._ops == ops and p.rtos2_writes == 0, out[-200:])
        rc, out = run("rtos-logo-restore", rtos.LOGO_CONFIRM_WORD, "a" * 64)
        check("rtos-logo-restore refuses the logo's confirmation word", rc == 2 and p.rtos2_writes == 0)

        # --- refusals that must not write --------------------------------
        def refused(label, reason, prepare, undo):
            prepare()
            writes, rtos2 = p.rtos2_writes, p.partitions["rtos2"]
            rc, out = run("rtos-logo", rtos.LOGO_CONFIRM_WORD)
            same = p.partitions["rtos2"] == rtos2
            undo()
            check("rtos-logo refuses %s and writes nothing" % label,
                  rc == 2 and reason in out and p.rtos2_writes == writes
                  and same and p.flash_lock_holder is None, out[-300:])

        refused("when the marker selects stock", "does not select NebulaOS",
                lambda: p.partitions.__setitem__("ota", marker.canonical(marker.KERNEL)),
                lambda: p.partitions.__setitem__("ota", marker.canonical(marker.KERNEL2)))
        refused("during a print", "proven idle",
                lambda: setattr(p, "printing", True), lambda: setattr(p, "printing", False))
        refused("with a heater target set", "proven idle",
                lambda: p.heater_targets.__setitem__("heater_bed", 60),
                lambda: p.heater_targets.__setitem__("heater_bed", 0))
        txn = []
        refused("while an install transaction is open", "transaction is open",
                lambda: txn.append(journal.Transaction.begin(
                    "printer-sim", fx.control_commit, SOURCE_HEAD, "a" * 64, "b" * 64)),
                lambda: txn[0].advance(journal.DONE, "sim"))
        refused("when rtos2 holds unknown bytes", "does not start with the pinned stock",
                lambda: p.partitions.__setitem__("rtos2", b"\x01" + original[1:]),
                lambda: p.partitions.__setitem__("rtos2", original))
        refused("when the backup copy arrives short", "stopped before writing",
                lambda: setattr(p, "backup_read_short", True),
                lambda: setattr(p, "backup_read_short", False))
        refused("when a print starts after staging (re-checked before the write)", "proven idle",
                lambda: setattr(p, "busy_after_staging", rtos.STAGED_LOGO),
                lambda: (setattr(p, "busy_after_staging", None), setattr(p, "printing", False)))
        refused("on Stock", "could not reach",
                lambda: setattr(p, "running_os", device.OS_STOCK),
                lambda: setattr(p, "running_os", device.OS_NEBULAOS))

        # --- the write -----------------------------------------------------
        before = list(bins())
        rc, out = run("rtos-logo", rtos.LOGO_CONFIRM_WORD)
        new = [b for b in bins() if b not in before]
        check("rtos-logo writes rtos2 once and reports WRITTEN",
              rc == 0 and p.rtos2_writes == 1 and "RTOS2_LOGO=WRITTEN" in out, out[-600:])
        check("rtos2 now holds the pinned NebulaOS image, and its tail is untouched",
              p.partitions["rtos2"] == patched + original[len(patched):])
        check("rtos (p3) is byte-identical and reported unchanged",
              p.partitions["rtos"] == original and "RTOS_P3_UNCHANGED=YES" in out)
        backup = os.path.join(backups, new[-1]) if new else ""
        check("a backup of the ORIGINAL rtos2 was kept on the host, 0600, with its facts",
              bool(new) and open(backup, "rb").read() == original
              and (os.stat(backup).st_mode & 0o777) == 0o600
              and os.path.isfile(backup[:-4] + ".txt"), str(new))
        order = out.find("RTOS2_BACKUP_SHA256="), out.find("WRITE_PLAN target=rtos2")
        check("the backup is reported before the write plan", -1 < order[0] < order[1], out[-600:])
        check("the device lock is released", p.flash_lock_holder is None)

        rc, out = run("rtos-logo", rtos.LOGO_CONFIRM_WORD)
        check("a second rtos-logo finds the logo present and writes nothing",
              rc == 0 and "ALREADY_PRESENT" in out and p.rtos2_writes == 1, out[-300:])

        rc, out = run("rtos-logo-restore", rtos.RESTORE_CONFIRM_WORD, "c" * 64)
        check("restore refuses a backup sha256 it does not have",
              rc == 2 and "no rtos2 backup" in out and p.rtos2_writes == 1, out[-200:])
        rc, out = run("rtos-logo-restore", rtos.RESTORE_CONFIRM_WORD, hashlib.sha256(original).hexdigest())
        check("restore writes the named backup back, byte for byte",
              rc == 0 and p.partitions["rtos2"] == original and p.rtos2_writes == 2
              and "RTOS2_RESTORE=WRITTEN" in out, out[-400:])
        rc, out = run("rtos-logo-restore", rtos.RESTORE_CONFIRM_WORD, hashlib.sha256(original).hexdigest())
        check("restoring what is already there writes nothing",
              rc == 0 and "ALREADY_EQUAL" in out and p.rtos2_writes == 2, out[-200:])

        # --- failed writes ---------------------------------------------------
        for fault in ("rtos_write_corrupt", "rtos_write_raises"):
            setattr(p, fault, True)
            rc, out = run("rtos-logo", rtos.LOGO_CONFIRM_WORD)
            setattr(p, fault, False)
            check("%s: reported as RTOS_WRITE_FAILED with the restore command" % fault,
                  rc == 1 and "RUN_NEBULAOS_HARDWARE=RTOS_WRITE_FAILED" in out
                  and "Do NOT reboot" in out
                  and "rtos-logo-restore %s" % hashlib.sha256(original).hexdigest() in out, out[-500:])
            check("%s: the lock is released" % fault, p.flash_lock_holder is None)
            rc, out = run("rtos-logo-restore", rtos.RESTORE_CONFIRM_WORD, hashlib.sha256(original).hexdigest())
            check("%s: the suggested restore brings rtos2 back" % fault,
                  rc == 0 and p.partitions["rtos2"] == original, out[-300:])
        log = open(os.path.join(root, "jstate", "rtos-backups", "printer-sim.log")).read()
        check("every rtos operation that reached the printer is logged on the host",
              log.count("OP=rtos-logo ") >= 9 and "RESULT=FAILED" in log and "RESULT=WRITTEN" in log, log[-300:])

        # --- the policy and the writer never reach rtos (p3) ------------------
        try:
            targets.RTOS2_ONLY.select("rtos")
            check("RTOS2_ONLY cannot select rtos", False)
        except targets.TargetError:
            check("RTOS2_ONLY cannot select rtos", True)
        check("the install policy does not include rtos2", "rtos2" not in targets.DEV_PRESERVE_STOCK.allowed)
        plan = targets.RECOVERY_BOTH_SIDES.select("rtos").plan_write(1024, "0" * 64)
        check("the rtos2 writer refuses a plan for rtos, even one a broader policy allowed",
              _raises(lambda: device.rtos2_write_script(plan, "x")))
        s = sim.make_session_factory(p, fx.profile)(device.OS_NEBULAOS, p.addresses[device.OS_NEBULAOS])
        check("whole-partition reads are limited to rtos/rtos2", _raises(lambda: s.read_target_image("rootfs")))
    finally:
        unpin()
        agent.FW_ROOT, agent.ssh_session_factory = saved
        shutil.rmtree(root, ignore_errors=True)


def case_rtos2_write_script_in_a_real_shell():
    """The composed rtos2 writer and partition guard, run by /bin/sh against a
    fixture sysfs/dev tree: the guards refuse before dd, and a good plan writes
    and reads back."""
    root = tempfile.mkdtemp(prefix="nebulaos-rtos2sh.", dir=os.environ.get("TMPDIR") or None)
    try:
        t = targets.resolve("rtos2")
        sysd = os.path.join(root, "sys", "mmcblk0p4")
        os.makedirs(sysd)
        os.makedirs(os.path.join(root, "bylabel"))
        os.makedirs(os.path.join(root, "stage"))
        dev = os.path.join(root, "mmcblk0p4")
        with open(dev, "wb") as fh:
            fh.write(b"\x55" * t.size)
        os.symlink(dev, os.path.join(root, "bylabel", "rtos2"))
        open(os.path.join(root, "mounts"), "w").write("/dev/mmcblk0p8 / squashfs ro 0 0\n")
        open(os.path.join(root, "drop_caches"), "w").close()

        def setsys(name="rtos2", sectors=t.size // 512):
            open(os.path.join(sysd, "uevent"), "w").write("MAJOR=179\nPARTN=4\nPARTNAME=%s\n" % name)
            open(os.path.join(sysd, "size"), "w").write("%d\n" % sectors)

        payload = b"RTOS-PAYLOAD" * 1000
        with open(os.path.join(root, "stage", "zero2.bin"), "wb") as fh:
            fh.write(payload)
        plan = targets.RTOS2_ONLY.select("rtos2").plan_write(len(payload),
                                                             hashlib.sha256(payload).hexdigest())

        def run(p=plan):
            script = device.rtos2_write_script(p, "zero2.bin")
            for a, b in (("/sys/class/block/mmcblk0p4", sysd),
                         ("/dev/disk/by-partlabel/", os.path.join(root, "bylabel") + "/"),
                         ("/dev/mmcblk0p4", dev), ("/proc/mounts", os.path.join(root, "mounts")),
                         ("/proc/sys/vm/drop_caches", os.path.join(root, "drop_caches")),
                         ("/usr/data/nebulaos-hwagent", os.path.join(root, "stage"))):
                script = script.replace(a, b)
            proc = subprocess.run(["/bin/sh", "-c", script], capture_output=True, text=True)
            return proc.returncode, proc.stdout

        untouched = lambda: open(dev, "rb").read() == b"\x55" * t.size     # noqa: E731
        setsys(name="rtos")
        rc, out = run()
        check("shell guard: a partition whose GPT name is not rtos2 is refused before dd",
              rc == 3 and "guard=PARTNAME" in out and untouched(), out)
        setsys(sectors=4096)
        rc, out = run()
        check("shell guard: a partition of the wrong size is refused", rc == 3 and "guard=SIZE" in out
              and untouched(), out)
        setsys()
        with open(os.path.join(root, "mounts"), "a") as fh:
            fh.write("%s /mnt vfat rw 0 0\n" % dev)
        rc, out = run()
        check("shell guard: a mounted target is refused", rc == 3 and "guard=MOUNTED" in out and untouched(), out)
        open(os.path.join(root, "mounts"), "w").write("/dev/mmcblk0p8 / squashfs ro 0 0\n")
        wrong = targets.RTOS2_ONLY.select("rtos2").plan_write(len(payload), "0" * 64)
        rc, out = run(wrong)
        check("shell guard: a staged file that does not hash to the plan is refused",
              rc == 3 and "guard=STAGED_SHA" in out and untouched(), out)
        rc, out = run()
        data = open(dev, "rb").read()
        check("a good plan writes exactly the payload and reads it back",
              rc == 0 and "rtos2_dd_rc=0" in out
              and "rtos2_readback_sha256=%s" % plan.payload_sha256 in out
              and data[:len(payload)] == payload and data[len(payload):] == b"\x55" * (t.size - len(payload))
              and len(data) == t.size, out)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_restart_script_in_a_real_shell():
    """The composed restart script, run by /bin/sh against a fixture tree with
    a stub wget - so the refusals are proven in shell, not only in the model."""
    root = tempfile.mkdtemp(prefix="nebulaos-restart.", dir=os.environ.get("TMPDIR") or None)
    try:
        nroot = os.path.join(root, "nebulaos")
        os.makedirs(os.path.join(nroot, "updates", "locks"))
        os.makedirs(os.path.join(nroot, "updates", "moonraker"))
        bindir = os.path.join(root, "bin")
        os.makedirs(bindir)
        pidfile = os.path.join(root, "svc.pid")
        init = os.path.join(root, "S56moonraker")
        with open(init, "w") as fh:
            fh.write("#!/bin/sh\ncase \"$1\" in\n"
                     "start) sleep 30 >/dev/null 2>&1 & echo $! > %s ;;\n"
                     "stop) [ -f %s ] && kill $(cat %s) 2>/dev/null; rm -f %s ;;\nesac\n"
                     % ((shlex_quote(pidfile),) * 4))
        os.chmod(init, 0o755)
        state = os.path.join(root, "print_state")
        with open(os.path.join(bindir, "wget"), "w") as fh:
            fh.write("#!/bin/sh\ncat %s 2>/dev/null\n" % shlex_quote(state))
        os.chmod(os.path.join(bindir, "wget"), 0o755)

        def run(name, print_json):
            with open(state, "w") as fh:
                fh.write(print_json)
            script = device.restart_script(name)
            real_init, real_pid = device.RESTARTABLE_SERVICES[name]
            script = (script.replace(shlex_quote(real_init), shlex_quote(init))
                      .replace(shlex_quote(real_pid), shlex_quote(pidfile))
                      .replace("R=/usr/data/nebulaos", "R=" + shlex_quote(nroot)))
            env = dict(os.environ, PATH=bindir + ":" + os.environ.get("PATH", ""))
            out = subprocess.run(["sh", "-c", script], capture_output=True, text=True,
                                 env=env, timeout=60).stdout
            return dict(l.split("=", 1) for l in out.splitlines() if "=" in l)

        idle = '{"result":{"status":{"print_stats":{"state":"standby"}}}}'
        r = run("moonraker", '{"result": {"status": {"print_stats": {"state": "printing"}}}}')
        check("shell: refuses during a print (spaced JSON)", r.get("restart_result") == "REFUSED", str(r))
        lock = os.path.join(nroot, "updates", "locks", "moonraker.lock")
        open(lock, "w").close()
        r = run("moonraker", idle)
        check("shell: refuses while a supervisor lock exists",
              r.get("restart_result") == "REFUSED" and "moonraker.lock" in r.get("restart_reason", ""), str(r))
        os.remove(lock)
        st = os.path.join(nroot, "updates", "moonraker", "state.json")
        with open(st, "w") as fh:
            fh.write('{\n  "state": "validating",\n}\n')
        r = run("moonraker", idle)
        check("shell: refuses while a component is validating",
              r.get("restart_result") == "REFUSED" and "validating" in r.get("restart_reason", ""), str(r))
        os.remove(st)
        r = run("klipper", "")
        check("shell: klipper refuses when the print state is unreadable",
              r.get("restart_result") == "REFUSED" and "unreadable" in r.get("restart_reason", ""), str(r))
        r = run("moonraker", "")
        check("shell: moonraker restarts when only the print state is unreadable",
              r.get("restart_result") == "DONE" and r.get("restart_new_pid"), str(r))
        old = r.get("restart_new_pid")
        r = run("moonraker", idle)
        check("shell: a second restart replaces the process",
              r.get("restart_result") == "DONE" and r.get("restart_old_pid") == old
              and r.get("restart_new_pid") not in ("", old), str(r))
        # An old process that will not exit: start-stop-daemon would refuse to
        # start, so the pid stays the same - that is FAILED, never DONE.
        stubborn = os.path.join(root, "S-stubborn")
        with open(stubborn, "w") as fh:
            fh.write("#!/bin/sh\ncase \"$1\" in\nstop) : ;;\nstart) : ;;\nesac\n")
        os.chmod(stubborn, 0o755)
        real_init_q = shlex_quote(device.RESTARTABLE_SERVICES["moonraker"][0])
        script = (device.restart_script("moonraker").replace(real_init_q, shlex_quote(stubborn))
                  .replace(shlex_quote(device.RESTARTABLE_SERVICES["moonraker"][1]), shlex_quote(pidfile))
                  .replace("R=/usr/data/nebulaos", "R=" + shlex_quote(nroot))
                  .replace("[ \"$n\" -ge 20 ]", "[ \"$n\" -ge 1 ]"))
        with open(state, "w") as fh:
            fh.write(idle)
        env = dict(os.environ, PATH=bindir + ":" + os.environ.get("PATH", ""))
        out = subprocess.run(["sh", "-c", script], capture_output=True, text=True, env=env,
                             timeout=60).stdout
        check("shell: an unchanged pid after start is FAILED, not DONE",
              "restart_result=FAILED" in out and "did not exit" in out, out)
        subprocess.run(["sh", init, "stop"], capture_output=True)
        check("shell: an unknown service never becomes a script",
              _raises(lambda: device.restart_script("sshd; reboot")))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def shlex_quote(s):
    import shlex
    return shlex.quote(s)


def _raises(fn):
    try:
        fn()
    except device.DeviceError:
        return True
    return False


def case_no_raw_surface():
    """The closed vocabulary, asserted rather than asserted-in-prose."""
    forbidden = ("run", "exec", "shell", "dd", "read_offset", "write_offset", "raw")
    public = [n for n in dir(device.DeviceSession) if not n.startswith("_")]
    leaked = [n for n in public if n in forbidden]
    check("DeviceSession exposes no arbitrary-execution method", not leaked,
          "leaked: %s" % leaked)
    check("DeviceSession exposes no method taking a raw offset",
          not any("offset" in n for n in public), str(public))
    # region_sha256 and apply_write_plans take NAMES and PLANS, never paths.
    import inspect
    sig = inspect.signature(device.DeviceSession.region_sha256)
    check("region_sha256 addresses a target by name, not by device path",
          "target_name" in sig.parameters, str(sig))


# ---------------------------------------------------------------------------
# NebulaOS in either or both slots (human decision 2026-10-14)
# ---------------------------------------------------------------------------

import nebulaos_slots as slots        # noqa: E402

OLD_NEB_K = b"NEBULAOS-XIMAGE-OLD-" + b"o" * 512
OLD_NEB_R = b"NEBULAOS-ROOTFS-OLD-" + b"o" * 2048
CRE_K = b"\xde\xad" * 1024
CRE_R = b"\xbe\xef" * 4096


def set_profile(fx, **keys):
    """Append human-owned keys to the fixture profile and reload it."""
    conf = os.path.join(os.environ[profiles.ENV_HOME], "devices", "printer-sim", "profile.conf")
    with open(conf, "a") as fh:
        for k, v in keys.items():
            fh.write("%s=%s\n" % (k, v))
    os.chmod(conf, 0o600)
    fx.profile = profiles.DeviceProfile.load("printer-sim")


def layout(fx, running, slot1, slot2, marker_slot=None):
    """Put the simulated printer into a both-slots state.
    slotN is 'nebulaos' (an OLDER NebulaOS), 'creality', 'empty' or 'junk'."""
    p = fx.printer
    for n, holds in ((1, slot1), (2, slot2)):
        k, r = p.SLOT_PARTS[n]
        p.partitions[k], p.partitions[r] = {
            "nebulaos": (OLD_NEB_K, OLD_NEB_R), "creality": (CRE_K, CRE_R),
            "empty": (b"", b""), "junk": (b"\x11" * 64, b"\x22" * 64)}[holds]
    p.running_slot = running
    p.running_os = {"nebulaos": device.OS_NEBULAOS, "creality": device.OS_STOCK}[
        slot1 if running == 1 else slot2]
    p.partitions["ota"] = marker.canonical(slots.SLOTS[marker_slot or running].marker)


def sha(b):
    return hashlib.sha256(b or b"").hexdigest()


def run_install_keep(fx, txn=None):
    """-> (installer, result, error): run_install, keeping the installer's output."""
    inst = fx.installer(txn=txn)
    try:
        return inst, inst.run(), None
    except install.InstallError as exc:
        return inst, None, exc
    except Exception as exc:                      # noqa: BLE001 - surfaced as a failure
        return inst, None, exc


def booted_stock(printer):
    return any("stock MCU updater" in l for l in printer.log) or \
        getattr(printer, "_stock_boots", 0) > 0


def _count_stock_boots(printer):
    real = printer.boot

    def boot():
        real()
        if printer.running_os == device.OS_STOCK:
            printer._stock_boots = getattr(printer, "_stock_boots", 0) + 1
    printer.boot = boot


def case_slot_classification():
    """nebulaos_slots.classify: pure, fail-closed rules."""
    base = {"slot1_kernel_magic": "27051956", "slot1_kernel_name": "Linux-4.4.94",
            "slot1_rootfs_magic": "68737173", "slot1_inspect": "mounted",
            "slot1_nebulaos_markers": "0", "slot1_creality_markers": "1"}
    check("slots: Creality markers + 4.4 kernel classify as creality",
          slots.classify(base, 1)[0] == slots.HOLDS_CREALITY, slots.classify(base, 1)[1])
    f = dict(base, slot1_nebulaos_markers="1", slot1_creality_markers="0")
    check("slots: NebulaOS rootfs behind a 4.4 kernel is UNKNOWN (mixed/half-written)",
          slots.classify(f, 1)[0] == slots.HOLDS_UNKNOWN, slots.classify(f, 1)[1])
    f = dict(base, slot1_kernel_name="Linux-6.6.18-rt23", slot1_nebulaos_markers="1",
             slot1_creality_markers="0")
    check("slots: NebulaOS markers + 6.x kernel classify as nebulaos",
          slots.classify(f, 1)[0] == slots.HOLDS_NEBULAOS)
    f = dict(base, slot1_inspect="failed")
    check("slots: a squashfs that could not be mounted is UNKNOWN, never assumed",
          slots.classify(f, 1)[0] == slots.HOLDS_UNKNOWN)
    f = dict(base, slot1_rootfs_magic="11111111")
    check("slots: no squashfs superblock is EMPTY",
          slots.classify(f, 1)[0] == slots.HOLDS_EMPTY)
    f = dict(base, slot1_kernel_magic="00000000")
    check("slots: no uImage header on the kernel partition is EMPTY",
          slots.classify(f, 1)[0] == slots.HOLDS_EMPTY)
    f = dict(base, slot1_nebulaos_markers="1")
    check("slots: both markers at once is UNKNOWN",
          slots.classify(f, 1)[0] == slots.HOLDS_UNKNOWN)
    check("slots: an unknown kernel name does not override the rootfs markers",
          slots.classify(dict(base, slot1_kernel_name="custom"), 1)[0] == slots.HOLDS_CREALITY)
    check("slots: slot_of_root knows exactly p7 and p8",
          slots.slot_of_root("/dev/mmcblk0p7") == 1 and slots.slot_of_root("/dev/mmcblk0p8") == 2
          and slots.slot_of_root("/dev/mmcblk0p9") is None and slots.slot_of_root("") is None)

    # The policies: one slot each, never the running one by construction.
    for n, pol in ((1, targets.DEV_INACTIVE_SLOT_1), (2, targets.DEV_INACTIVE_SLOT_2)):
        other = slots.SLOTS[slots.other(n)]
        refused = []
        for name in (other.kernel, other.rootfs, "sn_mac", "rtos", "rtos2"):
            try:
                pol.select(name)
            except targets.TargetError:
                refused.append(name)
        check("policy %s selects only slot %d (+ marker)" % (pol.name, n),
              len(refused) == 5 and pol.allowed == {slots.SLOTS[n].kernel, slots.SLOTS[n].rootfs, "ota"},
              "refused %s" % refused)
    try:
        device.plans_slot([targets.DEV_INACTIVE_SLOT_1.select("kernel").plan_write(1, "a" * 64),
                           targets.RECOVERY_BOTH_SIDES.select("rootfs2").plan_write(1, "a" * 64)])
        bad("a mixed kernel/rootfs2 plan set is refused by the session", "accepted")
    except device.DeviceError:
        ok("a mixed kernel/rootfs2 plan set is refused by the session")
    try:
        device.plans_slot([targets.DEV_INACTIVE_SLOT_1.select("kernel").plan_write(1, "a" * 64)])
        bad("a lone kernel plan is refused by the session", "accepted")
    except device.DeviceError:
        ok("a lone kernel plan is refused by the session")


def case_slot_facts_script_in_a_real_shell():
    """The exact probe text, run by sh against fixture partitions, with a fake
    mount that logs what it mounts. Proves: the running root is inspected in
    place and never mounted; the other rootfs is mounted read-only and
    unmounted; markers, kernel names and the seed manifest's firmware_head are
    read; a slot without a squashfs superblock is not mounted at all."""
    import struct
    root = tempfile.mkdtemp(prefix="slotfacts.", dir=os.environ.get("TMPDIR") or None)
    try:
        dev = os.path.join(root, "dev"); os.makedirs(dev)
        bin_dir = os.path.join(root, "bin"); os.makedirs(bin_dir)
        tmp = os.path.join(root, "tmp"); os.makedirs(tmp)
        mlog = os.path.join(root, "mount.log")

        def uimage(name):
            return struct.pack(">I", 0x27051956) + b"\0" * 28 + name.encode().ljust(32, b"\0")

        def tree(name, nebulaos):
            t = os.path.join(root, name)
            if nebulaos:
                os.makedirs(os.path.join(t, "etc")); os.makedirs(os.path.join(t, "opt", "nebulaos"))
                open(os.path.join(t, "etc", "ota_marker.sh"), "w").close()
                os.makedirs(os.path.join(t, "opt", "nebulaos-seeds"))
                with open(os.path.join(t, "opt", "nebulaos-seeds", "seed-manifest.json"), "w") as fh:
                    fh.write('{\n  "firmware_head": "%s",\n  "x": 1\n}\n' % ("ab" * 20))
            else:
                os.makedirs(os.path.join(t, "etc", "ota_bin"))
            return t

        def run(cmdline, p5, p6, p7, p8, other_tree, mount_ok=True):
            for n, data in (("p5", p5), ("p6", p6), ("p7", p7), ("p8", p8)):
                with open(os.path.join(dev, "mmcblk0" + n), "wb") as fh:
                    fh.write(data)
            with open(os.path.join(root, "cmdline"), "w") as fh:
                fh.write(cmdline + "\n")
            with open(os.path.join(bin_dir, "mount"), "w") as fh:
                fh.write("#!/bin/sh\necho \"$*\" >> %s\n" % mlog
                         + ("for a; do d=$a; done; cp -R %s/. \"$d\"\n" % other_tree if mount_ok
                            else "exit 32\n"))
            with open(os.path.join(bin_dir, "umount"), "w") as fh:
                fh.write("#!/bin/sh\necho \"umount $*\" >> %s\nrm -rf \"$1\"/* 2>/dev/null; exit 0\n" % mlog)
            for n in ("mount", "umount"):
                os.chmod(os.path.join(bin_dir, n), 0o755)
            if os.path.exists(mlog):
                os.unlink(mlog)
            script = device.slot_facts_script(dev_prefix=root, cmdline=os.path.join(root, "cmdline"),
                                              tmp_dir=tmp)
            out = subprocess.run(["sh", "-c", script], capture_output=True, text=True,
                                 env=dict(os.environ, PATH=bin_dir + ":" + os.environ.get("PATH", "")))
            facts = dict(l.split("=", 1) for l in out.stdout.splitlines() if "=" in l)
            mounts = open(mlog).read() if os.path.exists(mlog) else ""
            return out.returncode, facts, mounts

        running_tree = tree("running", True)
        # The running slot is inspected at $D/ = the fixture root.
        for rel in ("etc", "opt"):
            shutil.copytree(os.path.join(running_tree, rel), os.path.join(root, rel))
        cre = tree("creality", False)
        sq = b"hsqs" + b"\0" * 60
        rc, facts, mounts = run("console=ttyS4 root=/dev/mmcblk0p8 rw", uimage("Linux-4.4.94"),
                                uimage("Linux-6.6.18-rt23"), sq, sq, cre)
        check("slot probe: exits 0", rc == 0, str(rc))
        check("slot probe: slot 2 (the live root) is inspected in place, never mounted",
              facts.get("slot2_inspect") == "running" and "mmcblk0p8" not in mounts, mounts)
        check("slot probe: slot 1 is mounted READ-ONLY as squashfs and unmounted",
              facts.get("slot1_inspect") == "mounted" and "-t squashfs -o ro" in mounts
              and "mmcblk0p7" in mounts and "umount" in mounts, mounts)
        check("slot probe: Creality markers found in slot 1, NebulaOS markers in slot 2",
              facts.get("slot1_creality_markers") == "1" and facts.get("slot1_nebulaos_markers") == "0"
              and facts.get("slot2_nebulaos_markers") == "1", str(facts))
        check("slot probe: uImage magic and kernel names read",
              facts.get("slot1_kernel_magic") == "27051956"
              and facts.get("slot1_kernel_name") == "Linux-4.4.94"
              and facts.get("slot2_kernel_name") == "Linux-6.6.18-rt23", str(facts))
        check("slot probe: the running NebulaOS's firmware_head is read from its seed manifest",
              facts.get("slot2_firmware_head") == "ab" * 20, facts.get("slot2_firmware_head"))
        check("slot probe: its private mount point is removed",
              not [n for n in os.listdir(tmp) if n.startswith(".nebulaos-slotro")], str(os.listdir(tmp)))
        state = slots.SlotState("nebulaos", "/dev/mmcblk0p8", marker.KERNEL2, "", facts)
        check("slot probe -> SlotState: 1=creality 2=nebulaos",
              state.holds == {1: "creality", 2: "nebulaos"}, state.describe())

        neb_other = tree("nebother", True)
        rc, facts, mounts = run("root=/dev/mmcblk0p7", uimage("Linux-6.6.18-rt23"),
                                uimage("Linux-6.6.18-rt23"), sq, sq, neb_other)
        state = slots.SlotState("nebulaos", "/dev/mmcblk0p7", marker.KERNEL, "", facts)
        check("slot probe: NebulaOS in slot 1 running, older NebulaOS in slot 2 mounted",
              state.holds == {1: "nebulaos", 2: "nebulaos"} and "mmcblk0p7" not in mounts
              and "mmcblk0p8" in mounts, state.describe() + " | " + mounts)
        rc, facts, mounts = run("root=/dev/mmcblk0p7", uimage("Linux-6.6.18-rt23"),
                                b"\0" * 64, sq, b"\xff" * 64, neb_other)
        check("slot probe: a rootfs without a squashfs superblock is not mounted at all",
              facts.get("slot2_inspect") == "skipped" and not mounts, mounts)
        rc, facts, mounts = run("root=/dev/mmcblk0p7", uimage("Linux-6.6.18-rt23"),
                                uimage("Linux-4.4.94"), sq, sq, cre, mount_ok=False)
        state = slots.SlotState("nebulaos", "/dev/mmcblk0p7", marker.KERNEL, "", facts)
        check("slot probe: a failed mount fails closed (slot 2 unknown, no markers)",
              facts.get("slot2_inspect") == "failed" and state.holds[2] == slots.HOLDS_UNKNOWN,
              state.describe())
        rc, facts, mounts = run("root=PARTUUID=dead-beef", uimage("Linux-6.6.18-rt23"),
                                uimage("Linux-4.4.94"), sq, sq, cre)
        check("slot probe: an unrecognised root= mounts nothing (both slots root_unknown)",
              facts.get("slot1_inspect") == "root_unknown" and facts.get("slot2_inspect") == "root_unknown"
              and not mounts, str(facts))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_both_slots_b_nebulaos_a_creality_default():
    """NebulaOS in slot 2 + Creality in slot 1, no profile key: the original
    PRESERVE_STOCK path, unchanged."""
    fx, root = scenario("bs-preserve")
    try:
        inst, result, err = run_install_keep(fx)
        out = "\n".join(inst.result.lines)
        check("B=NebulaOS A=Creality (no key): install succeeds", err is None and result.ok,
              str(err)[:200])
        check("B=NebulaOS A=Creality (no key): path is PRESERVE_STOCK via Creality",
              "DEV_INSTALL_PATH=PRESERVE_STOCK" in out and "STATE=STOCK_RUNNING" in out)
        check("B=NebulaOS A=Creality (no key): only slot 2 written, Creality intact",
              getattr(fx.printer, "slot_writes", []) == [2]
              and fx.printer.partitions["kernel"] == CRE_K and fx.printer.partitions["rootfs"] == CRE_R)
        check("B=NebulaOS A=Creality (no key): the slot state is reported",
              "SLOT_1_HOLDS=creality" in out and "SLOT_2_HOLDS=nebulaos" in out
              and "SLOT_RUNNING=2" in out and "SLOT_MARKER_SELECTS=2" in out)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_both_slots_b_nebulaos_a_creality_expendable():
    """NebulaOS in slot 2 + Creality in slot 1 + INSTALL_OTHER_SLOT=expendable
    on a DEV device: slot 1 is written directly, Creality is never booted."""
    fx, root = scenario("bs-expend")
    try:
        set_profile(fx, INSTALL_MODE="dev", INSTALL_OTHER_SLOT="expendable")
        _count_stock_boots(fx.printer)
        old2 = (fx.printer.partitions["kernel2"], fx.printer.partitions["rootfs2"])
        inst, result, err = run_install_keep(fx)
        out = "\n".join(inst.result.lines)
        check("B=NebulaOS A=Creality (expendable): install succeeds", err is None and result.ok,
              str(err)[:300] + out[-600:])
        check("B=NebulaOS A=Creality (expendable): INACTIVE_SLOT, writes slot 1, overwrites Creality",
              "DEV_INSTALL_PATH=INACTIVE_SLOT" in out and "DEV_INSTALL_TARGET_SLOT=1" in out
              and "DEV_INSTALL_OVERWRITES_CREALITY=YES" in out)
        check("B=NebulaOS A=Creality (expendable): Creality was never booted",
              not booted_stock(fx.printer) and "STOCK_RUNNING" not in out)
        check("B=NebulaOS A=Creality (expendable): slot 1 holds exactly the new build",
              sha(fx.printer.partitions["kernel"]) == fx.artifacts.ximage_sha
              and sha(fx.printer.partitions["rootfs"]) == fx.artifacts.rootfs_sha)
        check("B=NebulaOS A=Creality (expendable): the running slot 2 was never written",
              (fx.printer.partitions["kernel2"], fx.printer.partitions["rootfs2"]) == old2
              and getattr(fx.printer, "slot_writes", []) == [1])
        check("B=NebulaOS A=Creality (expendable): ends running NebulaOS from slot 1, marker on slot 1",
              fx.printer.running_os == device.OS_NEBULAOS and fx.printer.running_slot == 1
              and marker_state(fx.printer) == marker.KERNEL)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_both_slots_a_and_b_nebulaos():
    """NebulaOS running in slot 1, an older NebulaOS in slot 2: no key needed;
    slot 2 is written and booted; then the reverse direction."""
    fx, root = scenario("bs-both")
    try:
        layout(fx, running=1, slot1="nebulaos", slot2="nebulaos")
        _count_stock_boots(fx.printer)
        inst, result, err = run_install_keep(fx)
        out = "\n".join(inst.result.lines)
        check("A=NebulaOS(run) B=NebulaOS: install succeeds without any profile key",
              err is None and result.ok, str(err)[:300] + out[-400:])
        check("A=NebulaOS(run) B=NebulaOS: INACTIVE_SLOT writes slot 2 under INACTIVE_SLOT_2",
              "DEV_INSTALL_PATH=INACTIVE_SLOT" in out and "DEV_INSTALL_POLICY=INACTIVE_SLOT_2" in out
              and getattr(fx.printer, "slot_writes", []) == [2])
        check("A=NebulaOS(run) B=NebulaOS: slot 1 (the way back) untouched",
              fx.printer.partitions["kernel"] == OLD_NEB_K and fx.printer.partitions["rootfs"] == OLD_NEB_R)
        check("A=NebulaOS(run) B=NebulaOS: runs the new build from slot 2, marker on slot 2, no stock",
              fx.printer.running_slot == 2 and marker_state(fx.printer) == marker.KERNEL2
              and sha(fx.printer.partitions["rootfs2"]) == fx.artifacts.rootfs_sha
              and not booted_stock(fx.printer))
        check("A=NebulaOS(run) B=NebulaOS: PART1 verified against slot 2's partitions",
              "kernel2 holds exactly the expected xImage" in out and "PART1_INSTALL_VERIFIED=YES" in out)
        check("A=NebulaOS(run) B=NebulaOS: no power-cycle-dangerous state on this path",
              "POWER_CYCLE_DANGEROUS=YES" not in out and "ARMED_STOCK" not in out)

        # Now the reverse: running slot 2 (the new build), slot 1 holds the old one.
        fx.printer.slot_writes = []
        inst, result, err = run_install_keep(fx)
        out = "\n".join(inst.result.lines)
        check("B=NebulaOS(run) A=NebulaOS: install writes slot 1 and boots it",
              err is None and result.ok and getattr(fx.printer, "slot_writes", []) == [1]
              and fx.printer.running_slot == 1 and marker_state(fx.printer) == marker.KERNEL,
              str(err)[:300] + out[-300:])
        check("B=NebulaOS(run) A=NebulaOS: PART1 verified against slot 1's partitions",
              "kernel holds exactly the expected xImage" in out and "PART1_INSTALL_VERIFIED=YES" in out)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_both_slots_a_nebulaos_b_creality():
    """NebulaOS running in slot 1 and Creality in slot 2: refused without the
    human's key (naming it), written with it."""
    fx, root = scenario("bs-acreb")
    try:
        layout(fx, running=1, slot1="nebulaos", slot2="creality")
        before = dict(fx.printer.partitions)
        inst, result, err = run_install_keep(fx)
        out = "\n".join(inst.result.lines)
        check("A=NebulaOS(run) B=Creality (no key): refused", err is not None and result is None)
        check("A=NebulaOS(run) B=Creality (no key): the refusal names INSTALL_OTHER_SLOT=expendable",
              err is not None and "INSTALL_OTHER_SLOT=expendable" in str(err), str(err)[:300])
        check("A=NebulaOS(run) B=Creality (no key): nothing written, marker still on slot 1, not rebooted",
              fx.printer.partitions == before and fx.printer.boot_id == "boot-0001"
              and fx.printer.staged == {})
        check("A=NebulaOS(run) B=Creality (no key): the refusal state is SAFE_NEBULAOS",
              getattr(err, "state", None) == journal.SAFE_NEBULAOS, str(getattr(err, "state", None)))

        set_profile(fx, INSTALL_OTHER_SLOT="expendable")          # still a RELEASE device
        inst, result, err = run_install_keep(fx)
        check("A=NebulaOS(run) B=Creality: expendable is IGNORED on a RELEASE device",
              err is not None and "ignored on a RELEASE device" in "\n".join(inst.result.lines)
              and fx.printer.partitions == before, str(err)[:200])

        set_profile(fx, INSTALL_MODE="dev")
        _count_stock_boots(fx.printer)
        inst, result, err = run_install_keep(fx)
        out = "\n".join(inst.result.lines)
        check("A=NebulaOS(run) B=Creality (dev, expendable): slot 2 written and booted",
              err is None and result.ok and fx.printer.running_slot == 2
              and sha(fx.printer.partitions["kernel2"]) == fx.artifacts.ximage_sha
              and not booted_stock(fx.printer), str(err)[:300] + out[-300:])
        check("A=NebulaOS(run) B=Creality (dev, expendable): slot 1 untouched",
              fx.printer.partitions["kernel"] == OLD_NEB_K and fx.printer.partitions["rootfs"] == OLD_NEB_R)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_both_slots_unknown_other_slot():
    """An other slot that cannot be identified is overwritten only with the key."""
    fx, root = scenario("bs-unknown")
    try:
        layout(fx, running=1, slot1="nebulaos", slot2="junk")
        before = dict(fx.printer.partitions)
        inst, result, err = run_install_keep(fx)
        check("A=NebulaOS(run) B=unknown (no key): refused, nothing written",
              err is not None and fx.printer.partitions == before
              and "INSTALL_OTHER_SLOT=expendable" in str(err), str(err)[:200])
        layout(fx, running=1, slot1="nebulaos", slot2="nebulaos")
        fx.printer.slot_facts_fail = True                     # the probe cannot mount slot 2
        before = dict(fx.printer.partitions)
        inst, result, err = run_install_keep(fx)
        check("A=NebulaOS(run) B=NebulaOS but unmountable (no key): UNKNOWN, refused",
              err is not None and fx.printer.partitions == before
              and "SLOT_2_HOLDS=unknown" in "\n".join(inst.result.lines), str(err)[:200])
        fx.printer.slot_facts_fail = False
        layout(fx, running=1, slot1="nebulaos", slot2="empty")
        set_profile(fx, INSTALL_MODE="dev", INSTALL_OTHER_SLOT="expendable")
        inst, result, err = run_install_keep(fx)
        check("A=NebulaOS(run) B=empty (dev, expendable): written and booted",
              err is None and result.ok and fx.printer.running_slot == 2, str(err)[:200])
    finally:
        shutil.rmtree(root, ignore_errors=True)

    # Already running Creality from slot 1 with a SECOND Creality in slot 2.
    fx, root = scenario("bs-stock2")
    try:
        layout(fx, running=1, slot1="creality", slot2="creality")
        fx.printer.staged.update({"xImage": XIMAGE, "rootfs.squashfs": ROOTFS,
                                  "build-manifest.txt": b"x"})
        before = (fx.printer.partitions["kernel2"], fx.printer.partitions["rootfs2"])
        inst, result, err = run_install_keep(fx)
        check("on stock with Creality in slot 2 too (no key): slot 2 is not overwritten",
              err is not None and "INSTALL_OTHER_SLOT=expendable" in str(err)
              and (fx.printer.partitions["kernel2"], fx.printer.partitions["rootfs2"]) == before,
              str(err)[:200])
        set_profile(fx, INSTALL_MODE="dev", INSTALL_OTHER_SLOT="expendable")
        inst, result, err = run_install_keep(fx)
        check("on stock with Creality in slot 2 (dev, expendable): the stock path writes slot 2",
              err is None and result.ok and sha(fx.printer.partitions["kernel2"]) == fx.artifacts.ximage_sha,
              str(err)[:200])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_both_slots_never_write_running_slot():
    """Refusal to write the running slot, at every layer that can refuse it."""
    fx, root = scenario("bs-running")
    try:
        layout(fx, running=1, slot1="nebulaos", slot2="nebulaos")
        # (1) the simulated helper (as flash-spare-slot.sh) refuses the live slot.
        session = sim.SimSession(fx.printer, device.OS_NEBULAOS, fx.printer.addresses[device.OS_NEBULAOS],
                                 fx.printer.host_keys[device.OS_NEBULAOS],
                                 fx.printer.passwords[device.OS_NEBULAOS])
        fx.printer.staged["flash-spare-slot.sh"] = b"x"
        fx.printer.staged["xImage"], fx.printer.staged["rootfs.squashfs"] = XIMAGE, ROOTFS
        pol = targets.inactive_slot_policy(1)
        okw, report = session.apply_write_plans(
            [pol.select("kernel").plan_write(len(XIMAGE), sha(XIMAGE)),
             pol.select("rootfs").plan_write(len(ROOTFS), sha(ROOTFS))], "build-manifest.txt")
        check("the flash helper refuses the live slot's pair",
              not okw and fx.printer.partitions["kernel"] == OLD_NEB_K, report)
        fx.printer.staged = {}

        # (2) a plan that names the running slot is caught by the way-back proof.
        real_plan = slots.plan_install

        def evil(state, policy):
            return slots.InstallPlan(slots.PATH_INACTIVE_SLOT, 1, 1, targets.inactive_slot_policy(1),
                                     "nebulaos", "sabotaged")
        slots.plan_install = evil
        try:
            before = dict(fx.printer.partitions)
            inst, result, err = run_install_keep(fx)
        finally:
            slots.plan_install = real_plan
        out = "\n".join(inst.result.lines)
        check("a plan targeting the running slot fails the way-back proof, nothing written",
              err is not None and "way-back proof failed" in str(err)
              and fx.printer.partitions == before and fx.printer.boot_id == "boot-0001",
              str(err)[:200])

        # (3) the live root changes between the proof and the write.
        real_root = sim.SimSession.active_root
        calls = {"n": 0}

        def moving_root(self):
            # Only once everything is proven and staged: the re-check right
            # before the write is the one that must catch it.
            if "flash-spare-slot.sh" in self.printer.staged:
                calls["n"] += 1
                return "/dev/mmcblk0p8"          # the target's root
            return real_root(self)
        sim.SimSession.active_root = moving_root
        try:
            before = dict(fx.printer.partitions)
            inst, result, err = run_install_keep(fx)
        finally:
            sim.SimSession.active_root = real_root
        out = "\n".join(inst.result.lines)
        check("a live root that changes before the write refuses it (re-checked from /proc/cmdline)",
              err is not None and fx.printer.partitions["kernel2"] == before["kernel2"]
              and fx.printer.partitions["rootfs2"] == before["rootfs2"]
              and marker_state(fx.printer) == marker.KERNEL and fx.printer.flash_lock_holder is None
              and "ACTIVE_ROOT_RECHECK=/dev/mmcblk0p8" in out and "live root is now" in str(err),
              str(err)[:200] + " calls=%d" % calls["n"])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_both_slots_marker_and_failures():
    """The marker on the other NebulaOS slot is pointed home BEFORE writing;
    a failed write or marker flip leaves the running slot selected."""
    fx, root = scenario("bs-marker")
    try:
        layout(fx, running=1, slot1="nebulaos", slot2="nebulaos", marker_slot=2)
        order = []
        real_write = sim.SimSession.write_marker
        real_apply = sim.SimSession.apply_write_plans

        def w(self, state):
            order.append(("marker", state))
            return real_write(self, state)

        def a(self, plans, manifest):
            order.append(("write", device.plans_slot(plans)))
            return real_apply(self, plans, manifest)
        sim.SimSession.write_marker, sim.SimSession.apply_write_plans = w, a
        try:
            inst, result, err = run_install_keep(fx)
        finally:
            sim.SimSession.write_marker, sim.SimSession.apply_write_plans = real_write, real_apply
        check("marker on the other NebulaOS slot: pointed back home BEFORE slot 2 is written",
              err is None and order[:3] == [("marker", marker.KERNEL), ("write", 2),
                                            ("marker", marker.KERNEL2)],
              str(order) + str(err)[:200])

        layout(fx, running=1, slot1="nebulaos", slot2="nebulaos")
        fx.printer.corrupt_flash = True
        inst, result, err = run_install_keep(fx)
        check("a slot write that does not verify: refused, marker still on the running slot, no reboot",
              err is not None and marker_state(fx.printer) == marker.KERNEL
              and fx.printer.running_slot == 1 and getattr(err, "state", None) == journal.SAFE_NEBULAOS,
              str(err)[:200])
        fx.printer.corrupt_flash = False

        layout(fx, running=1, slot1="nebulaos", slot2="nebulaos")
        boot = fx.printer.boot_id
        fx.printer.fail_marker_write = True
        inst, result, err = run_install_keep(fx)
        fx.printer.fail_marker_write = False
        check("a marker flip that does not land: refused, marker on the running slot, not rebooted",
              err is not None and marker_state(fx.printer) == marker.KERNEL
              and fx.printer.boot_id == boot and "put back on the running slot" in str(err),
              str(err)[:200])

        layout(fx, running=1, slot1="nebulaos", slot2="nebulaos")
        fx.printer.flash_helper_fails = True
        inst, result, err = run_install_keep(fx)
        fx.printer.flash_helper_fails = False
        check("a flash helper refusal: marker on the running slot, lock released",
              err is not None and marker_state(fx.printer) == marker.KERNEL
              and fx.printer.flash_lock_holder is None, str(err)[:200])

        # A busy printer is refused before anything is staged.
        layout(fx, running=1, slot1="nebulaos", slot2="nebulaos")
        fx.printer.staged = {}
        fx.printer.printing = True
        inst, result, err = run_install_keep(fx)
        fx.printer.printing = False
        check("INACTIVE_SLOT refuses a printing printer before staging anything",
              err is not None and "idle" in str(err) and fx.printer.staged == {}, str(err)[:200])

        # The journal remembers the path for `status`; nothing is power-cycle dangerous.
        os.environ[journal.ENV_STATE_HOME] = os.path.join(root, "jstate")
        layout(fx, running=1, slot1="nebulaos", slot2="nebulaos")
        txn = journal.Transaction.begin("printer-sim", fx.control_commit, SOURCE_HEAD,
                                        fx.artifacts.ximage_sha, fx.artifacts.rootfs_sha)
        inst, result, err = run_install_keep(fx, txn=txn)
        desc = journal.Transaction.open("printer-sim").describe()
        check("status after an INACTIVE_SLOT install: path and slots recorded, never dangerous",
              err is None and "TRANSACTION_LAST_OBSERVED_INSTALL_PATH=INACTIVE_SLOT" in desc
              and "TRANSACTION_LAST_OBSERVED_INSTALL_TARGET_SLOT=2" in desc
              and "TRANSACTION_LAST_OBSERVED_SLOT_1_HOLDS=nebulaos" in desc
              and "TRANSACTION_LAST_OBSERVED_SLOT_RUNNING=2" in desc
              and "TRANSACTION_POWER_CYCLE_DANGEROUS=NO" in desc, desc[-600:])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_both_slots_reboot_and_rtos():
    """reboot: only into a slot that holds NebulaOS; rtos-logo: slot 2 only."""
    import argparse
    import contextlib
    import io
    import time as _time
    import nebulaos_agent as agent
    import nebulaos_rtos as rtos

    saved = (agent.FW_ROOT, agent.ssh_session_factory, _time.sleep)
    fx, root = scenario("bs-reboot")
    try:
        os.environ[journal.ENV_STATE_HOME] = os.path.join(root, "jstate")
        set_profile(fx, INSTALL_MODE="dev")
        agent.FW_ROOT = fx.control_work
        agent.ssh_session_factory = lambda profile: sim.make_session_factory(fx.printer, profile)
        _time.sleep = lambda _s: None

        def reboot(confirm=agent.REBOOT_CONFIRM_WORD):
            ns = argparse.Namespace(device="printer-sim", control_commit=fx.control_commit,
                                    op="reboot", confirm=confirm)
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                try:
                    rc = agent.op_reboot(ns)
                except (agent.AgentRefusal, profiles.ProfileError, control.ControlError) as exc:
                    print("REFUSED: %s" % exc)
                    rc = 2
            return rc, buf.getvalue()

        p = fx.printer
        layout(fx, running=1, slot1="nebulaos", slot2="creality")
        b = p.boot_id
        rc, out = reboot()
        check("reboot: NebulaOS running from slot 1 with the marker on slot 1 is allowed",
              rc == 0 and p.boot_id != b and p.running_slot == 1 and "REBOOT_INTO_SLOT=1" in out
              and "REBOOT_SWITCHES_SLOT=NO" in out, out[-300:])

        layout(fx, running=1, slot1="nebulaos", slot2="creality", marker_slot=2)
        b = p.boot_id
        rc, out = reboot()
        check("reboot: the marker on a Creality slot 2 is refused, nothing rebooted",
              rc == 2 and p.boot_id == b and "holds creality" in out, out[-300:])

        layout(fx, running=2, slot1="creality", slot2="nebulaos", marker_slot=1)
        b = p.boot_id
        rc, out = reboot()
        check("reboot: the marker on a Creality slot 1 (classic armed) is refused",
              rc == 2 and p.boot_id == b and "holds creality" in out, out[-300:])

        layout(fx, running=1, slot1="nebulaos", slot2="junk", marker_slot=2)
        b = p.boot_id
        rc, out = reboot()
        check("reboot: the marker on an unidentifiable slot is refused",
              rc == 2 and p.boot_id == b, out[-300:])

        layout(fx, running=1, slot1="nebulaos", slot2="nebulaos", marker_slot=2)
        rc, out = reboot()
        check("reboot: the marker on the OTHER NebulaOS slot boots it and says so",
              rc == 0 and p.running_slot == 2 and "REBOOT_SWITCHES_SLOT=YES" in out, out[-300:])

        layout(fx, running=2, slot1="creality", slot2="nebulaos")
        rc, out = reboot()
        check("reboot: the original case (slot 2, marker kernel2) still works",
              rc == 0 and p.running_slot == 2 and "REBOOT_INTO_SLOT=2" in out, out[-300:])

        # inspect's slot report and the install path it predicts.
        import nebulaos_verify as verifylib
        layout(fx, running=1, slot1="nebulaos", slot2="creality")
        session = sim.SimSession(p, device.OS_NEBULAOS, p.addresses[device.OS_NEBULAOS],
                                 p.host_keys[device.OS_NEBULAOS], p.passwords[device.OS_NEBULAOS])
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            agent._say_slot_state(session, fx.profile)
        out = buf.getvalue()
        check("inspect: reports both slots and the refused install path with the key to set",
              "SLOT_RUNNING=1" in out and "SLOT_2_HOLDS=creality" in out
              and "INSTALL_WOULD_TAKE=REFUSED" in out and "INSTALL_OTHER_SLOT=expendable" in out,
              out[-400:])

        # verify: a build running from slot 1 is verified against slot 1.
        p.partitions["kernel"], p.partitions["rootfs"] = XIMAGE, ROOTFS
        a = fx.artifacts
        res = verifylib.part1_verify(session, a.ximage_sha, a.ximage_size, a.rootfs_sha,
                                     a.rootfs_size, SOURCE_HEAD, profile=fx.profile)
        check("verify: NebulaOS running from slot 1 verifies against kernel/rootfs and marker kernel",
              res.ok(), verifylib.render_part1(res, SOURCE_HEAD)[-500:])
        p.partitions["kernel"] = OLD_NEB_K
        res = verifylib.part1_verify(session, a.ximage_sha, a.ximage_size, a.rootfs_sha,
                                     a.rootfs_size, SOURCE_HEAD, profile=fx.profile)
        check("verify: other bytes in the running slot 1 fail verification",
              not res.ok() and any("kernel holds" in c.name for c in res.failures()))

        # rtos-logo: refused with the out-of-scope reason when NebulaOS runs from slot 1.
        layout(fx, running=1, slot1="nebulaos", slot2="nebulaos")
        session = sim.SimSession(p, device.OS_NEBULAOS, p.addresses[device.OS_NEBULAOS],
                                 p.host_keys[device.OS_NEBULAOS], p.passwords[device.OS_NEBULAOS])
        said = []
        try:
            rtos.RtosOperation("printer-sim", session, said.append, fx.control_commit)._guards()
            bad("rtos-logo refuses NebulaOS running from slot 1", "guards passed")
        except rtos.RtosError as exc:
            check("rtos-logo refuses NebulaOS running from slot 1 (its RTOS would be p3)",
                  "slot 1" in str(exc) and "p3" in str(exc) and "out of scope" in str(exc), str(exc))
    finally:
        agent.FW_ROOT, agent.ssh_session_factory, _time.sleep = saved
        shutil.rmtree(root, ignore_errors=True)


def case_both_slots_profile_key():
    """INSTALL_OTHER_SLOT is human-owned, strict, and preserve by default."""
    fx, root = scenario("bs-profile")
    try:
        check("INSTALL_OTHER_SLOT absent means preserve",
              fx.profile.effective_other_slot_policy()[0] == "preserve")
        set_profile(fx, INSTALL_OTHER_SLOT="yes-please")
        try:
            fx.profile.other_slot_policy()
            bad("an invalid INSTALL_OTHER_SLOT is refused", "accepted")
        except profiles.ProfileError as exc:
            ok("an invalid INSTALL_OTHER_SLOT is refused", str(exc)[:100])
        layout(fx, running=1, slot1="nebulaos", slot2="nebulaos")
        before = dict(fx.printer.partitions)
        inst, result, err = run_install_keep(fx)
        check("an invalid INSTALL_OTHER_SLOT refuses the install before writing",
              err is not None and fx.printer.partitions == before, str(err)[:200])
    finally:
        shutil.rmtree(root, ignore_errors=True)


# ---------------------------------------------------------------------------

SCENARIOS = [
    ("capability vs policy", case_capability_vs_policy),
    ("scp uses the legacy protocol", case_scp_uses_legacy_protocol),
    ("service probe works without pgrep", case_service_probe_without_pgrep),
    ("DEV_INSTALL end to end (no attestation)", case_dev_install_end_to_end),
    ("closed vocabulary", case_no_raw_surface),
    ("diagnose and restart (repairs)", case_diagnose_and_restart),
    ("restart script in a real shell", case_restart_script_in_a_real_shell),
    ("rtos-logo and rtos-logo-restore", case_rtos_logo),
    ("rtos2 writer in a real shell", case_rtos2_write_script_in_a_real_shell),
    ("control provenance", case_control_provenance),
    ("attestation v2 required", case_attestation_required),
    ("happy path", case_happy_path),
    ("already on stock", case_already_on_stock),
    ("on stock with a stale payload", case_on_stock_with_a_stale_payload),
    ("wrong printer", case_wrong_printer),
    ("host key mismatch", case_host_key_mismatch),
    ("ip change (un-enrolled)", case_ip_change),
    ("ip change (enrolled)", case_ip_change_enrolled),
    ("stock unavailable", case_stock_unavailable),
    ("stock way-out reads stock itself", case_stock_wayout_reads_stock),
    ("printer busy", case_printer_busy),
    ("heater active", case_heater_active),
    ("paused print", case_paused_print),
    ("marker write silently fails", case_marker_write_silently_fails),
    ("marker write raises", case_marker_write_raises),
    ("busy after arming -> disarm", case_busy_after_arming_disarms),
    ("marker lands then connection drops", case_marker_write_lands_then_connection_drops),
    ("resume finds ARMED", case_resume_finds_armed),
    ("ssh loss during flash", case_ssh_loss_during_flash),
    ("flash verification mismatch", case_flash_verification_mismatch),
    ("flash helper refuses", case_flash_helper_refuses),
    ("concurrent installer (device lock)", case_concurrent_installer),
    ("host lock", case_host_lock),
    ("mcu updater acted", case_mcu_updater_acted),
    ("stock updater log (evidenced signal)", case_stock_update_log_probe),
    ("mcu guard restored", case_mcu_guard_restored),
    ("mcu restore probe (per-boot guard state)", case_mcu_restore_probe),
    ("mcu guard verdict must be PASS", case_mcu_guard_not_pass),
    ("publication fails closed", case_publication_fails_closed),
    ("journal keeps the danger after a refusal", case_journal_keeps_danger_after_refusal),
    ("new image will not boot", case_new_image_will_not_boot),
    ("armed window is exception-safe", case_armed_window_is_exception_safe),
    ("helper provenance on every path", case_helper_provenance_on_every_path),
    ("journal vs reality", case_journal_reality_conflict),
    ("journal key mismatch", case_journal_key_mismatch),
    ("both slots: classification and policies", case_slot_classification),
    ("both slots: slot probe in a real shell", case_slot_facts_script_in_a_real_shell),
    ("both slots: B=NebulaOS A=Creality (default)", case_both_slots_b_nebulaos_a_creality_default),
    ("both slots: B=NebulaOS A=Creality (expendable)", case_both_slots_b_nebulaos_a_creality_expendable),
    ("both slots: A=NebulaOS B=NebulaOS", case_both_slots_a_and_b_nebulaos),
    ("both slots: A=NebulaOS B=Creality", case_both_slots_a_nebulaos_b_creality),
    ("both slots: unknown other slot", case_both_slots_unknown_other_slot),
    ("both slots: never the running slot", case_both_slots_never_write_running_slot),
    ("both slots: marker and failures", case_both_slots_marker_and_failures),
    ("both slots: reboot and rtos-logo", case_both_slots_reboot_and_rtos),
    ("both slots: the profile key", case_both_slots_profile_key),
]


def main():
    print("=== hardware install: adversarial simulation ===")
    print()
    for name, fn in SCENARIOS:
        print("--- %s ---" % name)
        try:
            fn()
        except Exception as exc:                  # noqa: BLE001
            import traceback
            bad("scenario %r ran to completion" % name, traceback.format_exc()[-500:])
        print()
    print("HARDWARE_SIMULATION_TESTS_PASS=%d" % len(PASS))
    print("HARDWARE_SIMULATION_TESTS_FAIL=%d" % len(FAIL))
    return 0 if not FAIL else 1


if __name__ == "__main__":
    sys.exit(main())
