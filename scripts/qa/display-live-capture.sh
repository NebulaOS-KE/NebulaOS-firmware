#!/bin/sh
#
# Read-only live display/touch/backlight/DPU/boot capture over SSH, for the
# powered-on display investigation mission (2026-08-01). Every remote
# command this script runs is a read - no writes, no ioctls, no service
# restarts, no reboots. See docs/NEBULAOS_DISPLAY_LIVE_QUALIFICATION_PLAN.md
# for the test matrix this supports (HT-01 through HT-10, minus HT-09 which
# is the one write/flash test and is NOT part of this script).
#
# Password SSH pattern per [[reference_device_access]]: this image's /root
# is read-only squashfs (no authorized_keys can be installed), so every
# session needs password auth. Uses SSH_ASKPASS (no sshpass, no setsid -
# setsid silently breaks stdout capture in this class of environment,
# confirmed in a prior session).
#
# Usage:
#   sh scripts/qa/display-live-capture.sh <device-ip> [output-dir]
#
# Environment overrides:
#   NEBULAOS_SSH_PASSWORD   default: NebulaOS (the image default root password)
#   NEBULAOS_SSH_USER       default: root
#
# Confirm printer identity (hostname/CID-MAC/manifest) BEFORE running the
# full capture - this script's own "identity" group is meant to be run
# first, in isolation, precisely so that confirmation can happen before any
# other group touches the device. See Phase 6/7 of the mission text.

set -eu

DEVICE_IP="${1:?usage: $0 <device-ip> [output-dir]}"
OUT_DIR="${2:-}"
SSH_USER="${NEBULAOS_SSH_USER:-root}"
SSH_PASSWORD="${NEBULAOS_SSH_PASSWORD:-NebulaOS}"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

if [ -z "$OUT_DIR" ]; then
	OUT_DIR="$REPO_ROOT/build-work/display-live-investigation/capture-${DEVICE_IP}"
fi
mkdir -p "$OUT_DIR"

ASKPASS_SCRIPT=$(mktemp)
chmod 700 "$ASKPASS_SCRIPT"
# Single-quoted heredoc marker - do not interpolate $SSH_PASSWORD via shell
# expansion here (would embed a real secret in a process-listable argv);
# print it from a closed-over shell variable inside the script body instead.
cat > "$ASKPASS_SCRIPT" <<EOF
#!/bin/sh
printf '%s\n' "$SSH_PASSWORD"
EOF
cleanup() { rm -f "$ASKPASS_SCRIPT"; }
trap cleanup EXIT

# Run one read-only remote command, save its output, never abort the whole
# capture run if one command/group fails (a missing sysfs node on this
# kernel is itself a real, useful negative result - record it, don't crash).
remote() {
	label="$1"
	shift
	SSH_ASKPASS="$ASKPASS_SCRIPT" SSH_ASKPASS_REQUIRE=force ssh \
		-o PreferredAuthentications=password \
		-o PubkeyAuthentication=no \
		-o StrictHostKeyChecking=accept-new \
		-o ConnectTimeout=10 \
		"$SSH_USER@$DEVICE_IP" "$@" > "$OUT_DIR/$label.txt" 2> "$OUT_DIR/$label.stderr.txt" || {
		echo "  (non-fatal) $label: remote command exited non-zero or was unreachable - see $label.stderr.txt" >&2
	}
}

group_identity() {
	echo "== identity =="
	remote identity-hostname "hostname; uname -a; cat /proc/cmdline; uptime"
	remote identity-manifest "cat /usr/data/nebulaos/build-manifest.txt 2>/dev/null || cat /opt/build-manifest.txt 2>/dev/null || echo NO_MANIFEST_FOUND"
	remote identity-root-slot "cat /proc/mounts | grep ' / ' ; cat /etc/ota_marker* 2>/dev/null || true"
	remote identity-mac "cat /sys/class/net/wlan0/address 2>/dev/null || ip link show wlan0 2>/dev/null"
	remote identity-klipper "curl -s --max-time 5 http://127.0.0.1:7125/printer/info 2>/dev/null || echo NO_MOONRAKER_RESPONSE"
}

group_rt_kernel() {
	echo "== RT and kernel =="
	remote rt-realtime "cat /sys/kernel/realtime 2>/dev/null || echo NOT_PRESENT"
	remote rt-version "cat /proc/version"
	remote rt-config "zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_PREEMPT|CONFIG_HZ' || echo NO_CONFIG_GZ"
}

group_root_slot() {
	echo "== root slot =="
	remote rootslot-mounts "cat /proc/mounts"
	remote rootslot-partitions "cat /proc/partitions; ls -la /dev/disk/by-partlabel/ 2>/dev/null || true"
}

group_live_dt() {
	echo "== live device tree =="
	remote dt-dpu "find /sys/firmware/devicetree/base -iname '*dpu*' -o -iname '*13050000*' 2>/dev/null | while read -r n; do echo \"--\$n--\"; for f in \"\$n\"/*; do [ -f \"\$f\" ] && echo \"\$f: \$(od -An -tx1 \"\$f\" 2>/dev/null | tr -d ' \n')\"; done; done"
	remote dt-panel "find /sys/firmware/devicetree/base -iname '*panel*' -o -iname '*openke*' 2>/dev/null"
	remote dt-pwm "find /sys/firmware/devicetree/base -iname '*pwm*' 2>/dev/null"
	remote dt-backlight "find /sys/firmware/devicetree/base -iname '*backlight*' 2>/dev/null || echo NO_BACKLIGHT_NODE"
	remote dt-touch "find /sys/firmware/devicetree/base -iname '*ns2009*' -o -iname '*i2c4*' 2>/dev/null"
	remote dt-reserved-memory "find /sys/firmware/devicetree/base/reserved-memory -type d 2>/dev/null"
}

group_framebuffer() {
	echo "== framebuffer =="
	remote fb-class "for f in /sys/class/graphics/fb0/*; do [ -f \"\$f\" ] && echo \"\$f: \$(cat \"\$f\" 2>/dev/null)\"; done"
	remote fb-fbset "fbset -i 2>/dev/null || echo NO_FBSET"
	remote fb-modes "cat /sys/class/graphics/fb0/modes 2>/dev/null"
}

group_dpu() {
	echo "== DPU =="
	remote dpu-irq "cat /proc/interrupts | grep -i 'lcd\\|dpu\\|13050000' || echo NO_MATCHING_IRQ_LINE"
	remote dpu-irq-rate-10s "A=\$(cat /proc/interrupts | grep -i 'lcd\\|dpu'); sleep 10; B=\$(cat /proc/interrupts | grep -i 'lcd\\|dpu'); echo \"BEFORE: \$A\"; echo \"AFTER: \$B\""
	remote dpu-debugfs "find /sys/kernel/debug -iname '*dpu*' -o -iname '*ingenicfb*' 2>/dev/null || echo NO_DEBUGFS_DPU_NODE"
}

group_clocks() {
	echo "== clocks =="
	remote clocks-summary "cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -iE 'lcd|pwm|gate_lcd|div_lcd' || echo NO_DEBUGFS_CLK_SUMMARY"
}

group_interrupts() {
	echo "== interrupts (full snapshot) =="
	remote interrupts-full "cat /proc/interrupts"
}

group_gpio() {
	echo "== GPIO =="
	remote gpio-debugfs "cat /sys/kernel/debug/gpio 2>/dev/null || gpioinfo 2>/dev/null || echo NO_GPIO_DEBUG_INTERFACE"
}

group_pinctrl() {
	echo "== pinctrl =="
	remote pinctrl-debugfs "cat /sys/kernel/debug/pinctrl/*/pinmux-pins 2>/dev/null | grep -iE 'pwm|gpc0|gpc1|gpc21|gpc22|gpb16|gpc15' || echo NO_DEBUGFS_PINCTRL"
}

group_pwm() {
	echo "== PWM =="
	remote pwm-class "for c in /sys/class/pwm/*/; do echo \"--\$c--\"; for f in \"\$c\"*; do [ -f \"\$f\" ] && echo \"\$f: \$(cat \"\$f\" 2>/dev/null)\"; done; for n in \"\$c\"pwm*/; do [ -d \"\$n\" ] && for f in \"\$n\"*; do [ -f \"\$f\" ] && echo \"\$f: \$(cat \"\$f\" 2>/dev/null)\"; done; done; done"
	remote pwm-debugfs "cat /sys/kernel/debug/pwm 2>/dev/null || echo NO_DEBUGFS_PWM"
}

group_backlight() {
	echo "== backlight =="
	remote backlight-class "ls -la /sys/class/backlight/ 2>/dev/null || echo NO_BACKLIGHT_CLASS_DEVICES"
}

group_touch() {
	echo "== touch/input =="
	remote touch-devices "cat /proc/bus/input/devices"
	remote touch-i2c "ls /sys/bus/i2c/devices/ 2>/dev/null; i2cdetect -y \$(ls /sys/bus/i2c/devices/ | grep -o '^[0-9]*' | sort -n | tail -1) 2>/dev/null || echo NO_I2CDETECT"
	remote touch-gpio79 "cat /sys/kernel/debug/gpio 2>/dev/null | grep -i 'gpio-79\\|gpioc15\\|gpc15' || echo GPIO79_NOT_FOUND_IN_DEBUGFS"
	remote touch-irq "cat /proc/interrupts | grep -i 'ns2009\\|gpio' || echo NO_TOUCH_IRQ_LINE"
}

group_kernel_logs() {
	echo "== kernel logs =="
	remote klog-dmesg "dmesg 2>/dev/null | grep -iE 'dpu|lcd|panel|backlight|ns2009|touch|fb0|framebuffer' || dmesg | tail -200"
}

group_boot_timing() {
	echo "== boot timing =="
	remote boot-timing "cat /var/log/nebulaos-boot-timing* 2>/dev/null || echo NO_BOOT_TIMING_LOG"
}

echo "=== display-live-capture: target $SSH_USER@$DEVICE_IP, output $OUT_DIR ==="
echo "=== Run group_identity FIRST and confirm device identity before trusting any other group's output ==="

case "${3:-all}" in
	identity) group_identity ;;
	all)
		group_identity
		group_rt_kernel
		group_root_slot
		group_live_dt
		group_framebuffer
		group_dpu
		group_clocks
		group_interrupts
		group_gpio
		group_pinctrl
		group_pwm
		group_backlight
		group_touch
		group_kernel_logs
		group_boot_timing
		;;
	*)
		echo "unknown group '${3:-}' - use 'identity' or 'all' (or edit this script to call one group_* function directly)" >&2
		exit 1
		;;
esac

echo "=== capture complete: $OUT_DIR ==="
ls -la "$OUT_DIR"
