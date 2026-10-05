#!/bin/sh
# Live gap verification G8 (2026-10-05): why the mainsail-macros seeder logs
# "failed" on every boot. Shows the boot log and marker, then runs the image's
# seeder run() against the live Moonraker with every POST and DELETE replaced
# by a stub that refuses and records the would-be write (reads are real), and
# a marker path in tmpfs. No Moonraker database entry is written or deleted.
L=/run/nebulaos-live-verify; mkdir -p $L
LOG=/usr/data/nebulaos/maintenance/logs/mainsail-macros-seed.log
echo "== seed log: $(wc -l < $LOG) lines, $(grep -c 'marker written' $LOG) runs"
grep -n 'marker written' $LOG | tail -3 | cut -c1-600
echo "== last run"; awk '/attempt 1\/|Moonraker database API|migration|rc3|group|mode default|marker written/' $LOG | tail -40 | cut -c1-300
echo "== distinct failure lines"; grep -iE 'fail|could not|error' $LOG | sed 's/[0-9]\{4\}-[0-9-]*T[0-9:]*Z//' | sort | uniq -c | sort -rn | head -12 | cut -c1-300
echo "== marker"; cat /usr/data/nebulaos/system/default-mainsail-macros-seeded.json 2>&1 | head -40
echo "== dry run (reads real, writes refused)"
cat > $L/g8dry.py <<'G8_PY'
import importlib.machinery, importlib.util, json, sys, time
loader = importlib.machinery.SourceFileLoader("seed", "/usr/libexec/nebulaos-seed-mainsail-macros")
spec = importlib.util.spec_from_loader("seed", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
writes = []
gets = []
def get_status(path):
    t = time.monotonic()
    try:
        st, body = m.real_http_get_status(path)
        gets.append((path, st, int((time.monotonic() - t) * 1000)))
        return st, body
    except Exception as e:
        gets.append((path, "EXC %s" % e, int((time.monotonic() - t) * 1000)))
        raise
def post(path, payload):
    writes.append(("POST", payload.get("key")))
    raise RuntimeError("DRY_RUN_WRITE_REFUSED")
def delete(path):
    writes.append(("DELETE", path))
    raise RuntimeError("DRY_RUN_WRITE_REFUSED")
rc = m.run(get_status=get_status, post=post, delete=delete, marker_path=sys.argv[1],
           log=lambda s: print("  LOG " + s[:300]), retry_attempts=3, retry_delay=1)
print("DRY_RUN rc=%d reads=%d would_write=%d" % (rc, len(gets), len(writes)))
for g in gets:
    print("  GET %s -> %s (%d ms)" % g)
for w in writes:
    print("  WOULD %s %s" % w)
print("legacy_map=%s" % json.dumps(m.LEGACY_GROUP_ID_MAP))
G8_PY
python3 $L/g8dry.py $L/g8-marker.json 2>&1 | cut -c1-400
echo "== dry-run marker"; cat $L/g8-marker.json 2>/dev/null
rm -f $L/g8dry.py $L/g8-marker.json
