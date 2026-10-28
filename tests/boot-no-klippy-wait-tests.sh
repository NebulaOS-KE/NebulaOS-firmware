#!/bin/sh
#
# G103 P4 (Run 21): the boot does not wait for Klippy's startup. S95's
# MCU-recovery watch and S99confirm-good's health log return at once and do
# their work in the background (S97 is covered by
# nebulaos-display-qualified-tests.sh). No network: a fake wget answers.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INITD="$SCRIPT_DIR/../scripts/build/overlay/etc/init.d"
W=$(mktemp -d "${TMPDIR:-/tmp}/boot-no-klippy-wait.XXXXXX") || exit 1
[ -n "$W" ] && [ -d "$W" ] || exit 1
trap 'rm -rf "$W"' EXIT INT TERM

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

mkdir -p "$W/bin" "$W/etc"
# klippy_state=ready after a short delay (Klippy still starting meanwhile)
cat > "$W/bin/wget" <<EOT
#!/bin/sh
echo call >> "$W/wget-calls"
[ -f "$W/klippy-ready" ] || exit 1
echo '{"result":{"klippy_state":"ready"}}'
EOT
chmod +x "$W/bin/wget"
: > "$W/etc/ota_marker.sh"

wait_for() { # file pattern
	n=0
	while ! grep -q "$2" "$1" 2>/dev/null; do
		n=$((n + 1)); [ $n -gt 80 ] && return 1; sleep 0.1
	done
}

# --- S95: returns at once, the watch sees Klippy become ready later ---
sed -e "s#^MARKER=.*#MARKER=$W/s95-marker#" -e 's#^POLL_DELAY=.*#POLL_DELAY=0.2#' \
	"$INITD/S95mcu-boot-recovery" > "$W/S95"
rm -f "$W/klippy-ready"
s0=$(date +%s)
PATH="$W/bin:$PATH" sh "$W/S95" start > "$W/s95.out" 2>&1; rc=$?
s1=$(date +%s)
[ $rc -eq 0 ] && [ $((s1 - s0)) -le 1 ] && pass || fail "S95 start waited for Klippy (rc=$rc, $((s1 - s0)) s)"
touch "$W/klippy-ready"
wait_for "$W/s95.out" "reached ready on its own" && pass || fail "S95 background watch did not see Klippy ready ($(cat "$W/s95.out"))"
PATH="$W/bin:$PATH" sh "$W/S95" start > "$W/s95b.out" 2>&1
grep -q "already ran this boot" "$W/s95b.out" && pass || fail "S95 marker no longer stops a second run"
rm -f "$W/s95-marker" "$W/klippy-ready"
NEBULAOS_MCU_RECOVERY_FOREGROUND=1 PATH="$W/bin:$PATH" sh "$W/S95" start > "$W/s95c.out" 2>&1 &
fg=$!; sleep 0.5
kill -0 $fg 2>/dev/null && pass || fail "S95 foreground mode did not wait"
touch "$W/klippy-ready"; wait $fg

# --- S99confirm-good: returns at once, logs the verdict in the background ---
sed -e "s#^\. /etc/ota_marker.sh#. $W/etc/ota_marker.sh#" -e 's#^DELAY=.*#DELAY=0.2#' \
	"$INITD/S99confirm-good" > "$W/S99"
rm -f "$W/klippy-ready"
s0=$(date +%s)
PATH="$W/bin:$PATH" sh "$W/S99" start > "$W/s99.out" 2>&1; rc=$?
s1=$(date +%s)
[ $rc -eq 0 ] && [ $((s1 - s0)) -le 1 ] && pass || fail "S99confirm-good waited for Klippy (rc=$rc, $((s1 - s0)) s)"
touch "$W/klippy-ready"
wait_for "$W/s99.out" "confirmed healthy" && pass || fail "S99confirm-good background check did not log the verdict"
rm -f "$W/klippy-ready"
NEBULAOS_CONFIRM_GOOD_FOREGROUND=1 PATH="$W/bin:$PATH" sh -c "sed 's/^RETRIES=.*/RETRIES=2/' '$W/S99' > '$W/S99f'; sh '$W/S99f' start" > /dev/null 2>&1
[ $? -eq 1 ] && pass || fail "S99confirm-good foreground mode lost its failure exit code"

echo "boot-no-klippy-wait-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
