"""Read-only capture profiles for the hardware decision points (TOOL-01).

Every profile is a FIXED shell text composed here. The caller chooses only a
profile NAME from CAPTURE_PROFILES; nothing the caller types is interpolated
into a device command. A profile:

  - runs under /tmp/nebulaos-capture.$$ (tmpfs), removed on exit;
  - prints CAPTURE_PROFILE=, START_UTC= and END_UTC= so an operator can align
    load steps performed outside the profile;
  - changes no device state. Profiles that need a write (USB power control,
    the SOF-filter switch, a memory load, a camera pause) are EXERCISE
    profiles (TOOL-02), not captures, and are listed in EXERCISE_ONLY;
  - refuses with PROFILE_REQUIRES_DIAGNOSTIC_IMAGE on a production kernel
    when it needs the diagnostic kernel (uname -r ending in -diag).

Probe-based profiles embed a tracked tools/hwcap/*.py file. Those files are
pinned in CONTROL_MANIFEST as host files, so the control layer has already
compared the running copies with control commit C before any operation runs.

The profile bodies are taken from 09-programmer-execution-plan.md (TOOL-01
and Appendices A/B); where the plan gives two definitions for one name, the
Appendix definition wins, as the plan specifies.
"""

import os

FW_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HWCAP_DIR = os.path.join(FW_ROOT, "tools", "hwcap")

PROBES = ("schedsnap.py", "timerlat.py", "ptyrtt.py", "kduty.py", "adxl_overflows.py", "qualmcu.py",
          "lv_m1.py", "lv_s1.sh", "lv_s2.sh", "lv_g5.sh", "lv_cam.sh", "lv_g6.sh", "lv_g7.sh", "lv_g8.sh", "lv_g9.sh", "lv_g10.sh", "lv_ng1.py", "pf_cam.sh", "fb_ng3.sh", "fb_cam10.sh",
          "gs_services.sh", "gs_display.sh", "gs_sleep.sh", "gs_bootmode.sh", "gs_wifi.sh")
# Pinned data files embedded compressed (dropbear refuses a command longer than
# MAX_CMD_LEN = 9000 bytes, so a whole profile must stay under SCRIPT_LIMIT).
DATA_FILES = ("klipper-dict-board.json",)
SCRIPT_LIMIT = 8800

# Logs live under /opt/printer_data/logs (bind-mounted from /usr/data).
KLIPPY_LOG = "/opt/printer_data/logs/klippy.log"

_RT_SPLAT = ("P='BUG: sleeping function called from invalid context|BUG: scheduling while atomic|"
             "BUG: using smp_processor_id\\(\\) in preemptible|WARNING: .*lockdep|possible recursive locking|"
             "inconsistent lock state|invalid wait context|rcu: INFO: rcu_preempt detected stalls|hung_task'; "
             "echo \"splat_count=$(dmesg | grep -cE \"$P\")\"; dmesg | grep -B2 -A40 -E \"$P\" | head -600")

_THREADS_PY = "python3 $T/schedsnap.py --interval 60 --out $T/out.json; cat $T/out.json"

_MEMPROC = ("for p in /proc/[0-9]*; do printf '%s %s adj=%s ' ${p#/proc/} \"$(cat $p/comm 2>/dev/null)\" "
            "\"$(cat $p/oom_score_adj 2>/dev/null)\"; grep -E '^(VmRSS|VmLck|VmSwap|Threads)' $p/status 2>/dev/null "
            "| tr -s ' \\n' ' '; echo; done; "
            "tr '\\0' '\\n' < /proc/$(cat /var/run/moonraker.pid 2>/dev/null)/environ 2>/dev/null | grep -E '^(TMPDIR|PATH)='")

_MEMSTATE = ("cat /proc/meminfo; cat /proc/swaps; cat /proc/vmstat; cat /proc/pressure/memory 2>/dev/null || echo NO_PSI; "
             "for f in comp_algorithm disksize mm_stat io_stat mem_limit; do echo \"== $f\"; cat /sys/block/zram0/$f 2>/dev/null; done; "
             "for k in swappiness page-cluster min_free_kbytes watermark_scale_factor; do echo \"$k=$(cat /proc/sys/vm/$k)\"; done; "
             "df -k /tmp /run /dev/shm /usr/data; du -sk /tmp/* /run/* /dev/shm/* 2>/dev/null | sort -n | tail -20; "
             "cat /proc/device-tree/reserved-memory/*/status 2>/dev/null; ls /proc/device-tree/reserved-memory/; "
             "dmesg | grep -E 'Memory:|reserved memory|vidmem|oom|page allocation failure|zram'; "
             "cat /run/nebulaos/memguard/state 2>/dev/null; tail -n 200 /usr/data/nebulaos/logs/memguard.log 2>/dev/null; "
             "ls /run/nebulaos /run/nebulaos/shed /run/nebulaos/memguard 2>/dev/null")

_USB_TOPOLOGY = ("for d in /sys/bus/usb/devices/*; do echo \"$d $(cat $d/idVendor 2>/dev/null):$(cat $d/idProduct 2>/dev/null) "
                 "$(cat $d/speed 2>/dev/null) $(cat $d/power/control 2>/dev/null) $(cat $d/power/runtime_status 2>/dev/null) "
                 "$(cat $d/power/autosuspend_delay_ms 2>/dev/null)\"; for e in $d/ep_* $d/*:*/ep_*; do [ -d $e ] && "
                 "echo \"  $e $(cat $e/type) $(cat $e/direction) $(cat $e/interval) $(cat $e/wMaxPacketSize)\"; done; done; "
                 "lsusb -t 2>/dev/null; cat /sys/kernel/debug/usb/devices 2>/dev/null")

_DWC2_HW = ("mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug 2>/dev/null; D=/sys/kernel/debug/usb/13500000.otg; "
            "cat $D/hw_params $D/params $D/dr_mode $D/sof_filter 2>/dev/null; "
            "grep -E 'GSNPSID|GHWCFG[1-4]|GOTGCTL|GUSBCFG|GINTMSK|GAHBCFG|HCFG|HPRT0' $D/regdump 2>/dev/null; "
            "find /sys/devices -name dwc2_mode -exec cat {} \\; 2>/dev/null; "
            "cat /sys/module/dwc2/parameters/sof_filter 2>/dev/null; dmesg | grep -i dwc2")

_IRQ_RATE = ("a=$(awk '$1==\"9:\"{print $2+$3}' /proc/interrupts); sleep 10; b=$(awk '$1==\"9:\"{print $2+$3}' /proc/interrupts); "
             "echo \"irq9_per_s=$(( (b-a)/10 ))\"; "
             "for p in /proc/[0-9]*; do c=$(cat $p/comm 2>/dev/null); case \"$c\" in irq/9-*|ksoftirqd/*|ktimers/*) "
             "echo \"$c $(awk '{print $14, $15}' $p/stat) $(grep -E 'nr_switches|^policy|^prio' $p/sched 2>/dev/null | tr -s ' \\n' ' ')\";; esac; done; "
             "cat /sys/kernel/debug/usb/13500000.otg/sof_filter 2>/dev/null")

_BOOT_TIMING = (
    "echo '== uptime'; cat /proc/uptime; echo \"now_epoch=$(date +%s)\"; date; "
    "echo \"boot_id=$(cat /proc/sys/kernel/random/boot_id)\"; "
    "echo '== boot-timing-log'; cat /var/run/nebulaos-boot-timing.log 2>/dev/null || echo NO_BOOT_TIMING_LOG; "
    "echo '== boot-scripts-log'; cat /run/nebulaos-boot-scripts.log 2>/dev/null || echo NO_BOOT_SCRIPTS_LOG; "
    "echo '== swaps'; cat /proc/swaps; echo '== wifi-boot-wait-result'; cat /run/nebulaos-wifi-boot-wait.result 2>/dev/null || echo NO_RESULT; "
    "ls -la /usr/data/nebulaos/maintenance/ 2>/dev/null; echo '== venv-validation'; ls -la /usr/data/nebulaos/system/venv-validation/ 2>/dev/null; "
    "echo \"migrate_refused_backups=$(ls /usr/data/nebulaos/system/migration-backups/printer-cfg-migration-refused 2>/dev/null | wc -l)\"; "
    "echo '== cmdline'; cat /proc/cmdline; echo '== mounts'; cat /proc/mounts; "
    "echo '== proc-start (field22 ticks, USER_HZ=100)'; "
    "for p in /proc/[0-9]*; do s=$(cat $p/stat 2>/dev/null) || continue; r=${s##*) }; set -- $r; "
    "c=$(tr '\\0' ' ' < $p/cmdline 2>/dev/null | cut -c1-120); [ -n \"$c\" ] || c=\"[$(cat $p/comm 2>/dev/null)]\"; "
    "echo \"${20} ${p#/proc/} $c\"; done | sort -n | head -400; "
    "echo '== services'; for f in /var/run/*.pid; do pid=$(cat $f 2>/dev/null); "
    "if [ -n \"$pid\" ] && [ -d /proc/$pid ]; then st=alive; else st=dead; fi; echo \"$(basename $f) $pid $st\"; done; "
    "echo '== datafs'; cat /run/nebulaos/data-fs.state 2>/dev/null || echo NO_DATAFS_STATE; "
    "echo \"datafs_unchecked_warning=$(dmesg | grep -c 'mounting unchecked fs') "
    "datafs_tools=$(for t in e2fsck fsck.ext4 dumpe2fs; do PATH=/sbin:/usr/sbin:$PATH command -v $t >/dev/null && echo -n $t,; done)\"; "
    "tail -n 6 /usr/data/nebulaos/system/diagnostics/data-fs.log 2>/dev/null; "
    "echo '== mcu-guard'; cat /run/nebulaos-mcu-guard.state 2>/dev/null; "
    "echo '== camera-idle'; cat /var/run/nebulaos-camera-idle-state 2>/dev/null; echo; "
    "echo '== moonraker'; curl -s --max-time 5 http://127.0.0.1:7125/server/info; echo; "
    "curl -s --max-time 5 'http://127.0.0.1:7125/printer/objects/query?webhooks'; echo; "
    "echo '== wifi'; iw dev wlan0 link 2>/dev/null | head -8; "
    "echo '== klippy-log'; grep -nE 'Start printer at|Starting Klippy|Loaded MCU|Configured MCU|Klipper state|Git version' "
    + KLIPPY_LOG + " 2>/dev/null | tail -30; "
    "n=$(grep -n 'Start printer at' " + KLIPPY_LOG + " | tail -1 | cut -d: -f1); "
    "echo \"klippy_last_start: connect_timeouts=$(tail -n +$n " + KLIPPY_LOG + " | grep -c 'Timeout on connect') "
    "streamed_before_identify=$(tail -n +$n " + KLIPPY_LOG + " | sed -n '/Starting serial connect/,/Loaded MCU .mcu./p' | grep -c sensor_bulk_data) "
    "shutdowns=$(tail -n +$n " + KLIPPY_LOG + " | grep -ciE 'MCU .* shutdown|Lost communication|Transition to shutdown')\"; "
    "echo '== moonraker-log'; grep -nE 'Starting Moonraker|Klippy Connection Established|Klippy ready|Server Startup|Webcam' "
    "/opt/printer_data/logs/moonraker.log 2>/dev/null | tail -30; "
    "echo '== memguard-log'; grep -E 'started \\(pid' /usr/data/nebulaos/logs/memguard.log 2>/dev/null | tail -3; "
    "echo '== migration-log'; tail -n 60 /usr/data/nebulaos/system/diagnostics/migration.log 2>/dev/null; "
    "echo '== activation-log'; tail -n 60 /usr/data/nebulaos/system/diagnostics/activation.log 2>/dev/null; "
    "echo '== syslog'; head -c 60000 /var/log/messages 2>/dev/null; "
    "echo '== dmesg'; dmesg | head -c 400000")

_PRESSURE = (
    "snap(){ echo \"== t=$(cut -d' ' -f1 /proc/uptime)\"; for f in cpu memory io; do echo \"$f: $(tr '\\n' ' ' < /proc/pressure/$f 2>/dev/null)\"; done; "
    "grep -E '^(cpu[0-9]* |ctxt|procs_running|procs_blocked)' /proc/stat; "
    "grep -E '^(pgfault|pgmajfault|pswpin|pswpout|allocstall_normal|oom_kill) ' /proc/vmstat; cat /proc/loadavg; }; "
    "snap; sleep 10; snap")

# The two RTOS partitions (rtos p3 = stock's, rtos2 p4 = NebulaOS's; SPL loads
# rtos2 for ota:kernel2). Read-only: sha256 of the whole 4 MiB partition and of
# the first zero.bin-sized bytes, compared with the pinned stock and NebulaOS
# images (scripts/package/rtos_logo.py), the first 64 bytes, and what fills the
# rest of the partition (count of bytes that are not 0x00 / not 0xFF), so the
# relation between the partition and the 432824-byte file is evidence, not a
# guess. The partition name and size are read from sysfs, not assumed.
def _rtos_hashes():
    import sys
    sys.path.insert(0, os.path.join(FW_ROOT, "scripts", "package"))
    import rtos_logo
    n = rtos_logo.STOCK_ZERO_SIZE
    return (
        "for p in 3 4; do d=/dev/mmcblk0p$p; s=/sys/class/block/mmcblk0p$p; "
        "echo \"== p$p name=$(sed -n 's/^PARTNAME=//p' $s/uevent) bytes=$(( $(cat $s/size) * 512 ))\"; "
        "f=$(sha256sum < $d | cut -d' ' -f1); h=$(head -c %d $d | sha256sum | cut -d' ' -f1); "
        "case $h in %s) k=stock ;; %s) k=nebulaos ;; *) k=unknown ;; esac; "
        "echo \"p${p}_sha256_full=$f\"; echo \"p${p}_sha256_first_%d=$h\"; echo \"p${p}_first_%d_is=$k\"; "
        "echo \"p${p}_head64=$(head -c 64 $d | od -An -tx1 -v | tr -d ' \\n')\"; "
        "echo \"p${p}_tail_bytes_not_00=$(tail -c +%d $d | tr -d '\\000' | wc -c)\"; "
        "echo \"p${p}_tail_bytes_not_ff=$(tail -c +%d $d | tr -d '\\377' | wc -c)\"; "
        "eval \"F$p=$f\"; done; "
        "echo \"p3_p4_identical=$([ \"$F3\" = \"$F4\" ] && echo YES || echo NO)\"; "
        "echo \"ota_marker=$(head -c 512 /dev/mmcblk0p1 | tr -d '\\000' | tr '\\n' ' ' | head -c 64)\"; "
        "echo \"ref_stock_zero_sha256=%s\"; echo \"ref_nebulaos_zero_sha256=%s\""
        % (n, rtos_logo.STOCK_ZERO_SHA256, rtos_logo.NEBULAOS_ZERO_SHA256, n, n, n + 1, n + 1,
           rtos_logo.STOCK_ZERO_SHA256, rtos_logo.NEBULAOS_ZERO_SHA256))


# NebulaOS did not finish booting (2026-10-14: ping only, no SSH, screen on
# the logo): read what it left on the shared data partition, from whichever
# system is up - usually Creality's in the other slot. Read-only: lists and
# tails files under /usr/data/nebulaos; never prints Wi-Fi secrets.
_NEBULAOS_POSTMORTEM = (
    "R=/usr/data/nebulaos; "
    "echo \"marker=$(head -c 512 /dev/mmcblk0p1 | tr -d '\\000' | tr '\\n' ' ' | head -c 64)\"; "
    "echo; echo '== newest files under /usr/data/nebulaos (48 h) =='; "
    "find $R -xdev -type f -mmin -2880 2>/dev/null | grep -v -e '/envs/' -e '/\\.git/' "
    "| head -n 400 | xargs -r ls -l --full-time 2>&1 | tail -n 150; "
    "echo; echo '== directories, newest first =='; "
    "for d in /usr/data $R $R/system $R/system/diagnostics $R/printer_data $R/printer_data/logs "
    "$R/printer_data/config $R/network; do echo \"--- $d\"; ls -lat --full-time $d 2>&1 | head -n 25; done; "
    "echo; echo '== data partition =='; df -h /usr/data 2>&1; "
    "(dumpe2fs -h /dev/mmcblk0p10 || tune2fs -l /dev/mmcblk0p10) 2>&1 | grep -i -e state -e error -e 'mount count' "
    "-e 'mount time' -e 'write time' -e 'last checked' -e features | head -n 30; "
    "echo \"superblock s_state=$(head -c 1084 /dev/mmcblk0p10 | tail -c 2 | od -An -tu2 | tr -d ' ') "
    "(1 clean, 2 errors, 0 not clean) s_errors=$(head -c 1086 /dev/mmcblk0p10 | tail -c 2 | od -An -tu2 | tr -d ' ') "
    "s_error_count=$(head -c 1432 /dev/mmcblk0p10 | tail -c 4 | od -An -tu4 | tr -d ' ')\"; "
    "dmesg 2>&1 | grep -i -e ext4 -e mmcblk0p10 | tail -n 20; "
    "for f in $R/system/diagnostics/*.log $R/system/*.log $R/system/*.json $R/printer_data/logs/*.log "
    "$R/*.log /usr/data/.nebulaos-clean-reset.log; do [ -f \"$f\" ] || continue; "
    "echo; echo \"== $f (last 120 lines) ==\"; tail -n 120 \"$f\" | grep -v -i -e psk -e passw; done; "
    "echo; echo '== network config (secrets filtered) =='; "
    "find $R -maxdepth 4 -name '*.json' -path '*network*' 2>/dev/null | while read f; do "
    "echo \"--- $f\"; grep -v -i -e psk -e passw \"$f\" | head -c 4000; echo; done"
)

# What `e2fsck -p` would meet on the data partition, without changing it:
# `e2fsck -n` opens the device read-only and answers "no" to every question.
# Run while the partition is mounted (it always is on a running system), so
# a few items can be artefacts of live writes; real damage still shows.
_DATAFS_CHECK_READONLY = (
    "D=/dev/mmcblk0p10; "
    "(dumpe2fs -h $D || tune2fs -l $D) 2>&1 | grep -i -e 'state' -e 'mount count' -e 'last checked' | head -n 6; "
    "E=$(command -v e2fsck || command -v fsck.ext4 || command -v fsck.ext2); "
    "[ -n \"$E\" ] || { echo NO_E2FSCK; exit 0; }; echo \"checker=$E\"; "
    "S=$(date +%s); ( $E -n -f $D </dev/null; echo \"e2fsck_rc=$?\" ) 2>&1 | tail -n 120; "
    "echo \"seconds=$(( $(date +%s) - S ))\"; "
    "echo; echo '== what the preen pass alone would do (still -n) =='; "
    "( $E -n $D </dev/null; echo \"e2fsck_rc=$?\" ) 2>&1 | tail -n 20"
)

# How this boot went, from the RAM-only records (2026-10-15): the per-script
# timing rcS writes, the data partition's boot decision, mounts and the
# kernel log lines of the boot steps. Read-only. Meant for a NebulaOS that is
# reachable over SSH (started early) but did not finish booting.
_BOOT_STATE = (
    "echo \"uptime=$(cut -d' ' -f1 /proc/uptime)\"; "
    "for f in /run/nebulaos-boot-scripts.log /run/nebulaos/data-fs.state /run/nebulaos/data-fs.e2fsck.log "
    "/var/run/nebulaos-boot-timing.log; do echo; echo \"== $f ==\"; cat \"$f\" 2>&1 | tail -n 200; done; "
    "echo; echo '== last script started, not ended =='; "
    "awk '/EV=start/{s=$3} /EV=end/{s=\"\"} END{print (s==\"\" ? \"none\" : s)}' /run/nebulaos-boot-scripts.log 2>&1; "
    "echo; echo '== mounts =='; grep -e mmcblk -e ' /usr/data' -e ' /opt' /proc/mounts; "
    "echo; echo '== kernel log (boot steps, storage) =='; "
    "dmesg 2>&1 | grep -i -e nebulaos -e ext4 -e mmcblk0p10 -e 'blocked for more than' -e oom | tail -n 80; "
    "echo; echo '== processes =='; ps w 2>&1 | grep -v ' \\[' | head -n 80; "
    "L=/opt/printer_data/logs; echo; echo \"== persistent logs ($L) ==\"; "
    "ls -l $L/system.log* $L/boot-timing.log 2>&1; "
    "echo \"system.log lines: wpa_supplicant=$(grep -c wpa_supplicant $L/system.log 2>/dev/null) "
    "udhcpc=$(grep -c udhcpc $L/system.log 2>/dev/null) nebulaos-osconfig=$(grep -c nebulaos-osconfig $L/system.log 2>/dev/null) "
    "nebulaos-datafs=$(grep -c nebulaos-datafs $L/system.log 2>/dev/null)\"; "
    "echo '--- system.log (last 25, secrets filtered)'; tail -n 25 $L/system.log 2>&1 | grep -v -i -e psk -e passw; "
    "echo '--- boot-timing.log (last 15)'; tail -n 15 $L/boot-timing.log 2>&1"
)

# What NebulaOS itself reports as versions - what the screen shows (System
# info, Settings > Printer > MCU firmware) - next to what Klipper reads from
# the MCU (2026-10-15). Read-only: local Moonraker GETs only.
_VERSIONS = (
    "M=http://127.0.0.1:7125; "
    "for e in machine/nebulaos/info machine/nebulaos/mcu/status machine/nebulaos/mcu/files "
    "'printer/objects/query?mcu' server/info machine/update/status; do echo; echo \"== $e ==\"; "
    "curl -s --max-time 10 \"$M/$e\" 2>&1 | head -c 6000; echo; done; "
    # G56: one line per updater - the raw status is cut off after 6000 bytes
    "echo; echo '== update entries =='; curl -s --max-time 10 \"$M/machine/update/status\" 2>&1 "
    "| python3 -c 'import json,sys; d=json.load(sys.stdin)[\"result\"][\"version_info\"]; "
    "[print(k, *[\"%s=%s\" % (f, v.get(f)) for f in (\"version\", \"remote_version\", \"is_valid\", "
    "\"corrupt\", \"channel\", \"warnings\", \"anomalies\")]) for k, v in sorted(d.items()) "
    "if isinstance(v, dict)]' 2>&1; "
    # G56: why Klipper calls its own checkout "-dirty" - klippy.log lists
    # the git version and the files it sees as modified/untracked at start.
    "echo; echo '== klippy.log git info (last start)'; grep -E 'Git version|Branch:|Remote:|Tracked URL|Modified|Untracked|file_status|dirty' "
    "/opt/printer_data/logs/klippy.log 2>/dev/null | tail -n 25; "
    "echo; echo '== /etc/nebulaos-build (image) =='; cat /etc/nebulaos-build 2>&1 | head -n 40; "
    "echo; echo '== kernel =='; uname -r"
)

# App updates (Moonraker's update manager + NebulaOS's update supervisor),
# read-only: the supervisor's per-component states and locks, and the
# update-related part of Moonraker's log (2026-10-15, P15).
_UPDATE_LOG = (
    "U=/usr/data/nebulaos/updates; echo '== supervisor locks'; ls -l $U/locks 2>&1; "
    "for f in $U/*/state.json; do echo \"--- $f\"; cat \"$f\"; done; "
    "echo; echo '== moonraker.log (update lines, last 1500 lines scanned)'; "
    "tail -n 1500 /opt/printer_data/logs/moonraker.log | grep -v -e get_file_list -e 'Updating File List' "
    "-e 'JSON-RPC Request Error - Requested Method: server.database' | "
    "grep -i -e update -e 'git ' -e git_deploy -e pip -e klipper -e error -e fail -e Traceback -e Exception -e rollback "
    "| tail -n 200 | cut -c1-400"
)

# Profiles that may also run on Creality's system (the other slot): read-only
# and meaningful from there.
STOCK_CAPTURE_PROFILES = ("nebulaos-postmortem", "datafs-check-readonly")

# name -> (body, needs_diag, probe or None, timeout seconds)
CAPTURE_PROFILES = {
    "nebulaos-postmortem": (_NEBULAOS_POSTMORTEM, False, None, 120),
    "datafs-check-readonly": (_DATAFS_CHECK_READONLY, False, None, 600),
    "boot-state": (_BOOT_STATE, False, None, 60),
    # G60 (2026-10-16): a log review - per log, its errors and warnings
    # grouped and counted (timestamps and numbers stripped so repeats
    # collapse), plus the state file and README. Read-only.
    "logs-review": (
        "L=/opt/printer_data/logs; echo '== files'; ls -la $L; "
        "for f in $L/klippy.log $L/moonraker.log $L/system.log $L/system.log.0 $L/nebulascreen.log $L/guppyscreen.log "
        "$L/nginx-error.log /usr/data/nebulaos/logs/memguard.log /usr/data/nebulaos/maintenance/retention.log "
        "/usr/data/nebulaos/maintenance/logs/*.log /usr/data/nebulaos/system/diagnostics/*.log; do "
        "[ -f \"$f\" ] || continue; echo; echo \"== $f ($(wc -l < \"$f\") lines)\"; "
        "grep -iE 'error|exception|traceback|warn|fail|refus|timeout|unable|cannot|denied|critical' \"$f\" "
        "| grep -viE 'psk|passw' | sed -E 's/^[A-Z][a-z]{2} +[0-9]+ [0-9:]+ //; s/^\\[[^]]*\\] //; "
        "s/^[0-9-]+ [0-9:,.]+ //; s/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -n 25; "
        "echo '-- latest two, as written:'; grep -iE 'error|exception|traceback|fail|critical' \"$f\" "
        "| grep -viE 'psk|passw|RESPOND TYPE|on_error_gcode|_ON_GCODE_FAILURE' | tail -n 2 | cut -c1-300; done; "
        "echo; echo '== nebulaos-state.txt'; cat $L/nebulaos-state.txt 2>&1 | head -n 120; "
        "echo; echo '== README'; head -n 5 /opt/printer_data/README.txt 2>&1; "
        "echo; echo '== log level'; cat /usr/data/nebulaos/system/log-level 2>&1; ps w | grep -v grep | grep syslogd",
        False, None, 120),
    # 2026-10-15: what is on the data partition, before any cleanup. Read-only.
    "datafs-inventory": (
        "echo '== df'; df -k /usr/data; "
        "echo; echo '== /usr/data top level (KB)'; du -sk /usr/data/* /usr/data/.[!.]* 2>/dev/null | sort -rn; "
        "echo; echo '== /usr/data/nebulaos (KB, 2 levels)'; du -k -d 2 /usr/data/nebulaos 2>/dev/null | sort -rn | head -n 60; "
        "echo; echo '== /usr/data/printer_data (KB, 2 levels)'; du -k -d 2 /usr/data/printer_data 2>/dev/null | sort -rn | head -n 30; "
        "echo; echo '== largest files (> 1 MB)'; find /usr/data -xdev -type f -size +1024k 2>/dev/null "
        "| while read -r f; do echo \"$(du -k \"$f\" | cut -f1) $(date -r \"$f\" +%Y-%m-%d 2>/dev/null) $f\"; done | sort -rn | head -n 60; "
        "echo; echo '== config tree'; find /usr/data/nebulaos/printer_data/config -maxdepth 3 2>/dev/null | sort | head -n 200; "
        "echo; echo '== logs'; ls -la /usr/data/nebulaos/printer_data/logs 2>/dev/null; "
        "echo; echo '== uploads (G62)'; ls -laR /usr/data/nebulaos/printer_data/uploads 2>/dev/null | head -n 60; "
        "echo; echo '== old boot uploads'; ls -la /usr/data/nebulaos/boot/uploads 2>/dev/null",
        False, None, 180),
    "versions": (_VERSIONS, False, None, 90),
    # G125 follow-up (Tim 2026-10-29: the Spoolman page opens empty although the
    # server works), read-only: the file, the helper, Moonraker's endpoint and
    # what the screen logged about it.
    "spoolman": ("C=/opt/printer_data/config/moonraker.conf; echo \"== $C\"; ls -la $C; "
        "echo '== [spoolman] section'; sed -n '/^\\[spoolman\\]/,/^\\[/p' $C; "
        "echo '== osconfig spoolman status'; /usr/libexec/nebulaos/nebulaos-osconfig spoolman status; "
        "echo; echo '== moonraker /machine/nebulaos/spoolman/status'; "
        "wget -q -O - http://127.0.0.1:7125/machine/nebulaos/spoolman/status 2>&1 | head -c 2000; "
        "echo; echo '== moonraker server.config spoolman'; "
        "wget -q -O - http://127.0.0.1:7125/server/config 2>&1 | grep -o '\"spoolman\": *{[^}]*}' | head -3; "
        "echo '== screen log'; grep -i spoolman /opt/printer_data/logs/nebulascreen.log 2>/dev/null | tail -20",
        False, None, 60),
    "update-log": (_UPDATE_LOG, False, None, 60),
    # G82 (Run 15 test): the GuppyScreen -> NebulaScreen settings migration,
    # read-only - the old file must be unchanged, the new one a copy of it.
    # Result and step order of the last auto-calibrate (Run 18 test 4), read-only.
    "autocal-result": ("echo '== calibration status'; wget -q -O - 'http://127.0.0.1:7125/printer/objects/query?nebulaos_calibration' 2>&1 | head -c 3000; "
        "echo; echo '== journal'; cat /usr/data/nebulaos/printer_data/calibration/*journal*.json 2>&1 | head -c 3000; "
        "echo; echo '== saved z_offset / mesh (printer.cfg autosave)'; grep -nE '^#\*# \[(bltouch|bed_mesh default|nebulaos_z_offset_probe)\]|^#\*# z_offset|^#\*# (x|y)_count|^#\*# min_x' /opt/printer_data/config/printer.cfg 2>&1 | head -n 20; "
        "echo '== klippy.log auto-calibrate sequence'; L=/opt/printer_data/logs/klippy.log; "
        "grep -nE 'NEBULAOS_AUTO_CALIBRATE|_NEBULAOS_|AUTO_CHECK|auto check|NOZZLE_CLEAN|nozzle_clear|Z_OFFSET|z_offset|BED_MESH|probe at|bed will contact|SAVE_CONFIG|calibration:|estart|rror|!!|stage|heat' $L 2>/dev/null | tail -n 120",
        False, None, 90),
    # G99 load-cell state as Klipper and Moonraker see it (Run 18 test 3), read-only.
    "loadcell-mode": ("echo '== status'; wget -q -O - 'http://127.0.0.1:7125/printer/objects/query?nebulaos_load_cell_calibration&nebulaos_z_offset_probe' 2>&1 | head -c 4000; "
        "echo; echo '== extensions version'; wget -q -O - 'http://127.0.0.1:7125/printer/objects/query?nebulaos_version' 2>&1 | head -c 1500; "
        "echo; echo '== mode file'; cat /usr/data/nebulaos/printer_data/calibration/load_cell_mode.json 2>&1; "
        "echo; echo '== klippy.log G99 lines'; grep -hE 'NEBULAOS_LOAD_CELL|load_cell_mode|auto check|AUTO_CHECK' /opt/printer_data/logs/klippy.log 2>/dev/null | tail -n 30; "
        "echo '== nebulascreen.log'; grep -hiE 'load.?cell|AUTO_CHECK|LOAD_CELL_MODE' /opt/printer_data/logs/nebulascreen.log 2>/dev/null | tail -n 30",
        False, None, 60),
    # Run 18 checks (G96 boot picture, G99 load-cell mode, G92 Z adjust,
    # G97 boot timing), read-only.
    "run18-checks": ("echo '== G96 boot picture (kernel)'; dmesg | grep 'boot picture'; "
        "echo '== kernel'; uname -v; "
        "echo '== G99 load-cell mode'; cat /usr/data/nebulaos/printer_data/calibration/load_cell_mode.json 2>&1; "
        "echo '== G92 Z adjust'; cat /opt/printer_data/config/z_offset_adjust.json 2>&1; "
        "echo '== nebulaos refusals (syslog)'; grep -h 'NebulaOS refused' /opt/printer_data/logs/system.log 2>/dev/null | tail -n 10; "
        "echo '== boot script timing'; grep -E 'S00|S01|S58' /run/nebulaos-boot-scripts.log",
        False, None, 60),
    # Run 19 checks (G108 buzzer channel, G104/G105 history, G82 stage 4
    # screen release, G96 boot picture), read-only: nothing sounds or moves.
    "run19-checks": ("echo '== kernel'; uname -v; "
        "echo '== G96 boot picture'; dmesg | grep 'boot picture'; "
        "echo '== G108 pwm/pinctrl kernel messages'; dmesg | grep -iE 'pwm|pinctrl' | tail -n 20; "
        "echo '== G108 pwm channels'; ls /sys/class/pwm/pwmchip0/ 2>&1; "
        "for f in enable period duty_cycle; do echo \"pwm3/$f=$(cat /sys/class/pwm/pwmchip0/pwm3/$f 2>&1)\"; done; "
        "echo '== G108 beeper in klippy.log'; grep -iE 'nebulaos_beeper|beeper' /opt/printer_data/logs/klippy.log 2>/dev/null | tail -n 10; "
        "echo '== status objects'; curl -s -m 3 'http://127.0.0.1:7125/printer/objects/query?nebulaos_beeper&nebulaos_calibration=history,last_result,progress' 2>&1 | head -c 3000; echo; "
        "echo '== G105 history file'; cat /usr/data/nebulaos/printer_data/calibration/calibration_history.json 2>&1 | head -c 2000; echo; "
        "echo '== G82 screen release'; cat /usr/share/nebulaos/nebulascreen/release_info.json 2>&1; "
        "cat /usr/data/nebulaos/apps/nebulascreen/release_info.json 2>&1; "
        "echo '== screen process'; ps | grep -E '[n]ebulascreen'",
        False, None, 60),
    # Every (re)start of Klippy, Moonraker and the screen with its time and
    # what triggered it (update_manager, service restart, firmware restart),
    # read-only - "did something restart twice?" (Run 19 test).
    "restarts": ("L=/opt/printer_data/logs; echo '== uptime / now'; uptime; date; "
        "echo '== klippy.log: starts, restarts, config/update lines'; "
        "grep -nE 'Start printer at|Restarting printer|_RESTART|Git version|Exiting|Unhandled exception|beeper' $L/klippy.log 2>/dev/null | tail -n 40 | cut -c1-250; "
        "echo '== moonraker.log: updates and service actions'; "
        "grep -nE 'update|Update|restart|Restart|service|Service|Klippy|klippy' $L/moonraker.log 2>/dev/null "
        "| grep -v -e get_file_list -e 'Updating File List' -e server.database | tail -n 60 | cut -c1-250; "
        "echo '== system.log: init scripts, supervisorctl, screen, refusals'; "
        "grep -hE 'S55klipper|S56moonraker|S58nebulascreen|supervisorctl|nebulascreen|NebulaOS refused|update-supervisor' $L/system.log 2>/dev/null | tail -n 40 | cut -c1-250; "
        "echo '== processes (start times)'; ps -o pid,etime,args 2>/dev/null | grep -E '[k]lippy|[m]oonraker|[n]ebulascreen' "
        "|| ps | grep -E '[k]lippy|[m]oonraker|[n]ebulascreen'",
        False, None, 60),
    # Who paused a print (Run 19 test, G112): klippy.log of the last prints
    # with the file position (sd_pos) stall/move transitions, Moonraker's
    # pause/resume/job lines, the screen's pause/resume lines and Moonraker's
    # console history, read-only.
    "print-pause": ("L=/opt/printer_data/logs; echo '== now'; date; uptime; "
        "echo '== klippy.log: SD card print lines'; grep -nE 'SD card print|Exiting SD' $L/klippy.log 2>/dev/null | tail -n 10; "
        "n=$(grep -n 'Starting SD card print' $L/klippy.log 2>/dev/null | tail -n 3 | head -n 1 | cut -d: -f1); "
        "echo \"== klippy.log from line ${n:-1}: non-Stats lines + sd_pos stalled/moving\"; "
        "tail -n +${n:-1} $L/klippy.log | awk '/^Stats /{p=\"\"; if (match($0,/sd_pos=[0-9]+/)) p=substr($0,RSTART+7,RLENGTH-7); "
        "s=(p!=\"\" && p==q); if (p!=\"\" && s!=ls) print \"STATS \" $2 \" sd_pos=\" p (s ? \" STALLED\" : \" moving\"); ls=s; q=p; next} {print}' "
        "| head -n 300 | cut -c1-250; "
        "echo '== moonraker.log: pause/resume/job lines'; grep -nEi 'pause|resume|print_stats|printer\\.print|job' $L/moonraker.log 2>/dev/null "
        "| grep -v -e get_file_list -e 'Updating File List' | tail -n 60 | cut -c1-250; "
        "echo '== nebulascreen.log: pause/resume'; grep -hiE 'pause|resume' $L/nebulascreen.log 2>/dev/null | tail -n 30 | cut -c1-250; "
        "echo '== moonraker console history (last 300)'; python3 -c 'import json,time,urllib.request as u; "
        "d=json.load(u.urlopen(\"http://127.0.0.1:7125/server/gcode_store?count=300\",timeout=10))[\"result\"][\"gcode_store\"]; "
        "[print(time.strftime(\"%H:%M:%S\",time.localtime(e[\"time\"])),e[\"type\"],e[\"message\"][:200]) for e in d]' 2>&1 | tail -n 300",
        False, None, 60),
    # Why Klippy crashed or shut down (Run 21 Q1 test, Tim 2026-10-26): the
    # live state, the last traceback / shutdown with context, the last
    # non-Stats lines, kernel OOM lines, memguard, the shaper CSVs in /tmp.
    # Read-only.
    "klippy-crash": ("L=/opt/printer_data/logs/klippy.log; echo '== now'; date; uptime; free; "
        "echo '== klippy state'; wget -q -O - 'http://127.0.0.1:7125/printer/info' 2>&1 | head -c 1500; echo; "
        "echo '== processes'; ps w | grep -E '[k]lippy|[k]lipper_mcu|[m]oonraker|[n]ebulascreen'; "
        "echo '== last Traceback / shutdown (with context)'; n=$(grep -nE 'Traceback|Transition to shutdown|MCU .* shutdown|Lost communication|Unhandled exception|Exiting|Timeout with MCU' $L | tail -n 1 | cut -d: -f1); "
        "[ -n \"$n\" ] && sed -n \"$((n>60 ? n-60 : 1)),$((n+40))p\" $L | grep -v '^Stats ' | cut -c1-300; "
        "echo '== last 50 non-Stats lines'; grep -v '^Stats ' $L | tail -n 50 | cut -c1-300; "
        "echo '== Stats around the end (last 5)'; grep '^Stats ' $L | tail -n 5 | cut -c1-400; "
        "echo '== kernel: oom / killed / segfault'; dmesg | grep -iE 'oom|killed process|segfault|out of memory' | tail -n 15; "
        "echo '== memguard'; tail -n 20 /usr/data/nebulaos/logs/memguard.log 2>/dev/null; "
        "echo '== shaper CSVs in /tmp'; ls -la /tmp/calibration_data_* /tmp/resonances_* 2>&1 | tail -n 10; "
        "S=/opt/printer_data/logs/system.log; echo '== system.log (persistent): oom/killed/memguard/watchdog/panic, last 40'; "
        "grep -hiE 'oom|killed process|out of memory|memguard|watchdog|panic|hung_task|blocked for more|soft lockup|rcu' $S.0 $S 2>/dev/null | grep -viE 'psk|passw' | tail -n 40 | cut -c1-300; "
        "echo '== system.log: last 30 lines before the last syslogd start'; b=$(grep -n 'syslogd started' $S | tail -n 1 | cut -d: -f1); "
        "[ -n \"$b\" ] && sed -n \"$((b>30 ? b-30 : 1)),$((b))p\" $S | grep -viE 'psk|passw' | cut -c1-300; "
        "echo '== klippy.log: lines before the last Start printer'; k=$(grep -n 'Start printer at' $L | tail -n 1 | cut -d: -f1); "
        "[ -n \"$k\" ] && sed -n \"$((k>80 ? k-80 : 1)),$((k))p\" $L | grep -v '^Stats ' | tail -n 40 | cut -c1-300; "
        "echo '== Stats before the last Start printer (last 8)'; [ -n \"$k\" ] && head -n $k $L | grep '^Stats ' | tail -n 8 | cut -c1-400",
        False, None, 90),
    # G117 replication (Run 21): a live stream for up to 20 min - every 2 s
    # the busiest threads (with RT priority), load, memory and CPU pressure,
    # Klippy's newest log line and new kernel lines - so the seconds before
    # a whole-system freeze reach the PC even when nothing is written to
    # disk any more. Read-only; ends by itself.
    "live-watch": ("K=/opt/printer_data/logs/klippy.log; d0=$(dmesg | wc -l); i=0; while [ $i -lt 600 ]; do i=$((i+1)); "
        "echo \"== t=$(cut -d' ' -f1 /proc/uptime) load=$(cut -d' ' -f1-3 /proc/loadavg) "
        "memavail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)kB cpu_psi=$(head -n 1 /proc/pressure/cpu 2>/dev/null | cut -d' ' -f2) "
        "mem_psi=$(head -n 1 /proc/pressure/memory 2>/dev/null | cut -d' ' -f2)\"; "
        "top -b -n 1 -H 2>/dev/null | sed -n '5,12p' | cut -c1-120; "
        "echo \"klippy: $(tail -n 60 $K | grep -v '^Stats ' | tail -n 2 | cut -c1-160 | tr '\\n' '|')\"; "
        "d1=$(dmesg | wc -l); [ $d1 -gt $d0 ] && dmesg | tail -n $((d1-d0)) | cut -c1-200; d0=$d1; sleep 2; done; echo '== live-watch ended (20 min)'",
        False, None, 1260),
    # G103 (Run 21 investigation): every recorded boot from the persistent
    # boot-timing.log - the scripts that took more than 0.5 s and when the
    # boot was done, read-only.
    "boot-history": ("L=/opt/printer_data/logs/boot-timing.log; echo \"== $(grep -c EV=begin $L) boots recorded\"; "
        "awk '/EV=begin/{n++; printf \"\\nBOOT %d \", n} / EV=end /{split($1,t,\"=\"); for(i=1;i<=NF;i++){if($i ~ /^S=/)s=substr($i,3); "
        "if($i ~ /^DUR=/)d=substr($i,5)} if(d+0>0.5) printf \"%s=%s@%s \", s, d, t[2]} /EV=done/{split($1,t,\"=\"); printf \"DONE@%s\", t[2]}' "
        "$L | tail -n 12; echo",
        False, None, 60),
    # G103 P3 (Run 21): why S04nebulaos-factory-seed runs its full venv
    # import checks on some normal boots - the venv validation stamps (their
    # text is the key they were written with, their time the last full
    # check), every app checkout's HEAD reflog (update times, epoch) and the
    # Klippy starts (boot times). Read-only.
    "seed-reasons": ("D=/usr/data/nebulaos; echo \"== now $(date '+%F %T') epoch $(date +%s)\"; "
        "for f in $D/system/venv-validation/*.key; do echo \"== stamp $f written $(date -r $f '+%F %T')\"; "
        "cat $f | cut -c1-200; done; "
        "for a in $D/apps/*; do [ -f $a/.git/logs/HEAD ] || continue; echo \"== reflog $a (old new epoch msg)\"; "
        "tail -n 8 $a/.git/logs/HEAD | awk -F'\\t' '{n=split($1,f,\" \"); print substr(f[1],1,8), substr(f[2],1,8), f[n-1], substr($2,1,80)}'; done; "
        "for e in $D/envs/*; do for sp in $e/lib/python*/site-packages; do [ -d $sp ] && echo \"== $sp changed $(date -r $sp '+%F %T')\"; done; done; "
        "echo '== klippy starts'; grep -h 'Start printer at' $(ls -tr /opt/printer_data/logs/klippy.log* 2>/dev/null) 2>/dev/null | tail -n 25 | cut -c1-120",
        False, None, 60),
    # G114 (Run 21 investigation): MCU load per MCU from Klippy's own Stats
    # lines (mcu_awake, mcu_task_avg/stddev, retransmits) split into idle,
    # printing (sd_pos present) and SHAPER_CALIBRATE (between its "Testing
    # axis" and "Recommended shaper" console lines), plus accelerometer
    # overflow lines. Mainsail's 'load' = task_avg + 3*task_stddev/0.0025 (its
    # JS precedence: only the spread is scaled); mcu_awake is the busy share.
    # Read-only.
    "mcu-load": ("L=/opt/printer_data/logs; for f in $(ls -tr $L/klippy.log* 2>/dev/null); do echo \"== $f ($(wc -l < $f) lines)\"; "
        "awk '/Testing axis/{st=\"shaper\"} /Recommended shaper/{st=\"\"} /^Stats /{ph=(st!=\"\")?st:((index($0,\"sd_pos=\")>0)?\"print\":\"idle\"); "
        "m=\"host\"; for(i=3;i<=NF;i++){if($i ~ /:$/){m=substr($i,1,length($i)-1); continue} split($i,kv,\"=\"); k=ph\"|\"m; "
        "if(kv[1]==\"mcu_awake\"){n[k]++; aw[k]+=kv[2]; if(kv[2]>maw[k])maw[k]=kv[2]} if(kv[1]==\"mcu_task_avg\")ta=kv[2]; "
        "if(kv[1]==\"mcu_task_stddev\"){ld=ta+3*kv[2]/0.0025; sl[k]+=ld; if(ld>ml[k])ml[k]=ld} "
        "if(kv[1]==\"bytes_retransmit\"&&kv[2]>rt[k])rt[k]=kv[2]; if(kv[1]==\"sysload\"&&kv[2]>sy[ph])sy[ph]=kv[2]}} "
        "END{for(k in n) printf \"%-22s n=%-6d awake avg %.4f max %.4f | mainsail-load avg %.1f%% max %.1f%% | retransmit %s\\n\", "
        "k, n[k], aw[k]/n[k], maw[k], 100*sl[k]/n[k], 100*ml[k], rt[k]; for(p in sy) printf \"sysload max %s: %s\\n\", p, sy[p]}' $f; "
        "grep -ciE 'overflow' $f | sed 's/^/overflow lines: /'; done; "
        "echo '== resonance/shaper lines (last 12)'; grep -hE 'Testing axis|Recommended shaper|Wait for calculations|overflow' $L/klippy.log* 2>/dev/null | tail -n 12",
        False, None, 120),
    # Run 16 kernel image checks (K1 log levels, G5 sysfs/no debugfs, G3
    # early boot screen), read-only.
    "kernel-run16": ("echo '== kernel'; uname -r; uname -v; "
        "echo '== kernel messages at warning or worse (raw levels 0-4)'; dmesg -r | grep -E '^<[0-4]>' ; "
        "echo '== debugfs mounted?'; grep -c ' debugfs ' /proc/mounts; "
        "echo '== touch sysfs (G5)'; for f in /sys/bus/i2c/devices/*/nebulaos_touch/*; do echo \"$f=$(cat $f 2>&1)\"; done; "
        "echo '== backlight sysfs'; for f in brightness actual_brightness bl_power; do "
        "echo \"$f=$(cat /sys/class/backlight/nebulaos_backlight/$f 2>&1)\"; done; "
        "echo '== display apply / watcher log'; grep -hE 'display-qualified|sleep-wake|nebulaos-backlight' /opt/printer_data/logs/system.log 2>/dev/null | tail -n 15; "
        "echo '== boot display (G3)'; grep -h nebulaos-boot-display /opt/printer_data/logs/system.log 2>/dev/null | tail -n 5; "
        "ls -l /run/nebulaos-boot-display.drawn 2>&1; "
        "echo '== boot script timing'; grep -E 'S00|S01' /run/nebulaos-boot-scripts.log",
        False, None, 60),
    "screen-migration": ("D=/usr/data/nebulaos; for f in $D/guppyscreen/guppyconfig.json "
        "$D/nebulascreen/nebulascreen.json /opt/nebulascreen/nebulascreen.json "
        "/opt/printer_data/config/nebulascreen/nebulascreen.json; do "
        "echo \"== $f\"; ls -l --full-time \"$f\" 2>&1; sha256sum \"$f\" 2>&1; done; "
        "echo '== mounts'; grep -E 'nebulascreen|guppyscreen' /proc/self/mounts; "
        "echo '== config/guppyscreen placeholder'; ls -la $D/printer_data/config/guppyscreen 2>&1; "
        "echo '== settings keys (old / new)'; for f in $D/guppyscreen/guppyconfig.json $D/nebulascreen/nebulascreen.json; do "
        "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); "
        "print(sys.argv[1], sorted(d.keys()))' \"$f\" 2>&1; done; "
        "echo '== nebulascreen boot log'; grep -h nebulascreen /opt/printer_data/logs/system.log 2>/dev/null | tail -n 20; "
        "echo '== screen process'; ps | grep -E '[n]ebulascreen|[g]uppyscreen'",
        False, None, 60),
    # G50 (2026-10-17): what an app update did - pip's lines (index, packages,
    # errors), update_manager and the supervisor - without the debug noise.
    # Run 10 checks (2026-10-17): B2 memguard priority, S1 config tree
    # README/hashes, S2 database lookups - since the last boot.
    "run10-checks": ("echo '== B2 memguard lines in system.log since boot (priority)'; "
                     "B=$(grep -n 'syslogd started' /opt/printer_data/logs/system.log | tail -1 | cut -d: -f1); "
                     "tail -n +${B:-1} /opt/printer_data/logs/system.log | grep 'memguard:' "
                     "| sed -n 's/^.* nebulaos \\([a-z]*\\.[a-z]*\\) memguard: \\([a-z]*\\).*/\\1 \\2/p' | sort | uniq -c; "
                     "echo '== log level'; cat /usr/data/nebulaos/system/log-level 2>/dev/null; "
                     "echo; echo '== S1 config/nebulaos'; ls /opt/printer_data/config/nebulaos; "
                     "head -3 /opt/printer_data/config/nebulaos/README.txt 2>/dev/null; "
                     "echo '== S1 config-generation.json'; cat /usr/data/nebulaos/system/config-generation.json 2>/dev/null; "
                     "echo; echo '== S2 moonraker.log since its last start: missing namespace/key errors'; "
                     "M=$(grep -n 'Starting Moonraker' /opt/printer_data/logs/moonraker.log | tail -1 | cut -d: -f1); "
                     "tail -n +${M:-1} /opt/printer_data/logs/moonraker.log | grep -cE \"Namespace guppyscreen not found|Key 'console' in namespace 'fluidd'\"; "
                     "echo '== moonraker starts in this log'; grep -c 'Starting Moonraker' /opt/printer_data/logs/moonraker.log",
                     False, None, 60),
    "update-history": ("echo '== moonraker.log: update_manager / pip'; "
                       "grep -hE 'pip|update_manager|app_deploy|git_deploy|Updating|Update|requirements|"
                       "Successfully|No matching|ERROR|Traceback|Error' "
                       "/opt/printer_data/logs/moonraker.log.* /opt/printer_data/logs/moonraker.log 2>/dev/null "
                       "| grep -vE 'GET /machine/update/status|_log_debug|log_request' | tail -250; "
                       "echo; echo '== update-supervisor.log'; "
                       "tail -120 /usr/data/nebulaos/maintenance/logs/update-supervisor.log 2>/dev/null; "
                       "echo; echo '== pip.conf'; cat /etc/pip.conf 2>/dev/null; "
                       "echo; echo '== moonraker venv site-packages'; "
                       "ls /usr/data/nebulaos/envs/moonraker/lib/python3*/site-packages 2>/dev/null | head -60; "
                       "cat /usr/data/nebulaos/envs/moonraker/.nebulaos-abi 2>/dev/null",
                       False, None, 60),
    # G70 (Run 13): the camera (USB 1-1.1) resets once ~49 s after some
    # boots. Every boot's camera/USB/idle-controller lines from the kept
    # system logs, each boot marked, to see how often and what precedes it.
    "camera-usb-history": ("L=/opt/printer_data/logs; for f in $L/system.log.1 $L/system.log.0 $L/system.log; do "
                           "[ -f \"$f\" ] || continue; echo \"== $f\"; "
                           "grep -E 'syslogd started|usb 1-1|uvcvideo|UVC|ustreamer|camera-idle|webcam|dwc2|-145|-71|-110' \"$f\" "
                           "| grep -v dropbear | cut -c1-200 | tail -n 400; done; "
                           "echo '== now'; dmesg | grep -E 'usb 1-1|uvc|dwc2' | tail -n 40; "
                           "cat /var/run/nebulaos-camera-idle-state 2>/dev/null",
                           False, None, 90),
    # G83b (Run 13): ke-dev's real load-cell contact traces (calibrated
    # sensor) for the offline raw-count replay - the probe logs every
    # contact's raw samples and fit window to klippy.log.
    "loadcell-traces": ("L=/opt/printer_data/logs; for f in $(ls -tr $L/klippy.log* 2>/dev/null); do "
                        "grep -hE 'raw collector samples|ascent fit window data|fit: n_below|counts_per_gram' \"$f\"; "
                        "done | tail -n 600",
                        False, None, 120),
    # RTOS logo (G7): what is on rtos/rtos2 before anything writes rtos2.
    "rtos-hashes": (_rtos_hashes(), False, None, 120),
    # --- TOOL-01 base list ---------------------------------------------------
    "usb-topology": (_USB_TOPOLOGY, False, None, 60),
    "dwc2-hw": (_DWC2_HW, False, None, 60),
    "irq-rates": ("cat /proc/interrupts; sleep 10; cat /proc/interrupts", False, None, 60),
    "threads": (_THREADS_PY + "; for i in /proc/irq/*/; do echo \"$i $(ls $i 2>/dev/null | tr '\\n' ' ') "
                "$(cat $i/smp_affinity_list 2>/dev/null)\"; done", False, "schedsnap.py", 180),
    "serial": ("cat /proc/tty/driver/* 2>/dev/null; for f in /sys/class/tty/ttyS1/*; do [ -f $f ] && echo \"$f=$(cat $f 2>/dev/null)\"; done; "
               "grep -E '^Stats' " + KLIPPY_LOG + " 2>/dev/null | tail -200", False, None, 60),
    "memory": ("cat /proc/meminfo /proc/vmstat /proc/swaps 2>/dev/null; cat /sys/block/zram0/comp_algorithm /sys/block/zram0/disksize "
               "/sys/block/zram0/mm_stat /sys/block/zram0/mem_limit /proc/pressure/* 2>/dev/null; " + _MEMPROC, False, None, 60),
    "cpu-fpu": ("cat /proc/cpuinfo; dmesg | grep -iE 'fpu|nan|ieee754|msa'; cat /proc/cmdline", False, None, 60),
    "latency-baseline": ("command -v cyclictest >/dev/null || { echo CYCLICTEST_ABSENT; exit 3; }; "
                         "for p in 90 49 1; do echo \"== prio $p\"; cyclictest -m -S -p $p -i 1000 -h 2000 -D 600 -q; done",
                         True, None, 1900),
    "timerlat-tracer": ("echo timerlat > /sys/kernel/tracing/current_tracer; sleep 600; cat /sys/kernel/tracing/osnoise/* 2>/dev/null; "
                        "tail -n 2000 /sys/kernel/tracing/trace; echo nop > /sys/kernel/tracing/current_tracer", True, None, 700),
    "missed-sof": ("cat /sys/kernel/debug/*otg*/* 2>/dev/null | grep -i -A3 missed; dmesg | grep -i missed", True, None, 60),
    "dt-memory": ("cat /proc/iomem; dmesg | grep -iE 'reserved|cma|Memory:'; ls /proc/device-tree/reserved-memory/*", False, None, 60),
    "emmc-life": ("for f in life_time pre_eol_info name cid; do echo \"$f=$(cat /sys/block/mmcblk0/device/$f 2>/dev/null)\"; done",
                  False, None, 60),
    # --- Appendix A/B and task definitions ---------------------------------
    "kernel-identity": ("uname -r; uname -v; cat /proc/cmdline; zcat /proc/config.gz | sha256sum; sha256sum /sys/firmware/fdt; "
                        "cat /sys/module/brcmfmac/parameters/roamoff", False, None, 60),
    "kernel-features": ("ls /sys/kernel/debug/nebulaos_backlight_final /sys/kernel/debug/ns2009_final_qualification; "
                        "cat /sys/kernel/debug/nebulaos_backlight_final/status; ls -l /dev/spidev2.0; "
                        "cat /sys/bus/i2c/devices/2-0050/name; cat /sys/kernel/debug/pwm; grep -E 'mmc1|wlan' /proc/interrupts; "
                        "dmesg | grep -iE 'redefinition|brcmfmac|ns2009|at24|spi_gpio'", False, None, 60),
    "kernel-diag": ("cat /sys/kernel/tracing/available_tracers; ls /proc/pressure; head -3 /proc/schedstat; "
                    "cat /sys/kernel/debug/usb/13500000.otg/hw_params; grep -E 'MemTotal|MemAvailable' /proc/meminfo; uname -r",
                    True, None, 60),
    "kernel": ("uname -a; zcat /proc/config.gz | grep -E '^CONFIG_(PREEMPT_RT|LOCALVERSION)='; "
               "dmesg | grep -iE 'BUG:|WARNING:|Oops|use-after|stall|scheduling while atomic|sleeping function'", False, None, 60),
    "meminfo": ("cat /proc/meminfo; head -40 /proc/vmstat; free", False, None, 60),
    "memstate": (_MEMSTATE, False, None, 60),
    "memproc": (_MEMPROC, False, None, 60),
    "mem": ("cat /proc/swaps /proc/meminfo; grep -E '^(pswpin|pswpout|allocstall|oom_kill)' /proc/vmstat; "
            "dmesg | grep -iE 'oom|zram|swap'", False, None, 60),
    "usb": ("cat /sys/kernel/debug/usb/devices; grep -i dwc2 /proc/interrupts; grep -E '^ *9:' /proc/interrupts; "
            "cat /sys/kernel/debug/usb/13500000.otg/hw_params /sys/kernel/debug/usb/13500000.otg/params 2>/dev/null; "
            "dmesg | grep -iE 'dwc2|usb [0-9]-|uvcvideo|usb-storage'", False, None, 60),
    "usb-pm": ("for d in usb1 1-1 1-1.1 1-1.2; do p=/sys/bus/usb/devices/$d/power; echo \"$d $(cat $p/control $p/runtime_status "
               "$p/autosuspend_delay_ms $p/runtime_active_time $p/runtime_suspended_time 2>/dev/null | tr '\\n' ' ')\"; done; "
               "grep -i drvvbus /sys/kernel/debug/gpio; dmesg | grep -iE 'usb 1-|dwc2|disconnect' | tail -50", False, None, 60),
    "cam": ("for d in /sys/class/video4linux/*; do echo \"$d $(cat $d/name) index=$(cat $d/index)\"; done; dmesg | grep -i uvcvideo",
            False, None, 60),
    "wifi": ("iw dev; iw dev wlan0 link; iw dev wlan0 station dump 2>/dev/null | head -40; dmesg | grep -iE 'brcmf|cfg80211'",
             False, None, 60),
    # G10 (2026-10-16): can this Wi-Fi chip/driver join WPA3 (SAE) networks?
    # Read-only: phy capabilities, driver, supplicant's own key management
    # list and the security of nearby networks (cached scan, no new scan).
    "wifi-caps": ("echo '== driver'; readlink /sys/class/net/wlan0/device/driver; "
                  "dmesg | grep -iE 'brcmf|firmware|wlan' | head -20; "
                  "echo '== iw phy'; iw phy; "
                  "echo '== supplicant'; wpa_supplicant -v 2>&1 | head -2; "
                  "wpa_cli -i wlan0 get_capability key_mgmt 2>&1; wpa_cli -i wlan0 get_capability auth_alg 2>&1; "
                  "echo '== nearby networks (cached)'; "
                  "iw dev wlan0 scan dump 2>/dev/null | grep -E '^BSS|SSID:|Authentication suites|Group cipher|^\\s+\\* (Version|Pairwise)'",
                  False, None, 60),
    "irq-threads": (_IRQ_RATE, False, None, 60),
    "irq-rate-streaming": (_IRQ_RATE, False, None, 60),
    "irq-rate-paused": (_IRQ_RATE, False, None, 60),
    "schedsnap": (_THREADS_PY, False, "schedsnap.py", 180),
    "timerlat": ("python3 $T/timerlat.py --prio 49 --period-us 1250 --seconds 600 --out $T/out.json; cat $T/out.json",
                 False, "timerlat.py", 700),
    "ptyrtt": ("nice -n -10 python3 $T/ptyrtt.py --period-ms 10 --bytes 16 --seconds 600 --out $T/out.json; cat $T/out.json",
               False, "ptyrtt.py", 700),
    "kduty": ("python3 $T/kduty.py --pid \"$(cat /var/run/klippy.pid)\" --hz 10 --seconds 1800 --out $T/out.json; cat $T/out.json",
              False, "kduty.py", 1900),
    "kduty-mcu": ("python3 $T/kduty.py --pid \"$(cat /var/run/klipper_mcu.pid)\" --hz 10 --seconds 1800 --out $T/out.json; "
                  "cat $T/out.json", False, "kduty.py", 1900),
    "kduty-ktimers": ("python3 $T/kduty.py --comm ktimers --hz 10 --seconds 1800 --out $T/out.json; cat $T/out.json",
                      False, "kduty.py", 1900),
    "kstats": ("grep -E 'Stats [0-9.]+:' " + KLIPPY_LOG + " | sed -n '1p;$p'; "
               "echo \"timer_shutdowns=$(grep -cE 'Timer too close|Rescheduled timer in the past|Lost communication' " + KLIPPY_LOG + ")\"",
               False, None, 60),
    "adxl": ("python3 $T/adxl_overflows.py --seconds 120 --out $T/out.json; cat $T/out.json", False, "adxl_overflows.py", 200),
    "uartoe": ("cat '/proc/tty/driver/INGENIC serial' 2>/dev/null || cat /proc/tty/driver/* 2>/dev/null", False, None, 60),
    "dmesg": ("dmesg | grep -E 'RT throttling activated|BUG: scheduling while atomic|workqueue lockup|hung_task|WARNING:'; "
              "echo dmesg_scan_done", False, None, 60),
    "load": ("cat /proc/loadavg; head -1 /proc/stat; sleep 10; cat /proc/loadavg; head -1 /proc/stat; "
             "top -b -n 1 2>/dev/null | head -25", False, None, 60),
    "rt-config": ("uname -a; cat /sys/kernel/realtime; zcat /proc/config.gz | grep -E '^(# )?CONFIG_(PREEMPT_RT|PREEMPT_BUILD_AUTO|"
                  "HAVE_PREEMPT_AUTO|INGENIC_RSA|DEBUG_ATOMIC_SLEEP|PROVE_LOCKING|FTRACE|SCHED_DEBUG|NEBULAOS_[A-Z_]*)[= ]'; "
                  "cat /proc/interrupts; ls -l /dev/rsa /dev/hwrng 2>&1", False, None, 60),
    "rt-splat": (_RT_SPLAT, False, None, 60),
    "rt-gpio": ("grep -E 'GPIO|gpio' /proc/interrupts", False, None, 60),
    "rt-uart": ("grep -oE 'bytes_(retransmit|invalid)=[0-9]+' " + KLIPPY_LOG + " | tail -8; grep -E '^ *(51|54):' /proc/interrupts; "
                "grep -ciE 'lost communication|timer too close' " + KLIPPY_LOG, False, None, 60),
    "rt-ipi": ("dmesg | grep 'xburst2-ipi'; grep -E '^ *3:' /proc/interrupts; dmesg | grep -c 'invalid mailboxes action'",
               False, None, 60),
    "rt-lazy": ("T2=/sys/kernel/tracing; mountpoint -q $T2 || mount -t tracefs nodev $T2; "
                "echo 0 > $T2/tracing_on; echo > $T2/trace; echo 4096 > $T2/buffer_size_kb; "
                "echo 1 > $T2/events/sched/sched_waking/enable; echo 1 > $T2/events/sched/sched_switch/enable; "
                "taskset -c 1 sh -c 'while :; do :; done' & HOG=$!; echo 1 > $T2/tracing_on; "
                "taskset -c 0 sh -c 'i=0; while [ $i -lt 1000 ]; do echo x; usleep 5000; i=$((i+1)); done' | taskset -c 1 cat > /dev/null; "
                "echo 0 > $T2/tracing_on; kill $HOG; "
                "echo 0 > $T2/events/sched/sched_waking/enable; echo 0 > $T2/events/sched/sched_switch/enable; "
                "awk '/sched_waking:/ && / comm=cat /{for(i=1;i<=NF;i++){if($i~/^pid=/)p=substr($i,5);if($i~/^[0-9]+\\.[0-9]+:$/)t=$i+0}w[p]=t} "
                "/sched_switch:/ && /next_comm=cat /{for(i=1;i<=NF;i++){if($i~/^next_pid=/)p=substr($i,10);if($i~/^[0-9]+\\.[0-9]+:$/)t=$i+0} "
                "if(p in w){printf \"%d\\n\",(t-w[p])*1000000;delete w[p]}}' $T2/trace | sort -n | "
                "awk '{a[NR]=$1}END{print \"n=\"NR\" p50=\"a[int(NR*.5)]\" p90=\"a[int(NR*.9)]\" p99=\"a[int(NR*.99)]\" max=\"a[NR]}'",
                True, None, 120),
    "rt-throughput": ("command -v hackbench >/dev/null || { echo HACKBENCH_ABSENT; exit 3; }; "
                      "for i in 1 2 3 4 5; do hackbench -g 8 -l 2000 | grep Time; done; cyclictest -m -S -p 90 -i 1000 -l 60000 -q",
                      True, None, 600),
    "rt-console": ("echo t > /proc/sysrq-trigger; dmesg | tail -5", True, None, 60),
    # Boot forensics: everything that dates this boot on the device's own
    # monotonic clock. Process start times are /proc/<pid>/stat field 22 in
    # USER_HZ (100) ticks since boot; wall-clock logs convert through
    # now_epoch - uptime.
    "boot-timing": (_BOOT_TIMING, False, None, 120),
    # CPU/memory/IO pressure and scheduler counters over 10 s.
    "pressure": (_PRESSURE, False, None, 60),
    # Per-process CPU over 10 s: utime+stime ticks (USER_HZ 100), all threads summed.
    "top-cpu": ("snap(){ for p in /proc/[0-9]*; do s=$(cat $p/stat 2>/dev/null) || continue; r=${s##*) }; set -- $r; "
                "echo \"${p#/proc/} $(( ${12} + ${13} )) $(cat $p/comm 2>/dev/null) nice=${17}\"; done; }; "
                "snap > $T/a; sleep 10; snap > $T/b; echo 'ticks_in_10s pid comm nice'; "
                "awk 'NR==FNR{a[$1]=$2; next} ($1 in a){d=$2-a[$1]; if(d>0) print d, $1, $3, $4}' $T/a $T/b | sort -rn | head -30",
                False, None, 60),
}

# Defined by the plan as reversible state changes: TOOL-02 `exercise`, never `capture`.
EXERCISE_ONLY = ("camera-resume", "camera-states", "memexercise", "sof-filter-ab", "storage-autosuspend",
                 "cpu-load", "camera-viewer", "wifi-load", "usb-storage-io", "ktimers-ab", "ttyflip-ab",
                 "memexercise-sw100", "watchdog-arm", "watchdog-fire", "camera-resolution-trial", "nebula-camera-sweep")


class CaptureError(Exception):
    pass


def _data_b64(name):
    """A pinned tools/hwcap data file as minified, zlib-compressed base64."""
    import base64
    import json
    import zlib
    if name not in DATA_FILES:
        raise CaptureError("unknown data file %r" % name)
    with open(os.path.join(HWCAP_DIR, name), encoding="utf-8") as fh:
        raw = json.dumps(json.load(fh), separators=(",", ":")).encode()
    return base64.b64encode(zlib.compress(raw, 9)).decode()


def _probe_source(name):
    if name not in PROBES:
        raise CaptureError("unknown probe %r" % name)
    with open(os.path.join(HWCAP_DIR, name), encoding="utf-8") as fh:
        src = fh.read()
    if "NEBULAOS_PROBE_EOF" in src:
        raise CaptureError("probe %s contains the heredoc terminator" % name)
    return src


def capture_script(name):
    """-> (shell text, timeout) for one profile NAME. Raises CaptureError."""
    if name in EXERCISE_ONLY:
        raise CaptureError("%s changes device state: it is an exercise profile, not a capture" % name)
    if name not in CAPTURE_PROFILES:
        raise CaptureError("unknown capture profile %r" % name)
    body, needs_diag, probe, timeout = CAPTURE_PROFILES[name]
    s = ("T=/tmp/nebulaos-capture.$$; rm -rf \"$T\"; mkdir -p \"$T\" || exit 4; trap 'rm -rf \"$T\"' EXIT; "
         "printf 'CAPTURE_PROFILE=%s\\nKERNEL_RELEASE=%%s\\nSTART_UTC=%%s\\n' \"$(uname -r)\" \"$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)\"; "
         % name)
    if needs_diag:
        s += ("case \"$(uname -r)\" in *-diag) ;; *) echo PROFILE_REQUIRES_DIAGNOSTIC_IMAGE; exit 3 ;; esac; ")
    if probe:
        s += "cat > \"$T/%s\" <<'NEBULAOS_PROBE_EOF'\n%s\nNEBULAOS_PROBE_EOF\n" % (probe, _probe_source(probe))
    s += "{ %s; } 2>&1 | head -c 1048576; printf '\\nEND_UTC=%%s\\n' \"$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)\"" % body
    return s, timeout


# ---------------------------------------------------------------------------
# TOOL-02: exercise profiles - reversible, allow-listed state changes.
# ---------------------------------------------------------------------------
# Each is (setup+body, undo, timeout). The undo block runs from an EXIT/INT/TERM
# trap, so the device returns to its prior state even if the run is interrupted.
# The agent additionally requires an interactive EXERCISE_CONFIRM=<profile>
# line on stdin, and refuses any profile whose text contains a word from
# EXERCISE_REFUSED (motion, heat, firmware restart, flashing, block writes,
# swap teardown, reboot) - checked at run time, not only in review.

EXERCISE_REFUSED = ("G28", "G1 ", "M104", "M140", "SET_HEATER", "FIRMWARE_RESTART",
                    "flash", "dd ", "mkfs", "swapoff -a", "reboot")

# Milliseconds since boot. The image's BusyBox is built without
# FEATURE_DATE_NANO, so `date +%s%N` yields a literal "%N" and the shell
# arithmetic on it aborts the profile; /proc/uptime has 10 ms resolution.
_NOW_MS = "$(awk '{printf \"%d\", $1 * 1000}' /proc/uptime)"

_STORAGE_DEV = ("S=; for i in /sys/bus/usb/devices/*:*; do "
                "[ \"$(basename \"$(readlink $i/driver 2>/dev/null)\")\" = usb-storage ] && { S=${i%:*}; break; }; done; "
                "[ -n \"$S\" ] || { echo NO_USB_STORAGE; exit 3; }; P=$S/power; "
                "C0=$(cat $P/control); D0=$(cat $P/autosuspend_delay_ms)")

EXERCISE_PROFILES = {
    # HWDP-DWC-3: IRQ 9 rate and DWC2 thread cost, filter on vs off.
    "sof-filter-ab": (
        "F=/sys/module/dwc2/parameters/sof_filter; [ -w $F ] || { echo NO_SOF_FILTER_PARAM; exit 3; }; F0=$(cat $F); "
        "for v in 1 0; do echo $v > $F; sleep 2; echo \"== sof_filter=$v\"; " + _IRQ_RATE + "; done",
        "[ -n \"${F0:-}\" ] && echo $F0 > $F",
        120),
    # HWDP-DWC-5: does the USB drive autosuspend, and how long is the first read after?
    "storage-autosuspend": (
        _STORAGE_DEV + "; echo \"device=$S control=$C0 delay=$D0\"; "
        "echo 2000 > $P/autosuspend_delay_ms; echo auto > $P/control; sleep 15; "
        "echo \"runtime_status=$(cat $P/runtime_status)\"; sync; echo 3 > /proc/sys/vm/drop_caches; "
        "B=$(ls /sys/$(readlink -f $S | sed 's#^/sys/##')/*/host*/target*/*/block 2>/dev/null | head -1); "
        "t0=" + _NOW_MS + "; head -c 65536 /dev/${B:-sda} > /dev/null; t1=" + _NOW_MS + "; "
        "echo \"resume_read_ms=$(( t1 - t0 ))\"; dmesg | tail -20 | grep -iE 'usb|sd ' ",
        "[ -n \"${P:-}\" ] && { echo ${D0:-2000} > $P/autosuspend_delay_ms; echo ${C0:-on} > $P/control; }",
        90),
    # HWDP-DWC-6: first-frame latency after an idle pause.
    "camera-resume": (
        "curl -s -o /dev/null --max-time 5 localhost:8080/pause; sleep 30; t0=" + _NOW_MS + "; "
        "curl -s -o /dev/null --max-time 5 localhost:8080/resume; "
        "i=0; until curl -sf -o /dev/null --max-time 2 localhost:8080/snapshot || [ $i -ge 60 ]; do i=$((i+1)); done; "
        "t1=" + _NOW_MS + "; echo \"first_frame_ms=$(( t1 - t0 )) attempts=$i\"",
        "curl -s -o /dev/null --max-time 5 localhost:8080/resume",
        120),
    # BASE-01 step 2 / HWDP-DWC-3/4 baselines: IRQ 9 rate, DWC2 thread cost and
    # the USB runtime-PM chain in each camera state the product can enter
    # remotely - paused (/pause), ustreamer stopped (S50webcam stop) and
    # restarted (S50webcam start). Measured inside the profile after a settle
    # time, so the 10 s window is not smeared across a state transition.
    "camera-states": (
        "W=/etc/init.d/S50webcam; [ -x $W ] || { echo NO_S50WEBCAM; exit 3; }; "
        "st(){ echo \"== state=$1 utc=$(date -u +%H:%M:%S)\"; " + _IRQ_RATE + "; "
        "for d in usb1 1-1 1-1.1 1-1.2; do p=/sys/bus/usb/devices/$d/power; echo \"pm $d $(cat $p/control $p/runtime_status "
        "$p/runtime_active_time $p/runtime_suspended_time 2>/dev/null | tr '\\n' ' ')\"; done; "
        "grep -i drvvbus /sys/kernel/debug/gpio; }; "
        "D0=$(dmesg | grep -ciE 'usb 1-.*disconnect'); "
        "curl -s -o /dev/null --max-time 5 localhost:8080/pause; sleep 12; st paused; "
        "curl -s -o /dev/null --max-time 5 localhost:8080/resume; sleep 5; "
        "$W stop; sleep 12; st stopped; "
        "$W start; sleep 20; st restarted; "
        "i=0; until curl -sf -o /dev/null --max-time 2 localhost:8080/snapshot || [ $i -ge 30 ]; do i=$((i+1)); sleep 1; done; "
        "echo \"snapshot_after_restart_attempts=$i\"; "
        "echo \"usb_disconnects_during=$(( $(dmesg | grep -ciE 'usb 1-.*disconnect') - D0 ))\"",
        "$W status 2>/dev/null | grep -q 'supervisor: RUNNING' || $W start; "
        "curl -s -o /dev/null --max-time 5 localhost:8080/resume",
        240),
    # HWDP-MEM-3/6/8: memory ramps while the printer is idle-connected (no print).
    # Steps of 16..96 MiB, incompressible then compressible, 60 s each, logging
    # memory state every second; stops early when memguard reaches P3.
    # The 200 MB upload step of the plan is run from the host, not here.
    "memexercise": (
        "M=/run/nebulaos/memguard/state; "
        "case \"$(wget -q -T 2 -O - 'http://127.0.0.1:7125/printer/objects/query?print_stats=state' 2>/dev/null)\" in "
        "*printing*|*paused*) echo PRINT_ACTIVE_REFUSED; exit 3 ;; esac; "
        "mon(){ while :; do printf '%s ' \"$(date +%s)\"; grep -E '^(MemAvailable|Shmem|SwapFree):' /proc/meminfo | tr -s ' \\n' ' '; "
        "cat /sys/block/zram0/mm_stat 2>/dev/null | tr '\\n' ' '; head -1 /proc/pressure/memory 2>/dev/null | tr '\\n' ' '; "
        "cat $M 2>/dev/null; sleep 1; done; }; mon & MON=$!; "
        "for kind in urandom pattern; do for n in 16 32 48 64 96; do "
        "case \"$(cat $M 2>/dev/null)\" in P3|P4|P4_EXHAUSTED) echo \"STOP memguard=$(cat $M)\"; break 2 ;; esac; "
        "echo \"== $kind $n MiB\"; "
        "python3 -c \"import os,sys,time;k=sys.argv[1];n=int(sys.argv[2]);"
        "b=[bytearray(os.urandom(1<<20)) if k=='urandom' else bytearray((b'nebulaos compressible fill 0123456789\\\\n'*65536)[:1<<20]) for _ in range(n)];"
        "time.sleep(60)\" $kind $n & EX=$!; wait $EX; EX=; done; done",
        "[ -n \"${EX:-}\" ] && kill $EX 2>/dev/null; [ -n \"${MON:-}\" ] && kill $MON 2>/dev/null",
        900),
}


# --- Final-qualification synthetic loads and runtime A/Bs (2026-10-04) -------
# Each load runs for LOAD_SECONDS so several can overlap one measurement
# window; each is bounded and its undo kills what it started.
LOAD_SECONDS = 420
_NOW_S = "$(cut -d. -f1 /proc/uptime)"
_STAT_PID = "s=$(cat /proc/$k/stat 2>/dev/null); r=${s##*) }; set -- $r"   # ${38}=rt_priority ${39}=policy

EXERCISE_PROFILES.update({
    # L3: one busy loop per CPU at nice 0 (klippy runs at nice -10; RT threads unaffected).
    "cpu-load": (
        "N=$(nproc); P=; i=0; while [ $i -lt $N ]; do sh -c 'while :; do :; done' & P=\"$P $!\"; i=$((i + 1)); done; "
        "echo \"cpu_hogs=$N nice=0 seconds=%d\"; sleep %d; "
        "echo \"pressure_cpu=$(head -1 /proc/pressure/cpu 2>/dev/null)\"" % (LOAD_SECONDS, LOAD_SECONDS),
        "[ -n \"${P:-}\" ] && kill $P 2>/dev/null",
        LOAD_SECONDS + 120),
    # L1a: a local 1080p30 MJPEG viewer, so ustreamer encodes and the camera streams; samples ustreamer /state.
    "camera-viewer": (
        "curl -s --max-time %d -o /dev/null -w 'stream_bytes=%%{size_download} stream_Bps=%%{speed_download} http=%%{http_code}\\n' "
        "http://127.0.0.1:8080/stream & C=$!; i=0; while [ $i -lt %d ]; do sleep 30; i=$((i + 30)); "
        "echo \"t=$i state=$(curl -s --max-time 3 http://127.0.0.1:8080/state | tr -d ' \\n' | cut -c1-400)\"; done; "
        "wait $C; C=" % (LOAD_SECONDS, LOAD_SECONDS - 30),
        "[ -n \"${C:-}\" ] && kill $C 2>/dev/null",
        LOAD_SECONDS + 120),
    # L1b: sustained bidirectional Wi-Fi traffic to the default gateway (4 x 100 pkt/s x 1400 B).
    "wifi-load": (
        "GW=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}'); [ -n \"$GW\" ] || { echo NO_GATEWAY; exit 3; }; "
        "echo \"gateway=$GW\"; P=; for i in 1 2 3 4; do ping -q -s 1400 -i 0.01 -w %d \"$GW\" > $T/ping$i.txt 2>&1 & P=\"$P $!\"; done; "
        "wait; P=; cat $T/ping*.txt | grep -E 'transmitted|round-trip'; "
        "grep -E 'wlan0' /proc/net/dev" % LOAD_SECONDS,
        "[ -n \"${P:-}\" ] && kill $P 2>/dev/null",
        LOAD_SECONDS + 120),
    # L2: USB stick. Raw sequential read of the block device, and - only on a
    # read-write mounted stick - a 32 MiB temporary file written, read back and
    # deleted, in cycles for LOAD_SECONDS. User files are never touched.
    "usb-storage-io": (
        _STORAGE_DEV + "; B=$(ls /sys/$(readlink -f $S | sed 's#^/sys/##')/*/host*/target*/*/block 2>/dev/null | head -1); "
        "[ -n \"$B\" ] || { echo NO_BLOCK_DEVICE; exit 3; }; "
        "M=$(awk -v b=\"/dev/$B\" 'index($1,b)==1 && $4 ~ /^rw/ {print $2; exit}' /proc/mounts); "
        "echo \"device=$S block=$B mount=${M:-none}\"; end=$((" + _NOW_S + " + " + str(LOAD_SECONDS) + ")); n=0; "
        "while [ " + _NOW_S + " -lt $end ]; do n=$((n + 1)); sync; echo 3 > /proc/sys/vm/drop_caches; "
        "t0=" + _NOW_MS + "; head -c 67108864 /dev/$B > /dev/null; t1=" + _NOW_MS + "; echo \"cycle=$n raw_read_64MiB_ms=$((t1 - t0))\"; "
        "if [ -n \"$M\" ]; then F=\"$M/.nebulaos-qual-io.$$\"; t0=" + _NOW_MS + "; head -c 33554432 /dev/zero > \"$F\"; sync; "
        "t1=" + _NOW_MS + "; echo 3 > /proc/sys/vm/drop_caches; cat \"$F\" > /dev/null; t2=" + _NOW_MS + "; rm -f \"$F\"; F=; "
        "echo \"cycle=$n write_32MiB_ms=$((t1 - t0)) read_32MiB_ms=$((t2 - t1))\"; fi; done; "
        "dmesg | tail -30 | grep -iE 'usb|sd |I/O error|reset'",
        "[ -n \"${F:-}\" ] && rm -f \"$F\"",
        LOAD_SECONDS + 180),
    # HWDP-SCHED-1 attribution: timer latency at the shipped ktimers priority
    # (FIFO 50, IRQ-03) vs the pre-IRQ-03 reference (FIFO 1), 180 s each.
    # SCHED-01F, the documented fallback, applies FIFO 50 from userspace and so
    # is identical at runtime; FIFO 1 is the "before" the rule compares with.
    "ktimers-ab": (
        "K=; for p in /proc/[0-9]*; do case \"$(cat $p/comm 2>/dev/null)\" in ktimers/*) K=\"$K ${p#/proc/}\";; esac; done; "
        "[ -n \"$K\" ] || { echo NO_KTIMERS; exit 3; }; O=; for k in $K; do " + _STAT_PID + "; O=\"$O $k:${38}\"; done; "
        "echo \"ktimers_original=$O\"; "
        "echo '== arm A: ktimers as shipped'; python3 $T/timerlat.py --prio 49 --period-us 1250 --seconds 180 --out $T/a.json; "
        "for k in $K; do chrt -f -p 1 $k; done; "
        "for k in $K; do " + _STAT_PID + "; echo \"ktimers $k now FIFO ${38}\"; done; "
        "echo '== arm B: ktimers FIFO 1 (pre-IRQ-03 reference)'; python3 $T/timerlat.py --prio 49 --period-us 1250 --seconds 180 --out $T/b.json",
        "for e in ${O:-}; do chrt -f -p ${e#*:} ${e%%:*}; done; "
        "for e in ${O:-}; do k=${e%%:*}; " + _STAT_PID + "; echo \"ktimers $k restored FIFO ${38}\"; done",
        600),
    # HWDP-SCHED-3: pty round trip with tty_flip at its shipped nice -20 vs
    # nice 0 (the policy-only fallback = system_unbound_wq priority), 180 s each.
    "ttyflip-ab": (
        "W=/sys/devices/virtual/workqueue/tty_flip/nice; [ -w $W ] || { echo NO_TTY_FLIP_WQ; exit 3; }; N0=$(cat $W); "
        "echo \"tty_flip_nice_original=$N0\"; "
        "echo '== arm A: tty_flip as shipped'; nice -n -10 python3 $T/ptyrtt.py --period-ms 10 --bytes 16 --seconds 180 --out $T/a.json; "
        "echo 0 > $W; echo \"tty_flip_nice_now=$(cat $W)\"; "
        "echo '== arm B: tty_flip nice 0 (policy-only fallback)'; nice -n -10 python3 $T/ptyrtt.py --period-ms 10 --bytes 16 --seconds 180 --out $T/b.json",
        "[ -n \"${N0:-}\" ] && echo $N0 > $W; echo \"tty_flip_nice_restored=$(cat $W 2>/dev/null)\"",
        600),
})
# G117(b) (Run 21): the first live arming of the hardware watchdog, as a
# one-shot (never a first boot of an image that arms it). Refused unless the
# running kernel has the arming fix (NebulaOS-kernel 38c467b+ exposes
# /sys/module/ingenic_wdt/parameters/nebulaos_arm_fix = Y; the vendor start()
# armed a leftover TDR - an instant reset). Reads the WDT registers (TDR +0,
# TCER +4, TCNT +8, TCSR +0xC at 0x10002000), arms BusyBox watchdog -F -T 60
# -t 10 at oom_score_adj -1000 in the background, shows the printer keeps
# running for 30 s, then stops it with TERM (magic close) and reads TCER back
# (0 = disarmed). A lost session (HUP/PIPE) and the cleanup TERM it too.
_WDT_REGS = ("for o in 0x10002000 0x10002004 0x10002008 0x1000200c; do "
             "echo \"$o=$(devmem $o 32 2>/dev/null)\"; done")
EXERCISE_PROFILES["watchdog-arm"] = (
    "[ -c /dev/watchdog ] || { echo NO_WATCHDOG_DEVICE; exit 3; }; "
    "[ \"$(cat /sys/module/ingenic_wdt/parameters/nebulaos_arm_fix 2>/dev/null)\" = Y ] "
    "|| { echo KERNEL_WITHOUT_ARM_FIX; exit 3; }; "
    "pidof watchdog >/dev/null && { echo WATCHDOG_ALREADY_FED; exit 3; }; "
    "echo \"== kernel $(uname -v)\"; echo '== registers before'; " + _WDT_REGS + "; "
    "U0=$(cut -d' ' -f1 /proc/uptime); "
    "( echo -1000 > /proc/self/oom_score_adj; exec watchdog -F -T 60 -t 10 /dev/watchdog ) & W=$!; "
    "trap '[ -n \"${W:-}\" ] && kill -TERM $W 2>/dev/null' HUP PIPE; "
    "echo \"armed pid=$W uptime=$U0\"; sleep 2; echo '== registers armed'; " + _WDT_REGS + "; "
    "i=0; while [ $i -lt 30 ]; do sleep 5; i=$((i + 5)); echo \"t=$i uptime=$(cut -d' ' -f1 /proc/uptime) "
    "tcnt=$(devmem 0x10002008 32 2>/dev/null)\"; done; "
    "kill -TERM $W; wait $W 2>/dev/null; W=; sleep 1; echo '== registers after TERM'; " + _WDT_REGS + "; "
    "[ \"$(devmem 0x10002004 32 2>/dev/null)\" = 0x00000000 ] && echo WATCHDOG_ARM_RESULT=PASS_DISARMED "
    "|| echo WATCHDOG_ARM_RESULT=STILL_ENABLED",
    "[ -n \"${W:-}\" ] && kill -TERM $W 2>/dev/null",
    150)

# Run 23 (2026-10-31): an old full-speed (USB 1.1) webcam behind the internal
# hub loses its port ("disabled by hub (EMI?)") within seconds of streaming.
# Does a smaller frame (a smaller isochronous alt setting) hold? The product
# ustreamer is stopped; a trial one serves 60 s on port 8090 with a viewer
# attached, counting USB disconnects: the product's 1080p request on an idle
# CPU, then 640x480 and 320x240 with every core busy (is it IRQ latency?).
# S50webcam is restarted.
EXERCISE_PROFILES["camera-resolution-trial"] = (
    "W=/etc/init.d/S50webcam; [ -x $W ] || { echo NO_S50WEBCAM; exit 3; }; "
    "DEV=; for n in /sys/class/video4linux/video*; do [ \"$(cat $n/index 2>/dev/null)\" = 0 ] && "
    "readlink -f $n/device | grep -q /usb && { DEV=/dev/${n##*/}; break; }; done; "
    "[ -n \"$DEV\" ] || { echo NO_USB_CAMERA; exit 3; }; "
    "echo \"== $DEV $(cat /sys/class/video4linux/${DEV#/dev/}/device/../idVendor):"
    "$(cat /sys/class/video4linux/${DEV#/dev/}/device/../idProduct) "
    "speed=$(cat /sys/class/video4linux/${DEV#/dev/}/device/../speed)\"; "
    "v4l2-ctl -d $DEV --list-formats-ext 2>&1 | head -40; "
    "v4l2-ctl -d $DEV --list-formats 2>/dev/null | grep -q \"'MJPG'\" && F=MJPEG || F=JPEG; "
    "$W stop; sleep 3; H=; "
    "trial(){ L=$1; R=$2; "
    "if [ $3 = load ]; then N=$(nproc); i=0; while [ $i -lt $N ]; do sh -c 'while :; do :; done' & H=\"$H $!\"; i=$((i + 1)); done; fi; "
    "D0=$(dmesg | grep -c 'USB disconnect'); E0=$(dmesg | grep -c 'URB error'); "
    "/usr/bin/ustreamer --device=$DEV --format=$F --encoder=HW --resolution=$R --desired-fps=30 "
    "--host=127.0.0.1 --port=8090 --tcp-nodelay > /tmp/nebulaos-camtrial.log 2>&1 & U=$!; sleep 3; "
    "curl -s --max-time 60 -o /dev/null -w \"$L stream_bytes=%{size_download} Bps=%{speed_download}\\n\" "
    "http://127.0.0.1:8090/stream; "
    "echo \"$L load=$(cut -d' ' -f1-3 /proc/loadavg) state=$(curl -s --max-time 3 http://127.0.0.1:8090/state | tr -d ' \\n' | cut -c90-260)\"; "
    "kill $U 2>/dev/null; wait $U 2>/dev/null; U=; [ -n \"$H\" ] && kill $H 2>/dev/null; H=; "
    "echo \"$L usb_disconnects=$(( $(dmesg | grep -c 'USB disconnect') - D0 )) "
    "urb_errors=$(( $(dmesg | grep -c 'URB error') - E0 ))\"; "
    "grep -iE 'error|lost|unavailable' /tmp/nebulaos-camtrial.log | head -5; sleep 5; }; "
    "trial product-1080-idle 1920x1080 idle; trial 640-cpu-load 640x480 load; trial 320-cpu-load 320x240 load; "
    "rm -f /tmp/nebulaos-camtrial.log; $W start; sleep 5; $W status",
    "[ -n \"${U:-}\" ] && kill $U 2>/dev/null; [ -n \"${H:-}\" ] && kill $H 2>/dev/null; rm -f /tmp/nebulaos-camtrial.log; "
    "/etc/init.d/S50webcam status 2>/dev/null | grep -q 'supervisor: RUNNING' || /etc/init.d/S50webcam start",
    360)

# Run 23 (2026-10-31): a picture per candidate image setting of the Nebula
# Camera (a108:2231), to choose its defaults. Only the plain UVC controls are
# set, temporarily, with v4l2-ctl: brightness, contrast, saturation,
# sharpness, anti-flicker. Never exposure (manual is one-way), white balance
# mode or the vendor XU (night mode). A local viewer keeps the stream awake;
# each picture is a 1080p snapshot scaled to 960 px by ffmpeg and printed as
# base64 between "IMG <name>" and "END". The saved settings are re-applied.
_CAM_SWEEP = (
    ("base", "128 128 128 128 0"), ("flicker50", "128 128 128 128 1"),
    ("flicker60", "128 128 128 128 2"), ("bright105", "105 128 128 128 0"),
    ("bright150", "150 128 128 128 0"), ("contrast105", "128 105 128 128 0"),
    ("contrast150", "128 150 128 128 0"), ("sat105", "128 128 105 128 0"),
    ("sat150", "128 128 150 128 0"), ("sharp90", "128 128 128 90 0"),
    ("sharp150", "128 128 128 150 0"),
)
EXERCISE_PROFILES["nebula-camera-sweep"] = (
    "OSC=/usr/libexec/nebulaos/nebulaos-osconfig; DEV=; for n in /sys/class/video4linux/video*; do "
    "[ \"$(cat $n/index 2>/dev/null)\" = 0 ] && [ \"$(cat $n/device/../idVendor 2>/dev/null)\" = a108 ] "
    "&& { DEV=/dev/${n##*/}; break; }; done; [ -n \"$DEV\" ] || { echo NO_NEBULA_CAMERA; exit 3; }; "
    "command -v ffmpeg >/dev/null || { echo NO_FFMPEG; exit 3; }; "
    "echo \"== $DEV saved: $(cat /usr/data/nebulaos/camera/camera.json 2>/dev/null)\"; "
    "v4l2-ctl -d $DEV --list-ctrls 2>&1 | head -30; "
    "curl -s -o /dev/null --max-time 400 http://127.0.0.1:8080/stream & V=$!; sleep 8; "
    "shot(){ v4l2-ctl -d $DEV --set-ctrl=brightness=$2 --set-ctrl=contrast=$3 --set-ctrl=saturation=$4 "
    "--set-ctrl=sharpness=$5 --set-ctrl=power_line_frequency=$6 2>&1; sleep 4; "
    "curl -s -o /dev/null --max-time 5 http://127.0.0.1:8080/snapshot; sleep 1; "
    "curl -s -o /tmp/nebulaos-sweep.jpg --max-time 5 http://127.0.0.1:8080/snapshot; "
    "ffmpeg -loglevel error -y -i /tmp/nebulaos-sweep.jpg -vf scale=960:-2 -q:v 3 /tmp/nebulaos-sweep-s.jpg "
    "|| cp /tmp/nebulaos-sweep.jpg /tmp/nebulaos-sweep-s.jpg; "
    "echo \"IMG $1 ($2 $3 $4 $5 $6) bytes=$(wc -c < /tmp/nebulaos-sweep.jpg)\"; "
    "base64 /tmp/nebulaos-sweep-s.jpg; echo END; }; "
    + "; ".join("shot %s %s" % (n, v) for n, v in _CAM_SWEEP) + "; "
    "kill $V 2>/dev/null; V=; rm -f /tmp/nebulaos-sweep.jpg /tmp/nebulaos-sweep-s.jpg; "
    "$OSC camera apply >/dev/null 2>&1; echo \"restored=$?\"",
    "[ -n \"${V:-}\" ] && kill $V 2>/dev/null; rm -f /tmp/nebulaos-sweep.jpg /tmp/nebulaos-sweep-s.jpg; "
    "/usr/libexec/nebulaos/nebulaos-osconfig camera apply >/dev/null 2>&1",
    300)

# HWDP-MEM-6: the same memory ramp at swappiness 100 (MEM-T11 ships 60).
EXERCISE_PROFILES["memexercise-sw100"] = (
    "S0=$(cat /proc/sys/vm/swappiness); echo 100 > /proc/sys/vm/swappiness; "
    "echo \"swappiness=$(cat /proc/sys/vm/swappiness) (was $S0)\"; " + EXERCISE_PROFILES["memexercise"][0],
    EXERCISE_PROFILES["memexercise"][1] + "; [ -n \"${S0:-}\" ] && echo $S0 > /proc/sys/vm/swappiness",
    EXERCISE_PROFILES["memexercise"][2])


# --- Second qualification round (2026-10-04): uart1, L5, L6, boot checks -----
# Refuse unless Klipper is up, idle and has no heater target set.
_IDLE_GUARD = (
    "Q=$(wget -q -T 3 -O - 'http://127.0.0.1:7125/printer/objects/query?print_stats=state&extruder=target&heater_bed=target' "
    "2>/dev/null); case \"$Q\" in *printing*|*paused*) echo PRINT_ACTIVE_REFUSED; exit 3 ;; esac; "
    "echo \"$Q\" | grep -q '\"print_stats\"' || { echo KLIPPY_NOT_READY_REFUSED; exit 3; }; "
    "echo \"$Q\" | grep -qE '\"target\": *[1-9]' && { echo HEATER_TARGET_SET_REFUSED; exit 3; }; ")
_QM = "python3 $T/qualmcu.py"
# Stop klippy and wait until nothing holds /dev/ttyS1. KS marks it for the undo.
_KLIPPY_STOP = (
    "KS=1; /etc/init.d/S55klipper stop; i=0; while [ -n \"$(" + _QM + " holders)\" ] && [ $i -lt 30 ]; do sleep 1; "
    "i=$((i + 1)); done; [ -z \"$(" + _QM + " holders)\" ] || { echo PORT_STILL_HELD; exit 4; }; ")
# Undo: start klippy if it is not running, wait for ready, record the counters.
_KLIPPY_RESTORE = (
    "if [ -n \"${KS:-}\" ]; then p=$(cat /var/run/klippy.pid 2>/dev/null); "
    "if [ -z \"$p\" ] || [ ! -d /proc/$p ]; then /etc/init.d/S55klipper start; fi; i=0; s=; "
    "while [ $i -lt 120 ]; do s=$(wget -q -T 3 -O - http://127.0.0.1:7125/printer/info 2>/dev/null "
    "| sed -n 's/.*\"state\": *\"\\([a-z]*\\)\".*/\\1/p'); [ \"$s\" = ready ] && break; sleep 2; i=$((i + 2)); done; "
    "echo \"klippy_state_after=${s:-unknown} waited_s=$i\"; " + _QM + " snap klippy-restarted; fi")
_APP_IDENTIFY = "/usr/bin/python3 /etc/nebulaos/mcu_application_identify.py; " + _QM + " snap"

# G117(b) step 2 (Run 21, Tim 2026-10-28): the watchdog really resets a
# printer that stops feeding it. Idle printer only (no print, no heater
# target). Uses S02nebulaos-watchdog's feeder when it runs (on by default
# since Run 22), else arms BusyBox watchdog -F -T 60 -t 10 like S02;
# then SIGKILLs it: no magic close, the counter keeps running - what a hung
# userspace looks like to the hardware. Shows the counter climbing for 20 s,
# then returns; the SoC resets itself ~60 s after the last feed. Check
# afterwards with inspect (new boot_id) and capture boot-history. The undo
# stops a feeder that was not killed yet (TERM = magic close).
EXERCISE_PROFILES["watchdog-fire"] = (
    _IDLE_GUARD +
    "[ -c /dev/watchdog ] || { echo NO_WATCHDOG_DEVICE; exit 3; }; "
    "[ \"$(cat /sys/module/ingenic_wdt/parameters/nebulaos_arm_fix 2>/dev/null)\" = Y ] "
    "|| { echo KERNEL_WITHOUT_ARM_FIX; exit 3; }; "
    "echo \"boot_id_before=$(cat /proc/sys/kernel/random/boot_id) uptime=$(cut -d' ' -f1 /proc/uptime)\"; "
    "sync; "
    # Run 22: the watchdog is on by default - kill S02nebulaos-watchdog's own
    # feeder when it runs (the real configuration), else arm one like S02.
    "W=$(pidof watchdog); if [ -n \"$W\" ]; then echo \"feeder from S02 pid=$W\"; else "
    "( echo -1000 > /proc/self/oom_score_adj; exec watchdog -F -T 60 -t 10 /dev/watchdog ) & W=$!; "
    "echo \"feeder started here pid=$W\"; fi; "
    "trap '[ -n \"${W:-}\" ] && kill -TERM $W 2>/dev/null' HUP PIPE; "
    "sleep 3; echo '== registers armed'; " + _WDT_REGS + "; "
    "[ \"$(devmem 0x10002004 32 2>/dev/null)\" = 0x00000001 ] || { echo WATCHDOG_NOT_ARMED; exit 4; }; "
    "kill -KILL $W; wait $W 2>/dev/null; W=; "
    "echo \"feeder killed without magic close at uptime=$(cut -d' ' -f1 /proc/uptime)\"; "
    "i=0; while [ $i -lt 20 ]; do sleep 5; i=$((i + 5)); echo \"t=$i tcer=$(devmem 0x10002004 32 2>/dev/null) "
    "tcnt=$(devmem 0x10002008 32 2>/dev/null)\"; done; "
    "echo WATCHDOG_FIRE_RESULT=COUNTING_RESET_EXPECTED_WITHIN_60S",
    "[ -n \"${W:-}\" ] && kill -TERM $W 2>/dev/null",
    90)

EXERCISE_PROFILES.update({
    # uart1 framing errors at boot (open observation): which open produces
    # them. The MCU sends a stats message every 5 s with or without a host, so
    # the port is listened to at the right and at wrong rates, then the guard's
    # identify and klippy's own connect run from a saved 230400 and from the
    # 9600 a first open after boot starts with. Nothing is written to the MCU
    # except the identify handshake the guard sends on every boot.
    "uart-fe-probe": (
        _QM + " snap start; " + _IDLE_GUARD + _KLIPPY_STOP + _QM + " snap klippy-stopped; "
        "sleep 12; " + _QM + " snap closed-12s; "
        "for b in 230400 115200 9600; do " + _QM + " listen $b 12; " + _QM + " snap listened-$b; done; "
        + _QM + " setbaud 230400; " + _QM + " snap saved-230400; "
        + _APP_IDENTIFY + " identify-from-saved-230400; "
        + _QM + " setbaud 9600; " + _QM + " snap saved-9600; "
        + _APP_IDENTIFY + " identify-from-saved-9600; "
        + _QM + " setbaud 9600; " + _QM + " snap saved-9600-before-klippy",
        _KLIPPY_RESTORE,
        480),
    # L6: MCU link benchmark with klippy stopped - round-trip times of read-only
    # commands and debug_nop throughput, through Klipper's own serialhdl.
    "mcu-link-bench": (
        _QM + " snap start; " + _IDLE_GUARD + _KLIPPY_STOP + _QM + " snap klippy-stopped; "
        + _QM + " bench; " + _QM + " snap after-bench",
        _KLIPPY_RESTORE,
        480),
    # L5: Klipper host batch mode on the printer's own machine definition and
    # printer.cfg calibration (includes, power-loss recovery and accelerometer sections left out, so nothing is
    # written outside $T), fed the first 300k lines of the largest stored G-code
    # file (the USB stick included, read only), output discarded.
    # Host processing only: batch mode never opens an MCU port.
    "klippy-batch": (
        "Q=$(wget -q -T 3 -O - 'http://127.0.0.1:7125/printer/objects/query?print_stats=state' 2>/dev/null); "
        "case \"$Q\" in *printing*|*paused*) echo PRINT_ACTIVE_REFUSED; exit 3 ;; esac; "
        "M=/opt/printer_data/config/nebulaos/machine.cfg; [ -f $M ] || M=/etc/nebulaos/klipper/machine.cfg; "
        "python3 -c \"import re,sys;out=['[bltouch]\\nz_offset: 0\\n[heater_bed]\\ncontrol: watermark\\n[extruder]\\ncontrol: watermark\\nrotation_distance: 7.5\\n']\n"
        "for f in sys.argv[2:]:\n"
        " keep=True\n"
        " for l in open(f):\n"
        "  m=re.match(r'(#\\*# )?\\[([^\\]]+)\\]',l)\n"
        "  if m: keep=not re.match(r'(include |nebulaos_|adxl345|resonance_tester|temperature_sensor mcu_temp)',m.group(2))\n"
        "  if keep: out.append(l)\n"
        "open(sys.argv[1],'w').write(''.join(out))\" $T/batch.cfg $M /opt/printer_data/config/printer.cfg; "
        "echo \"config=$M sections=$(grep -c '^\\[' $T/batch.cfg)\"; "
        "G=$(find /opt/printer_data/gcodes -name '*.gcode' -type f 2>/dev/null "
        "| while read f; do echo \"$(wc -c < \"$f\") $f\"; done | sort -n | tail -1 | cut -d' ' -f2-); "
        "[ -n \"$G\" ] || { echo NO_GCODE_FILE; exit 3; }; "
        "echo \"gcode=$G bytes=$(wc -c < \"$G\") lines=$(wc -l < \"$G\") used_lines=300000\"; mkfifo $T/in.gcode; "
        "head -n 300000 \"$G\" > $T/in.gcode & "
        "echo '" + _data_b64("klipper-dict-board.json") + "' | python3 -c \"import sys,zlib,base64;"
        "open(sys.argv[1],'wb').write(zlib.decompress(base64.b64decode(sys.stdin.read())))\" $T/board.json; "
        "python3 -c \"import sys,zlib,json\nd=open('/usr/bin/klipper_mcu','rb').read()\nfor i in range(len(d)-1):\n"
        " if d[i]==0x78 and d[i+1] in (1,0x5e,0x9c,0xda):\n  try: j=zlib.decompressobj().decompress(d[i:i+65536]);json.loads(j)\n"
        "  except Exception: continue\n  open(sys.argv[1],'wb').write(j);break\" $T/host.json; "
        "echo \"dicts: board=$(wc -c < $T/board.json) host=$(wc -c < $T/host.json)\"; "
        "PY=/usr/bin/python3; [ -x /usr/data/nebulaos/envs/klipper/bin/python3 ] && PY=/usr/data/nebulaos/envs/klipper/bin/python3; "
        "echo \"before: $(cat /proc/loadavg) cpu_psi=$(head -1 /proc/pressure/cpu)\"; "
        "python3 -c \"import os,subprocess,sys,time;t=time.monotonic();rc=subprocess.call(sys.argv[1:]);"
        "w=time.monotonic()-t;u=os.times();"
        "print('BATCH rc=%d wall_s=%.1f user_s=%.1f sys_s=%.1f'%(rc,w,u.children_user,u.children_system))\" "
        "$PY /opt/klipper/klippy/klippy.py $T/batch.cfg -i /dev/stdin -o /dev/null "
        "-d $T/board.json -d rpi=$T/host.json -l $T/batch.log < $T/in.gcode 2>&1 | tail -20; ls -la $T; "
        "echo \"after: $(cat /proc/loadavg) cpu_psi=$(head -1 /proc/pressure/cpu)\"; "
        "echo \"unknown_commands=$(grep -c 'Unknown command' $T/batch.log) errors=$(grep -c '^!!' $T/batch.log)\"; "
        "grep -m5 'Unknown command' $T/batch.log; grep -E 'Exiting|print time|Traceback|Error' $T/batch.log | tail -10; "
        "tail -5 $T/batch.log",
        ":",
        1500),
    # Boot forensics: the cost of the checks S04/S05 repeat on every normal
    # boot, cold (page cache dropped, as at boot) and warm; plus the evidence
    # behind the per-boot migrate findings. The checks only import modules and
    # read git refs.
    "boot-check-costs": (
        "log(){ :; }; . /usr/libexec/nebulaos-venv-lib.sh; "
        "MS='import tornado, numpy, streaming_form_data.targets'; KSM='import greenlet, cffi, jinja2, serial, can'; "
        "A=/usr/data/nebulaos/apps; "
        "c(){ l=$1; shift; s=$(cut -d' ' -f1 /proc/uptime); \"$@\" >/dev/null 2>&1; r=$?; e=$(cut -d' ' -f1 /proc/uptime); "
        "echo \"COST $l rc=$r seconds=$(awk -v a=$s -v b=$e 'BEGIN{printf \"%.2f\", b-a}')\"; }; "
        "g(){ for x in klipper nebulaos-klipper-extensions moonraker; do git -C $A/$x rev-parse HEAD; done; }; "
        "for pass in cold warm; do [ $pass = cold ] && { sync; echo 3 > /proc/sys/vm/drop_caches; }; "
        "c $pass-python-bare /usr/bin/python3 -c pass; "
        "c $pass-S04-moonraker-venv venv_is_usable /usr/data/nebulaos/envs/moonraker \"$MS\"; "
        "c $pass-S04-klipper-venv venv_is_usable /usr/data/nebulaos/envs/klipper \"$KSM\"; "
        "c $pass-S05-klipper-venv venv_is_usable /usr/data/nebulaos/envs/klipper \"$KSM\"; "
        "c $pass-S04-migrate-git-heads g; done; "
        "echo '== printer.cfg includes'; grep -n '^\\[include' /opt/printer_data/config/printer.cfg; "
        "echo '== migrate refusal backups'; B=/usr/data/nebulaos/system/migration-backups/printer-cfg-migration-refused; "
        "echo \"count=$(ls $B 2>/dev/null | wc -l) kb=$(du -sk $B 2>/dev/null | cut -f1)\"; ls $B 2>/dev/null | sed -n '1p;$p'; "
        "echo '== migration-backups total'; du -sk /usr/data/nebulaos/system/migration-backups/* 2>/dev/null; "
        "echo '== diskswap'; cat /proc/swaps; grep -iE 'diskswap|swapfile' /usr/data/nebulaos/logs/memguard.log 2>/dev/null | tail -5; "
        "echo '== seeds'; tail -n 5 /usr/data/nebulaos/maintenance/logs/camera-seed.log /usr/data/nebulaos/maintenance/logs/mainsail-macros-seed.log 2>/dev/null",
        ":",
        300),
})

# --- Final pre-baseline validation (2026-10-05) ------------------------------
# Read-only boot forensics: S97's four health gates re-evaluated now, debugfs,
# the display configuration, disk writes and CPU after readiness, errors.
CAPTURE_PROFILES["boot-forensics"] = (
    "echo \"uptime=$(cut -d' ' -f1 /proc/uptime)\"; echo '== swaps'; cat /proc/swaps; "
    "echo '== swapfile'; ls -l --full-time /usr/data/nebulaos/system/swapfile 2>&1; "
    "echo '== app-generation'; cat /usr/data/nebulaos/system/app-generation.json 2>/dev/null; "
    "grep -o '\"migration_version\"[^,}]*' /opt/nebulaos-seeds/seed-manifest.json; "
    "echo '== venv-validation'; ls -l --full-time /usr/data/nebulaos/system/venv-validation/ 2>&1; "
    "echo '== migration-log'; tail -n 30 /usr/data/nebulaos/system/diagnostics/migration.log 2>/dev/null; "
    "echo '== activation-log'; tail -n 16 /usr/data/nebulaos/system/diagnostics/activation.log 2>/dev/null; "
    "echo '== refused-backups'; ls -l --full-time /usr/data/nebulaos/system/migration-backups/printer-cfg-migration-refused 2>&1 | tail -4; "
    "echo '== debugfs'; grep debugfs /proc/mounts || echo DEBUGFS_NOT_MOUNTED; "
    "ls -l /sys/kernel/debug/nebulaos_backlight_final/status 2>&1; "
    "echo '== S97 gates now'; /etc/nebulaos-healthcheck.sh stage2 2>&1 | tail -8; "
    "p=$(cat /var/run/nebulascreen.pid /var/run/guppyscreen.pid 2>/dev/null | head -1); [ -n \"$p\" ] && [ -d /proc/$p ] && echo GATE_GUPPYSCREEN=ok || echo GATE_GUPPYSCREEN=fail; "
    "ip -4 -o addr show scope global | grep -q . && echo GATE_NETWORK=ok || echo GATE_NETWORK=fail; "
    "[ -r /sys/kernel/debug/nebulaos_backlight_final/status ] && echo GATE_DISPLAY=ok || echo GATE_DISPLAY=fail; "
    "echo '== display config'; cat /usr/data/nebulaos/display-qualified.conf 2>&1 | head -30; "
    "echo '== display controllers'; ls /var/run/*display* /run/nebulaos-display* 2>&1; "
    "for f in /var/run/nebulaos-display-sleep-wake-controller.pid; do p=$(cat $f 2>/dev/null); echo \"$f pid=$p alive=$([ -n \"$p\" ] && [ -d /proc/$p ] && echo yes || echo no)\"; done; "
    "echo '== disk writes 10s'; a=$(awk '$3==\"mmcblk0\"{print $10}' /proc/diskstats); sleep 10; b=$(awk '$3==\"mmcblk0\"{print $10}' /proc/diskstats); "
    "echo \"mmcblk0_sectors_written_10s=$((b - a))\"; awk '$3 ~ /^mmcblk0p/ {print $3, \"reads=\"$4, \"sectors_written=\"$10}' /proc/diskstats; "
    "echo '== vmstat'; grep -E '^(pswpin|pswpout|pgmajfault|oom_kill) ' /proc/vmstat; head -3 /proc/meminfo; "
    "echo '== errors dmesg'; dmesg | grep -iE 'error|fail|warn|bug|oops|timeout|reset' | grep -viE 'loglevel|ignoring' | tail -40; "
    "echo '== errors syslog'; grep -iE 'error|fail|segfault|killed|respawn' /var/log/messages 2>/dev/null | grep -v dropbear | tail -40; "
    "echo '== memguard'; tail -n 25 /usr/data/nebulaos/logs/memguard.log 2>/dev/null",
    False, None, 120)

CAPTURE_PROFILES["cam-state"] = (
    "echo \"marker=$(cat /usr/data/nebulaos/maintenance/camera-idle-mode 2>/dev/null || echo absent) "
    "state_file=$(cat /var/run/nebulaos-camera-idle-state 2>/dev/null || echo absent)\"; "
    "ps | grep '[c]amera-idle-controller' | head -3; curl -s --max-time 3 http://127.0.0.1:8080/state | tr -d ' \\n' | cut -c1-500; echo; "
    "for d in usb1 1-1 1-1.1 1-1.2; do echo \"pm $d $(cat /sys/bus/usb/devices/$d/power/runtime_status 2>/dev/null)\"; done",
    False, None, 60)

EXERCISE_PROFILES.update({
    # BOOT-02 qualification: arm the one-shot event-driven Wi-Fi selector for
    # the NEXT boot only (S01wifi consumes it before acting on it).
    "wifi-eventdriven-arm": (
        "M=/usr/data/nebulaos/maintenance/wifi-boot-wait-mode; mkdir -p ${M%/*}; printf 'event-driven\\n' > $M; sync; "
        "echo \"armed=$(cat $M)\"; ls -l $M",
        ":",
        60),
    # BOOT-08: explicit maintenance enable/disable of the eMMC swap tier, and
    # memguard's defensive swapoff outside maintenance.
    "diskswap-cycle": (
        "D=/etc/init.d/S03nebulaos-diskswap; F=/usr/data/nebulaos/system/swapfile; echo '== before'; cat /proc/swaps; "
        "$D enable; echo \"enable_rc=$?\"; cat /proc/swaps; grep -q \"^$F \" /proc/swaps && echo SWAPFILE_ACTIVE=yes || echo SWAPFILE_ACTIVE=no; "
        "echo \"status=$($D status)\"; echo '== memguard defensive policy (no maintenance lock)'; "
        "i=0; while grep -q \"^$F \" /proc/swaps && [ $i -lt 90 ]; do sleep 2; i=$((i + 2)); done; "
        "echo \"memguard_swapoff_after_s=$i still_active=$(grep -c \"^$F \" /proc/swaps)\"; "
        "grep -E 'disk swap|DISKSWAP' /usr/data/nebulaos/logs/memguard.log | tail -3; "
        "echo '== explicit enable/disable'; $D enable >/dev/null; grep -c \"^$F \" /proc/swaps; $D disable; echo \"disable_rc=$?\"; "
        "$D disable; echo \"disable_again_rc=$?\"; echo \"status=$($D status)\"; cat /proc/swaps",
        "/etc/init.d/S03nebulaos-diskswap disable >/dev/null 2>&1; cat /proc/swaps",
        300),
})

# CAM-01R / CAM-05: opt into C2, measure the paused camera, viewer-triggered
# resume, repeated cycles; the undo removes the marker and resumes (C0).
_CAM_UST = ("ust(){ p=$(cat /var/run/ustreamer.pid); a=$(awk '{print $14+$15}' /proc/$p/stat); "
            "w=$(for q in /proc/[0-9]*; do case \"$(cat $q/comm 2>/dev/null)\" in irq/9-*) awk '{print $14+$15}' $q/stat;; esac; done | awk '{s+=$1} END{print s+0}'); "
            "sleep 20; b=$(awk '{print $14+$15}' /proc/$p/stat); "
            "x=$(for q in /proc/[0-9]*; do case \"$(cat $q/comm 2>/dev/null)\" in irq/9-*) awk '{print $14+$15}' $q/stat;; esac; done | awk '{s+=$1} END{print s+0}'); "
            "awk -v d=$((b - a)) -v w=$((x - w)) -v l=\"$1\" 'BEGIN{printf \"CPU %s ustreamer=%.2f%% dwc2_irq_thread=%.2f%% (of one CPU, 20 s)\\n\", l, d/20, w/20}'; }; ")
_CAM_PM = ("pm(){ for d in usb1 1-1 1-1.1 1-1.2; do echo \"pm $d $(cat /sys/bus/usb/devices/$d/power/runtime_status 2>/dev/null)\"; done; }; ")
_CAM_WAIT = ("waitstate(){ i=0; while [ \"$(cat $SF 2>/dev/null)\" != \"$1\" ] && [ $i -lt $2 ]; do sleep 1; i=$((i + 1)); done; "
             "echo \"state=$(cat $SF 2>/dev/null) after_s=$i\"; }; ")
_CAM_ONLINE = ("online(){ curl -s --max-time 2 http://127.0.0.1:8080/state | tr -d ' \\n' | grep -o '\"online\":[a-z]*' | head -1; }; ")
EXERCISE_PROFILES["camera-c2-qualify"] = (
    "M=/usr/data/nebulaos/maintenance/camera-idle-mode; S51=/etc/init.d/S51nebulaos-camera-idle-controller; "
    "SF=/var/run/nebulaos-camera-idle-state; " + _CAM_UST + _CAM_PM + _CAM_WAIT + _CAM_ONLINE +
    "echo \"default_marker=$(cat $M 2>/dev/null || echo absent) default_state=$(cat $SF 2>/dev/null || echo absent) \"; "
    "ps | grep -c '[n]ebulaos-camera-idle' | sed 's/^/controller_processes=/'; ust idle-C0; " + _IRQ_RATE + "; pm; "
    "printf 'C2\\n' > $M; sync; C2SET=1; $S51 start; t0=$(cut -d. -f1 /proc/uptime); waitstate paused 150; "
    "echo \"pause_after_s=$(( $(cut -d. -f1 /proc/uptime) - t0 ))\"; sleep 5; ust paused-C2; " + _IRQ_RATE + "; pm; online; "
    "curl -s -o $T/snap.jpg --max-time 5 http://127.0.0.1:8080/snapshot; echo \"paused_snapshot_bytes=$(wc -c < $T/snap.jpg)\"; "
    "for c in 1 2 3; do echo \"== cycle $c: viewer\"; ms0=$(awk '{printf \"%d\", $1*1000}' /proc/uptime); "
    "curl -s --max-time 25 -o /dev/null -w \"stream_bytes=%{size_download} Bps=%{speed_download}\\n\" http://127.0.0.1:8080/stream & V=$!; "
    "k=0; until online | grep -q true || [ $k -ge 200 ]; do sleep 0.1; k=$((k + 1)); done; "
    "echo \"viewer_resume_ms=$(( $(awk '{printf \"%d\", $1*1000}' /proc/uptime) - ms0 ))\"; sleep 15; "
    "echo \"fps=$(curl -s --max-time 2 http://127.0.0.1:8080/state | tr -d ' \\n' | grep -o '\"captured_fps\":[0-9]*' | head -1)\"; "
    "wait $V; V=; waitstate paused 150; done; ust paused-after-cycles; "
    "dmesg | tail -40 | grep -ciE 'usb .*disconnect|uvc.*error' | sed 's/^/usb_errors_tail=/'",
    "[ -n \"${V:-}\" ] && kill $V 2>/dev/null; if [ -n \"${C2SET:-}\" ]; then rm -f $M; sync; fi; "
    "$S51 stop >/dev/null 2>&1; curl -s -o /dev/null --max-time 5 http://127.0.0.1:8080/resume; "
    "echo \"restored marker=$(cat $M 2>/dev/null || echo absent) state=$(cat $SF 2>/dev/null || echo absent)\"",
    1200)

# MCU guard identify reliability: the guard's exact application-identify step
# (5 s budget) run repeatedly with klippy stopped, warm and with the page cache
# dropped (as at boot); uart1 counters around each attempt. Read-only for the
# MCU (identify handshake only, never the bootloader path).
EXERCISE_PROFILES["mcu-identify-repeat"] = (
    _QM + " snap start; " + _IDLE_GUARD + _KLIPPY_STOP + _QM + " snap klippy-stopped; "
    "for pass in warm warm warm warm cold cold cold warm warm cold; do "
    "[ $pass = cold ] && { sync; echo 3 > /proc/sys/vm/drop_caches; }; "
    "s=$(awk '{printf \"%d\", $1*1000}' /proc/uptime); "
    "o=$(/usr/bin/python3 /etc/nebulaos/mcu_application_identify.py 2>&1 | tail -1); rc=$?; "
    "e=$(awk '{printf \"%d\", $1*1000}' /proc/uptime); "
    "echo \"IDENTIFY pass=$pass ms=$((e - s)) out=$o\"; " + _QM + " snap after-$pass; sleep 2; done; "
    "echo '== import cost cold'; sync; echo 3 > /proc/sys/vm/drop_caches; s=$(awk '{printf \"%d\", $1*1000}' /proc/uptime); "
    "/usr/bin/python3 -c \"import sys; sys.path.insert(0, '/opt/klipper/klippy'); sys.path.insert(0, '/etc/nebulaos'); "
    "import reactor, serialhdl, mcu_application_identify; serialhdl.SerialReader(reactor.Reactor())\"; "
    "e=$(awk '{printf \"%d\", $1*1000}' /proc/uptime); echo \"cold_import_and_reader_ms=$((e - s))\"",
    _KLIPPY_RESTORE,
    600)

# --- Live final fix verification (2026-10-05) ---------------------------------
# Every proposed final-baseline fix is run as a patched COPY under
# /run/nebulaos-live-verify (tmpfs) next to the image's own script; the image is
# never modified, and each undo removes its copies. Probe texts: tools/hwcap/lv_*.sh.
_LV = "/run/nebulaos-live-verify"
_LV_M1 = _LV + "/m1"
_M1 = "python3 $T/lv_m1.py"
_ID = _M1 + " identify"
EXERCISE_PROFILES.update({
    # M1: the guard's identify with the proposed 15 s budget (a patched copy of
    # mcu_application_identify.py, imported ahead of /etc/nebulaos) against the
    # image's 5 s: warm, cold, and cold + two CPU hogs + the port's saved rate
    # at 9600 (the boot conditions); then the failure path must stay bounded.
    "live-m1-identify": (
        _M1 + " snap start; " + _IDLE_GUARD + _KLIPPY_STOP.replace(_QM, _M1) + _M1 + " snap klippy-stopped; "
        "mkdir -p " + _LV_M1 + "; cp /etc/nebulaos/mcu_application_identify.py " + _LV_M1 + "/; "
        "sed -i 's/^def get_application_identity(port, baud, timeout=5.0,/def get_application_identity(port, baud, timeout=15.0,/' "
        + _LV_M1 + "/mcu_application_identify.py; "
        "grep -n '^def get_application_identity' " + _LV_M1 + "/mcu_application_identify.py; "
        "grep -q 'timeout=15.0, klippy_lib_path' " + _LV_M1 + "/mcu_application_identify.py || { echo PATCH_FAILED; exit 4; }; "
        "echo \"decide_call=$(grep -n 'identify_fn(port, baud)' /etc/nebulaos/mcu_lifecycle.py)\"; P=/dev/ttyS1; "
        "for i in 1 2 3 4 5; do " + _ID + " warm-patched-$i 230400 $P " + _LV_M1 + "; done; "
        "for i in 1 2 3; do sync; echo 3 > /proc/sys/vm/drop_caches; " + _ID + " cold-patched-$i 230400 $P " + _LV_M1 + "; done; "
        "yes > /dev/null & H1=$!; yes > /dev/null & H2=$!; "
        "for i in 1 2 3 4; do for v in image patched; do M=; [ $v = patched ] && M=" + _LV_M1 + "; "
        + _M1 + " setbaud 9600; sync; echo 3 > /proc/sys/vm/drop_caches; "
        + _ID + " stress-9600-$v-$i 230400 $P $M; done; done; kill $H1 $H2; H1=; H2=; " + _M1 + " snap after-stress; "
        + _ID + " fail-wrongbaud-patched 115200 $P " + _LV_M1 + "; echo \"holders_after=[$(" + _M1 + " holders)]\"; "
        + _ID + " fail-noport-patched 230400 /dev/nebulaos-live-verify-noport " + _LV_M1 + "; "
        + _ID + " fail-wrongbaud-image 115200 $P; "
        + _ID + " final-ok-patched 230400 $P " + _LV_M1 + "; " + _M1 + " snap end",
        "[ -n \"${H1:-}\" ] && kill $H1 $H2 2>/dev/null; rm -rf " + _LV_M1 + "; " + _KLIPPY_RESTORE.replace(_QM, _M1),
        900),
    "live-s1-s03": (
        ". $T/lv_s1.sh",
        "/etc/init.d/S03nebulaos-diskswap disable > /dev/null 2>&1; rm -f " + _LV + "/S03-patched; "
        "echo \"undo: swapfile_in_swaps=$(grep -c swapfile /proc/swaps)\"",
        600),
    "live-s2-s97": (
        ". $T/lv_s2.sh",
        "rm -rf " + _LV + "/S97-patched " + _LV + "/ndq-wrap.sh " + _LV + "/s2conf " + _LV + "/s2-insert " + _LV + "/s2marker.*",
        300),
    "live-g5-debugfs": (
        ". $T/lv_g5.sh",
        "[ -n \"${G5M:-}\" ] && umount /sys/kernel/debug; rm -f " + _LV + "/ndq-wrap-g5.sh " + _LV + "/g5-synthetic-qc1 " + _LV + "/g5marker; "
        "echo \"undo: debugfs_mounted=$(grep -c ' /sys/kernel/debug debugfs ' /proc/mounts)\"",
        180),
    "live-s3-s4-camera": (
        ". $T/lv_cam.sh",
        "[ -n \"${V:-}\" ] && kill $V 2>/dev/null; if [ -n \"${CAMLV:-}\" ]; then "
        "[ -x \"$S51\" ] && \"$S51\" stop > /dev/null 2>&1; curl -s -o /dev/null --max-time 5 http://127.0.0.1:8080/resume; "
        "if [ \"$SF0\" = absent ]; then rm -f $SF; else printf '%s' \"$SF0\" > $SF; fi; "
        "rm -f " + _LV + "/cam-lib.sh " + _LV + "/S51-patched " + _LV + "/s4-stop; fi; "
        "echo \"undo: state=$(cat /var/run/nebulaos-camera-idle-state 2>/dev/null || echo absent) "
        "controller_loops=$(for c in /proc/[0-9]*/cmdline; do tr '\\0' ' ' < $c 2>/dev/null; echo; done | grep -cE '(idle-controller|S51-patched) __run $')\"",
        1500),
    "live-g6-dhcp": (". $T/lv_g6.sh", "rm -f " + _LV + "/g6script " + _LV + "/g6.log " + _LV + "/g6.err", 180),
    "live-g7-klippy": (
        _IDLE_GUARD + "KS=1; . $T/lv_g7.sh",
        "rm -f " + _LV + "/g7poll.py; for s in moonraker nebulascreen guppyscreen; do p=$(cat /var/run/$s.pid 2>/dev/null); "
        "[ -n \"$p\" ] && [ -d /proc/$p ] || /etc/init.d/S5*$s start; done; " + _KLIPPY_RESTORE,
        1200),
    "live-g8-seeder": (". $T/lv_g8.sh", "rm -f " + _LV + "/g8dry.py " + _LV + "/g8-marker.json", 240),
    "live-g9-ext4": (". $T/lv_g9.sh", ":", 120),
    "live-g10-diskswap": (
        ". $T/lv_g10.sh",
        "/etc/init.d/S03nebulaos-diskswap disable > /dev/null 2>&1; echo \"undo: swapfile_in_swaps=$(grep -c swapfile /proc/swaps)\"",
        300),
    # NG1: Moonraker's HTTP errors never reach the client (Tornado send_error
    # raises). A throwaway Tornado app on 127.0.0.1:7199, as shipped and with
    # the missing httputil._ABNF defined; Moonraker is not touched.
    "live-ng1-tornado": (
        "PY=/usr/data/nebulaos/envs/moonraker/bin/python3; [ -x $PY ] || PY=python3; "
        "$PY $T/lv_ng1.py image 2>&1 | grep -vE '^ +|^Traceback' | tail -8; $PY $T/lv_ng1.py fixed 2>&1 | tail -6",
        ":",
        120),
    # The end state the mission must prove: no override left anywhere.
    "live-verify-cleanup": (
        "echo \"before: $(ls -A " + _LV + " 2>/dev/null | tr '\\n' ' ')\"; rm -rf " + _LV + " /usr/data/nebulaos/maintenance/live-verify; "
        "echo \"lv_dir=$(ls -d " + _LV + " 2>/dev/null || echo absent) lv_persistent=$(ls -d /usr/data/nebulaos/maintenance/live-verify 2>/dev/null || echo absent)\"",
        ":",
        60),
})
# G8: how Moonraker answers a read of a missing database key (read-only GETs).
CAPTURE_PROFILES["live-g8-missing-key"] = (
    "U=http://127.0.0.1:7125/server/database/item; "
    "for q in 'namespace=mainsail&key=macros.macrogroups.nebulaos-calibration' "
    "'namespace=mainsail&key=macros.macrogroups.nebulaos_calibration' "
    "'namespace=mainsail&key=nebulaos_live_verify_absent_top_level' "
    "'namespace=nebulaos_live_verify_absent_ns&key=x'; do "
    "echo \"GET $q -> $(curl -s -o $T/b -m 40 -w 'http=%{http_code} seconds=%{time_total}' \"$U?$q\") body=$(head -c 160 $T/b 2>/dev/null)\"; done; "
    "echo '== moonraker.log'; grep -nE 'database|Traceback|Error|error' /opt/printer_data/logs/moonraker.log | tail -n 25 | cut -c1-260; "
    "echo '== moonraker version'; wget -q -T 3 -O - http://127.0.0.1:7125/server/info | grep -o '\"moonraker_version\": *\"[^\"]*\"'",
    False, None, 240)
CAPTURE_PROFILES["live-pristine"] = (
    "echo \"lv_dir=$(ls -A " + _LV + " 2>/dev/null | wc -l) lv_persistent=$(ls -d /usr/data/nebulaos/maintenance/live-verify 2>/dev/null || echo absent)\"; "
    "echo \"bind_or_overlay_on_image_paths=$(grep -cE ' /(etc|usr/libexec|usr/bin|opt/nebulaos)[/ ]' /proc/mounts)\"; "
    "grep -E ' /(etc|usr/libexec|usr/bin|opt/nebulaos)[/ ]' /proc/mounts; "
    "echo \"debugfs=$(grep -c ' /sys/kernel/debug debugfs ' /proc/mounts) swaps=$(tail -n +2 /proc/swaps | awk '{print $1}' | tr '\\n' ' ')\"; "
    "echo \"camera_marker=$(cat /usr/data/nebulaos/maintenance/camera-idle-mode 2>/dev/null || echo absent) "
    "camera_state=$(cat /var/run/nebulaos-camera-idle-state 2>/dev/null || echo absent) "
    "camera_controller_loops=$(for c in /proc/[0-9]*/cmdline; do tr '\\0' ' ' < $c 2>/dev/null; echo; done | grep -cE '(idle-controller|S51-patched) __run $')\"; "
    "echo \"locks=[$(ls -A /usr/data/nebulaos/updates/locks 2>/dev/null | tr '\\n' ' ')] "
    "wifi_marker=$(ls /usr/data/nebulaos/maintenance/wifi-boot-wait-mode 2>/dev/null || echo absent) "
    "diskswap_request=$(ls /usr/data/nebulaos/maintenance/diskswap-next-boot 2>/dev/null || echo absent)\"; "
    "echo \"stray_processes=$(for c in /proc/[0-9]*/cmdline; do tr '\\0' ' ' < $c 2>/dev/null; echo; done | grep -cE '^(yes |python3 [^ ]*(g7poll|g8dry)|udhcpc -i wlan0 -f)')\"; "
    "for f in /etc/init.d/S03nebulaos-diskswap /etc/init.d/S97nebulaos-display-qualified-apply /etc/init.d/S51nebulaos-camera-idle-controller "
    "/etc/nebulaos-camera-idle-controller.sh /etc/nebulaos/mcu_application_identify.py /etc/nebulaos/mcu_lifecycle.py; do "
    "echo \"$(sha256sum $f)\"; done; cat /etc/nebulaos-release 2>/dev/null | head -5; "
    "echo \"mcu_guard=$(grep -h '^MCU_GUARD_RESULT=' /run/nebulaos-mcu-guard.state 2>/dev/null)\"; "
    "wget -q -T 3 -O - http://127.0.0.1:7125/server/info 2>/dev/null | grep -o '\"klippy_state\": *\"[a-z]*\"'",
    False, None, 60)

# --- Pre-final acceptance (2026-10-07) ----------------------------------------
# S3/S4 against the installed image's own camera policy (no marker, no patch).
EXERCISE_PROFILES["pf-camera"] = (
    _IDLE_GUARD + ". $T/pf_cam.sh",
    "[ -n \"${V:-}\" ] && kill $V 2>/dev/null; p=$(cat /var/run/nebulaos-camera-idle-controller.pid 2>/dev/null); "
    "[ -n \"$p\" ] && [ -d /proc/$p ] || /etc/init.d/S51nebulaos-camera-idle-controller start > /dev/null 2>&1; "
    "echo \"undo: controller_pid=$(cat /var/run/nebulaos-camera-idle-controller.pid 2>/dev/null)\"",
    1500)
# NG1 through the real Moonraker: missing-key reads answer at once, no _ABNF
# traceback since boot, the boot-time seeder run, normal API health.
# Klippy's last start, read only: the log from the last "Start printer at",
# without the large config dump, plus S95's recovery marker and syslog lines.
CAPTURE_PROFILES["pf-klippy-start"] = (
    "L=/opt/printer_data/logs/klippy.log; n=$(grep -n 'Start printer at' $L | tail -1 | cut -d: -f1); "
    "echo \"start_line=$n uptime=$(cut -d' ' -f1 /proc/uptime)\"; "
    "tail -n +$n $L | awk 'NR==1{print} /^=======================$/{on=1; next} on' | grep -vE '^Stats [0-9]' | head -n 120 | cut -c1-220; "
    "echo '== stats'; tail -n +$n $L | grep -E '^Stats [0-9]' | sed -n '1,3p' | cut -c1-200; "
    "echo '== s95'; ls -l --full-time /run/mcu-boot-recovery-attempted 2>&1; "
    "grep -aE 'S95|mcu-boot-recovery|mcu_boot_recovery' /var/log/messages 2>/dev/null | tail -20; "
    "echo '== uart'; cat '/proc/tty/driver/INGENIC serial' 2>/dev/null | sed -n '2,3p'",
    False, None, 60)
# When the _ABNF tracebacks in moonraker.log were written (log persists across images).
CAPTURE_PROFILES["pf-ng1-abnf-times"] = (
    "L=/opt/printer_data/logs/moonraker.log; echo \"log_first=$(head -c 23 $L) log_lines=$(wc -l < $L) boot_utc=$(date -u -d @$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) )) +%Y-%m-%dT%H:%M:%S)\"; "
    "grep -n \"has no attribute '_ABNF'\" $L | cut -d: -f1 | while read n; do "
    "sed -n \"1,${n}p\" $L | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' | tail -1 | cut -c1-23; done | sort | uniq -c; "
    "echo \"moonraker_starts=$(grep -c 'Starting Moonraker' $L) last_start=$(grep 'Starting Moonraker' $L | tail -1 | cut -c1-23)\"",
    False, None, 120)
# After a load run, read only: memguard decisions, kernel and Wi-Fi state.
CAPTURE_PROFILES["pf-after-load"] = (
    "echo \"uptime=$(cut -d' ' -f1 /proc/uptime) now=$(date -u +%H:%M:%S)\"; "
    "echo '== memguard (last 60 lines, no adj/snapshot)'; grep -vE ' adj [0-9]+ | snapshot ' /usr/data/nebulaos/logs/memguard.log | tail -n 60; "
    "echo '== memguard state'; cat /run/nebulaos/memguard/state 2>/dev/null; ls /run/nebulaos/shed 2>/dev/null; "
    "echo '== dmesg tail'; dmesg | tail -n 60 | cut -c1-200; "
    "echo '== wifi'; iw dev wlan0 link 2>/dev/null; iw dev wlan0 station dump 2>/dev/null | grep -E 'tx (retries|failed)|rx drop|signal|beacon loss|tx bitrate'; "
    "cat /proc/net/dev | grep wlan0; grep -E 'wlan|brcm|sdio|mmc1' /proc/interrupts; "
    "echo '== camera idle'; cat /var/run/nebulaos-camera-idle-state 2>/dev/null; echo; "
    "echo '== services'; for f in klippy moonraker nebulascreen guppyscreen ustreamer nebulaos-camera-idle-controller; do p=$(cat /var/run/$f.pid 2>/dev/null); "
    "echo \"$f pid=$p alive=$([ -n \"$p\" ] && [ -d /proc/$p ] && echo yes || echo no)\"; done; "
    "echo '== swaps'; cat /proc/swaps; grep -E '^(pswpin|pswpout|oom_kill) ' /proc/vmstat; head -3 /proc/meminfo; "
    "echo '== uart'; cat '/proc/tty/driver/INGENIC serial' 2>/dev/null | sed -n '2p'; "
    "echo '== klippy'; grep -oE 'bytes_(retransmit|invalid)=[0-9]+' " + KLIPPY_LOG + " | tail -2; grep -cE 'Timer too close|MCU .* shutdown|Lost communication' " + KLIPPY_LOG + "; "
    "wget -q -T 3 -O - http://127.0.0.1:7125/server/info | grep -o '\"klippy_state\": *\"[a-z]*\"'",
    False, None, 120)
# S50webcam supervisor and memguard camera shed, read only.
CAPTURE_PROFILES["pf-webcam-sup"] = (
    "for f in /var/run/webcam*.pid /var/run/ustreamer.pid /var/run/S50webcam*.pid; do [ -f $f ] || continue; p=$(cat $f); "
    "echo \"$f pid=$p alive=$([ -d /proc/$p ] && echo yes || echo no) start_ticks=$(cut -d')' -f2 /proc/$p/stat 2>/dev/null | awk '{print $20}') "
    "cmd=$(tr '\\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-80)\"; done; "
    "echo \"supervisor_pidfile=$(cat /var/run/ustreamer-supervisor.pid 2>/dev/null)\"; "
    "for d in /proc/[0-9]*; do c=$(tr '\\0' ' ' < $d/cmdline 2>/dev/null); case \"$c\" in *'S50webcam __supervise'*|*'idle-controller __run'*) "
    "echo \"proc pid=${d#/proc/} ppid=$(awk '{print $4}' $d/stat 2>/dev/null) start=$(cut -d')' -f2 $d/stat 2>/dev/null | awk '{print $20}') cmd=$c\";; esac; done; "
    "echo '== syslog webcam/shed'; grep -aE 'S50webcam|shed' /var/log/messages 2>/dev/null | tail -20; "
    "echo '== shed dir'; ls -la /run/nebulaos/shed/ 2>&1; echo \"uptime=$(cut -d' ' -f1 /proc/uptime)\"",
    False, None, 60)
# Wi-Fi loss over time: 16 windows of 30 s (150 pings at 0.2 s) to the gateway,
# each stamped with uptime, memguard state and the camera shed marker.
CAPTURE_PROFILES["pf-ping-windows"] = (
    "G=$(ip route | awk '/^default/{print $3; exit}'); echo \"gateway=$G\"; "
    "for w in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do t0=$(cut -d' ' -f1 /proc/uptime); "
    "r=$(ping -q -c 150 -i 0.2 -W 1 $G 2>&1 | grep -oE '[0-9]+ packets received|[0-9.]+% packet loss|= [0-9./]+ ms' | tr '\\n' ' '); "
    "echo \"W$w t0=$t0 mg=$(cat /run/nebulaos/memguard/state 2>/dev/null) shed=$(ls /run/nebulaos/shed 2>/dev/null | tr '\\n' ,) "
    "load=$(cut -d' ' -f1 /proc/loadavg) cpu_psi=$(sed -n 's/^some avg10=\\([0-9.]*\\).*/\\1/p' /proc/pressure/cpu) "
    "ma=$(awk '/MemAvailable/{print $2}' /proc/meminfo) $r\"; done",
    False, None, 700)
CAPTURE_PROFILES["pf-ng1"] = (
    "U=http://127.0.0.1:7125; L=/opt/printer_data/logs/moonraker.log; "
    "for q in 'namespace=mainsail&key=macros.macrogroups.nebulaos_calibration' "
    "'namespace=mainsail&key=nebulaos_prefinal_absent_key' 'namespace=nebulaos_prefinal_absent_ns&key=x'; do "
    "echo \"GET $q -> $(curl -s -o $T/b -m 30 -w 'http=%{http_code} seconds=%{time_total}' \"$U/server/database/item?$q\") body=$(head -c 140 $T/b 2>/dev/null)\"; done; "
    "echo \"GET /no/such/endpoint -> $(curl -s -o /dev/null -m 30 -w 'http=%{http_code} seconds=%{time_total}' $U/no/such/endpoint)\"; "
    "echo \"GET /server/files/metadata?filename=nebulaos-absent.gcode -> $(curl -s -o /dev/null -m 30 -w 'http=%{http_code} seconds=%{time_total}' \"$U/server/files/metadata?filename=nebulaos-absent.gcode\")\"; "
    "for e in /server/info /printer/info '/server/database/list' '/printer/objects/query?webhooks&print_stats'; do "
    "echo \"GET $e -> $(curl -s -o /dev/null -m 10 -w 'http=%{http_code} seconds=%{time_total}' \"$U$e\")\"; done; "
    "MP=$(tr '\\0' '\\n' < /proc/$(cat /var/run/moonraker.pid)/cmdline | head -1); "
    "echo \"moonraker_python=$MP tornado=$($MP -c 'import tornado, tornado.httputil as h; print(tornado.version, tornado.__file__, h._ABNF.reason_phrase.pattern)' 2>&1 | tail -1)\"; "
    "echo \"moonraker_log_ABNF_errors=$(grep -c \"has no attribute '_ABNF'\" $L) send_error_tracebacks=$(grep -c 'in send_error' $L)\"; "
    "echo '== seed log, last run'; S=/usr/data/nebulaos/maintenance/logs/mainsail-macros-seed.log; "
    "awk '/attempt 1\\//{buf=\"\"} {buf=buf $0 \"\\n\"} END{printf \"%s\", buf}' $S | tail -n 25 | cut -c1-300; "
    "echo \"timed_out_lines_total=$(grep -c 'timed out' $S)\"; "
    "echo '== marker'; cat /usr/data/nebulaos/system/default-mainsail-macros-seeded.json",
    False, None, 200)

# --- Final blockers (2026-10-07) -------------------------------------------------
EXERCISE_PROFILES["fb-ng3-handoff"] = (
    _IDLE_GUARD + "KS=1; . $T/fb_ng3.sh",
    "[ -n \"${H:-}\" ] && kill $H 2>/dev/null; " + _KLIPPY_RESTORE.replace(_QM, "python3 $T/lv_m1.py"),
    2400)
EXERCISE_PROFILES["fb-camera-10"] = (
    _IDLE_GUARD + ". $T/fb_cam10.sh",
    "[ -n \"${V:-}\" ] && kill $V 2>/dev/null; p=$(cat /var/run/nebulaos-camera-idle-controller.pid 2>/dev/null); "
    "[ -n \"$p\" ] && [ -d /proc/$p ] || /etc/init.d/S51nebulaos-camera-idle-controller start > /dev/null 2>&1; "
    "echo \"undo: controller_pid=$(cat /var/run/nebulaos-camera-idle-controller.pid 2>/dev/null)\"",
    2400)

# --- GUI/service readiness (2026-10-09) -----------------------------------------
# Read only: [nebulaos] component, network/hostname/mDNS, SFTP, sudo adapter
# refusals, PLR status, boot display, backlight. See tools/hwcap/gs_services.sh.
CAPTURE_PROFILES["gs-services"] = (". $T/gs_services.sh", False, "gs_services.sh", 240)
# Wi-Fi diagnosis (Q3), read only, keys redacted. See tools/hwcap/gs_wifi.sh.
CAPTURE_PROFILES["gs-wifi"] = (". $T/gs_wifi.sh", False, "gs_wifi.sh", 120)
# Self-undoing backlight brightness exercise through nebulaos-osconfig (the GUI
# path, standard backlight device). The undo runs only once gs_display.sh has
# recorded the starting state: the original sysfs brightness and the original
# display files (or none).
EXERCISE_PROFILES["gs-display-brightness"] = (
    _IDLE_GUARD + ". $T/gs_display.sh",
    "if [ \"${GS_STARTED:-0}\" = 1 ]; then "
    "printf '%s' \"$B0\" > $B/brightness; "
    "if [ \"$HAD_J\" = 1 ]; then cp $T/display.json $DD/display.json; else rm -f $DD/display.json; fi; "
    "if [ \"$HAD_E\" = 1 ]; then cp $T/display.env $DD/display.env; else rm -f $DD/display.env; fi; "
    "echo \"undo: $(bl) files: $(ls $DD 2>/dev/null | tr '\\n' ' ')\"; fi",
    300)

# Why S04/S05's venv validation stamp misses on a normal boot (the 4.6 s
# S04nebulaos-factory-seed seen on every boot of 3580378): the current key of
# each environment against its stored stamp. Read only; no interpreter start.
CAPTURE_PROFILES["venv-stamp-diff"] = (
    "log(){ :; }; . /usr/libexec/nebulaos-venv-lib.sh; "
    "MS='import tornado, numpy, streaming_form_data.targets'; KSM='import greenlet, cffi, jinja2, serial, can'; "
    "echo \"uptime=$(cut -d' ' -f1 /proc/uptime) marker=$([ -e \"$VENV_REVALIDATE_MARKER\" ] && echo present || echo absent)\"; "
    "ls -la --full-time $VENV_VALIDATION_DIR 2>&1; "
    "for e in moonraker:MS klipper:KSM; do n=${e%%:*}; v=${e#*:}; eval sm=\\$$v; "
    "d=/usr/data/nebulaos/envs/$n; st=$(_venv_stamp_path $d); "
    "venv_validation_key $d \"$sm\" > $T/$n.now; "
    "echo \"== $n stamp=$st\"; if [ -f \"$st\" ]; then diff $st $T/$n.now && echo SAME; else echo NO_STAMP; cat $T/$n.now; fi; "
    "for sp in $d/lib/python*/site-packages; do ls -lna --full-time $sp | head -4; ls -lnad --full-time $sp/__pycache__ 2>/dev/null; done; done",
    False, None, 120)

# Human-observed backlight exercise (T4): levels 25-100 % then sleep, woken by a
# touch through the NebulaOS watcher. Undo wakes it if still off and restores
# the recorded brightness and display files.
EXERCISE_PROFILES["gs-display-sleep"] = (
    _IDLE_GUARD + ". $T/gs_sleep.sh",
    "if [ \"${GS_STARTED:-0}\" = 1 ]; then "
    "[ \"$(cat $B/bl_power)\" = 0 ] || $O display wake > /dev/null 2>&1; "
    "printf '%s' \"$B0\" > $B/brightness; "
    "if [ \"$HAD_J\" = 1 ]; then cp $T/display.json $DD/display.json; else rm -f $DD/display.json; fi; "
    "if [ \"$HAD_E\" = 1 ]; then cp $T/display.env $DD/display.env; else rm -f $DD/display.env; fi; "
    "echo \"undo: $(bl) files: $(ls $DD 2>/dev/null | tr '\\n' ' ')\"; fi",
    300)
# Boot screen mode (T3/T5): a persistent user setting that only takes effect on
# the next boot, so deliberately no undo - the session ends with the logo one.
for _mode in ("blank", "console", "logo"):
    EXERCISE_PROFILES["gs-boot-mode-" + _mode] = (
        _IDLE_GUARD + "MODE=" + _mode + "; . $T/gs_bootmode.sh", ":", 60)

# Recovery for the console-mode deadlock (T5/D10, 2026-10-10): with fbcon
# owning the display, a render job hangs in fb_open holding the boot-display
# lock, so nebulaos-osconfig set-mode waits forever. This writes the persisted
# mode back to logo directly (same two files, atomically) without that lock.
EXERCISE_PROFILES["gs-boot-mode-logo-direct"] = (
    "D=/usr/data/nebulaos/boot; echo \"before: $(cat $D/display.env 2>/dev/null)\"; "
    "printf 'MODE=\"logo\"\\n' > $D/display.env.tmp && mv -f $D/display.env.tmp $D/display.env; "
    "printf '{\"image\": \"builtin\", \"mode\": \"logo\", \"schema\": 1}\\n' > $D/display.json.tmp "
    "&& mv -f $D/display.json.tmp $D/display.json; sync; "
    "echo \"after: $(cat $D/display.env) $(cat $D/display.json)\"",
    ":", 60)

# Exercises that embed a tracked hwcap probe, the same way captures do.
EXERCISE_PROBES = {"ktimers-ab": ("timerlat.py",), "ttyflip-ab": ("ptyrtt.py",),
                   "uart-fe-probe": ("qualmcu.py",), "mcu-link-bench": ("qualmcu.py",),
                   "mcu-identify-repeat": ("qualmcu.py",), "live-m1-identify": ("lv_m1.py",),
                   "live-s1-s03": ("lv_s1.sh",), "live-s2-s97": ("lv_s2.sh",), "live-g5-debugfs": ("lv_g5.sh",),
                   "live-s3-s4-camera": ("lv_cam.sh",), "live-g6-dhcp": ("lv_g6.sh",), "live-g7-klippy": ("lv_g7.sh",),
                   "live-g8-seeder": ("lv_g8.sh",), "live-g9-ext4": ("lv_g9.sh",), "live-g10-diskswap": ("lv_g10.sh",), "live-ng1-tornado": ("lv_ng1.py",), "pf-camera": ("pf_cam.sh",), "fb-ng3-handoff": ("lv_m1.py", "fb_ng3.sh"), "fb-camera-10": ("fb_cam10.sh",),
                   "gs-display-brightness": ("gs_display.sh",),
                   "gs-display-sleep": ("gs_sleep.sh",),
                   "gs-boot-mode-blank": ("gs_bootmode.sh",),
                   "gs-boot-mode-console": ("gs_bootmode.sh",),
                   "gs-boot-mode-logo": ("gs_bootmode.sh",)}


def exercise_script(name):
    """-> (shell text, timeout) for one exercise NAME. Raises CaptureError."""
    if name not in EXERCISE_PROFILES:
        raise CaptureError("unknown exercise profile %r" % name)
    body, undo, timeout = EXERCISE_PROFILES[name]
    for word in EXERCISE_REFUSED:
        if word in body or word in undo:
            raise CaptureError("exercise %s contains refused text %r" % (name, word))
    s = ("T=/tmp/nebulaos-capture.$$; rm -rf \"$T\"; mkdir -p \"$T\" || exit 4; "
         "nebulaos_undo(){ trap - EXIT INT TERM; %s; rm -rf \"$T\"; }; "
         "trap nebulaos_undo EXIT; trap 'exit 130' INT TERM; "
         "printf 'EXERCISE_PROFILE=%s\\nSTART_UTC=%%s\\n' \"$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)\"; "
         % (undo, name))
    for probe in EXERCISE_PROBES.get(name, ()):
        s += "cat > \"$T/%s\" <<'NEBULAOS_PROBE_EOF'\n%s\nNEBULAOS_PROBE_EOF\n" % (probe, _probe_source(probe))
    s += "%s; printf '\\nEND_UTC=%%s\\n' \"$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)\"" % body
    if len(s) > SCRIPT_LIMIT:
        raise CaptureError("exercise %s is %d bytes, over the %d-byte command limit" % (name, len(s), SCRIPT_LIMIT))
    return s, timeout
