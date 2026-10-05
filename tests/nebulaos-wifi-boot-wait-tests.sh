#!/bin/sh
#
# Offline, repeatable tests for scripts/build/overlay/etc/nebulaos-wifi-
# boot-wait.sh (pre-qualification mission Phase A6, 2026-07-31). Sources
# the actual production library. Fakes `wpa_cli` on PATH so no real
# wpa_supplicant instance is needed. Uses short timeouts for the event-
# driven-path tests; the one fixed-path test genuinely waits out the
# real, unparameterized `sleep 2` on purpose - it exists specifically to
# prove that path is byte-for-byte the original untouched behavior, not
# a parameterized/shortened stand-in for it.
#
# Usage: sh tests/nebulaos-wifi-boot-wait-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LIB="$SCRIPT_DIR/../scripts/build/overlay/etc/nebulaos-wifi-boot-wait.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulaos-wifi-boot-wait-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: nebulaos-wifi-boot-wait-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=$((FAIL + 1))
}

pass() {
	PASS=$((PASS + 1))
}

[ -f "$LIB" ] || { echo "FATAL: $LIB not found"; exit 1; }
# shellcheck disable=SC1090
. "$LIB"

NEBULAOS_WIFI_BOOT_WAIT_MIN=0
NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT=2

FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
FAKE_WPA_STATE="$WORK/wpa-state"

# --- Test 1: no marker present -> requested mode is "fixed". ---
MARKER="$WORK/marker-absent"
mode=$(nebulaos_wifi_boot_wait_requested_mode "$MARKER")
if [ "$mode" = "fixed" ]; then
	pass
else
	fail "requested mode with no marker file was '$mode', expected fixed"
fi

# --- Test 2: marker containing event-driven -> requested mode is
# event-driven. ---
MARKER="$WORK/marker-event"
printf 'event-driven\n' > "$MARKER"
mode=$(nebulaos_wifi_boot_wait_requested_mode "$MARKER")
if [ "$mode" = "event-driven" ]; then
	pass
else
	fail "requested mode with an event-driven marker was '$mode', expected event-driven"
fi

# --- Test 3: an unrecognized marker value fails safe to "fixed". ---
MARKER="$WORK/marker-garbage"
printf 'banana\n' > "$MARKER"
mode=$(nebulaos_wifi_boot_wait_requested_mode "$MARKER")
if [ "$mode" = "fixed" ]; then
	pass
else
	fail "an unrecognized marker value produced '$mode' instead of failing safe to fixed"
fi

# --- Test 4: event-driven wait returns quickly (fast path) when
# association is already COMPLETED. ---
cat > "$FAKE_BIN/wpa_cli" <<'EOF'
#!/bin/sh
echo "wpa_state=COMPLETED"
exit 0
EOF
chmod +x "$FAKE_BIN/wpa_cli"
start_s=$(date +%s 2>/dev/null || echo 0)
PATH="$FAKE_BIN:$PATH" nebulaos_wifi_wait_for_association_event_driven testif >/dev/null 2>&1
rc=$?
end_s=$(date +%s 2>/dev/null || echo 0)
elapsed=$((end_s - start_s))
if [ "$rc" -eq 0 ] && [ "$elapsed" -le 1 ]; then
	pass
else
	fail "fast-path association wait did not return quickly with success (rc=$rc elapsed=${elapsed}s)"
fi

# --- Test 5: event-driven wait times out (not indefinitely) when
# association never completes, and still returns control to the caller. ---
cat > "$FAKE_BIN/wpa_cli" <<'EOF'
#!/bin/sh
echo "wpa_state=SCANNING"
exit 0
EOF
chmod +x "$FAKE_BIN/wpa_cli"
start_s=$(date +%s 2>/dev/null || echo 0)
if PATH="$FAKE_BIN:$PATH" nebulaos_wifi_wait_for_association_event_driven testif >/dev/null 2>&1; then
	fail "wait reported success even though association never completed"
else
	end_s=$(date +%s 2>/dev/null || echo 0)
	elapsed=$((end_s - start_s))
	if [ "$elapsed" -ge "$NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT" ] && [ "$elapsed" -le $((NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT + 2)) ]; then
		pass
	else
		fail "wait did not respect the configured timeout bound (elapsed=${elapsed}s, timeout=${NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT}s)"
	fi
fi

# --- Test 6: orchestration in "fixed" mode does not invoke wpa_cli at
# all (proves it takes the untouched sleep-only path). ---
rm -f "$FAKE_BIN/wpa_cli"
cat > "$FAKE_BIN/wpa_cli" <<'EOF'
#!/bin/sh
echo "called" >> "$FAKE_WPA_CALLED"
echo "wpa_state=COMPLETED"
EOF
chmod +x "$FAKE_BIN/wpa_cli"
FAKE_WPA_CALLED="$WORK/wpa-called"
export FAKE_WPA_CALLED
: > "$FAKE_WPA_CALLED"
NEBULAOS_WIFI_BOOT_WAIT_MARKER="$WORK/marker-absent-2"
PATH="$FAKE_BIN:$PATH" nebulaos_wifi_boot_wait testif >/dev/null 2>&1
if [ ! -s "$FAKE_WPA_CALLED" ]; then
	pass
else
	fail "fixed-mode orchestration unexpectedly invoked wpa_cli"
fi

# --- Test 7: orchestration in "event-driven" mode does invoke wpa_cli
# (proves the marker correctly switches which path runs). ---
: > "$FAKE_WPA_CALLED"
NEBULAOS_WIFI_BOOT_WAIT_MARKER="$WORK/marker-event-2"
printf 'event-driven\n' > "$NEBULAOS_WIFI_BOOT_WAIT_MARKER"
PATH="$FAKE_BIN:$PATH" nebulaos_wifi_boot_wait testif >/dev/null 2>&1
if [ -s "$FAKE_WPA_CALLED" ]; then
	pass
else
	fail "event-driven-mode orchestration did not invoke wpa_cli at all"
fi

# ============================================================
# BOOT-02 (2026-10-05): one-shot selector, fallbacks, result file
# ============================================================
RES="$WORK/result"
NEBULAOS_WIFI_BOOT_WAIT_RESULT="$RES"
NEBULAOS_WIFI_BOOT_WAIT_FIXED_SLEEP=0
printf '42.10 1\n' > "$WORK/uptime"; NEBULAOS_WIFI_UPTIME_SRC="$WORK/uptime"

# --- Test 8: test 7's marker was consumed; the next boot is fixed. ---
[ -e "$WORK/marker-event-2" ] && fail "event-driven marker survived its boot (sticky)" || pass
: > "$FAKE_WPA_CALLED"
PATH="$FAKE_BIN:$PATH" nebulaos_wifi_boot_wait testif >/dev/null 2>&1
[ ! -s "$FAKE_WPA_CALLED" ] && grep -qx 'MODE=fixed' "$RES" && pass || fail "boot after a consumed marker was not on the fixed path"

# --- Test 9: take_mode consumes valid and malformed markers alike. ---
M="$WORK/m9"; printf 'event-driven\n' > "$M"
[ "$(nebulaos_wifi_boot_wait_take_mode "$M")" = event-driven ] && [ ! -e "$M" ] && pass || fail "valid marker not taken+consumed"
[ "$(nebulaos_wifi_boot_wait_take_mode "$M")" = fixed ] && pass || fail "second take did not return fixed"
printf 'event-driven-ish\n' > "$M"
[ "$(nebulaos_wifi_boot_wait_take_mode "$M")" = fixed ] && [ ! -e "$M" ] && pass || fail "malformed marker not consumed as fixed"
: > "$M"
[ "$(nebulaos_wifi_boot_wait_take_mode "$M")" = fixed ] && [ ! -e "$M" ] && pass || fail "empty marker not consumed as fixed"

# --- Test 10: a marker that cannot be removed is never honoured. ---
mkdir -p "$WORK/ro"; printf 'event-driven\n' > "$WORK/ro/m"; chmod 555 "$WORK/ro"
if [ -w "$WORK/ro" ]; then
	echo "NOTE: running as root - read-only-dir case not reproducible here"; pass
else
	[ "$(nebulaos_wifi_boot_wait_take_mode "$WORK/ro/m" 2>/dev/null)" = fixed ] && [ -e "$WORK/ro/m" ] && pass \
		|| fail "an unremovable marker was honoured (would be sticky)"
fi
chmod 755 "$WORK/ro"

# --- Test 11: association arrives during the wait. ---
printf '#!/bin/sh\nn=$(cat "$FAKE_WPA_N" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$FAKE_WPA_N"\n[ $n -ge 2 ] && echo "wpa_state=COMPLETED" || echo "wpa_state=ASSOCIATING"\n' > "$FAKE_BIN/wpa_cli"
chmod +x "$FAKE_BIN/wpa_cli"; FAKE_WPA_N="$WORK/wpa-n"; export FAKE_WPA_N; echo 0 > "$FAKE_WPA_N"
NEBULAOS_WIFI_BOOT_WAIT_MARKER="$WORK/m11"; printf 'event-driven\n' > "$NEBULAOS_WIFI_BOOT_WAIT_MARKER"
NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT=4
PATH="$FAKE_BIN:$PATH" nebulaos_wifi_boot_wait testif >/dev/null 2>&1
grep -qx 'MODE=event-driven' "$RES" && grep -qx 'OUTCOME=associated' "$RES" && grep -qx 'ASSOC_AFTER=1' "$RES" && pass \
	|| fail "association during the wait not recorded ($(tr '\n' ' ' < "$RES"))"
grep -qx 'WAIT_START=42.10' "$RES" && grep -qx 'WAIT_END=42.10' "$RES" && pass || fail "uptime stamps missing"

# --- Test 12: association never arrives -> bounded timeout -> fallback. ---
printf '#!/bin/sh\necho "wpa_state=SCANNING"\n' > "$FAKE_BIN/wpa_cli"; chmod +x "$FAKE_BIN/wpa_cli"
NEBULAOS_WIFI_BOOT_WAIT_MARKER="$WORK/m12"; printf 'event-driven\n' > "$NEBULAOS_WIFI_BOOT_WAIT_MARKER"
NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT=2
s0=$(date +%s); PATH="$FAKE_BIN:$PATH" nebulaos_wifi_boot_wait testif >/dev/null 2>&1; rc=$?; s1=$(date +%s)
[ $rc -eq 0 ] && grep -qx 'OUTCOME=timeout-fallback' "$RES" && [ $((s1 - s0)) -le 4 ] && pass \
	|| fail "timeout fallback wrong (rc=$rc, $((s1 - s0))s, $(tr '\n' ' ' < "$RES"))"

# --- Test 13: wpa_cli missing -> immediate fixed fallback, no timeout wait. ---
NOWPA="$WORK/nowpa"; mkdir -p "$NOWPA"
for b in sleep cat rm sync date printf; do p=$(command -v $b) && ln -sf "$p" "$NOWPA/$b"; done
NEBULAOS_WIFI_BOOT_WAIT_MARKER="$WORK/m13"; printf 'event-driven\n' > "$NEBULAOS_WIFI_BOOT_WAIT_MARKER"
NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT=10
s0=$(date +%s); PATH="$NOWPA" nebulaos_wifi_boot_wait testif >/dev/null 2>&1; s1=$(date +%s)
grep -qx 'OUTCOME=no-wpa_cli-fallback' "$RES" && [ $((s1 - s0)) -le 2 ] && [ ! -e "$WORK/m13" ] && pass \
	|| fail "missing wpa_cli not handled ($(tr '\n' ' ' < "$RES"))"

# --- Test 14: ifup result recorded; a failure is reported, never fatal. ---
nebulaos_wifi_boot_wait_record_ifup 0; grep -qx 'IFUP_RC=0' "$RES" && ! grep -q 'IFUP=failed' "$RES" && pass || fail "ifup success not recorded"
nebulaos_wifi_boot_wait_record_ifup 1 2>/dev/null; rc=$?
[ $rc -eq 0 ] && grep -qx 'IFUP=failed-reported' "$RES" && pass || fail "ifup failure not reported safely (rc=$rc)"

# --- Test 15: an unusable result path / uptime never breaks the wait. ---
NEBULAOS_WIFI_BOOT_WAIT_RESULT="$WORK/no-such-dir/result"; NEBULAOS_WIFI_BOOT_WAIT_MARKER="$WORK/m15"
PATH="$FAKE_BIN:$PATH" nebulaos_wifi_boot_wait testif >/dev/null 2>&1; rc=$?
nebulaos_wifi_boot_wait_record_ifup 1 >/dev/null 2>&1; rc2=$?
[ $rc -eq 0 ] && [ $rc2 -eq 0 ] && pass || fail "unwritable result path broke the wait (rc=$rc/$rc2)"
NEBULAOS_WIFI_BOOT_WAIT_RESULT="$RES"; NEBULAOS_WIFI_UPTIME_SRC="$WORK/no-uptime"
PATH="$FAKE_BIN:$PATH" nebulaos_wifi_boot_wait testif >/dev/null 2>&1
grep -qx 'WAIT_START=?' "$RES" && pass || fail "missing /proc/uptime not reported as ?"

# --- Test 16: full S01wifi simulation (sandboxed paths, fake daemons). ---
SB="$WORK/s01"; mkdir -p "$SB/etc" "$SB/bin" "$SB/maint"
S01SRC="$SCRIPT_DIR/../scripts/build/overlay/etc/init.d/S01wifi"
sed -e "s#/etc/nebulaos-#$SB/etc/nebulaos-#g" -e "s#/sbin/ifup#$SB/bin/ifup#g" -e "s#/sbin/ifdown#$SB/bin/ifdown#g" \
	-e "s#/var/run/#$SB/#g" "$S01SRC" > "$SB/S01wifi"
cp "$LIB" "$SB/etc/nebulaos-wifi-boot-wait.sh"
printf 'NEBULAOS_WIFI_CONF=%s/wpa.conf\nnebulaos_wifi_migrate() { :; }\n' "$SB" > "$SB/etc/nebulaos-wifi-migrate.sh"
: > "$SB/wpa.conf"
printf '#!/bin/sh\necho "ssd $*" >> %s/calls\n' "$SB" > "$SB/bin/start-stop-daemon"
printf '#!/bin/sh\necho "ifup $*" >> %s/calls\nexit ${IFUP_RC:-0}\n' "$SB" > "$SB/bin/ifup"
printf '#!/bin/sh\necho "wpa_state=COMPLETED"\n' > "$SB/bin/wpa_cli"
chmod +x "$SB/bin/"*
s01() { env PATH="$SB/bin:$PATH" NEBULAOS_WIFI_BOOT_WAIT_MARKER="$SB/maint/wifi-boot-wait-mode" \
	NEBULAOS_WIFI_BOOT_WAIT_RESULT="$SB/result" NEBULAOS_WIFI_BOOT_WAIT_MIN=0 NEBULAOS_WIFI_BOOT_WAIT_FIXED_SLEEP=0 \
	NEBULAOS_WIFI_UPTIME_SRC=/proc/uptime IFUP_RC="${IFUP_RC:-0}" NEBULAOS_WLAN_SYSFS="${WLAN_SYSFS:-$SB}" \
	NEBULAOS_WLAN_WAIT_TENTHS="${WLAN_TENTHS:-100}" sh "$SB/S01wifi" start > "$SB/out" 2>&1; }
printf 'event-driven\n' > "$SB/maint/wifi-boot-wait-mode"
IFUP_RC=0; s01; rc=$?
[ $rc -eq 0 ] && grep -qx 'MODE=event-driven' "$SB/result" && grep -qx 'OUTCOME=associated' "$SB/result" \
	&& grep -qx 'IFUP_RC=0' "$SB/result" && [ ! -e "$SB/maint/wifi-boot-wait-mode" ] && pass \
	|| fail "S01 event-driven boot wrong (rc=$rc, $(tr '\n' ' ' < "$SB/result"), $(cat "$SB/out"))"
s01; grep -qx 'MODE=fixed' "$SB/result" && grep -qx 'OUTCOME=fixed' "$SB/result" && pass || fail "S01 next boot not back on the fixed path"
IFUP_RC=1; s01; rc=$?; IFUP_RC=0
[ $rc -eq 0 ] && grep -qx 'IFUP=failed-reported' "$SB/result" && pass || fail "S01 with failing ifup did not report safely (rc=$rc)"
[ "$(grep -c '^ifup wlan0' "$SB/calls")" = 3 ] && pass || fail "S01 did not run exactly one ifup per boot"
grep -hv '^[[:space:]]*#' "$SB/S01wifi" "$LIB" | grep -qw 'reboot' && fail "S01/lib can reboot" || pass
# BOOT-06: wlan0 appears late -> S01 waits for it (bounded), then proceeds
rm -rf "$SB/late-wlan0"; ( sleep 0.4; mkdir -p "$SB/late-wlan0" ) &
WLAN_SYSFS="$SB/late-wlan0"; s01; rc=$?; WLAN_SYSFS=
[ $rc -eq 0 ] && grep -q 'waited 0\.[3-9] s for wlan0' "$SB/out" && grep -c '^ssd -S' "$SB/calls" | grep -qx 4 && pass \
	|| fail "S01 did not wait for a late wlan0 ($(cat "$SB/out"))"
# wlan0 never appears -> bounded, boot continues, wpa_supplicant still started once
s0=$(date +%s); WLAN_SYSFS="$SB/never-wlan0"; WLAN_TENTHS=5; s01; rc=$?; WLAN_SYSFS=; WLAN_TENTHS=; s1=$(date +%s)
[ $rc -eq 0 ] && grep -q 'wlan0 did not appear' "$SB/out" && [ $((s1 - s0)) -le 3 ] && pass \
	|| fail "S01 missing-wlan0 case not bounded/safe (rc=$rc $((s1 - s0))s, $(cat "$SB/out"))"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
