#!/usr/bin/env python3
"""Behavioral tests for mcu_lifecycle.py / mcu_restore.py's decision logic.

These replace grep-based structural assertions with real invocations of
decide()/restore() against fully mocked application-identify and
creality_flash collaborators - no serial hardware, no real MCU, no real
flash. Covers the 11 test cases from the Phase 1.8B pre-build review
mission (CASE 1-11).

Run: python3 tests/mcu-lifecycle-decision-tests.py
"""

import os
import sys
import unittest

HELPER_DIR = os.path.join(
    os.path.dirname(__file__), "..",
    "scripts", "build", "overlay", "etc", "nebulaos")
sys.path.insert(0, os.path.abspath(HELPER_DIR))

import mcu_known_identities as known  # noqa: E402
import mcu_lifecycle as lifecycle  # noqa: E402
import mcu_restart as restart_mod  # noqa: E402
import mcu_restore as restore_mod  # noqa: E402

NATIVE_VERSION = known.NATIVE_CANDIDATE_001_VERSION
STOCK_VERSION = known.KNOWN_STOCK_VERSIONS[0]
UNKNOWN_VERSION = "v0.99.0-1-gdeadbeef"
GOOD_HW_ID = "mcu0_001_G32-mcu0_005_000"
BAD_HW_ID = "mcu0_002_XYZ-mcu0_001_000"


class FakeFlashError(Exception):
    pass


class FakeCrealityFlash:
    """Mocks the parts of creality_flash.py mcu_lifecycle.py/mcu_restore.py
    actually call - never a real serial port. Covers both the OLD magic-
    sequence path (identify()/flash(), still used as mcu_restore.py's
    fallback when the new restart-command mechanism is refused or fails)
    and the Phase 1.8B Option C path (handshake()/get_version()/
    get_sector_size()/flash_image()/app_start(), used directly by
    mcu_restore.py once bootloader entry succeeds - see that module's
    docstring for why it uses these low-level primitives instead of the
    identify()/flash() wrappers, which would attempt a redundant magic-
    sequence entry on top of an already-entered bootloader)."""

    FlashError = FakeFlashError
    DEFAULT_ALLOWED_HW_IDS = (GOOD_HW_ID.split("-")[0],)

    def __init__(self, hw_id=GOOD_HW_ID, bootloader_reachable=True,
                 flash_should_succeed=True):
        self.hw_id = hw_id
        self.bootloader_reachable = bootloader_reachable
        self.flash_should_succeed = flash_should_succeed
        self.app_start_calls = 0
        self.handshake_calls = 0
        self.flash_calls = []

    # --- OLD magic-sequence path (fallback only, post-Option-C) ---
    def identify(self, transport):
        if not self.bootloader_reachable:
            raise FakeFlashError("could not enter Creality serial bootloader")
        return self.hw_id

    def flash(self, transport, image_path):
        self.flash_calls.append(image_path)
        if not self.flash_should_succeed:
            raise FakeFlashError("simulated flash failure")

    # --- Option C path: low-level primitives used after restart-command
    # bootloader entry ---
    def handshake(self, transport):
        self.handshake_calls += 1
        return self.bootloader_reachable

    def get_version(self, transport):
        if not self.bootloader_reachable:
            raise FakeFlashError("version response short read")
        return self.hw_id

    def get_sector_size(self, transport):
        return 2

    def flash_image(self, transport, image, sector_size):
        self.flash_calls.append(image)
        return self.flash_should_succeed

    # --- shared by both paths ---
    def app_start(self, transport):
        self.app_start_calls += 1
        return True

    def check_identity(self, version_string, allowed=None):
        allowed = allowed or self.DEFAULT_ALLOWED_HW_IDS
        hw_part = version_string.split("-")[0] if "-" in version_string else version_string
        return hw_part in allowed


def make_identify_fn(version=None, should_fail=False):
    def _identify(port, baud):
        if should_fail:
            raise Exception("simulated_serial_timeout")
        return version, "fake_build_versions"
    return _identify


def make_restart_fn(should_succeed=True, command_name="reset",
                     refused=False):
    """Fake for mcu_restore.restore()'s restart_fn param - stands in for
    mcu_restart.request_generic_restart() without any real serial I/O."""
    def _restart_fn(port, baud):
        if refused:
            raise restart_mod.RestartRequestRefused(
                "simulated: MCU dictionary has neither reset nor config_reset")
        if not should_succeed:
            raise restart_mod.RestartRequestError("simulated_connection_failure")
        return command_name
    return _restart_fn


class FakeTransport:
    """Minimal stand-in with the two methods mcu_lifecycle.py actually
    calls on a transport (set_baudrate is called unconditionally after
    entering the bootloader, to switch to app_start's expected baud)."""
    def set_baudrate(self, baud):
        pass


def transport_factory_stub():
    return FakeTransport()


class DecideTests(unittest.TestCase):
    def test_case1_native_already_installed(self):
        """CASE 1: supported KE HW, native candidate already installed ->
        no erase, no write, PASS."""
        cf = FakeCrealityFlash()
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION))
        self.assertEqual(d.state, lifecycle.SUPPORTED_HW_NATIVE_APP)
        self.assertEqual(d.action, lifecycle.ALLOW_KLIPPER_START)
        self.assertEqual(cf.flash_calls, [])
        # Bootloader must never be entered for the already-healthy case.
        self.assertEqual(cf.app_start_calls, 0)

    def test_case2_known_stock_authorizes_restore(self):
        """CASE 2: exact known-stock application identity -> restore
        authorized directly (Stage 1, software gate only). Phase 1.8B
        Option C (2026-08-28): decide() no longer enters the bootloader for
        this case at all - that (Stage 2, the hardware gate) now happens
        inside restore(), via the new restart-command mechanism, only as
        part of an actual restore attempt. So the bootloader must NOT be
        touched here (app_start_calls stays 0), and hw_id_status reflects
        that the hardware check is deferred, not skipped."""
        cf = FakeCrealityFlash(hw_id=GOOD_HW_ID)
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(STOCK_VERSION))
        self.assertEqual(d.state, lifecycle.SUPPORTED_HW_KNOWN_STOCK_APP)
        self.assertEqual(d.action, lifecycle.RESTORE_AUTHORIZED)
        self.assertEqual(cf.app_start_calls, 0)
        self.assertEqual(d.hw_id_status, "not_checked_pending_restore")

    def test_case3_unknown_application_never_flashes(self):
        """CASE 3: supported KE HW, unknown application -> no erase, no
        write, safe refusal (WARN, not silently PASS)."""
        cf = FakeCrealityFlash(hw_id=GOOD_HW_ID)
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(UNKNOWN_VERSION))
        self.assertEqual(d.state, lifecycle.SUPPORTED_HW_UNKNOWN_APP)
        self.assertEqual(d.action, lifecycle.ALLOW_KLIPPER_START_WARN)
        self.assertEqual(cf.flash_calls, [])

    def test_case4_known_stock_hardware_check_deferred_to_restore(self):
        """CASE 4 (revised for Option C, 2026-08-28): for a known-stock
        application, decide() no longer checks hardware identity at all -
        it authorizes restore() unconditionally on application identity
        alone, deferring the hardware-ID check (and therefore the
        "unsupported HW -> no flash" enforcement) to restore() itself,
        after bootloader entry. See RestoreTests.
        test_restore_never_flashes_on_hardware_mismatch_after_restart for
        the actual enforcement test - this test only documents that
        decide() itself does not (and must not) reach a verdict about
        hardware support for this application class."""
        cf = FakeCrealityFlash(hw_id=BAD_HW_ID)
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(STOCK_VERSION))
        self.assertEqual(d.state, lifecycle.SUPPORTED_HW_KNOWN_STOCK_APP)
        self.assertEqual(d.action, lifecycle.RESTORE_AUTHORIZED)
        self.assertEqual(cf.flash_calls, [])

    def test_case4b_unsupported_hardware_even_with_unknown_app(self):
        """Hardware mismatch must block regardless of application class."""
        cf = FakeCrealityFlash(hw_id=BAD_HW_ID)
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(UNKNOWN_VERSION))
        self.assertEqual(d.state, lifecycle.UNSUPPORTED_HW)
        self.assertEqual(d.action, lifecycle.BLOCK_KLIPPER_START)

    def test_case5_mcu_unreachable_no_stock_fallback(self):
        """CASE 5: MCU unreachable -> no stock fallback, no infinite retry
        (decide() makes exactly one attempt)."""
        cf = FakeCrealityFlash(bootloader_reachable=False)
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(None, should_fail=True))
        self.assertEqual(d.state, lifecycle.MCU_UNREACHABLE)
        self.assertEqual(d.action, lifecycle.ALLOW_KLIPPER_START_WARN)
        self.assertEqual(cf.flash_calls, [])

    def test_hw_id_never_checked_for_native_app(self):
        """A native-app connection must never be disturbed by a bootloader
        entry attempt it doesn't need - regression guard for the original
        conflation bug."""
        cf = FakeCrealityFlash()
        lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION))
        self.assertEqual(cf.app_start_calls, 0,
                          "bootloader must not be entered for a healthy native app")

    def test_bootloader_hw_id_alone_never_implies_native_app(self):
        """Direct regression test for the conflation bug: a bootloader
        hw-id match by itself must never produce SUPPORTED_HW_NATIVE_APP -
        only an actual matching application identity can."""
        cf = FakeCrealityFlash(hw_id=GOOD_HW_ID)
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(STOCK_VERSION))
        self.assertNotEqual(d.state, lifecycle.SUPPORTED_HW_NATIVE_APP)


class RestoreTests(unittest.TestCase):
    def _fake_files(self, exists=True, sha=known.NATIVE_CANDIDATE_001_SHA256):
        return (lambda path: exists), (lambda path: sha)

    def test_case6_candidate_missing(self):
        """CASE 6: candidate missing -> no flash."""
        cf = FakeCrealityFlash()
        exists_fn, hash_fn = self._fake_files(exists=False)
        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION),
            file_exists_fn=exists_fn, hash_fn=hash_fn,
            read_bytes_fn=lambda path: b"fake-image-bytes")
        self.assertEqual(r.state, restore_mod.CANDIDATE_ARTIFACT_MISSING)
        self.assertEqual(cf.flash_calls, [])

    def test_case7_candidate_hash_mismatch(self):
        """CASE 7: candidate hash mismatch -> no flash."""
        cf = FakeCrealityFlash()
        exists_fn, hash_fn = self._fake_files(sha="0" * 64)
        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION),
            file_exists_fn=exists_fn, hash_fn=hash_fn,
            read_bytes_fn=lambda path: b"fake-image-bytes")
        self.assertEqual(r.state, restore_mod.CANDIDATE_HASH_BAD)
        self.assertEqual(cf.flash_calls, [])

    def test_case8_flash_failure_is_bounded(self):
        """CASE 8: flash failure -> bounded failure (exactly one attempt),
        diagnostics preserved."""
        cf = FakeCrealityFlash(flash_should_succeed=False)
        exists_fn, hash_fn = self._fake_files()
        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION),
            file_exists_fn=exists_fn, hash_fn=hash_fn,
            read_bytes_fn=lambda path: b"fake-image-bytes")
        self.assertEqual(r.state, restore_mod.FLASH_FAILED)
        self.assertEqual(len(cf.flash_calls), 1, "exactly one flash attempt, no retry loop")

    def test_case9_restore_succeeds_and_verifies_application_identity(self):
        """CASE 9: restore succeeds -> post-flash application identity ==
        candidate-001, not merely 'flash reported success'."""
        cf = FakeCrealityFlash(flash_should_succeed=True)
        exists_fn, hash_fn = self._fake_files()
        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION),
            file_exists_fn=exists_fn, hash_fn=hash_fn,
            read_bytes_fn=lambda path: b"fake-image-bytes")
        self.assertEqual(r.state, restore_mod.RESTORED_AND_VERIFIED)

    def test_case9b_flash_succeeds_but_post_verify_identity_wrong(self):
        """Flash reporting success is NOT sufficient - if the post-flash
        identify doesn't actually show candidate-001, this must be a
        failure, not a false PASS."""
        cf = FakeCrealityFlash(flash_should_succeed=True)
        exists_fn, hash_fn = self._fake_files()
        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(UNKNOWN_VERSION),
            file_exists_fn=exists_fn, hash_fn=hash_fn,
            read_bytes_fn=lambda path: b"fake-image-bytes")
        self.assertEqual(r.state, restore_mod.FLASH_FAILED)

    def test_case10_reboot_after_successful_restore_is_a_pure_read(self):
        """CASE 10: reboot after successful restore -> detect native
        candidate, zero writes (this is just decide() again, now seeing
        NATIVE_CANDIDATE_001)."""
        cf = FakeCrealityFlash()
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION))
        self.assertEqual(d.state, lifecycle.SUPPORTED_HW_NATIVE_APP)
        self.assertEqual(d.action, lifecycle.ALLOW_KLIPPER_START)
        self.assertEqual(cf.flash_calls, [])

    def test_option_c_restart_command_used_for_bootloader_entry(self):
        """Phase 1.8B Option C (2026-08-28): a successful restore must
        actually go through the restart-command mechanism (mcu_restart.py),
        not silently fall back to the old magic-sequence path, when the
        restart itself succeeds."""
        cf = FakeCrealityFlash(flash_should_succeed=True)
        exists_fn, hash_fn = self._fake_files()
        restart_calls = []

        def restart_fn(port, baud):
            restart_calls.append((port, baud))
            return "reset"

        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION),
            restart_fn=restart_fn, sleep_fn=lambda s: None,
            file_exists_fn=exists_fn, hash_fn=hash_fn,
            read_bytes_fn=lambda path: b"fake-image-bytes")
        self.assertEqual(r.state, restore_mod.RESTORED_AND_VERIFIED)
        self.assertEqual(len(restart_calls), 1)
        self.assertGreaterEqual(cf.handshake_calls, 1)
        self.assertIn("restart_command=reset", r.detail)

    def test_option_c_falls_back_to_magic_sequence_when_restart_refused(self):
        """If the MCU's dictionary exposes neither reset nor config_reset
        (RestartRequestRefused), restore() must fall back once to the
        existing magic-sequence enter_bootloader() path rather than giving
        up immediately - still exactly one bounded restore() call."""
        cf = FakeCrealityFlash(bootloader_reachable=True,
                                flash_should_succeed=True)
        exists_fn, hash_fn = self._fake_files()
        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION),
            restart_fn=make_restart_fn(refused=True), sleep_fn=lambda s: None,
            file_exists_fn=exists_fn, hash_fn=hash_fn,
            read_bytes_fn=lambda path: b"fake-image-bytes")
        self.assertEqual(r.state, restore_mod.RESTORED_AND_VERIFIED)
        self.assertIn("fallback_magic_sequence_succeeded", r.detail)

    def test_option_c_fails_when_restart_refused_and_fallback_also_fails(self):
        """If the restart-command path is refused AND the magic-sequence
        fallback also can't reach the bootloader, restore() must report
        FLASH_FAILED - never silently proceed, never raise out of
        restore()."""
        cf = FakeCrealityFlash(bootloader_reachable=False)
        exists_fn, hash_fn = self._fake_files()
        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION),
            restart_fn=make_restart_fn(refused=True), sleep_fn=lambda s: None,
            file_exists_fn=exists_fn, hash_fn=hash_fn,
            read_bytes_fn=lambda path: b"fake-image-bytes")
        self.assertEqual(r.state, restore_mod.FLASH_FAILED)
        self.assertIn("could_not_enter_bootloader", r.detail)
        self.assertEqual(cf.flash_calls, [])

    def test_restore_never_flashes_on_hardware_mismatch_after_restart(self):
        """"unsupported HW -> never flash", enforced in restore() (Option C
        moved this check here from decide() - see
        DecideTests.test_case4_known_stock_hardware_check_deferred_to_restore).
        Bootloader entry succeeds (restart command works, handshake
        succeeds), but the live hardware ID does not match the allow-list -
        this must fail closed, before any erase/write."""
        cf = FakeCrealityFlash(hw_id=BAD_HW_ID, bootloader_reachable=True)
        exists_fn, hash_fn = self._fake_files()
        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION),
            restart_fn=make_restart_fn(), sleep_fn=lambda s: None,
            file_exists_fn=exists_fn, hash_fn=hash_fn,
            read_bytes_fn=lambda path: b"fake-image-bytes")
        self.assertEqual(r.state, restore_mod.FLASH_FAILED)
        self.assertIn("hardware_identity_mismatch", r.detail)
        self.assertEqual(cf.flash_calls, [],
                          "no erase/write may occur on a hardware mismatch")

    def test_restore_never_raises_on_unexpected_restart_fn_exception(self):
        """"unhandled Python exceptions cannot silently choose the safety
        policy": if restart_fn raises something other than the two expected
        exception types (e.g. a bug), restore() must still return a
        RestoreResult (via the fallback path), never propagate the
        exception out of restore() itself."""
        cf = FakeCrealityFlash(bootloader_reachable=True,
                                flash_should_succeed=True)
        exists_fn, hash_fn = self._fake_files()

        def buggy_restart_fn(port, baud):
            raise ValueError("simulated unexpected bug, not a real failure type")

        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION),
            restart_fn=buggy_restart_fn, sleep_fn=lambda s: None,
            file_exists_fn=exists_fn, hash_fn=hash_fn,
            read_bytes_fn=lambda path: b"fake-image-bytes")
        self.assertIsInstance(r, restore_mod.RestoreResult)
        self.assertEqual(r.state, restore_mod.RESTORED_AND_VERIFIED)

    def test_restore_never_raises_on_unexpected_candidate_validation_exception(self):
        """"unhandled Python exceptions cannot silently choose the safety
        policy": an unexpected exception from exists_fn/hash_fn (e.g. a
        permissions error) must become FLASH_FAILED, never escape
        restore() uncaught - and, critically, must not proceed to attempt
        any restart/bootloader entry."""
        cf = FakeCrealityFlash()

        def buggy_exists_fn(path):
            raise OSError("simulated permission error")

        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION),
            file_exists_fn=buggy_exists_fn, hash_fn=lambda p: "0" * 64,
            read_bytes_fn=lambda path: b"fake-image-bytes")
        self.assertIsInstance(r, restore_mod.RestoreResult)
        self.assertEqual(r.state, restore_mod.FLASH_FAILED)
        self.assertEqual(cf.flash_calls, [])
        self.assertEqual(cf.handshake_calls, 0,
                          "must not attempt bootloader entry when candidate validation itself errors")

    def test_case11_unrelated_klipper_failure_never_triggers_reflash(self):
        """CASE 11: this module has no knowledge of Klipper's own runtime
        failures at all - decide() is only ever invoked at boot time by
        S50, before S55klipper starts, and never re-invoked by a later
        Klipper crash. This test documents that contract: calling decide()
        a second time with an unchanged native identity must be fully
        idempotent (no flash, same result) - there is no code path by
        which a later Klipper-only failure could reach mcu_restore.py."""
        cf = FakeCrealityFlash()
        identify_fn = make_identify_fn(NATIVE_VERSION)
        d1 = lifecycle.decide(creality_flash_module=cf,
                               transport_factory=transport_factory_stub,
                               application_identify_fn=identify_fn)
        d2 = lifecycle.decide(creality_flash_module=cf,
                               transport_factory=transport_factory_stub,
                               application_identify_fn=identify_fn)
        self.assertEqual(d1.state, d2.state)
        self.assertEqual(cf.flash_calls, [])


TOOLS_DIR = os.path.join(
    os.path.dirname(__file__), "..",
    "scripts", "build", "overlay", "opt", "nebulaos", "tools")


class RealCrealityFlashImportTests(unittest.TestCase):
    """Regression guard for the Phase 1.8B Gate 1 hardware failure
    (2026-08-28): every test above always injects a mock
    creality_flash_module/transport_factory into decide()/restore(), so none
    of them ever exercise the real `import creality_flash` fallback branch
    those functions take in production (when the init.d guard calls them
    with no arguments). That branch crashed with ModuleNotFoundError on the
    very first real boot, because creality_flash.py/creality_validator.py
    were never actually part of the overlay - a gap invisible to every mock-
    based test and to build verification's old presence-only checks.

    This test calls decide() completely unmocked (matching real production
    usage exactly), with only application_identify_fn stubbed so no serial
    hardware is required - CREALITY_FLASH_PATH is pointed at this repo's
    real overlay/opt/nebulaos/tools/ directory, so this proves the actual
    deployed file resolves, not a copy. It must resolve to MCU_UNREACHABLE
    (not raise), since there is no real MCU on the machine running this
    test - the fallback machinery itself failing closed, gracefully, is the
    behavior under test, not a real hardware read."""

    def setUp(self):
        self._old_env = os.environ.get("CREALITY_FLASH_PATH")
        os.environ["CREALITY_FLASH_PATH"] = os.path.abspath(TOOLS_DIR)

    def tearDown(self):
        if self._old_env is None:
            os.environ.pop("CREALITY_FLASH_PATH", None)
        else:
            os.environ["CREALITY_FLASH_PATH"] = self._old_env
        sys.modules.pop("creality_flash", None)
        sys.modules.pop("creality_validator", None)

    def test_unmocked_decide_resolves_real_creality_flash_import(self):
        def fake_identify(port, baud):
            raise RuntimeError("no MCU on this test host - expected")

        decision = lifecycle.decide(application_identify_fn=fake_identify)
        self.assertEqual(decision.state, lifecycle.MCU_UNREACHABLE)
        self.assertEqual(decision.hw_id_status, "UNREACHABLE")


class _ClosingTransport(FakeTransport):
    def __init__(self):
        self.closed = 0

    def close(self):
        self.closed += 1


class _CountingFactory:
    def __init__(self, exc=None):
        self.calls = 0
        self.exc = exc
        self.transports = []

    def __call__(self):
        self.calls += 1
        if self.exc:
            raise self.exc
        t = _ClosingTransport()
        self.transports.append(t)
        return t


class HardwareFallbackTests(unittest.TestCase):
    """The pyserial fallback path (_check_hardware_identity), ke-dev
    2026-10-03: primary identify timed out and the fallback crashed on
    pyserial 3.5's "unexpected keyword arguments: {'dtr', 'rts'}"."""

    def test_primary_success_fallback_not_used(self):
        f = _CountingFactory()
        d = lifecycle.decide(
            creality_flash_module=FakeCrealityFlash(), transport_factory=f,
            application_identify_fn=make_identify_fn(NATIVE_VERSION))
        self.assertEqual(d.hw_id_status, "not_checked_not_needed")
        self.assertEqual(f.calls, 0)

    def test_primary_failure_runs_fallback_and_closes(self):
        f = _CountingFactory()
        cf = FakeCrealityFlash()
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=f,
            application_identify_fn=make_identify_fn(None, should_fail=True))
        self.assertEqual(f.calls, 1)
        self.assertEqual(d.hw_id_status, "MATCH")
        self.assertEqual(cf.app_start_calls, 1)
        self.assertEqual(f.transports[0].closed, 1)

    def test_fallback_timeout_is_clean_failure(self):
        f = _CountingFactory()
        d = lifecycle.decide(
            creality_flash_module=FakeCrealityFlash(bootloader_reachable=False),
            transport_factory=f,
            application_identify_fn=make_identify_fn(None, should_fail=True))
        self.assertEqual(d.state, lifecycle.MCU_UNREACHABLE)
        self.assertEqual(d.hw_id_status, "UNREACHABLE")
        self.assertIn("bootloader_entry_failed", d.detail)
        self.assertEqual(f.transports[0].closed, 1)

    def test_fallback_unexpected_error_is_clean_failure(self):
        class _Raising(FakeCrealityFlash):
            def identify(self, transport):
                raise OSError("simulated SerialTimeoutException: Write timeout")
        f = _CountingFactory()
        d = lifecycle.decide(
            creality_flash_module=_Raising(), transport_factory=f,
            application_identify_fn=make_identify_fn(None, should_fail=True))
        self.assertEqual(d.hw_id_status, "UNREACHABLE")
        self.assertIn("unexpected_error", d.detail)
        self.assertEqual(f.transports[0].closed, 1)

    def test_identity_mismatch_still_blocks(self):
        f = _CountingFactory()
        d = lifecycle.decide(
            creality_flash_module=FakeCrealityFlash(hw_id=BAD_HW_ID),
            transport_factory=f,
            application_identify_fn=make_identify_fn(None, should_fail=True))
        self.assertEqual(d.state, lifecycle.UNSUPPORTED_HW)
        self.assertEqual(d.action, lifecycle.BLOCK_KLIPPER_START)
        self.assertEqual(f.transports[0].closed, 1)

    def test_open_failure_reports_exact_reason(self):
        f = _CountingFactory(exc=ValueError("unexpected keyword arguments: {'dtr': False}"))
        d = lifecycle.decide(
            creality_flash_module=FakeCrealityFlash(), transport_factory=f,
            application_identify_fn=make_identify_fn(None, should_fail=True))
        self.assertEqual(d.hw_id_status, "UNREACHABLE")
        self.assertIn("serial_open_failed: unexpected keyword arguments", d.detail)

    def test_close_failure_does_not_mask_the_result(self):
        class _BadClose(_ClosingTransport):
            def close(self):
                raise OSError("close failed")
        d = lifecycle.decide(
            creality_flash_module=FakeCrealityFlash(), transport_factory=_BadClose,
            application_identify_fn=make_identify_fn(None, should_fail=True))
        self.assertEqual(d.hw_id_status, "MATCH")


TOOLS_DIR = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "scripts", "build", "overlay", "opt", "nebulaos", "tools"))


class _Pyserial35:
    """The parts of pyserial 3.5's serial.Serial that SerialTransport uses,
    including its refusal of constructor keywords it does not know."""
    instances = []
    KNOWN = {"port", "baudrate", "bytesize", "parity", "stopbits", "timeout",
             "xonxoff", "rtscts", "write_timeout", "dsrdtr", "inter_byte_timeout",
             "exclusive"}

    def __init__(self, port=None, **kwargs):
        unknown = {k: v for k, v in kwargs.items() if k not in self.KNOWN}
        if unknown:
            raise ValueError("unexpected keyword arguments: {!r}".format(unknown))
        self.events = [("init", port, dict(kwargs))]
        self.port, self.is_open = port, port is not None
        _Pyserial35.instances.append(self)

    def __setattr__(self, k, v):
        if k in ("dtr", "rts", "port", "baudrate", "timeout", "write_timeout"):
            self.__dict__.setdefault("events", []).append(("set", k, v, self.__dict__.get("is_open")))
        object.__setattr__(self, k, v)

    def open(self):
        self.events.append(("open",))
        self.is_open = True

    def close(self):
        self.events.append(("close",))
        self.is_open = False


class SerialTransportApiTests(unittest.TestCase):
    def _load(self, fake_serial):
        import types
        mod = types.ModuleType("serial")
        mod.Serial = fake_serial
        self._saved = sys.modules.get("serial")
        sys.modules["serial"] = mod
        sys.path.insert(0, TOOLS_DIR)
        sys.modules.pop("creality_flash", None)
        import creality_flash
        return creality_flash

    def tearDown(self):
        if getattr(self, "_saved", None) is not None:
            sys.modules["serial"] = self._saved
        else:
            sys.modules.pop("serial", None)
        sys.modules.pop("creality_flash", None)
        if TOOLS_DIR in sys.path:
            sys.path.remove(TOOLS_DIR)

    def test_opens_with_pyserial_35_api(self):
        _Pyserial35.instances = []
        cf = self._load(_Pyserial35)
        t = cf.SerialTransport("/dev/ttyS1", 230400, timeout=2.0)
        s = _Pyserial35.instances[-1]
        init = s.events[0]
        self.assertIsNone(init[1], "the port must not be opened by the constructor")
        self.assertNotIn("dtr", init[2])
        self.assertNotIn("rts", init[2])
        sets = {e[1]: (e[2], e[3]) for e in s.events if e[0] == "set"}
        self.assertEqual(sets["dtr"], (False, False), "DTR set low before open()")
        self.assertEqual(sets["rts"], (False, False), "RTS set low before open()")
        self.assertEqual(sets["timeout"][0], 2.0)
        self.assertEqual(sets["write_timeout"][0], 2.0, "writes are bounded too")
        self.assertEqual(sets["baudrate"][0], 230400)
        self.assertIn(("open",), s.events)
        t.close()
        self.assertEqual(s.events[-1], ("close",))

    def test_real_pyserial_rejects_nothing_we_pass(self):
        try:
            import serial as real
        except ImportError:
            self.skipTest("pyserial not installed on this host")
        if not hasattr(real, "SerialException"):
            self.skipTest("not the real pyserial")
        sys.path.insert(0, TOOLS_DIR)
        sys.modules.pop("creality_flash", None)
        import creality_flash
        with self.assertRaises(real.SerialException):
            creality_flash.SerialTransport("/nonexistent/nebulaos-tty", 230400, timeout=0.1)


class ClassificationTests(unittest.TestCase):
    def test_exact_match_only_no_prefix_guessing(self):
        """A string that merely starts with the known-stock value must NOT
        classify as KNOWN_STOCK - exact match only."""
        almost = STOCK_VERSION + "-extra-suffix"
        self.assertEqual(
            known.classify_application_identity(almost),
            known.UNKNOWN_APPLICATION)

    def test_native_and_stock_are_distinguishable(self):
        self.assertNotEqual(
            known.classify_application_identity(NATIVE_VERSION),
            known.classify_application_identity(STOCK_VERSION))


if __name__ == "__main__":
    unittest.main()
