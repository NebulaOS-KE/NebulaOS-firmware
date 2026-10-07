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
          "lv_m1.py", "lv_s1.sh", "lv_s2.sh", "lv_g5.sh", "lv_cam.sh", "lv_g6.sh", "lv_g7.sh", "lv_g8.sh", "lv_g9.sh", "lv_g10.sh", "lv_ng1.py", "pf_cam.sh")
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
    "echo '== mcu-guard'; cat /run/nebulaos-mcu-guard.state 2>/dev/null; "
    "echo '== camera-idle'; cat /var/run/nebulaos-camera-idle-state 2>/dev/null; echo; "
    "echo '== moonraker'; curl -s --max-time 5 http://127.0.0.1:7125/server/info; echo; "
    "curl -s --max-time 5 'http://127.0.0.1:7125/printer/objects/query?webhooks'; echo; "
    "echo '== wifi'; iw dev wlan0 link 2>/dev/null | head -8; "
    "echo '== klippy-log'; grep -nE 'Start printer at|Starting Klippy|Loaded MCU|Configured MCU|Klipper state|Git version' "
    + KLIPPY_LOG + " 2>/dev/null | tail -30; "
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

# name -> (body, needs_diag, probe or None, timeout seconds)
CAPTURE_PROFILES = {
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
                 "memexercise-sw100")


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
    "p=$(cat /var/run/guppyscreen.pid 2>/dev/null); [ -n \"$p\" ] && [ -d /proc/$p ] && echo GATE_GUPPYSCREEN=ok || echo GATE_GUPPYSCREEN=fail; "
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
        "rm -f " + _LV + "/g7poll.py; for s in moonraker guppyscreen; do p=$(cat /var/run/$s.pid 2>/dev/null); "
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

# Exercises that embed a tracked hwcap probe, the same way captures do.
EXERCISE_PROBES = {"ktimers-ab": ("timerlat.py",), "ttyflip-ab": ("ptyrtt.py",),
                   "uart-fe-probe": ("qualmcu.py",), "mcu-link-bench": ("qualmcu.py",),
                   "mcu-identify-repeat": ("qualmcu.py",), "live-m1-identify": ("lv_m1.py",),
                   "live-s1-s03": ("lv_s1.sh",), "live-s2-s97": ("lv_s2.sh",), "live-g5-debugfs": ("lv_g5.sh",),
                   "live-s3-s4-camera": ("lv_cam.sh",), "live-g6-dhcp": ("lv_g6.sh",), "live-g7-klippy": ("lv_g7.sh",),
                   "live-g8-seeder": ("lv_g8.sh",), "live-g9-ext4": ("lv_g9.sh",), "live-g10-diskswap": ("lv_g10.sh",), "live-ng1-tornado": ("lv_ng1.py",), "pf-camera": ("pf_cam.sh",)}


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
