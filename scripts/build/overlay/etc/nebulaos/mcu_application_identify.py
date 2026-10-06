"""Pre-Klippy application identity handshake for the KE GD32F303 MCU.

Reads the MCU's own IDENTIFY dictionary - the same handshake Klipper itself
performs on every normal connect - WITHOUT starting full Klippy (no Printer,
no config, no toolhead). This lets the boot-time guard learn which
application firmware is currently running before deciding whether it's safe
to let S55klipper start normally.

This is not a novel protocol implementation. It follows the exact pattern
already shipped in upstream Klipper's own scripts/dump_mcu.py (present in
the same 58bd67db3ce1be1951c3e4a6d1156a79903d4edc commit this project's
native MCU candidate is built from): construct a bare reactor.Reactor(),
hand it to serialhdl.SerialReader(), call connect_uart(), then read the
version string via get_msgparser().get_version_info() - the identify
handshake completes synchronously inside connect_uart() itself, before it
returns, with no config or Printer object ever involved.

klippy.mcu.MCU surfaces this exact same field as the `mcu_version` status
value at runtime (see klippy/mcu.py: self._get_status_info['mcu_version'] =
version from msgparser.get_version_info()) - so this script's result is
directly comparable to what `printer/objects/query?mcu` reports once
Klipper is running.

run_connected() below is the shared reactor-driven connect helper: it
performs the connect once and hands the live, connected SerialReader to a
caller-supplied action_fn - mcu_restart.py's request_generic_restart() reuses
it for the pre-Klippy MCU_RESTART operation (candidate-002, Phase 1.8B
Option C), so both callers share one correct reactor pattern instead of each
re-deriving the reactor.run()/pause() plumbing independently.

SAFETY CONTRACT (this module):
  - READ-ONLY. Connects, reads the identify dictionary, disconnects.
  - Never sends any command beyond the identify handshake itself.
  - Never touches the bootloader protocol (that's creality_flash.py's job,
    a separate, deliberately distinct check - see mcu_lifecycle.py).
"""

import os
import sys

KLIPPY_LIB_PATH = os.environ.get("KLIPPY_LIB_PATH", "/opt/klipper/klippy")

# M1 (2026-10-05): the whole application-identify connect gets 15 s, not 5 s.
# Klipper's connect_uart() itself waits 5 s per identify session and then
# retries, so a 5 s budget left no room for a second session: one slow or
# garbled first session at boot (cold caches, the port's first open, a busy
# CPU) ended in identify_handshake_timeout and the bootloader fallback. Live on
# ke-dev a boot-like stressed identify took 8.86 s. A healthy MCU still answers
# in ~2-3 s; only a dead or absent MCU now takes ~15 s (bounded) before the
# unchanged fallback. Overridable for tests/diagnosis: MCU_APP_IDENTIFY_TIMEOUT.
DEFAULT_APP_IDENTIFY_TIMEOUT = 15.0


def app_identify_timeout(environ=None):
    """The identify budget in seconds: MCU_APP_IDENTIFY_TIMEOUT when it is a
    positive number, else DEFAULT_APP_IDENTIFY_TIMEOUT."""
    raw = (os.environ if environ is None else environ).get("MCU_APP_IDENTIFY_TIMEOUT", "")
    try:
        value = float(raw)
    except ValueError:
        return DEFAULT_APP_IDENTIFY_TIMEOUT
    return value if 0 < value <= 120 else DEFAULT_APP_IDENTIFY_TIMEOUT


class ApplicationIdentifyError(Exception):
    pass


def _import_klippy_serial_modules(klippy_lib_path=None):
    lib_path = klippy_lib_path or KLIPPY_LIB_PATH
    if lib_path not in sys.path:
        sys.path.insert(0, lib_path)
    import reactor
    import serialhdl
    return reactor, serialhdl


def _resolve_port_realpath(port):
    try:
        return os.path.realpath(port)
    except OSError:
        return port


def find_process_holding_port(port, proc_root="/proc"):
    """Scan /proc/[pid]/fd for any process that already has `port` open, by
    resolving both sides to their real device path first (a symlink like
    /dev/serial/by-id/... and its /dev/ttySN target must compare equal).
    Returns the owning pid (int) or None if the port appears free.

    Phase 2 overnight convergence mission (2026-09-09): real device found
    live where mcu_identity_check.py (via this module's run_connected(),
    which reuses Klipper's own serialhdl.SerialReader.connect_uart() -
    connect_uart() itself calls serial.Serial(..., exclusive=True), the
    exact same call Klipper's own normal MCU connection uses) was run
    manually while klippy.py already held /dev/ttyS1 open and connected.
    The competing open() raced Klipper's own connection and, going by
    Klipper's own serialhdl.py (which elsewhere uses an explicit DTR
    toggle - ser.dtr = True; ser.dtr = False - as its own deliberate
    MCU-reset mechanism over this exact class of port), very plausibly
    toggled DTR as a side effect of the OS-level open() itself, before
    pyserial's own exclusive-lock check ever had a chance to reject it -
    the MCU then stopped responding to Klipper's identify handshake
    entirely, and only a full power cycle (which the running printer
    otherwise had no problem with) recovered it.

    Rather than rely on the open() attempt failing safely (it doesn't
    always, and even a failed attempt already touched the device by the
    time pyserial notices), refuse to attempt the open AT ALL when the
    port is already visibly in use - checked with a plain fd scan, no
    actual open() call, so this check itself can never disturb a live
    connection. Not airtight against every possible race (a process could
    open the port in the instant after this check runs, before ours), but
    directly closes the exact failure mode found live: this check, plus
    S50nebulaos-mcu-guard's own documented ordering (it runs before
    S55klipper specifically so Klipper never holds the port yet), covers
    the realistic cases - a technician manually re-running this tool
    while Klipper is already up, or a second guard invocation racing a
    slow-starting Klipper.
    """
    target = _resolve_port_realpath(port)
    try:
        pids = [p for p in os.listdir(proc_root) if p.isdigit()]
    except OSError:
        return None
    for pid in pids:
        fd_dir = os.path.join(proc_root, pid, "fd")
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue
        for fd in fds:
            try:
                link = os.readlink(os.path.join(fd_dir, fd))
            except OSError:
                continue
            if _resolve_port_realpath(link) == target:
                return int(pid)
    return None


def run_connected(port, baud, action_fn, timeout=5.0, klippy_lib_path=None,
                   error_cls=ApplicationIdentifyError):
    """Connect to the MCU at (port, baud) and call action_fn(serial_reader)
    with a live, connected serialhdl.SerialReader - then always disconnect
    and clean up the reactor before returning. action_fn's return value is
    passed through; an exception it raises is re-raised (as error_cls if not
    already one) after cleanup has run.

    reactor.Reactor.pause() only dispatches registered callbacks/timers once
    its greenlet dispatch loop is running (self._g_dispatch is set, which
    happens inside run()) - called before that, it silently falls back to a
    plain time.sleep() (see reactor.py's pause()/_sys_pause()), so a
    callback registered and then waited-on via a bare top-level pause() loop
    would NEVER actually fire, timing out every time regardless of whether
    the MCU responds. This was discovered live on real hardware (2026-08-28
    Phase 1.8B hardware qualification) - a prior version of this function
    did exactly that and always failed with identify_handshake_timeout,
    which no offline test caught because every test injects
    application_identify_fn directly and never exercises this reactor
    plumbing. The fix, matching upstream Klipper's own scripts/dump_mcu.py
    (this module's stated model): drive everything through one top-level
    callback dispatched by run(), exactly like dump_mcu.py's
    MCUDump.run()/_run_dump_task() do - nested pause() calls made from
    inside that callback then correctly use the real dispatch greenlet
    instead of the do-nothing fallback. action_fn itself may safely call
    serial_reader/reactor methods that internally pause() - it always runs
    from inside the dispatched callback.
    """
    holder_pid = find_process_holding_port(port)
    if holder_pid is not None:
        raise error_cls(
            f"port_already_in_use_by_pid_{holder_pid}: refusing to open "
            f"{port} - another process already has it open, and opening "
            "it again risks disrupting that process's own connection to "
            "the MCU (see this function's own docstring)")

    try:
        reactor, serialhdl = _import_klippy_serial_modules(klippy_lib_path)
    except ImportError as e:
        raise error_cls(f"cannot_import_klippy_serial_modules: {e}")

    r = reactor.Reactor()
    serial_reader = serialhdl.SerialReader(r)
    outcome = {}

    def _do_run(eventtime):
        completion = r.completion()
        connected = {"ok": False}

        def _do_connect(eventtime):
            try:
                serial_reader.connect_uart(port, baud)
                connected["ok"] = True
            except Exception as e:
                connected["error"] = str(e)
            completion.complete(connected["ok"])

        r.register_callback(_do_connect)
        curtime = r.monotonic()
        deadline = curtime + timeout
        while curtime < deadline:
            curtime = r.pause(min(curtime + 0.1, deadline))
            if completion.test():
                break
        else:
            outcome["error"] = "identify_handshake_timeout"
            r.end()
            return

        if not completion.wait():
            outcome["error"] = connected.get("error", "connect_uart_failed")
            r.end()
            return

        try:
            outcome["result"] = action_fn(serial_reader)
        except Exception as e:
            outcome["error"] = str(e)
        r.end()

    try:
        r.register_callback(_do_run)
        r.run()
    finally:
        try:
            serial_reader.disconnect()
        except Exception:
            pass
        try:
            r.finalize()
        except Exception:
            pass

    if "error" in outcome:
        raise error_cls(outcome["error"])
    return outcome.get("result")


def get_application_identity(port, baud, timeout=None, klippy_lib_path=None):
    """Connect to the MCU at the application baud rate, complete the
    identify handshake, and return (version, build_versions). Raises
    ApplicationIdentifyError on any failure (port unopenable, handshake
    timeout, malformed dictionary). Always disconnects before returning.
    timeout=None means app_identify_timeout() (15 s unless overridden)."""
    if timeout is None:
        timeout = app_identify_timeout()

    def _read_version(serial_reader):
        version, build_versions = serial_reader.get_msgparser().get_version_info()
        if not version:
            raise ApplicationIdentifyError("empty_version_in_identify_dict")
        return version, build_versions

    return run_connected(port, baud, _read_version, timeout, klippy_lib_path,
                          error_cls=ApplicationIdentifyError)


if __name__ == "__main__":
    import argparse

    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--port", default=os.environ.get("MCU_SERIAL_PORT", "/dev/ttyS1"))
    p.add_argument("--baud", type=int, default=int(os.environ.get("MCU_APP_BAUD", "230400")))
    args = p.parse_args()
    try:
        version, build_versions = get_application_identity(args.port, args.baud)
        print(f"version={version}")
        print(f"build_versions={build_versions}")
    except ApplicationIdentifyError as e:
        print(f"error={e}")
        sys.exit(1)
