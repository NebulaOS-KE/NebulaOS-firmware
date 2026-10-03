#!/bin/sh
#
# TOOL-01: the Hardware Agent's read-only `capture <profile>` operation.
#   - every HWCAP profile named in the production kernel plan exists (as a
#     capture, or for state-changing ones as an exercise-only name);
#   - profile names are a fixed lowercase table; unknown names and anything
#     shaped like an injection are refused by the launcher and by the agent;
#   - profile bodies are static text: no caller value reaches the device;
#   - every probe-based profile embeds a tracked tools/hwcap probe, and those
#     probes are pinned in CONTROL_MANIFEST;
#   - capture is not a destructive operation and uses the identity proofs.
#
# Usage: sh tests/hardware-capture-profile-tests.sh
set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FW=$(cd "$SCRIPT_DIR/.." && pwd)
FAIL=0
python3 - "$FW" <<'PYEOF' || FAIL=1
import os, re, sys
fw = sys.argv[1]
sys.path.insert(0, os.path.join(fw, "tools", "hardware"))
import nebulaos_capture as c
passed = failed = 0
def check(ok, msg):
    global passed, failed
    if ok: passed += 1; print("PASS: " + msg)
    else: failed += 1; print("FAIL: " + msg)

required = """ADXL cam camera-resume DMESG dwc2-hw irq-rate-paused irq-rate-streaming irq-threads KDUTY kernel
kernel-diag kernel-features kernel-identity KSTATS LOAD mem memexercise meminfo memproc memstate PTYRTT
RT-CONFIG RT-CONSOLE RT-GPIO RT-IPI RT-LAZY RT-SPLAT RT-THROUGHPUT RT-UART SCHEDSNAP sof-filter-ab
storage-autosuspend TIMERLAT UARTOE usb usb-pm usb-topology wifi
usb-topology dwc2-hw irq-rates threads serial memory cpu-fpu latency-baseline timerlat-tracer missed-sof dt-memory emmc-life""".split()
for name in sorted(set(n.lower() for n in required)):
    check(name in c.CAPTURE_PROFILES or name in c.EXERCISE_ONLY, "profile %s is implemented" % name)
for name in c.CAPTURE_PROFILES:
    check(re.fullmatch(r"[a-z0-9-]+", name) is not None, "profile name %s is [a-z0-9-]" % name)
    check(name not in c.EXERCISE_ONLY, "%s is not both a capture and an exercise" % name)
for bad in ("nope", "kernel;reboot", "kernel reboot", "../kernel", "memexercise", "sof-filter-ab", ""):
    try:
        c.capture_script(bad); check(False, "refuses %r" % bad)
    except c.CaptureError:
        check(True, "refuses %r" % bad)
for name, (body, diag, probe, timeout) in c.CAPTURE_PROFILES.items():
    s, t = c.capture_script(name)
    check("{ %s; }" % body in s, "%s body reaches the device verbatim (no caller value is formatted in)" % name)
    check("trap 'rm -rf \"$T\"' EXIT" in s and "/tmp/nebulaos-capture.$$" in s, "%s cleans its tmp dir" % name)
    check("CAPTURE_PROFILE=%s" % name in s and "END_UTC=" in s, "%s prints its markers" % name)
    check((not diag) or "PROFILE_REQUIRES_DIAGNOSTIC_IMAGE" in s, "%s refuses a production kernel if diag-only" % name)
    for word in ("reboot", "mkfs", "dd if=", "dd of=", "swapoff", "G28", "M104", "M140", "SET_HEATER", "FIRMWARE_RESTART", "flash-spare"):
        check(word not in body, "%s body has no %s" % (name, word))
    if probe:
        check(probe in c.PROBES and os.path.isfile(os.path.join(c.HWCAP_DIR, probe)), "%s probe %s is tracked" % (name, probe))
manifest = open(os.path.join(fw, "tools", "hardware", "CONTROL_MANIFEST")).read()
for p in c.PROBES + ("../hardware/nebulaos_capture.py",):
    path = os.path.normpath(os.path.join("tools/hwcap", p))
    check(re.search(r"\shost\s+%s$" % re.escape(path), manifest, re.M) is not None, "%s pinned in CONTROL_MANIFEST" % path)
agent = open(os.path.join(fw, "tools", "hardware", "nebulaos_agent.py")).read()
op = agent[agent.index("def op_capture"):agent.index("def control_is_published")]
check("destructive=False" in op and "prove_preconditions(" in op, "op_capture proves identity and is non-destructive")
check("CAPTURE_PROFILES" in op, "op_capture refuses names outside the table")
print("capture-profile python checks: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
PYEOF

# The launcher's own grammar (real script, stub agent in a fake workspace root).
WORK=$(mktemp -d "${TMPDIR:-/tmp}/capture-grammar.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM
ROOT="$WORK/root"
mkdir -p "$ROOT/tools" "$ROOT/NebulaOS-firmware/tools/workspace-control/scripts" \
         "$ROOT/NebulaOS-firmware/tools/hardware" "$ROOT/NebulaOS-firmware/.git"
touch "$ROOT/NebulaOS-firmware/tools/workspace-control/MANIFEST"
LAUNCHER="$ROOT/NebulaOS-firmware/tools/workspace-control/scripts/run-nebulaos-hardware.sh"
cp "$FW/tools/workspace-control/scripts/run-nebulaos-hardware.sh" "$LAUNCHER"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/tools/verify-workspace-identity.sh"
printf 'import sys\nprint("AGENT_ARGS=" + " ".join(sys.argv[1:]))\n' > "$ROOT/NebulaOS-firmware/tools/hardware/nebulaos_agent.py"
chmod +x "$ROOT/tools/"*.sh "$LAUNCHER"
SHA=$(printf 'a%.0s' $(seq 40))
run() { bash "$LAUNCHER" --device p1 --control "$SHA" "$@" 2>&1; }
out=$(run capture kernel-identity)
case "$out" in *"AGENT_ARGS=--device p1 --control-commit $SHA capture kernel-identity"*) echo "PASS: launcher passes a valid profile name";; *) echo "FAIL: launcher did not pass capture: $out"; FAIL=1;; esac
for bad in "kernel;reboot" "kernel reboot" "../x" "-x" "KERNEL" ""; do
	out=$(run capture "$bad")
	case "$out" in *AGENT_ARGS*) echo "FAIL: launcher accepted capture '$bad'"; FAIL=1;; *) echo "PASS: launcher refuses capture '$bad'";; esac
done
out=$(run capture a b)
case "$out" in *AGENT_ARGS*) echo "FAIL: launcher accepted two profile names"; FAIL=1;; *) echo "PASS: launcher refuses extra arguments";; esac

[ "$FAIL" -eq 0 ] && echo "HARDWARE_CAPTURE_PROFILES=PASS" || echo "HARDWARE_CAPTURE_PROFILES=FAIL"
exit "$FAIL"
