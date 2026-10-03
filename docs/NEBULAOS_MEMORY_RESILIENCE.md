# NebulaOS Memory Resilience

**Status:** In progress — Memory Resilience Gate sub-mission, required before Phase 7 (mutable application installs) resumes.

---

## 1. Checkpoint (recorded before any kernel change)

- **Firmware repo HEAD:** `58a0ba5cdab669138c5c76ffade84139ed146398` (branch `master`, clean except the pre-existing documented untracked `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md`).
- **NebulaOS Klipper fork:** `coreflake1/NebulaOS-klipper`, branch `nebulaos`, commit `b3d5ab2b9484f1558586c3a2ea43d46ff9a473a7` (ancestry: `pellcorp/klipper@386fde4` + one commit, the klippy_extras addition). Local `vendor/klipper` checkout clean except a compiled `.so` build byproduct (not tracked).
- **Running device (192.168.0.146):** kernel `6.6.18-rt23`, OTA marker `ota:kernel2` (custom slot active), `klippy_state: ready`, `klippy_connected: true`.
- **Namespace state:** `/usr/data/nebulaos/apps/{klipper,moonraker,mainsail}` all present and empty (the earlier stuck `.partial` directories were cleaned up); `activation-state.json` shows `klipper`/`moonraker`/`mainsail` = `immutable:incomplete_or_invalid`, `printer_data`/`shared_gcode` = `persistent`. This exact state is the baseline the memory-resilience work must not regress.
- **OOM evidence (from `dmesg`, captured before this sub-mission began):**
  ```
  oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),task=git,pid=3277,uid=0
  Out of memory: Killed process 3277 (git) total-vm:56472kB, anon-rss:37480kB, file-rss:0kB, shmem-rss:9728kB, UID:0 pgtables:76kB oom_score_adj:0
  oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),task=git,pid=3477,uid=0
  Out of memory: Killed process 3477 (git) total-vm:55516kB, anon-rss:36540kB, file-rss:128kB, shmem-rss:9728kB, UID:0 pgtables:68kB oom_score_adj:0
  ```
  First event (pid 3277) occurred during the real boot's own `S03nebulaos-factory-seed` run; second (pid 3477) during a manual reproduction of the same `git clone` command afterward, run interactively for diagnosis (not part of any production path).
- **Root cause confirmed:** `swapon /usr/data/swap` → `Function not implemented`; `/proc/swaps` does not exist at all — `CONFIG_SWAP` is not compiled into this kernel. Stock's own pre-existing 128MB swap file at `/usr/data/swap` (same shared partition) is present but inert for this reason.
- **Total RAM:** 208MB (`free -m`), no swap.

Frozen functionality reconfirmed intact at this checkpoint: webcam (real snapshot captured), USB (`sda` mounted under `/opt/printer_data/gcodes/USB`), printer safety (standby, unhomed), `S99confirm-good`/OTA marker behavior.

## 2. Kernel Kconfig investigation (confirmed against real kernel source, not guessed)

Checked directly against `vendor/x2000_kernel_6.6/kernel/kernel-6.6`:

| Symbol | Location | Type/dependencies | Prior state |
|---|---|---|---|
| `CONFIG_SWAP` | `mm/Kconfig:15` | `menuconfig SWAP ... depends on MMU && BLOCK && !ARCH_NO_SWAP` | `# CONFIG_SWAP is not set`. `CONFIG_MMU=y` and `CONFIG_BLOCK=y` already satisfied; `ARCH_NO_SWAP` not defined for this arch (so `!ARCH_NO_SWAP` is true) |
| `CONFIG_ZRAM` | `drivers/block/zram/Kconfig` | `tristate ... depends on BLOCK && SYSFS && MMU`, `depends on CRYPTO_LZO \|\| CRYPTO_ZSTD \|\| CRYPTO_LZ4 \|\| CRYPTO_LZ4HC \|\| CRYPTO_842`, `select ZSMALLOC` | `# CONFIG_ZRAM is not set` |
| `CONFIG_CRYPTO_LZ4` | `crypto/Kconfig:1197` | `tristate ... select CRYPTO_ALGAPI/CRYPTO_ACOMP2/LZ4_COMPRESS/LZ4_DECOMPRESS` (all pure C, no MIPS-specific assembly to verify) | `# CONFIG_CRYPTO_LZ4 is not set`. `CONFIG_CRYPTO_LZO=y` was already enabled (used elsewhere), confirming a working fallback compressor choice already exists if LZ4 is ever found unsuitable |
| `CONFIG_ZSMALLOC` | `mm/Kconfig:190` | `tristate ... depends on MMU` (auto-`select`ed by `ZRAM`) | not set, no extra dependency beyond already-satisfied `MMU` |
| `CONFIG_IKCONFIG`/`CONFIG_IKCONFIG_PROC` | standard kernel option | live `/proc/config.gz` inspection | not set |

**Where the fix actually lives**: `artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config` — confirmed via `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES` in `buildroot.config` that this fragment file (not the `kernel.config` snapshot in the same artifacts directory, which `05-final-build.sh` only ever *copies from* the real built `.config` as a post-build record) is the actual input Buildroot merges onto the kernel's base defconfig. Added: `CONFIG_SWAP=y`, `CONFIG_ZRAM=y` (built directly into the kernel, not `=m` — no dependency on module-loading infrastructure at the very early boot point `S00zram-swap` needs to run), `CONFIG_CRYPTO_LZ4=y`, `CONFIG_ZRAM_DEF_COMP_LZ4=y`, `CONFIG_IKCONFIG=y`, `CONFIG_IKCONFIG_PROC=y`.

**BusyBox userspace tools already present, confirmed live — not assumed**: `swapon: unrecognized option '--show'` (from the earlier live diagnosis) already proved the `swapon` applet itself works and is compiled in; a direct check of `vendor/buildroot-x2000/package/busybox/busybox.config` confirms `CONFIG_MKSWAP=y`, `CONFIG_SWAPON=y`, `CONFIG_SWAPOFF=y`, `CONFIG_FREE=y` were already all enabled by default in this project's Buildroot BusyBox config — the original failure (`Function not implemented`) was conclusively the kernel's missing `CONFIG_SWAP`, not a missing userspace tool. Confirmed exact installed paths live: `/sbin/mkswap`, `/sbin/swapon`, `/sbin/swapoff` (all BusyBox multi-call symlinks), `/usr/bin/free`.

## 3. Implementation

### 3.1 Primary layer: zram (`S00zram-swap`)

New init script, numbered to run immediately after `S00revert-safety` and before `S01persistent-datastore` (no dependency on `/usr/data` being mounted at all — zram is pure RAM). Idempotent (checks `/proc/swaps` and `disksize` before acting), never blocks boot on failure (falls through with a logged warning if `/dev/zram0`/sysfs isn't present, or if any step fails). Starting qualification parameters: **128MiB logical size, LZ4 compressor, priority 100**. Caps zram's real (compressed) footprint with `mem_limit` = 20% of MemTotal and logs an error (plus `/run/nebulaos/zram-alg-mismatch`) if the active algorithm is not lz4 (MEM-T11). The sysctls moved to `/etc/sysctl.d/90-nebulaos-memory.conf`, applied by Buildroot's `S02sysctl`: `vm.swappiness=60` (with zram as the primary tier, compressing cold anonymous pages is cheaper than evicting file pages that must be re-read from eMMC; the earlier value 10 pushed reclaim onto file pages) and `vm.page-cluster=0` (no disk-seek-oriented multi-page swap readahead).

### 3.2 Fallback layer: NebulaOS-owned disk swap (`S03nebulaos-diskswap`)

New init script, runs after `S02nebulaos-namespace` (needs `/usr/data/nebulaos` to exist) and before `S04nebulaos-factory-seed` (the memory-heavy step being protected). Owns `/usr/data/nebulaos/system/swapfile` — **not** the stock swap file at `/usr/data/swap` (present but deliberately unused, per this mission's own direction not to depend on a stock-owned resource; its location/128MB size is recorded here for comparison only, not reuse). Starting qualification parameters: **128MiB, priority 10** (lower than zram's 100, so zram is always preferred first). Allocated via a bounded `dd if=/dev/zero ... conv=fsync` (never sparse, never `truncate`/`fallocate`, per this mission's explicit preference for deterministic, verifiable allocation on this exact ext4/eMMC setup), `chmod 600`, validated (exact size + `0:0` ownership + `-rw-------` permissions) before ever being trusted as already-valid on a later boot, recreated from scratch if invalid, never truncated once genuinely active (guarded by the `/proc/swaps` idempotency check). Tolerates `/usr/data` being unmounted/read-only by skipping cleanly rather than failing boot.

Both init scripts' logic (ownership checks, ordering, idempotency) follow the same patterns already established and live-tested in `S04nebulaos-namespace`/`S05nebulaos-activate` (BusyBox `ls -ldn`+`awk` for numeric ownership, not `stat`, per that earlier live finding).

### 3.3 OOM priority table (applied at process birth)

The values live in one place, `/etc/nebulaos-oom-policy.sh` (MEM-T07), and each
init script starts its daemon through `nebulaos_start_with_adj`, which writes
the value to a subshell's own `/proc/self/oom_score_adj` and then execs
`start-stop-daemon`, so the daemon and all its children are born with it. The
earlier pattern wrote `/proc/$(cat pidfile)/oom_score_adj` after
`start-stop-daemon -b` returned, which raced the fork and, with a stale pidfile,
could adjust an unrelated process. `stop()` now removes the pidfile.

| Tier | Process | `oom_score_adj` | Reasoning |
|---|---|---|---|
| Never a victim | host MCU `klipper_mcu` (`S54nebulaos-host-mcu`) | **-1000** | a few MiB, mlocked, printer-critical timing |
| Most protected (killable) | Klipper (`S55klipper`), `nebulaos-memguard` | **-900** | MCU/motion-control communication; not -1000, so the kernel always retains a sensible victim if memory is truly exhausted |
| Moderately protected | Moonraker (`S56moonraker`) | **-400** | coordinates updates/rollback, must outlive GuppyScreen/webcam/update-helpers under pressure, but is less critical than Klipper itself |
| Normal/expendable | GuppyScreen (`S58guppyscreen`) | **0** | explicit kernel-default value, so the full table is auditable in one place |
| More expendable | webcam/ustreamer (`S50webcam`) | **300** | optional media, never printer-critical |
| Most expendable | update supervisor (`S59`), factory-seed/update helpers (`S04nebulaos-factory-seed`) | **500** | real git processes were the ones OOM-killed in the original incident; this makes that outcome intentional |

nginx, dropbear and wpa_supplicant use Buildroot-owned init scripts; their
values are enforced by `nebulaos-memguard`'s periodic adj scan (MEM-T12).

### 3.4 Maintenance safety gate

`S04nebulaos-factory-seed`'s `maintenance_gate_ok()` (read-only checks only) blocks heavy seeding when: a print is active or paused (`/printer/objects/query?print_stats`, matching this project's own established live-JSON-format discipline — Moonraker's real output has no space after `:`); an update-transaction lock directory (`updates/locks`) is non-empty; or — the gate directly closing the original incident — **no memory-resilience swap is active at all** (neither `/dev/zram0` nor the NebulaOS disk swap file appear in `/proc/swaps`). A blocked run simply skips and logs, retrying on the next boot; it never partially proceeds.

### 3.5 Expendable-service pausing

`S04nebulaos-factory-seed` stops `S58guppyscreen`/`S50webcam` before seeding and restarts them after (success or failure path both reach `resume_expendable_services`). On a normal first boot this is a genuine no-op (`S04` runs at init position 4, well before `S50`/`S58` have ever started) — kept anyway for a later re-invocation (namespace-recovery-after-normal-boot, or Phase 7 reusing this same seeding pattern), per this mission's own explicit instruction not to treat "stopping services alone" as sufficient, but still wanting the extra margin when it *is* meaningful.

### 3.6 Serialization

`start()` seeds Klipper, then Moonraker, then Mainsail strictly in sequence (never concurrently), with `sync` after each git operation and once more at the end — matching this mission's own required "prepare → verify → release → next component" shape given this project's synchronous (non-backgrounded) init-script execution model.

### 3.7 Low-memory git behavior

`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_N`/`GIT_CONFIG_VALUE_N` (a documented git ≥2.31 mechanism, confirmed available — device git is 2.42.1) set for every `git clone` in `S04nebulaos-factory-seed`: `pack.threads=1` (single-threaded delta/pack work — directly reduces index-pack's peak RSS, the exact operation that was OOM-killed), `core.packedGitWindowSize=1m`, `core.deltaBaseCacheLimit=8m` (both bound how much of the pack this process maps/caches at once), `gc.auto=0` (no incidental background gc competing for memory immediately after a clone). Not yet measured against the alternative the mission also raises (a prepared archive with `.git` metadata instead of invoking `git clone` at all) — deferred pending the live re-test in Section 5, since the combination of swap + these settings may already resolve the original failure without needing a different seed format.

## 4. Static verification (`06-verify.sh` extended)

Added `check_builtin CONFIG_SWAP`/`CONFIG_ZRAM`/`CONFIG_CRYPTO_LZ4` (checked against the real built kernel `.config`, the same mechanism already used for other built-in-driver assertions — catches this exact class of regression, which a rootfs-file-only check could never see) and `check` calls for `/sbin/{mkswap,swapon,swapoff}`, `/usr/bin/free`, both new init scripts, and the seed bundles/manifest.

## 5. Live qualification (first pass — real bug found and fixed)

Flashed and booted the first memory-resilience build (following the same strict safety discipline as every prior flash — every safety query and state-changing command issued as separate SSH invocations). Results:

- **No OOM events** in `dmesg` this boot — a real improvement, though (see below) not yet for the intended reason.
- `zram0` correctly configured: `disksize=134217728` (128MiB), `comp_algorithm` shows `lzo lzo-rle [lz4]` (LZ4 correctly selected as active).
- **But `/proc/swaps` was completely empty** — zram was configured but never actually activated as swap.
- Direct on-device diagnosis (read-only/reversible commands only): `mkswap /dev/zram0` succeeded; `swapon -p 100 /dev/zram0` failed with `swapon: invalid option -- 'p'`. BusyBox's `swapon --help` confirmed only `[-a] [-e] [DEVICE]` — no `-p` at all.
- Tested the documented BusyBox fallback live (via a temporary `mount --bind` over `/etc/fstab`, cleanly reverted after — `/etc/fstab` itself is on the read-only squashfs, confirmed by a failed `echo >> /etc/fstab: Read-only file system`): an `fstab` entry with `pri=100` plus `swapon -a` **did** bring `/dev/zram0` up as swap, but `/proc/swaps` showed priority `-2`, not `100` — the requested priority was silently ignored.
- Root cause, confirmed directly against the real BusyBox source this build already produced (`vendor/buildroot-x2000/output/build/busybox-1.36.1/util-linux/swaponoff.c`), not guessed: `CONFIG_FEATURE_SWAPON_PRI` gates the `-p` CLI option specifically (`IF_FEATURE_SWAPON_PRI(" [-p PRI]")` in the usage string, `OPTBIT_p` conditionally compiled). This project's `busybox.config` had it unset. Both the `-p` flag and (per this same source) `fstab`'s `pri=` parsing are gated by the identical flag — so the fstab route would never have worked either without this fix.
- **Fix**: new `halley5-nebulaos-busybox-fragment.config` (mirroring the existing kernel-fragment pattern, wired through `BR2_PACKAGE_BUSYBOX_CONFIG_FRAGMENT_FILES` which was already present in `buildroot.config` but empty) setting `CONFIG_FEATURE_SWAPON_PRI=y`. Also added `make busybox-dirclean` to `02-configure-buildroot.sh`'s own normalization step — the exact same stale-package-stamp class of bug as the earlier `libopenssl` fix (§3.9 of the architecture doc), caught proactively this time rather than requiring a second live-boot failure to discover it.
- No change needed to `S00zram-swap`/`S03nebulaos-diskswap` themselves — they already used `swapon -p`, which will work correctly once this BusyBox feature is compiled in.

## 6. Live qualification — final pass: full success, two more real bugs found and fixed

After the swapon-priority fix (§5), a second live boot revealed **swap correctly active with zero OOM events**, but seeding was still stuck at `.partial` for all three components — proving the earlier "stuck partial" symptom was never actually about memory at all, even though it first surfaced during the original OOM incident.

**Bug 2 — `mv` into an existing directory.** `$dest` (e.g. `apps/klipper`) already exists as an empty directory (created by `S02nebulaos-namespace`'s own `mkdir -p`) by the time `seed_git_app`/`seed_mainsail` reach their final `mv "$dest.partial" "$dest"`. POSIX `mv srcdir destdir` when `destdir` already exists moves `srcdir` *inside* it rather than replacing it — confirmed with an isolated local reproduction before touching the fix. First attempted a plain `rmdir "$dest"` (only-if-empty) immediately before the `mv` — verified correct in isolation, but a real boot *still* produced the identical nesting, meaning `$dest` was not always genuinely empty at that point (most likely leftover debris from an earlier attempt the same boot; not fully root-caused, and no longer relevant once fixed more robustly). Switched to `rm -rf "$dest"` — safe unconditionally, since the function's own `-e "$dest/.git"` check earlier already proved `$dest` holds no valid seeded checkout, so discarding whatever it contains (empty or debris) before the `mv` is always correct.

Verified directly on the device before committing to another rebuild: copied the fixed script to `/tmp`, ran it standalone — all three components seeded cleanly with no nesting, `known-good.json` recorded, expendable services correctly paused/resumed, and a second invocation correctly no-op'd (`all components already seeded - nothing to do`).

**Bug 3 — `known-good.json`'s write-once guard.** After the `rm -rf` fix was rebuilt, reflashed, and boot-tested end-to-end from a genuinely reset (unseeded) namespace state, `known-good.json` still showed `"commit": "unseeded"` for both components despite the real checkouts being fully, correctly seeded. The guard (`[ -e "$kg" ] && return 0`) meant an earlier, premature write from the same boot's own history (exact mechanism not conclusively identified) could never be corrected once seeding actually finished afterward. Fixed to only skip recording if the existing file already reflects real committed versions, not merely any prior file — self-correcting rather than permanently wrong. Manually corrected the live device's file with the real commit hashes as an immediate fix; the source fix is committed for future builds.

### Final, authoritative end-to-end result (fresh-boot test, namespace reset to genuinely unseeded beforehand)

```
OTA marker:        ota:kernel2 (S99confirm-good validated this boot)
/proc/swaps:       /dev/zram0                          131068  0  100
                   /usr/data/nebulaos/system/swapfile   131068  0   10
free -m Swap:      256 total, 0 used, 256 free
dmesg OOM events:  zero
apps/klipper:      real seeded checkout, .git present, HEAD d7c3b338...
apps/moonraker:    real seeded checkout, .git present, HEAD c5a2acfa...
apps/mainsail:     real seeded release, index.html present
.partial debris:   none anywhere
known-good.json:   correct, real commits recorded
activation-state:  klipper=persistent, moonraker=persistent, mainsail=persistent,
                   printer_data=persistent, shared_gcode=persistent
klippy_state:      ready, klippy_connected: true (running from the MUTABLE checkout)
USB:               still auto-mounted (sda visible under gcodes/USB)
```

**The Memory Resilience Gate is complete.** Every acceptance item from the governing mission brief is met: kernel swap support enabled and proven; zram active as the high-priority primary layer; the NebulaOS-owned disk swap file active as the lower-priority fallback (not the stock file); zero OOM events during the exact workload that originally failed; the activation manager correctly activated all three previously-immutable apps once they became genuinely valid. Three real, independent bugs were found and fixed by testing directly against the device rather than trusting any single build or boot: the BusyBox `swapon` priority feature flag, the `mv`-into-existing-directory seeding bug, and the `known-good.json` write-once guard — none of which were the original memory/OOM problem, but all of which were blocking its full resolution from being observable.

## 7. Live HTTPS qualification (Phase 7 gate) — two more real bugs found and fixed, one permanent limitation documented

Attempting to prove live HTTPS ahead of Phase 7 (per the mission's own required commands) found two further real, permanent (not just early-boot-transient) gaps:

- **No NTP client existed on this image at all** (`which ntpd chronyd sntp` all empty). The clock was not just briefly wrong at boot (the already-known, already-handled RTC-before-NTP window, `docs/NEBULAOS_RETENTION_POLICY.md` §2.6) — it was **permanently** stuck at its post-reset default (confirmed live: `date -u` read `Sun Mar 1 2020` on a device that had been running for hours). Every TLS handshake to GitHub failed with `certificate is not yet valid` as a direct consequence, on every boot, forever, not just for the first minute.
- **BusyBox's `wget` had no HTTPS support compiled in at all** (`wget --help` showed only "HTTP or FTP"; a real `https://` URL was rejected outright with `not an http or ftp url`) — a separate gap that would have blocked `wget --spider https://github.com/` even with a correct clock.

**Fixes**: enabled `CONFIG_NTPD` and `CONFIG_FEATURE_WGET_HTTPS` in the busybox fragment; added `S40nebulaos-ntpsync` (backgrounded, one-shot `ntpd -n -q`, tries `pool.ntp.org`/`time.google.com`/`time.cloudflare.com` in order, after `S39wifi`, fails silently rather than blocking boot if none are reachable).

**Rebuilt, reflashed, and proven live** (same strict safety discipline as every prior flash):
```
date -u:                                    Sun Jul 26 20:57:45 UTC 2026  (correct - was permanently stuck at 2020 before)
git ls-remote .../NebulaOS-klipper.git HEAD: 386fde4fd38e8eda6999e58bf260eceb00051188  (real, correct commit)
curl --fail --location --head https://api.github.com/:  HTTP/1.1 200 OK (full real GitHub response headers)
curl backend:                               libcurl/8.5.0 OpenSSL/3.1.4 (real TLS, not a stub)
wget --spider https://github.com/:          "remote file exists"
python3 urllib.request.urlopen(...):        status 200
```

**Real, important finding requiring a permanent policy, not a bug to fix**: `wget`'s own output for the HTTPS request above included the line `wget: note: TLS certificate validation not implemented` — confirmed this is not a flag or a misconfiguration but a hard limitation of BusyBox's minimal internal TLS stack (the feature this project just enabled, `CONFIG_FEATURE_WGET_HTTPS`, exists specifically for basic connectivity use, not security-critical fetching). This means `wget` "succeeding" over HTTPS is **functionally equivalent to always running with certificate verification disabled** — exactly the outcome the mission's own rules explicitly forbid achieving via `wget --no-check-certificate`, except here it happens unconditionally with no flag involved at all.

**Positive and negative proof that `curl`/`git`/`python3` are genuinely trustworthy, unlike `wget`**: `curl` was tested against `https://wrong.host.badssl.com/` (a public certificate-mismatch test endpoint) and correctly **failed** with `SSL: no alternative certificate subject name matches target host name` — proving its validation is real and active, not merely that the earlier success was a fluke of an unreachable negative case.

**Policy going forward**: `curl` and `git` (both linked against the real system OpenSSL, both proven with positive and negative controls) are the only tools this project should use for any HTTPS fetch where content authenticity matters (cloning/fetching real repositories, checking release archives, anything Phase 7/10's update logic does over the network). `wget` remains fine for its existing uses in this project (plain HTTP - local Moonraker API calls, webcam snapshot fetches - all on the trusted local loopback/LAN) but must never be relied upon for HTTPS where the content's authenticity matters, since it cannot actually verify who it's talking to.

Live HTTPS qualification: **passed**, with this documented, permanent caveat rather than a false "all green."

Ready to resume Phase 7 (mutable Klipper/Moonraker/Mainsail installs, writable Moonraker environment) on top of this now-proven foundation.

## 8. Phase 7 writable Moonraker environment — proven live, one more real bug found and fixed

`setup_moonraker_env()` in `S04nebulaos-factory-seed` creates `/usr/data/nebulaos/envs/moonraker` via `python3 -m venv --system-site-packages` (all of Moonraker's real dependencies, per `vendor/moonraker/scripts/moonraker-requirements.txt`, are already importable through Buildroot's own python3 site-packages, so this needs zero new package installs to be immediately functional). `S56moonraker` prefers this venv's `bin/python3` when present, falling back to the system interpreter on a freshly-wiped namespace's first boot before `S04` has run.

**Fresh-boot qualification** (namespace reset to genuinely unseeded beforehand, same as §6): venv created successfully, passed its own `import tornado, numpy, streaming_form_data` smoke test, `S56moonraker` logged `Starting moonraker (using /usr/data/nebulaos/envs/moonraker/bin/python3)`, `ps aux` confirmed the running process's interpreter was the venv's own binary, Klipper/Moonraker both reached `ready`, zero OOM events despite the added ~59s of venv-creation CPU load, no `.partial` debris, `known-good.json` recorded real commits (not `"unseeded"`).

**Real bug found live while reviewing this boot's `moonraker.log`**: Moonraker's `machine.py` network-interface poller calls `ip -json -det address` roughly every 10s to serve its own `/machine/*` API and Mainsail's network status page. BusyBox's `ip` applet supports only `-f[amily]`/`-o[neline]` (confirmed directly against its own usage text — both `-json`/`-j` and `-det`/`-d` just printed the busybox help, never attempted the request) — a structural limitation of the minimal reimplementation, not a missing config flag, same class as the `swapon -p`/`wget`-HTTPS gaps in §5/§7. This produced a `ShellCommandError` traceback in `moonraker.log` every ~10s, indefinitely, on every boot.

**Fix**: enabled the real `BR2_PACKAGE_IPROUTE2` Buildroot package and disabled BusyBox's own `ip` applet (`CONFIG_IP=n` in the busybox fragment). This second half mattered: Buildroot's `busybox.mk` installs via the upstream `install-noclobber` rule (confirmed against `package/busybox/busybox.mk` and busybox's own `applets/install.sh`, which uses `ln -sf`/`-f` for `--symlinks`/`--hardlinks` but is invoked with `install-noclobber` here), meaning whichever of busybox/iproute2 happened to install `/sbin/ip` first during `TARGET_FINALIZE` would silently win — not something to leave to build-order luck. Disabling the applet removes the ambiguity entirely.

**Rebuilt (full Buildroot rebuild required — new package, not just an overlay change), reflashed, and proven live**:
```
/sbin/ip:                     real MIPS ELF (iproute2), not the busybox multi-call symlink
ip -json -det address:        real JSON output (ifindex/ifname/flags/mtu/... for lo, etc.)
moonraker.log:                no further "Error running shell command: 'ip -json -det address'" tracebacks
/proc/swaps:                  zram (pri 100) + disk swapfile (pri 10), both active
dmesg | grep -i oom:          empty
klippy_state:                 ready, klippy_connected: true
moonraker process interpreter: /usr/data/nebulaos/envs/moonraker/bin/python3 (persisted across reboot, no reseed needed)
/usr/data/nebulaos/{apps,envs}: no .partial debris
```

`06-verify.sh` was extended with a static check that `/sbin/ip` exists in the built rootfs and is not the busybox applet symlink (parsed from `debugfs stat`'s `Fast link dest` field), so this cannot silently regress in a future build.
