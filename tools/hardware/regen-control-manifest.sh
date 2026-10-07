#!/usr/bin/env bash
#
# Regenerate tools/hardware/CONTROL_MANIFEST.
#
# The manifest pins every privileged file by content, at the control commit that
# contains it. Two kinds, with different guarantees - see nebulaos_control.py:
#
#   on-device  staged onto the printer; its bytes are read from the git object
#              at C, so the working tree cannot influence what gets sent.
#   host       control modules the launcher itself executes; Python imports them
#              from disk, so the running copies are COMPARED against C and any
#              difference refuses the operation.
#
# Run this after changing any privileged file, then commit the manifest IN THE
# SAME COMMIT as the change. A manifest that lags its files makes every
# privileged operation refuse, which is the correct failure but an annoying one
# to debug at 2am.
set -uo pipefail
cd "$(dirname "$0")/../.."

ON_DEVICE=(
  scripts/flash-spare-slot.sh
)

HOST=(
  tools/attest/nebulaos-attest.py
  tools/emmc/nebulaos_layout.py
  tools/hardware/nebulaos_agent.py
  tools/hardware/nebulaos_capture.py
  tools/hardware/nebulaos_control.py
  tools/hardware/nebulaos_device.py
  tools/hardware/nebulaos_evidence.py
  tools/hardware/nebulaos_install.py
  tools/hardware/nebulaos_journal.py
  tools/hardware/nebulaos_marker.py
  tools/hardware/nebulaos_profile.py
  tools/hardware/nebulaos_target.py
  tools/hardware/nebulaos_verify.py
  tools/hwcap/adxl_overflows.py
  tools/hwcap/klipper-dict-board.json
  tools/hwcap/fb_cam10.sh
  tools/hwcap/fb_ng3.sh
  tools/hwcap/kduty.py
  tools/hwcap/lv_cam.sh
  tools/hwcap/lv_g10.sh
  tools/hwcap/lv_g5.sh
  tools/hwcap/lv_g6.sh
  tools/hwcap/lv_g7.sh
  tools/hwcap/lv_g8.sh
  tools/hwcap/lv_g9.sh
  tools/hwcap/lv_m1.py
  tools/hwcap/lv_ng1.py
  tools/hwcap/lv_s1.sh
  tools/hwcap/lv_s2.sh
  tools/hwcap/pf_cam.sh
  tools/hwcap/ptyrtt.py
  tools/hwcap/qualmcu.py
  tools/hwcap/schedsnap.py
  tools/hwcap/timerlat.py
)

OUT=tools/hardware/CONTROL_MANIFEST
{
  echo "# NebulaOS privileged control manifest"
  echo "#"
  echo "# <sha256>  <kind>  <path>"
  echo "#"
  echo "# Regenerate with tools/hardware/regen-control-manifest.sh and commit the"
  echo "# result together with whatever privileged file changed. Read by"
  echo "# tools/hardware/nebulaos_control.py at control commit C."
  echo
  for f in "${ON_DEVICE[@]}"; do
    [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
    printf '%s  on-device  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"
  done
  for f in "${HOST[@]}"; do
    [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
    printf '%s  host  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"
  done
} > "$OUT"

printf 'CONTROL_MANIFEST_ENTRIES=%d\n' "$(grep -c '^[0-9a-f]' "$OUT")"
printf 'CONTROL_MANIFEST_SHA256=%s\n' "$(sha256sum "$OUT" | cut -d' ' -f1)"
