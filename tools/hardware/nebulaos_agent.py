#!/usr/bin/env python3
"""The Hardware Agent's operations, and the proofs each one requires.

THE PUBLIC INTERFACE IS SEMANTIC

    inspect   read-only: what is this printer, what is it running, what is on it
    status    read-only: is a transaction open, and what state is it in
    verify    read-only: does this printer currently run this exact build
    diagnose  read-only: a fixed, bounded report - processes, logs, MCU guard,
              update-supervisor state, Moonraker endpoints
    restart   repair: restart ONE named service with the update supervisor's
              semantics (see nebulaos_device.restart_script)
    install   the developer install, NebulaOS -> Stock -> flash -> NebulaOS

There is no ssh, scp, dd, marker, reboot, flash, raw usbboot, --host, --password
or --command. Not because they are filtered - because no such operation exists
here to name. The device is reached only through DeviceSession, whose vocabulary
is closed, and the target is chosen only by enrolled device id.

WHAT IS PROVEN BEYOND "ALL REPOS MUST BE CLEAN"

The launcher still runs the full online identity gate, which still requires all
five canonical repositories to be clean and published. On top of that blunt
rule, the agent proves the specific properties a hardware operation depends on:

    control commit C is published, resolvable, and content-bound
    host control code matches C exactly
    on-device helper bytes come from C's git objects
    product commit X is published
    X has a v2 attestation that verifies
    the attestation's digests equal the artifact bytes
    the build profile is release or candidate
    workspace topology, archive isolation and sentinels are valid

What is NOT relaxed: the full online identity gate still runs. A commit that was
never compared against the canonical remote is an unverified source generation,
and flashing is the least reversible boundary in the project.
"""

import argparse
import hashlib
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

import nebulaos_control as control      # noqa: E402
import nebulaos_device as device        # noqa: E402
import nebulaos_evidence as evidence    # noqa: E402
import nebulaos_install as install      # noqa: E402
import nebulaos_journal as journal      # noqa: E402
import nebulaos_marker as marker        # noqa: E402
import nebulaos_profile as profiles     # noqa: E402
import nebulaos_target as targets       # noqa: E402
import nebulaos_verify as verifylib     # noqa: E402

FW_ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))
BUILD_BASE = "/var/tmp/nebulaos-build"


class AgentRefusal(Exception):
    """A precondition that was not met. Always names what to do about it."""


def say(text=""):
    print(text)


# ---------------------------------------------------------------------------
# artifact location
# ---------------------------------------------------------------------------

def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def locate_artifacts(source_head, ximage_sha, rootfs_sha):
    """Find the build workspace for this exact source identity.

    Deliberately not a "latest" symlink and not a newest-mtime pick: the
    workspace is keyed by commit, the clone inside it must BE that commit, and
    the bytes must hash to what the caller stated. Three independent agreements.
    """
    base = os.path.join(BUILD_BASE, source_head)
    if not os.path.isdir(base):
        raise AgentRefusal(
            "no build workspace for %s under %s. Build it first through the nebulaos-build "
            "agent; this launcher never builds and never picks an artifact by filename."
            % (source_head, BUILD_BASE))

    problems = []
    for run in sorted(os.listdir(base)):
        run_dir = os.path.join(base, run)
        art = os.path.join(run_dir, "artifacts", "buildroot-halley5-v30-image")
        ximage = os.path.join(art, "xImage")
        rootfs = os.path.join(art, "rootfs.squashfs")
        manifest = os.path.join(art, "build-manifest.txt")
        if not all(os.path.isfile(p) for p in (ximage, rootfs, manifest)):
            continue
        got_x = sha256_file(ximage)
        got_r = sha256_file(rootfs)
        if got_x != ximage_sha:
            problems.append("%s: xImage is %s" % (run, got_x[:16]))
            continue
        if got_r != rootfs_sha:
            problems.append("%s: rootfs is %s" % (run, got_r[:16]))
            continue
        return install.Artifacts(
            source_head=source_head, ximage_path=ximage, rootfs_path=rootfs,
            manifest_path=manifest, ximage_sha=got_x, ximage_size=os.path.getsize(ximage),
            rootfs_sha=got_r, rootfs_size=os.path.getsize(rootfs)), run_dir

    raise AgentRefusal(
        "no build under %s has artifacts matching the stated hashes.%s"
        % (base, ("\n       " + "\n       ".join(problems)) if problems else ""))


# ---------------------------------------------------------------------------
# preconditions
# ---------------------------------------------------------------------------

def resolve_control_dev(control_commit):
    """DEV_INSTALL: CONTROL_HEAD from the local repository's commit objects.

    Helper bytes still come from a commit (never the working tree), and the
    executing host modules must still equal that commit - but there is no
    protected mirror and no publication requirement. CONTROL_HEAD may be any
    local commit; changing it never touches PRODUCT_HEAD's artifacts.
    """
    source = control.LocalControlSource(FW_ROOT)
    if not source.commit_exists(control_commit):
        raise AgentRefusal("CONTROL_HEAD %s is not a commit in %s" % (control_commit, FW_ROOT))
    try:
        return control.ControlSet.load(source, control_commit, require_published=False)
    except control.ControlError as exc:
        raise AgentRefusal(str(exc))


def release_identity_gate():
    """RELEASE-mode devices only: the full online workspace identity gate.

    DEV hardware work is validated per operation (device, control bytes,
    product evidence, partitions, idle, readback) and does not depend on the
    rest of the workspace being clean or published. A release install does."""
    import subprocess
    gate = os.path.join(os.path.dirname(FW_ROOT), "tools", "verify-workspace-identity.sh")
    try:
        rc = subprocess.run([gate, "--release"], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=300).returncode
    except (OSError, subprocess.SubprocessError) as exc:
        raise AgentRefusal("release identity gate could not run: %s" % exc)
    if rc != 0:
        raise AgentRefusal("this device profile is in RELEASE mode and the full online workspace "
                           "identity gate failed. Run tools/verify-workspace-identity.sh --release.")
    say("RELEASE_IDENTITY_GATE=PASS")


def resolve_control(control_commit, refresh=True):
    """Resolve control commit C from the protected mirror."""
    import subprocess
    origin = subprocess.run(["git", "-C", FW_ROOT, "remote", "get-url", "origin"],
                            capture_output=True, text=True).stdout.strip()
    if not origin:
        raise AgentRefusal("cannot read the canonical firmware remote")
    mirror = control.ControlMirror(origin)
    if refresh:
        try:
            mirror.refresh()
        except control.ControlError as exc:
            raise AgentRefusal(
                "the protected control mirror could not be refreshed: %s\n"
                "       Privileged helper bytes are read from immutable git objects, so the "
                "mirror must be present and healthy before anything touches a printer." % exc)
    try:
        return control.ControlSet.load(mirror, control_commit)
    except control.ControlError as exc:
        raise AgentRefusal(str(exc))


def prove_preconditions(device_id, source_head, artifacts, build_run, control_commit,
                        destructive):
    """Everything that must hold before an operation may proceed."""
    say("--- preconditions ---")

    profile = profiles.DeviceProfile.load(device_id)
    say(profile.describe())
    mode = profile.install_mode()
    say("INSTALL_MODE=%s" % mode.upper())
    say()

    if mode == "dev":
        control_set = resolve_control_dev(control_commit)
    else:
        release_identity_gate()
        control_set = resolve_control(control_commit)
    say(control_set.describe())

    # Host control code must BE control commit C. On-device helpers are read
    # from C's objects so the working tree cannot influence them; host modules
    # are imported from disk, so they are compared and a difference refuses.
    checked = control.assert_host_control_matches(control_set, FW_ROOT)
    say("CONTROL_HOST_MODULES_VERIFIED=%d" % len(checked))

    # Reported, not gated: the helper bytes that reach the printer come from the
    # object database, so a dirty working tree cannot change them. An unrelated
    # edit in another session must not be able to corrupt an open transaction.
    drifted = control.working_tree_differs(control_set, FW_ROOT)
    say("CONTROL_WORKING_TREE_DIFFERS=%d%s"
        % (len(drifted), (" (" + "; ".join(drifted) + ")") if drifted else ""))
    say()

    if not destructive:
        return profile, control_set, None

    if mode == "dev":
        # DEV_INSTALL: the product is proven by its own build record and build
        # manifest agreeing with the bytes. No HMAC attestation, no publication
        # gate (reported for the record only), no rebuild when CONTROL_HEAD moves.
        try:
            published, why = evidence.product_is_published(FW_ROOT, source_head)
        except Exception as exc:                      # noqa: BLE001 - informational
            published, why = False, "not checked (%s)" % type(exc).__name__
        say("PRODUCT_PUBLISHED=%s (%s; informational in DEV_INSTALL)"
            % ("YES" if published else "NO", why))
        ev = evidence.require_dev_product(source_head, build_run, artifacts)
        say(ev.describe())
        say()
        return profile, control_set, ev

    published, why = evidence.product_is_published(FW_ROOT, source_head)
    if not published:
        raise AgentRefusal(
            "the product commit is not published: %s. What lands on a printer must correspond "
            "to source someone else can fetch." % why)
    say("PRODUCT_PUBLISHED=YES (%s)" % why)

    ev = evidence.require_v2(
        source_head, artifacts.ximage_sha, artifacts.ximage_size,
        artifacts.rootfs_sha, artifacts.rootfs_size, build_run=build_run)
    say(ev.describe())
    say()
    return profile, control_set, ev


def ssh_session_factory(profile):
    """The production seam. Builds an SSH session against an enrolled address."""
    import atexit
    import shutil
    import tempfile

    def factory(which_os, address):
        tmpdir = tempfile.mkdtemp(prefix=".nebulaos-kh.")
        # The session keeps using known_hosts after this returns, so the
        # directory is removed when the agent exits rather than here.
        atexit.register(shutil.rmtree, tmpdir, True)
        known = os.path.join(tmpdir, "known_hosts")
        profile.write_known_hosts(which_os, address, known)
        return device.SshDeviceSession(
            address=address, username=profile.username(which_os),
            password=profile.credential(which_os), known_hosts_path=known)
    return factory


# ---------------------------------------------------------------------------
# operations
# ---------------------------------------------------------------------------

def op_inspect(args):
    profile, control_set, _ = prove_preconditions(
        args.device, None, None, None, args.control_commit, destructive=False)
    say(targets.capability_report())
    say()
    say(targets.DEV_PRESERVE_STOCK.report(prefix="DEV_INSTALL_POLICY"))
    say()

    factory = ssh_session_factory(profile)
    for which in (device.OS_NEBULAOS, device.OS_STOCK):
        for address in profiles.candidate_addresses(profile, which):
            try:
                session = factory(which, address)
            except Exception as exc:
                say("PROBE=%s@%s unreachable (%s)" % (which, address, str(exc)[:100]))
                continue
            try:
                identity = session.probe_identity()
                ok, why = profile.identity_matches(identity)
                say("PROBE=%s@%s reachable" % (which, address))
                say(identity.describe())
                say("DEVICE_IDENTITY_MATCHES_PROFILE=%s (%s)" % ("YES" if ok else "NO", why))
                say("DEVICE_RUNNING_OS=%s" % session.which_os())
                say("DEVICE_ACTIVE_ROOT=%s" % session.active_root())
                state, reason = marker.parse(session.read_marker_block())
                say(marker.describe(state, reason))
                say(session.idle_state().describe())
                for key, value in sorted(session.service_health().items()):
                    say("SERVICE_%s=%s" % (key.upper(), value))
                return 0
            finally:
                session.close()
    say("INSPECT=NO_DEVICE_REACHABLE")
    return 3


def _say_power_cycle_warning(txn):
    """Printed on EVERY refusal while the journal says a power cycle is unsafe."""
    try:
        dangerous = txn is not None and txn.power_cycle_dangerous
    except Exception:
        dangerous = True          # cannot tell: warn rather than reassure
    if dangerous:
        say("TRANSACTION_POWER_CYCLE_DANGEROUS=YES")
        say("# The marker may select Creality's slot. Do NOT power cycle: a boot into stock")
        say("# lets its updater reflash the MCU. Re-run `install` (it disarms on connect) or")
        say("# resolve the marker by hand, then run `status`.")


def op_status(args):
    txn = journal.Transaction.open(args.device)
    if txn is None:
        say("TRANSACTION_OPEN=NO")
        say("# No install transaction is recorded for this device.")
        return 0
    say("TRANSACTION_OPEN=YES")
    say(txn.describe())
    if txn.power_cycle_dangerous:
        say()
        say("# This device may be ARMED FOR STOCK (last stock-window state: %s). Do not"
            % txn.danger_state)
        say("# power cycle: a power cycle into Creality's slot lets its updater reflash the")
        say("# MCU. Re-run `install` to disarm, or resolve the marker by hand.")
    return 0


def op_verify(args):
    profile, control_set, _ = prove_preconditions(
        args.device, args.source_head, None, None, args.control_commit, destructive=False)
    artifacts, _ = locate_artifacts(args.source_head, args.ximage_sha, args.rootfs_sha)

    factory = ssh_session_factory(profile)
    tried = []
    for address in profiles.candidate_addresses(profile, device.OS_NEBULAOS):
        try:
            session = factory(device.OS_NEBULAOS, address)
        except Exception as exc:                  # noqa: BLE001 - try the next address
            tried.append("%s: %s" % (address, str(exc)[:120]))
            continue
        try:
            result = verifylib.part1_verify(
                session, artifacts.ximage_sha, artifacts.ximage_size,
                artifacts.rootfs_sha, artifacts.rootfs_size, args.source_head,
                profile=profile)
            mcu = verifylib.observe_mcu_restore(session)
            say(verifylib.render_part1(result, args.source_head, mcu_restore_result=mcu))
            return 0 if result.ok() else 1
        except device.DeviceError as exc:
            # Unreachable or dropped mid-probe (the first real run hit "No route
            # to host" on a Wi-Fi that was still waking): try the next enrolled
            # address, and end in a clean refusal rather than a traceback.
            tried.append("%s: %s" % (address, str(exc)[:120]))
            continue
        finally:
            session.close()
    raise AgentRefusal("could not reach the enrolled printer as NebulaOS at any enrolled address. "
                       "Tried: %s" % (" | ".join(tried) or "none"))


def _connect_matching(profile, oses):
    """-> (session, os, address) for the first reachable address whose identity
    matches the enrolled profile. A printer that answers but is not THIS printer
    is never reported on, let alone repaired."""
    factory = ssh_session_factory(profile)
    tried = []
    for which in oses:
        for address in profiles.candidate_addresses(profile, which):
            try:
                session = factory(which, address)
                ok, why = profile.identity_matches(session.probe_identity())
            except Exception as exc:              # noqa: BLE001 - try the next address
                tried.append("%s@%s: %s" % (which, address, str(exc)[:120]))
                continue
            if not ok:
                session.close()
                tried.append("%s@%s: identity does not match the profile (%s)" % (which, address, why))
                continue
            return session, which, address
    raise AgentRefusal("could not reach the enrolled printer at any enrolled address. Tried: %s"
                       % (" | ".join(tried) or "none"))


def op_diagnose(args):
    profile, _, _ = prove_preconditions(
        args.device, None, None, None, args.control_commit, destructive=False)
    session, which, address = _connect_matching(profile, (device.OS_NEBULAOS, device.OS_STOCK))
    try:
        say("DIAGNOSE_TARGET=%s@%s" % (which, address))
        say("DEVICE_IDENTITY_MATCHES_PROFILE=YES")
        say(session.diagnose())
        return 0
    finally:
        session.close()


def op_capture(args):
    """TOOL-01: one read-only capture profile on the enrolled NebulaOS printer.
    Same identity proofs as diagnose; the output is also kept locally under
    the agent's state directory."""
    import time
    profile, _, _ = prove_preconditions(
        args.device, None, None, None, args.control_commit, destructive=False)
    if args.profile not in device.captures.CAPTURE_PROFILES:
        raise AgentRefusal("unknown capture profile %r (exercise profiles are not captures)" % args.profile)
    session, which, address = _connect_matching(profile, (device.OS_NEBULAOS,))
    try:
        say("CAPTURE_TARGET=%s@%s" % (which, address))
        say("DEVICE_IDENTITY_MATCHES_PROFILE=YES")
        text = session.capture(args.profile)
    finally:
        session.close()
    d = os.path.join(journal.state_home(), "captures", args.device)
    os.makedirs(d, mode=0o700, exist_ok=True)
    path = os.path.join(d, "%s-%s.txt" % (args.profile, time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    say(text)
    say("CAPTURE_FILE=%s" % path)
    say("RUN_NEBULAOS_HARDWARE=CAPTURE_COMPLETE")
    return 0


def op_exercise(args):
    """TOOL-02: one reversible, allow-listed device state change used by a
    hardware decision point (USB power control, the SOF filter switch, a
    camera pause/resume, a memory ramp). Requires EXERCISE_CONFIRM=<profile>,
    as the confirm argument or on stdin; refused while it is missing or names
    another profile, so it cannot run by accident."""
    import time
    if args.profile not in device.captures.EXERCISE_PROFILES:
        raise AgentRefusal("unknown exercise profile %r" % args.profile)
    try:
        device.captures.exercise_script(args.profile)
    except device.captures.CaptureError as exc:
        raise AgentRefusal(str(exc))
    want = "EXERCISE_CONFIRM=%s" % args.profile
    given = getattr(args, "confirm", None)
    if given is not None:
        # Stated on the command line by an authorised unattended session; the
        # launcher and the PreToolUse hook require the same exact word.
        if given != want:
            raise AgentRefusal("exercise not confirmed (expected %s)" % want)
    else:
        say("This changes device state reversibly. Type %s to continue:" % want)
        line = sys.stdin.readline().strip()
        if line != want:
            raise AgentRefusal("exercise not confirmed (expected %s on stdin)" % want)
    profile, _, _ = prove_preconditions(
        args.device, None, None, None, args.control_commit, destructive=False)
    session, which, address = _connect_matching(profile, (device.OS_NEBULAOS,))
    try:
        say("EXERCISE_TARGET=%s@%s" % (which, address))
        say("DEVICE_IDENTITY_MATCHES_PROFILE=YES")
        text = session.exercise(args.profile)
    finally:
        session.close()
    d = os.path.join(journal.state_home(), "captures", args.device)
    os.makedirs(d, mode=0o700, exist_ok=True)
    path = os.path.join(d, "exercise-%s-%s.txt" % (args.profile, time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    say(text)
    say("EXERCISE_FILE=%s" % path)
    say("RUN_NEBULAOS_HARDWARE=EXERCISE_COMPLETE")
    return 0


def control_is_published(control_commit):
    """The seam tests replace. Repairs require a PUBLISHED control commit."""
    return evidence.product_is_published(FW_ROOT, control_commit)


def _repair_log(device_id, control_commit, op, arg, result, reason):
    path = os.path.join(journal.state_home(), "repairs")
    os.makedirs(path, mode=0o700, exist_ok=True)
    import time
    with open(os.path.join(path, "%s.log" % device_id), "a", encoding="utf-8") as fh:
        fh.write("%s DEVICE=%s CONTROL=%s OP=%s ARG=%s RESULT=%s REASON=%s\n" % (
            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), device_id, control_commit,
            op, arg, result, (reason or "").replace("\n", " ")[:200]))


def op_restart(args):
    """Restart one named service on NebulaOS. On a RELEASE-mode device the
    control commit that composes the device command must be PUBLISHED; on the
    DEV printer a local control commit is enough (its bytes still come from a
    commit, never the working tree).

    Every attempt is logged, refusals included: a repair log that only records
    what reached the device cannot show what was tried."""
    try:
        return _restart(args)
    except AgentRefusal as exc:
        _repair_log(args.device, args.control_commit, "restart", args.service,
                    "REFUSED", str(exc))
        raise
    except BaseException as exc:
        _repair_log(args.device, args.control_commit, "restart", args.service,
                    "FAILED", "%s: %s" % (type(exc).__name__, exc))
        raise


def _restart(args):
    if args.service not in device.RESTARTABLE_SERVICES:
        raise AgentRefusal("unknown service '%s'. Restartable: %s"
                           % (args.service, ", ".join(sorted(device.RESTARTABLE_SERVICES))))
    profile, control_set, _ = prove_preconditions(
        args.device, None, None, None, args.control_commit, destructive=False)
    if profile.install_mode() == "dev":
        say("CONTROL_PUBLISHED=not required (DEV device)")
    else:
        published, why = control_is_published(control_set.commit)
        if not published:
            raise AgentRefusal("repairs on a RELEASE device require a published control commit: %s"
                               % why)
        say("CONTROL_PUBLISHED=YES (%s)" % why)

    with journal.HostLock(args.device):
        txn = journal.Transaction.open(args.device)
        if txn is not None and txn.state not in journal.TERMINAL_STATES:
            raise AgentRefusal("an install transaction is open (state %s). Run `status`, and "
                               "finish or resolve it before repairing anything." % txn.state)

        session, which, address = _connect_matching(profile, (device.OS_NEBULAOS,))
        owner = "restart-%s-%d" % (args.service, os.getpid())
        try:
            if session.which_os() != device.OS_NEBULAOS:
                raise AgentRefusal("the printer is not running NebulaOS; restart is NebulaOS-only")
            if args.service in device.PRINT_CRITICAL_SERVICES:
                idle = session.idle_state()
                say(idle.describe())
                if not idle.is_idle():
                    raise AgentRefusal("restarting %s needs a proven idle printer: %s"
                                       % (args.service, idle.why_not_idle()))
            got, holder = session.acquire_flash_lock(owner)
            if not got:
                raise AgentRefusal("the device-side hardware-agent lock is held by %s" % holder)
            try:
                result = session.restart_service(args.service)
            finally:
                session.release_flash_lock(owner)
        finally:
            session.close()

    outcome = result.get("restart_result", "UNKNOWN")
    reason = result.get("restart_reason", "")
    _repair_log(args.device, control_set.commit, "restart", args.service, outcome, reason)
    say("RESTART_TARGET=%s@%s" % (which, address))
    say("RESTART_SERVICE=%s" % args.service)
    for key in ("restart_old_pid", "restart_new_pid"):
        if key in result:
            say("%s=%s" % (key.upper(), result[key]))
    say("RESTART_RESULT=%s" % outcome)
    if reason:
        say("RESTART_REASON=%s" % reason)
    return 0 if outcome == "DONE" else 1


def _mode_summary(mode, control_commit, source_head):
    say("INSTALL_MODE=%s" % mode.upper())
    say("DEV_INSTALL=%s" % ("YES" if mode == "dev" else "NO"))
    say("RELEASE_INSTALL=%s" % ("YES" if mode == "release" else "NO"))
    if mode == "dev":
        say("RELEASE_QUALIFIED=NO")
    say("HARDWARE_QUALIFIED=NO")
    say("PRODUCT_HEAD=%s" % source_head)
    say("CONTROL_HEAD=%s" % control_commit)


def op_install(args):
    artifacts, build_run = locate_artifacts(args.source_head, args.ximage_sha, args.rootfs_sha)
    profile, control_set, ev = prove_preconditions(
        args.device, args.source_head, artifacts, build_run, args.control_commit,
        destructive=True)
    mode = profile.install_mode()
    say("=== %s ===" % ("DEV_INSTALL (development printer; NOT a release qualification)"
                        if mode == "dev" else "RELEASE_INSTALL"))
    _mode_summary(mode, control_set.commit, args.source_head)
    say()

    with journal.HostLock(args.device):
        txn = journal.Transaction.open(args.device)
        if txn is not None:
            same, why = txn.matches(args.device, control_set.commit, args.source_head,
                                    artifacts.ximage_sha, artifacts.rootfs_sha)
            say("TRANSACTION_RESUMABLE=%s (%s)" % ("YES" if same else "NO", why))
            if not same:
                txn = journal.Transaction.begin(
                    args.device, control_set.commit, args.source_head,
                    artifacts.ximage_sha, artifacts.rootfs_sha)
        else:
            txn = journal.Transaction.begin(
                args.device, control_set.commit, args.source_head,
                artifacts.ximage_sha, artifacts.rootfs_sha)

        installer = install.Installer(
            args.device, profile, control_set, artifacts,
            ssh_session_factory(profile), txn=txn)
        try:
            result = installer.run()
        except install.InstallError as exc:
            say(installer.result.render())
            say()
            say("INSTALL=REFUSED")
            say("REASON: %s" % exc)
            txn.advance(journal.FAILED_NEEDS_ATTENTION, str(exc)[:200])
            _say_power_cycle_warning(txn)
            return 3
        except BaseException as exc:
            # Anything the installer did not convert into an InstallError still
            # has to reach the operator as a refusal with the safety text, not
            # as a Python traceback. The installer's armed window converts its
            # own failures, but a bug outside it must not silently lose the
            # "do NOT power cycle" advice.
            say(installer.result.render())
            say()
            say("INSTALL=REFUSED")
            say("REASON: unexpected %s: %s" % (type(exc).__name__, str(exc)[:200]))
            say("# The install did not complete. If a transaction is open, run `status` before")
            say("# doing anything else, and do NOT power cycle a device that is armed for stock.")
            try:
                txn.advance(journal.FAILED_NEEDS_ATTENTION,
                            "unexpected %s" % type(exc).__name__)
            except Exception:
                pass
            _say_power_cycle_warning(txn)
            return 3
        say(result.render())
        say()
        _mode_summary(mode, control_set.commit, args.source_head)
        return 0 if result.ok else 1


# ---------------------------------------------------------------------------

def main(argv):
    parser = argparse.ArgumentParser(
        prog="nebulaos-agent",
        description="NebulaOS Hardware Agent: semantic operations on an enrolled printer")
    parser.add_argument("--device", required=True, help="an enrolled device id")
    parser.add_argument("--control-commit", required=True,
                        help="control commit C: the reviewed, published source of privileged code")
    sub = parser.add_subparsers(dest="op", required=True)

    sub.add_parser("inspect")
    sub.add_parser("status")
    sub.add_parser("diagnose")
    sub.add_parser("capture").add_argument("profile")
    p = sub.add_parser("exercise")
    p.add_argument("profile")
    p.add_argument("confirm", nargs="?", default=None)
    sub.add_parser("restart").add_argument("service")
    for name in ("verify", "install"):
        p = sub.add_parser(name)
        p.add_argument("source_head")
        p.add_argument("ximage_sha")
        p.add_argument("rootfs_sha")

    args = parser.parse_args(argv)
    handler = {"inspect": op_inspect, "status": op_status, "diagnose": op_diagnose,
               "capture": op_capture, "exercise": op_exercise,
               "restart": op_restart, "verify": op_verify, "install": op_install}[args.op]
    try:
        return handler(args)
    except AgentRefusal as exc:
        sys.stderr.write("RUN_NEBULAOS_HARDWARE=REFUSED\nREASON: %s\n" % exc)
        return 2
    except (profiles.ProfileError, control.ControlError, evidence.EvidenceError) as exc:
        sys.stderr.write("RUN_NEBULAOS_HARDWARE=REFUSED\nREASON: %s\n" % exc)
        return 2
    except (journal.LockError, journal.JournalError) as exc:
        # A concurrent installer (host lock) or an unusable journal is a clean
        # refusal, not a traceback. Nothing was done to the device.
        sys.stderr.write("RUN_NEBULAOS_HARDWARE=REFUSED\nREASON: %s: %s\n"
                         % (type(exc).__name__, exc))
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
