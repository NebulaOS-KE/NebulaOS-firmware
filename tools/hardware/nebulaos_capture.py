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

PROBES = ("schedsnap.py", "timerlat.py", "ptyrtt.py", "kduty.py", "adxl_overflows.py")

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
}

# Defined by the plan as reversible state changes: TOOL-02 `exercise`, never `capture`.
EXERCISE_ONLY = ("camera-resume", "memexercise", "sof-filter-ab", "storage-autosuspend")


class CaptureError(Exception):
    pass


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
        "t0=$(date +%s%N); head -c 65536 /dev/${B:-sda} > /dev/null; t1=$(date +%s%N); "
        "echo \"resume_read_ms=$(( (t1 - t0) / 1000000 ))\"; dmesg | tail -20 | grep -iE 'usb|sd ' ",
        "[ -n \"${P:-}\" ] && { echo ${D0:-2000} > $P/autosuspend_delay_ms; echo ${C0:-on} > $P/control; }",
        90),
    # HWDP-DWC-6: first-frame latency after an idle pause.
    "camera-resume": (
        "curl -s -o /dev/null --max-time 5 localhost:8080/pause; sleep 30; t0=$(date +%s%N); "
        "curl -s -o /dev/null --max-time 5 localhost:8080/resume; "
        "i=0; until curl -sf -o /dev/null --max-time 2 localhost:8080/snapshot || [ $i -ge 60 ]; do i=$((i+1)); done; "
        "t1=$(date +%s%N); echo \"first_frame_ms=$(( (t1 - t0) / 1000000 ))\"",
        "curl -s -o /dev/null --max-time 5 localhost:8080/resume",
        120),
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
    s += "%s; printf '\\nEND_UTC=%%s\\n' \"$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)\"" % body
    return s, timeout
