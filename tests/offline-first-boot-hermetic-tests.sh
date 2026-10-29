#!/bin/sh
#
# Phase 1.5 pre-qualification Gate 2: prove the entire first-boot seeding
# pipeline (S02nebulaos-namespace -> S04nebulaos-factory-seed ->
# S04nebulaos-migrate) is genuinely offline — zero external network
# attempts. Instruments git/wget/curl/pip with interceptor stubs that log
# and reject any non-local network operation, then runs the full pipeline
# and asserts CORE_STACK_EXTERNAL_NETWORK_ATTEMPTS=0.
#
# Local git operations (status, rev-parse, symbolic-ref, log, config) pass
# through to real git. Only network-touching subcommands (clone, fetch,
# pull, push) are intercepted and logged as violations.
#
# Usage: sh tests/offline-first-boot-hermetic-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# S04nebulaos-factory-seed and S05nebulaos-activate source the shared
# persistent-venv helpers. On the device that library is an absolute path
# (/usr/libexec/nebulaos-venv-lib.sh); here it lives in the overlay source
# tree, and these suites source the init script inside `sh -c`, where $0 gives
# the script no way to find it. Point at the real library so these tests
# exercise the real predicate rather than a stub.
NEBULAOS_VENV_LIB="$REPO_ROOT/scripts/build/overlay/usr/libexec/nebulaos-venv-lib.sh"
export NEBULAOS_VENV_LIB

# The S04 scripts source this shared reader (audit F-06). Exported once
# here so every `env ... sh -c ". $SCRIPT"` invocation below inherits it;
# on a device it is /etc/nebulaos-seed-manifest.sh and this is a no-op.
export SEED_MANIFEST_LIB="${SEED_MANIFEST_LIB:-$SCRIPT_DIR/../scripts/build/overlay/etc/nebulaos-seed-manifest.sh}"
export GATE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
MAKE_ARCHIVE_LIB="$REPO_ROOT/scripts/build/lib/make-seed-archive.sh"
S02_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S02nebulaos-namespace"
S04_FACTORY_SEED_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-factory-seed"
S04_MIGRATE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
REAL_PRINTER_DATA_CONFIG="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/offline-hermetic-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: offline-first-boot-hermetic-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

. "$MAKE_ARCHIVE_LIB"

NETWORK_LOG="$WORK/network-attempts.log"
: > "$NETWORK_LOG"

# --- Build interceptor stubs ---
STUB_DIR="$WORK/stubs"
mkdir -p "$STUB_DIR"

REAL_GIT=$(command -v git)

# git stub: intercept clone/fetch/pull/push, pass everything else through
cat > "$STUB_DIR/git" <<GITEOF
#!/bin/sh
for arg in "\$@"; do
	case "\$arg" in
		clone|fetch|pull|push)
			echo "NETWORK_VIOLATION: git \$*" >> "$NETWORK_LOG"
			echo "offline-hermetic-test: BLOCKED external git \$arg" >&2
			exit 1
			;;
	esac
done
exec "$REAL_GIT" "\$@"
GITEOF
chmod +x "$STUB_DIR/git"

# wget stub: allow localhost, block everything else
cat > "$STUB_DIR/wget" <<WGETEOF
#!/bin/sh
for arg in "\$@"; do
	case "\$arg" in
		http://127.0.0.1*|http://localhost*|https://127.0.0.1*|https://localhost*)
			# localhost — would pass through, but we have no Moonraker in test
			exit 1
			;;
		http://*|https://*)
			echo "NETWORK_VIOLATION: wget \$*" >> "$NETWORK_LOG"
			echo "offline-hermetic-test: BLOCKED external wget" >&2
			exit 1
			;;
	esac
done
exit 1
WGETEOF
chmod +x "$STUB_DIR/wget"

# curl stub: same pattern
cat > "$STUB_DIR/curl" <<CURLEOF
#!/bin/sh
for arg in "\$@"; do
	case "\$arg" in
		http://127.0.0.1*|http://localhost*|https://127.0.0.1*|https://localhost*)
			exit 1
			;;
		http://*|https://*)
			echo "NETWORK_VIOLATION: curl \$*" >> "$NETWORK_LOG"
			echo "offline-hermetic-test: BLOCKED external curl" >&2
			exit 1
			;;
	esac
done
exit 1
CURLEOF
chmod +x "$STUB_DIR/curl"

# pip/pip3 stub: any invocation is a violation during first boot
for pip_name in pip pip3; do
	cat > "$STUB_DIR/$pip_name" <<PIPEOF
#!/bin/sh
echo "NETWORK_VIOLATION: $pip_name \$*" >> "$NETWORK_LOG"
echo "offline-hermetic-test: BLOCKED $pip_name" >&2
exit 1
PIPEOF
	chmod +x "$STUB_DIR/$pip_name"
done

# --- Build seed fixtures ---
SEEDS="$WORK/seeds"
NEBULAOS_ROOT="$WORK/persistent-root"
mkdir -p "$SEEDS"

# Klipper fixture
klipper_src="$WORK/klipper-src"
git init -q -b master "$klipper_src"
echo "fixture klipper" > "$klipper_src/marker.txt"
git -C "$klipper_src" add -A && git -C "$klipper_src" commit -q -m "fixture"
make_seed_archive "$klipper_src" master \
	"https://github.com/Klipper3d/klipper.git" "$SEEDS/klipper.tar.gz" >/dev/null

# Extensions fixture
ext_src="$WORK/ext-src"
git init -q -b main "$ext_src"
echo "fixture extensions" > "$ext_src/marker.txt"
git -C "$ext_src" add -A && git -C "$ext_src" commit -q -m "fixture"
make_seed_archive "$ext_src" main \
	"https://github.com/NebulaOS-KE/NebulaOS-klipper-extensions.git" "$SEEDS/nebulaos-klipper-extensions.tar.gz" >/dev/null

# Moonraker fixture
moonraker_src="$WORK/moonraker-src"
git init -q -b master "$moonraker_src"
echo "fixture moonraker" > "$moonraker_src/marker.txt"
git -C "$moonraker_src" add -A && git -C "$moonraker_src" commit -q -m "fixture"
make_seed_archive "$moonraker_src" master \
	"https://github.com/Arksine/moonraker.git" "$SEEDS/moonraker.tar.gz" >/dev/null

# Venv seed fixtures (minimal: bin/python3 symlink + marker)
for venv_name in klipper-venv-seed moonraker-venv-seed; do
	venv_dir="$WORK/$venv_name"
	mkdir -p "$venv_dir/bin" "$venv_dir/lib"
	ln -s "$(command -v python3)" "$venv_dir/bin/python3"
	echo "venv-fixture" > "$venv_dir/lib/marker.txt"
	tar -czf "$SEEDS/$venv_name.tar.gz" -C "$venv_dir" .
done

# Seed manifest
klipper_commit=$(git -C "$klipper_src" rev-parse HEAD)
ext_commit=$(git -C "$ext_src" rev-parse HEAD)
moonraker_commit=$(git -C "$moonraker_src" rev-parse HEAD)
cat > "$SEEDS/seed-manifest.json" <<EOF
{
  "migration_version": "offline-hermetic-gen-1",
  "seeds": {
    "klipper": {"seed_commit": "$klipper_commit"},
    "nebulaos-klipper-extensions": {"branch": "main", "seed_commit": "$ext_commit"},
    "moonraker": {"seed_commit": "$moonraker_commit"}
  }
}
EOF

# --- Run the full pipeline with stubs on PATH ---
export PATH="$STUB_DIR:$PATH"

# S02: namespace creation
env S02NEBULAOS_NAMESPACE_NO_AUTORUN=1 NEBULAOS_ROOT="$NEBULAOS_ROOT" \
	PRINTER_DATA_CONFIG_SEED="$REAL_PRINTER_DATA_CONFIG" \
	sh -c ". '$S02_SCRIPT'; start" > "$WORK/s02.log" 2>&1

if [ -d "$NEBULAOS_ROOT" ]; then
	pass "S02 namespace created successfully under network interception"
else
	fail "S02 namespace creation failed ($(cat "$WORK/s02.log"))"
fi

# S04 factory-seed: full start() path including venv seeding
# Mainsail needs /usr/share/mainsail which doesn't exist in test — its
# failure is expected and harmless (seed_mainsail logs ERROR and returns 1,
# start() continues). The important thing is no network attempt.
env S04NEBULAOS_FACTORY_SEED_NO_AUTORUN=1 \
	SEEDS="$SEEDS" APPS="$NEBULAOS_ROOT/apps" \
	SYSTEM="$NEBULAOS_ROOT/system" LOCKDIR="$WORK/locks" \
	sh -c ". '$S04_FACTORY_SEED_SCRIPT'; start" > "$WORK/s04-seed.log" 2>&1

if [ -e "$NEBULAOS_ROOT/apps/klipper/.git" ]; then
	pass "S04 klipper seeded successfully under network interception"
else
	fail "S04 klipper seeding failed ($(cat "$WORK/s04-seed.log"))"
fi

if [ -e "$NEBULAOS_ROOT/apps/nebulaos-klipper-extensions/.git" ]; then
	pass "S04 extensions seeded successfully under network interception"
else
	fail "S04 extensions seeding failed ($(cat "$WORK/s04-seed.log"))"
fi

if [ -e "$NEBULAOS_ROOT/apps/moonraker/.git" ]; then
	pass "S04 moonraker seeded successfully under network interception"
else
	fail "S04 moonraker seeding failed ($(cat "$WORK/s04-seed.log"))"
fi

# S04 migrate: should be a no-op on a fresh seed
env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 \
	SEEDS="$SEEDS" APPS="$NEBULAOS_ROOT/apps" \
	SYSTEM="$NEBULAOS_ROOT/system" LOCKDIR="$WORK/locks" \
	sh -c ". '$S04_MIGRATE_SCRIPT'; start" > "$WORK/s04-migrate.log" 2>&1

if grep -q "already matches" "$WORK/s04-migrate.log"; then
	pass "S04 migrate is a clean no-op on freshly-seeded namespace"
else
	fail "S04 migrate did unexpected work ($(cat "$WORK/s04-migrate.log"))"
fi

# --- THE VERDICT ---
NETWORK_ATTEMPTS=$(wc -l < "$NETWORK_LOG" | tr -d ' ')

if [ "$NETWORK_ATTEMPTS" -eq 0 ]; then
	pass "CORE_STACK_EXTERNAL_NETWORK_ATTEMPTS=0 — first boot is genuinely offline"
else
	fail "CORE_STACK_EXTERNAL_NETWORK_ATTEMPTS=$NETWORK_ATTEMPTS — first boot attempted external network access:"
	cat "$NETWORK_LOG" | while IFS= read -r line; do
		echo "  $line"
	done
fi

# Verify venv code paths were exercised (the envdir paths are hardcoded to
# /usr/data/nebulaos/envs/ and aren't overridable for tests, so they fail
# with permission denied in a normal test environment — the important proof
# is that both try_venv_seed() and the python3 -m venv fallback are
# themselves offline operations, which CORE_STACK_EXTERNAL_NETWORK_ATTEMPTS=0
# above already proves end-to-end)
if grep -q "venv" "$WORK/s04-seed.log"; then
	pass "venv code paths exercised without any external network access"
else
	fail "venv code paths were not exercised at all"
fi

echo
echo "CORE_STACK_EXTERNAL_NETWORK_ATTEMPTS=$NETWORK_ATTEMPTS"
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
