#!/usr/bin/env bash
#
# NebulaOS Hardware Agent launcher - the ONLY route from an agent to a printer,
# and the only command an agent may run outside Claude's sandbox to get there.
#
# WHY THIS EXISTS
#
# The PreToolUse hook refuses ssh/scp/sftp/ping/nc/socat/... to the hardware
# agent outright, with no target-bound exception, and that refusal STAYS. The
# main agent has no network inside the sandbox and no access to the credential
# store. Both reach hardware only by invoking this file. All device contact is
# encapsulated below, where it can be constrained and reviewed, rather than
# spelled out ad hoc in agent-authored shell.
#
# WHO MAY RUN IT (enforced by the PreToolUse hook, not by this file)
#
#   nebulaos-hardware   every operation
#   main agent          every operation
#   anyone else         nothing
#
# Like the build launcher, the escape is bound to this file by REAL PATH **and by
# CONTENT**: the installed copy's bytes must equal the tracked canonical blob at
# firmware HEAD. Path identity alone is not enough - tools/ is unversioned
# derived state the sandbox permits writing, so naming an allowed path could
# otherwise run arbitrary code with host privilege.
#
# THE INTERFACE IS SEMANTIC
#
#   run-nebulaos-hardware.sh --device <id> --control <C> inspect
#   run-nebulaos-hardware.sh --device <id> --control <C> status
#   run-nebulaos-hardware.sh --device <id> --control <C> diagnose
#   run-nebulaos-hardware.sh --device <id> --control <C> capture <profile>
#   run-nebulaos-hardware.sh --device <id> --control <C> exercise <profile> [EXERCISE_CONFIRM=<profile>]
#                                          (without the confirmation word, confirm on stdin)
#   run-nebulaos-hardware.sh --device <id> --control <C> restart <service>
#   run-nebulaos-hardware.sh --device <id> --control <C> reboot REBOOT_CONFIRM=NEBULAOS
#   run-nebulaos-hardware.sh --device <id> --control <C> rtos-logo RTOS_LOGO_CONFIRM=RTOS2
#   run-nebulaos-hardware.sh --device <id> --control <C> rtos-logo-restore <backup-sha256> RTOS_RESTORE_CONFIRM=RTOS2
#   run-nebulaos-hardware.sh --device <id> --control <C> purge-dev-leftovers PURGE_CONFIRM=DEV-LEFTOVERS
#   run-nebulaos-hardware.sh --device <id> --control <C> verify  <X> <ximage-sha256> <rootfs-sha256>
#   run-nebulaos-hardware.sh --device <id> --control <C> install <X> <ximage-sha256> <rootfs-sha256>
#
# There is no --host, --password, --command, ssh, scp, dd, marker, flash or raw
# usbboot - not filtered, absent. `reboot` only returns an idle NebulaOS to
# NebulaOS; it writes nothing. `rtos-logo` writes the pinned NebulaOS RTOS image
# to rtos2 (p4) only, after a verified host backup; `rtos-logo-restore` writes
# such a backup back. Neither can name rtos (p3) or any other partition. The target is an ENROLLED DEVICE ID, not
# an address: an address is not an identity, DHCP moves leases, and the machine
# answering at a remembered IP may be a different one. Which addresses may be
# spoken to at all is a property of the human-created device profile.
#
# C AND X
#
#   C  the control commit: the reviewed, published source of every privileged
#      helper. Stated explicitly so that installing an OLD product still uses
#      CURRENT control machinery.
#   X  the product commit being installed. Payload and data only.
#
# THIS LAUNCHER REIMPLEMENTS NOTHING
#
# Every partition write is performed by scripts/flash-spare-slot.sh, ON the
# device, whose bytes are read from C's git objects. That script owns the slot
# model, the live-target collision refusal, the capacity checks and the
# post-write read-back, and it has its own offline test suite. This file is a
# gate and a courier.
#
# REPAIRS
#
# `restart` is the only repair: one service from a closed list (klipper,
# moonraker, guppyscreen, webcam, nginx), with the on-device update supervisor's
# stop/wait/start and print-idle semantics, refused while that supervisor holds a
# lock or is validating. A RELEASE-mode device additionally requires a published
# control commit. There is deliberately no package install: the Moonraker venv lives
# in persistent /usr/data, so a repair there would outlive the next install and
# hide a broken image. Product defects are fixed in the product and reinstalled.
#
# PART 1 SCOPE ONLY
#
# Nothing here homes an axis, moves a motor, heats a nozzle or bed, extrudes,
# calibrates, starts a print, or flashes the MCU. Those are Part 2 and are
# deliberately absent, not merely discouraged.
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 LC_ALL=C

die(){ printf 'RUN_NEBULAOS_HARDWARE=REFUSED\nREASON: %s\n' "$1" >&2; exit 2; }

# --- resolve the workspace root structurally, never by a hard-coded path ----
SELF=$(readlink -f "${BASH_SOURCE[0]}") || die "cannot resolve own path"
SELF_DIR=$(dirname "$SELF")
case "$SELF_DIR" in
  */NebulaOS-firmware/tools/workspace-control/scripts) ROOT=$(cd "$SELF_DIR/../../../.." && pwd -P) ;;
  */tools)                                             ROOT=$(cd "$SELF_DIR/.." && pwd -P) ;;
  *) die "launcher is not in a recognised location: $SELF_DIR" ;;
esac

[ -x "$ROOT/tools/verify-workspace-identity.sh" ] \
  || die "not a NebulaOS workspace root (no installed identity gate): $ROOT"
[ -f "$ROOT/NebulaOS-firmware/tools/workspace-control/MANIFEST" ] \
  || die "not a NebulaOS workspace root (no canonical control source): $ROOT"
FW="$ROOT/NebulaOS-firmware"
[ -d "$FW/.git" ] || die "$FW is not a git checkout"

AGENT="$FW/tools/hardware/nebulaos_agent.py"
[ -f "$AGENT" ] || die "the hardware agent is missing: $AGENT"

# --- grammar ----------------------------------------------------------------
# Validated here AND in the PreToolUse hook, deliberately not shared: the two
# are different programs with different failure modes, and a shared validator is
# exactly where a future mistake would hide.
DEVICE=""; CONTROL=""
while [ "$#" -gt 0 ]; do
  case "${1:-}" in
    --device)  DEVICE=${2:-}; shift 2 || die "--device requires an enrolled device id" ;;
    --control) CONTROL=${2:-}; shift 2 || die "--control requires a 40-character commit" ;;
    --*) die "unknown option '${1}'. This launcher accepts only --device and --control.
       There is deliberately no --host, --password or --command: the target is an enrolled
       device id, and every command is composed by reviewed control code." ;;
    *) break ;;
  esac
done

[ -n "$DEVICE" ]  || die "--device <enrolled-device-id> is required"
[ -n "$CONTROL" ] || die "--control <40-char control commit> is required"

case "$DEVICE" in
  *[!A-Za-z0-9_-]*|"") die "device id must be letters, digits, '-' and '_' only: '$DEVICE'
       It names a directory under the profile store, so anything else is a traversal." ;;
esac
[ "${#DEVICE}" -le 64 ] || die "device id is too long"

is_hex(){ case "$1" in *[!0-9a-f]*|"") return 1 ;; esac; [ "${#1}" -eq "$2" ]; }
is_hex "$CONTROL" 40 || die "--control must be a full 40-character lowercase hex commit"

OP=${1:-}
case "$OP" in
  inspect|status|diagnose)
    [ "$#" -eq 1 ] || die "'$OP' takes no further arguments" ;;
  restart)
    [ "$#" -eq 2 ] || die "'restart' requires exactly one service name"
    case "$2" in
      klipper|moonraker|guppyscreen|webcam|nginx) ;;
      *) die "unknown service '$2'. Restartable: klipper moonraker guppyscreen webcam nginx" ;;
    esac ;;
  capture|exercise)
    # A profile NAME from the agent's fixed tables (TOOL-01/02); the agent
    # refuses names it does not know. Never a command. An exercise may carry
    # its confirmation as a third word, EXERCISE_CONFIRM=<the same profile>,
    # so an authorised unattended session can run it; without that word the
    # agent asks on stdin.
    case "$OP:$#" in
      capture:2|exercise:2) ;;
      exercise:3) [ "$3" = "EXERCISE_CONFIRM=$2" ] || die "exercise confirmation must be EXERCISE_CONFIRM=$2" ;;
      *) die "'$OP' requires exactly one profile name" ;;
    esac
    case "$2" in
      ""|-*|*[!a-z0-9-]*) die "unknown $OP profile '$2'" ;;
    esac ;;
  reboot)
    # Software reboot of an idle NebulaOS back into NebulaOS (boot timing).
    # The agent refuses unless the OTA marker already selects NebulaOS.
    [ "$#" -eq 2 ] && [ "$2" = "REBOOT_CONFIRM=NEBULAOS" ] \
      || die "'reboot' requires exactly the confirmation word REBOOT_CONFIRM=NEBULAOS" ;;
  rtos-logo)
    # The NebulaOS boot logo into rtos2 (p4) only; backup first, read-back after.
    [ "$#" -eq 2 ] && [ "$2" = "RTOS_LOGO_CONFIRM=RTOS2" ] \
      || die "'rtos-logo' requires exactly the confirmation word RTOS_LOGO_CONFIRM=RTOS2" ;;
  purge-dev-leftovers)
    # 2026-10-15: removes the agent's FIXED list of development leftovers
    # from an idle NebulaOS printer's data partition. Nothing else.
    [ "$#" -eq 2 ] && [ "$2" = "PURGE_CONFIRM=DEV-LEFTOVERS" ] \
      || die "'purge-dev-leftovers' requires exactly the confirmation word PURGE_CONFIRM=DEV-LEFTOVERS" ;;
  rtos-logo-restore)
    [ "$#" -eq 3 ] || die "'rtos-logo-restore' requires <backup-sha256> RTOS_RESTORE_CONFIRM=RTOS2"
    is_hex "$2" 64 || die "the backup sha256 must be 64 lowercase hex characters"
    [ "$3" = "RTOS_RESTORE_CONFIRM=RTOS2" ] \
      || die "'rtos-logo-restore' requires the confirmation word RTOS_RESTORE_CONFIRM=RTOS2" ;;
  verify|install)
    [ "$#" -eq 4 ] || die "'$OP' requires <source-head> <ximage-sha256> <rootfs-sha256>"
    is_hex "$2" 40 || die "source-head must be a full 40-character lowercase hex SHA"
    is_hex "$3" 64 || die "ximage-sha256 must be 64 lowercase hex characters"
    is_hex "$4" 64 || die "rootfs-sha256 must be 64 lowercase hex characters" ;;
  *) die "unknown operation '${OP:-}'. The Hardware Agent has exactly twelve:
       inspect  status  diagnose  capture  exercise  restart  reboot  rtos-logo
       rtos-logo-restore  purge-dev-leftovers  verify  install
       Motion, heating, extrusion, calibration and MCU flashing are Part 2 and have no
       operation here." ;;
esac

# --- NO workspace-wide gate here --------------------------------------------
# DEV hardware work depends on the exact things the agent proves for THIS
# operation - enrolled device identity, pinned host key, control helper bytes
# from C's git objects, product build record and artifact hashes, partition
# targets, idle/heater state, readback - not on whether some unrelated repo is
# dirty or every commit is pushed. A device profile in RELEASE mode makes the
# agent itself require the full online identity gate, published C and X, and an
# authenticated attestation.

exec python3 "$AGENT" --device "$DEVICE" --control-commit "$CONTROL" "$@"
