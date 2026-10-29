# NebulaOS Camera / USB OTG / PREEMPT_RT Source Analysis

**Mission type**: analysis-only, source/read-only. No printer power-on, no live
device commands, no builds, no source modifications, no commits made during
this mission. Report written to `docs/` but **not committed** — hold for
explicit authorization per the mission's own instruction.

**Scope**: the Creality Ender-3 V3 KE + Nebula Pad, NebulaOS's own build only.
All findings below are cited to exact file paths (and line numbers where a
specific line matters); every vendored git tree's exact commit is recorded.
Where source evidence was insufficient to prove a claim, this report says so
explicitly rather than inferring.

---

## 1. Executive conclusion

The measured ~8,000 interrupts/sec is **real, expected, high-speed USB
periodic (isochronous) framing load** (a hardware SOF/microframe interrupt,
125µs period, `1/125µs = 8000`), not userspace polling and not a DWC2 driver
defect — the driver's SOF mask/unmask logic is correctly gated on
`periodic_qh_count` for this board's configuration. It is generated **only**
while the UVC camera has an active `VIDIOC_STREAMON` (i.e., while ustreamer is
actively streaming), not merely because `/dev/video0` is open.

Separately, and independently, NebulaOS's ustreamer fork takes a USB
runtime-PM reference (`usb_autopm_get_interface`) at `open()` time that is
**only released at `close()`**, never at `STREAMOFF`. Because ustreamer never
closes the device once discovered, the UVC interface (and by extension the
hub/root-hub chain above it) can never enter USB autosuspend, regardless of
streaming state. These are two separate, independently-fixable mechanisms:

- Stopping streaming (`STREAMOFF`) → kills the ~8,000/sec SOF load.
- Closing the file descriptor → additionally frees the autosuspend block and
  reclaims mmap'd capture buffers.

NebulaOS's ustreamer fork **already ships an unused, existing feature**
(`--exit-on-no-clients`) that could exit the whole process (thus closing the
fd) after an idle period, and **already exposes local-only HTTP
pause/resume endpoints** that drive a real close()/reopen() cycle internally
— both are currently unused by `S50webcam`'s invocation. A viewer-count-driven
mitigation is achievable with new orchestration glue and, at most, a small
patch to k1-ustreamer — not a from-scratch redesign.

SimpleAF (pellcorp/creality, `k1/` target) and stock/OpenKE both independently
converge on the **same always-open camera model** (continuously-running
capture daemon, no viewer-count gating, no supervised restart in SimpleAF's
case) — this is not something NebulaOS inherited from either; the three are
parallel, independently-built solutions to the same problem using three
different streamer binaries.

PREEMPT_RT is unexpectedly **cheap to enable at the Kconfig level** — this
kernel is a genuine `6.6-rt23`-lineage vendor drop with `CONFIG_PREEMPT_RT`
fully wired and all its dependencies already satisfied — but DWC2's ~8,000/sec
IRQ is the single highest-risk subsystem for an RT experiment, since its IRQ
handler is not marked `IRQF_NO_THREAD` and would be force-threaded under RT,
plausibly with a large context-switch-rate cost given the current baseline.
**The camera/USB decision should be made and frozen before any PREEMPT_RT A/B
test**, or the two variables will be conflated.

Vendor pin reproducibility has one genuinely open gap (the kernel repo pins to
a moving branch name, not a fixed SHA, with no build-time gate enforcing a
known-good commit) and two dead/orphaned vendor trees that should be deleted
or explained, not silently carried forward. Everything else is either clean
or already correctly flagged by existing tooling.

**Wi-Fi addendum (2026-07-31 follow-on mission)**: NebulaOS's real Wi-Fi
hardware is a Cypress CYW43438 SDIO combo chip, and — contrary to this
report's own earlier general concern that the shipped Wi-Fi driver might be
an unrecoverable binary blob — the actual, active driver is the mainline
**in-tree `brcmfmac`** (`CONFIG_BRCMFMAC=y`, built-in; the vendor's
conflicting out-of-tree `BCMDHD` driver is correctly and permanently
disabled). This means Wi-Fi's PREEMPT_RT exposure is fully source-provable
(§18.15) and rated **Low risk** — materially better than DWC2. Real hardware
association was already fully proven working end-to-end in a prior mission
(FIRMWARE.md §53: associated, DHCP-assigned, ping-verified) — this is
existing evidence, not re-measured here. Several concrete, source-proven
defects were found that plausibly explain real, previously-observed
symptoms: **the shipped Wi-Fi firmware NVRAM's MAC-address fields are
generic template placeholders** (inherited unchanged from stock, not a
NebulaOS regression) that trigger brcmfmac's own built-in "known-bad-default"
detection, causing a **fresh random MAC address on every single boot** — a
strong, source-proven explanation for this project's already-documented
DHCP/IP-address drift across reboots. Separately, the shipped firmware also
hardcodes **`ccode=CN`** (China regulatory domain, also inherited unchanged
from stock) regardless of actual deployment location. The device-tree is
missing `cap-sdio-irq` (so the SDIO link runs in polling mode even though the
host controller core already supports in-band IRQ) and sets the wrong
high-speed capability flag (`cap-mmc-highspeed` instead of `cap-sd-highspeed`,
so SDIO high-speed negotiation is never attempted). See §18 (subsections
18.1-18.20) for the full analysis; the existing camera/USB/RT sections below
are otherwise unchanged by this addendum except where explicitly
cross-referenced.

---

## 2. Vendor pin drift status

All commits/branches below were read directly from the actual local
checkouts in this repo on 2026-07-31; none were re-fetched or modified.

| Repo | Declared pin (fetch script) | Actual HEAD | Status |
|---|---|---|---|
| `vendor/buildroot-x2000` | `74d020081096972857acdb9e76c6c5335455d430` (`scripts/build/00-fetch-vendor-sources.sh`, `clone_pinned buildroot-x2000 ...`) | `74d020081096972857acdb9e76c6c5335455d430` | **PIN_MATCH**. Working tree shows a modified `package/python-matplotlib/python-matplotlib.mk` and untracked `board/halley5-nebulaos-*` files — all fully accounted for and deterministic, not accidental drift: the `.mk` change is copied in verbatim from the tracked `scripts/build/vendor-patches/python-matplotlib/python-matplotlib.mk` by `02-configure-buildroot.sh:139` (documented rationale in-file: matplotlib's `setup_requires` numpy fetch is broken under cross-compilation, fixed by a vendored host-platform wheel), and the `board/halley5-nebulaos-*` files are this project's own tracked config-layer inputs, copied in by the same script. **No automatic HEAD-vs-pin check exists for this repo** (see below) — the pin only matches today by chance of nobody having run `git pull` inside it. |
| `vendor/x2000_kernel_6.6` (kernel, fork `NebulaOS-KE/NebulaOS`) | **Branch name `openke`**, not a commit SHA (`00-fetch-vendor-sources.sh`: `git -C x2000_kernel_6.6 checkout openke`) | `f7ff80a8aa21886a32783dab167e451298c60a8d` | **PIN_DRIFT-BY-DESIGN**. Every other `clone_pinned` call in this script pins to an exact SHA; the kernel is the sole exception, pinned to a branch that can move on every fresh fetch. The current HEAD is recorded post-hoc in `artifacts/buildroot-halley5-v30-image/build-manifest.txt:4` (`git_commit_kernel=f7ff80a8a...`, `git_dirty_kernel=no`) — but that is a record made *after* a build, not a gate enforced *before* one. `01-apply-kernel-patches.sh:30` only checks the branch name (`openke`), never a specific commit. **If `openke` moves upstream before a fresh clone, a rebuild would silently use different kernel source with no error**, and there is no single place in the repo that states "the current authoritative pin is `f7ff80a8a...`" as a durable, checked value — only the manifest's after-the-fact record. |
| `vendor/x2000_kernel` (Jubian540/x2000_kernel fork, non-6.6) | **Not declared anywhere** in `00-fetch-vendor-sources.sh` | `7f14bc69e3125a92abf88b6e9525df405e1cd0e0` | **RETAINED, DOCUMENTED (corrected 2026-07-31)**. Not consumed by the numbered `00`-`06` build pipeline, but **not actually orphaned** either — this initial characterization was too hasty. `README.md:176`, multiple `FIRMWARE.md` sections, and `docs/PIN_OWNERSHIP_MAP.md:221` all confirm real, ongoing reference use: cross-compiling a stock-vermagic-matching kernel module, confirming the exact stock kernel version, and as a reference-tree search target during pin-conflict investigations. See `docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md`'s "Orphaned vendor tree resolution" section for the full resolution — kept, not deleted. |
| `vendor/klipper` (fork `coreflake1/NebulaOS-klipper`) | `b3d5ab2b9484f1558586c3a2ea43d46ff9a473a7` | `d839d0375a31327e57e0a35e99e70ba60814ec05` (one real commit ahead: `"chelper: replace incompatible upstream c_helper.so with NebulaOS's own build"`) | **PIN_DRIFT, already caught**. Confirmed `b3d5ab2...` is a genuine ancestor of the actual HEAD (`git merge-base --is-ancestor` succeeds) — not diverged, just stale. This is **not a hidden gap**: `scripts/build/06-verify.sh:39-55` already implements `check_vendor_pin()` and calls `check_vendor_pin klipper b3d5ab2b9484f1558586c3a2ea43d46ff9a473a7` (line 55), with an in-file comment (lines 30-38) explicitly documenting that this exact MISS is expected until the fetch script's own pin comment is bumped, and warning future readers not to silence it by changing the expected SHA to match. **A fresh `00-fetch-vendor-sources.sh` run today would check out `b3d5ab2` and miss the c_helper.so replacement commit the current build actually depends on** — this is a live, real reproducibility risk despite being correctly flagged. Working tree also shows the expected, previously-documented `M klippy/chelper/c_helper.so` build-artifact drift (unrelated to this pin gap). |
| `vendor/moonraker` (upstream `Arksine/moonraker`) | `d5ee17128bb88434aacdab90c2e9e990e2b64e4a` | `d5ee17128bb88434aacdab90c2e9e990e2b64e4a` | **PIN_MATCH**, and covered by `check_vendor_pin moonraker ...` (`06-verify.sh:56`). Clean. |
| `vendor/pellcorp-creality` (SimpleAF) | `d18d354456a89c20507e574feaa34d6389e679ca` | `d18d354456a89c20507e574feaa34d6389e679ca` | **PIN_MATCH**, and covered by `check_vendor_pin pellcorp-creality ...` (`06-verify.sh:57`). Clean. |
| `vendor/k1-ustreamer` (fork `pellcorp/k1-ustreamer`) | `18e30bb313d54b1b01dd995bd31ce5a3d5adffd6` | `18e30bb313d54b1b01dd995bd31ce5a3d5adffd6` | **PIN_MATCH**. Real git submodules (`jpeg-9d` → `pellcorp/jpeg-9d`, `ustreamer` → `pellcorp/ustreamer`, per `.gitmodules`), pinned deterministically via the parent commit's recorded submodule SHAs — no drift risk there. **Not covered by `check_vendor_pin`** — no automatic gate. |
| `vendor/v4l-utils` (linuxtv) | Tag `v4l-utils-1.20.0` | `3b22ab02b960e4d1e90618e9fce9b7c8a80d814a`, confirmed via `git describe --tags` = `v4l-utils-1.20.0` exactly | **PIN_MATCH**. Untracked `messages.mo` (a compiled gettext artifact left in the source tree) — harmless, minor `DIRTY_VENDOR_TREE`, not a reproducibility risk. **Not covered by `check_vendor_pin`**. |
| `vendor/mainsail` (git clone of `mainsail-crew/mainsail`) | **REMOVED (2026-07-31)** | was `4b3358577beda37f04f2f43aad92aafbbd82babc` | **RESOLVED**. Confirmed via `grep -rn "vendor/mainsail\b"` across scripts and docs — zero matches anywhere; nothing ever read this tree. A clean, unmodified, trivially re-clonable mirror with no unique content — deleted. See `docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md`'s "Orphaned vendor tree resolution" section. |
| GuppyScreen (`artifacts/guppyscreen-mips/{guppyscreen,guppybeep}`) | **Not declared anywhere** — no fetch-script entry at all | N/A — prebuilt MIPS binaries, no source tree vendored | **UNPINNED_ARTIFACT**. No declared source commit, no download URL, no hash verification recorded anywhere in this repo for these two binaries. This is the least-reproducible artifact in the whole build: if it were lost, there is no documented way to reconstruct or re-obtain it from source. |
| `artifacts/buildroot-halley5-v30-image/build-manifest.txt` (release record) | — | `git_commit_main=d168f08...`, `git_dirty_main=yes`, `git_commit_kernel=f7ff80a8a...`, `git_dirty_kernel=no` | Records only the **main repo** and **kernel** commits — does **not** record `git_commit_klipper`/`moonraker`/`pellcorp-creality`/`k1-ustreamer`/`v4l-utils`/`buildroot-x2000` at build time. A future investigator holding only this manifest cannot reconstruct which exact vendor commit produced 5 of the 7 vendored git trees in a shipped image. Also notable: the last recorded production build was made with `git_dirty_main=yes` — the main repo's own working tree was dirty at build time, and that dirty diff itself is not captured anywhere, so the exact overlay/script source for that specific build is not fully reconstructable from git alone. |

**Can the build currently fail automatically on drift?** **Updated
2026-07-31 — yes, substantially more than when this analysis was first
written.** At the time of the original analysis this was only Partially
true: `check_vendor_pin()` covered exactly three of seven vendored git trees
and nothing checked working-tree cleanliness or binary-artifact hashes. The
same day's pre-qualification engineering pass closed most of this: every
`clone_pinned()` call in `00-fetch-vendor-sources.sh` now re-verifies its
pin (SHA + remote URL) on *every* run, not just first clone, and fails
loudly (`exit 1`) on mismatch — this is a real, hard pre-build gate, not
just an advisory report. `06-verify.sh`'s `check_vendor_pin()` was extended
to cover all seven git trees plus the kernel, plus remote-URL and
working-tree-cleanliness checks (against an explicit, documented allowlist
per repo) and a dedicated k1-ustreamer submodule check. A new
`check_artifact_sha256()` gate covers every downloaded/prebuilt binary
(Mainsail zip, GuppyScreen binaries, Wi-Fi firmware/NVRAM, regulatory.db).
Note: `06-verify.sh` itself remains an advisory report by this project's own
long-standing, deliberate "never trust exit 0 alone" convention (documented
across many prior missions) — its `MISS` lines still require a human/agent
to read them; it does not `exit 1` on its own. The real hard gates are
`00-fetch-vendor-sources.sh` and `01-apply-kernel-patches.sh`, which do fail
the pipeline outright. `build-manifest.txt`'s own commit/hash coverage gap
(5 of 7 vendored git commits, no dirty-main-repo diff capture) remains open.

**Original list of reproducibility gaps identified by this analysis, and
their resolution** (all closed 2026-07-31 in the follow-on pre-qualification
engineering pass — commits `0e69da1` and the release-artifact-provenance
work; see `docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md` for artifact
details):

1. ~~Kernel fetch pins to a moving branch name (`openke`), not a SHA; no
   pre-build gate enforces a known-good commit.~~ **FIXED**:
   `00-fetch-vendor-sources.sh` now pins an exact SHA and fails loudly if
   `openke` has moved past it; `01-apply-kernel-patches.sh` independently
   re-verifies the same pin.
2. ~~`vendor/x2000_kernel` (non-6.6) and `vendor/mainsail` are orphaned,
   undeclared, unused vendor trees with no fetch-script provenance.~~
   **RESOLVED**: `vendor/x2000_kernel` is genuinely retained (real,
   documented reference use — see §2's corrected row above); `vendor/mainsail`
   had zero references anywhere and was removed.
3. GuppyScreen's prebuilt binaries have zero declared provenance (no source
   commit, URL, or hash) — **still true**, this is a real, unresolved
   limitation of the upstream artifact itself (see
   `docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md`), not something a build
   script fix can close. Its hash is now at least recorded and verified so
   drift is detectable even though full reconstruction isn't possible.
4. ~~`check_vendor_pin` does not cover `buildroot-x2000`, `k1-ustreamer`, or
   `v4l-utils`.~~ **FIXED**: all three now have `check_vendor_pin` calls in
   `06-verify.sh`, plus `k1-ustreamer`'s submodules (`jpeg-9d`, `ustreamer`)
   get their own dedicated check. `check_vendor_pin` itself was also
   extended to verify the origin remote URL and working-tree cleanliness
   (against an explicit, named allowlist of deterministically-managed
   paths per repo), not just the HEAD SHA.
5. ~~`build-manifest.txt` does not record 5 of 7 vendored git commits, and
   does not capture a dirty-main-repo diff when `git_dirty_main=yes`.~~
   **FIXED**: `05-final-build.sh` now records every vendored git commit
   (kernel, Buildroot, Klipper, Moonraker, pellcorp-creality, k1-ustreamer +
   its submodules, v4l-utils) plus dirty-state per repo, and every
   binary-artifact hash (Mainsail, GuppyScreen, Wi-Fi firmware/NVRAM,
   regulatory.db, device-tree). A real dirty-main-repo *diff capture* was
   not added (that's a much bigger change - archiving the actual diff
   alongside the manifest); instead, a new opt-in
   `NEBULAOS_REQUIRE_CLEAN_TREE=1` gate makes `05-final-build.sh` refuse to
   build at all from a dirty main tree, reserved for the final Phase 13
   production build (everyday iterative/experimental builds are unaffected,
   left able to build from an in-progress tree as this project always has).
6. ~~No hash verification exists for either downloaded binary artifact
   (Mainsail zip, GuppyScreen binaries).~~ **FIXED**: both (plus the Wi-Fi
   firmware/NVRAM and regulatory.db blobs) now have recorded SHA-256 hashes
   checked by `06-verify.sh`'s new `check_artifact_sha256()` gate — see
   `docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md`. Separately, Mainsail's
   fetch was found to be **entirely unpinned** (downloaded from a `/latest/`
   URL that silently tracks whatever GitHub's latest release is at fetch
   time — arguably worse than the kernel's moving-branch issue, since there
   was no way to even detect drift after the fact) and is now pinned to an
   exact release tag (`v2.18.2`) with a verified hash.
7. **Cross-confirmed during the Wi-Fi follow-on mission and now fixed**: the
   raw, on-disk `vendor/x2000_kernel_6.6/kernel/kernel-6.6/.config`/
   `.config.old` were found stale — root-owned build byproducts dated
   2026-07-20, predating this project's own BCMDHD-disable fix, showing
   `CONFIG_BRCMFMAC=m`/`CONFIG_BCMDHD=y`/`CONFIG_EXTRA_FIRMWARE=""`, all
   three contradicting the authoritative, git-tracked
   `artifacts/buildroot-halley5-v30-image/kernel.config`. This was a real,
   generalizable gotcha, not a live regression — the stale files have been
   removed, and `03-build-kernel-and-rootfs.sh` now unconditionally purges
   `.config`/`.config.old`/`include/config`/`include/generated` from the
   mounted kernel source tree (inside the docker container, since these
   files are root-owned) before every build, so this can't silently
   recur.

---

## 3. NebulaOS camera lifecycle

Full chain, boot to browser (all citations from direct source reading):

1. **Discovery** — no udev rule exists for the camera (`scripts/build/overlay/etc/udev/rules.d/91-usb-gcode-media.rules` only matches mass-storage `sd[a-z]` nodes). Discovery is userspace-polled: `S50webcam`'s `discover_uvc_device()` (`scripts/build/overlay/etc/init.d/S50webcam:87-106`) scans `/dev/video*` every 5s (`POLL_INTERVAL=5`, line 38), requiring `v4l2-ctl --info` to report `Driver name...: uvcvideo`, a `Video Capture` capability, and MJPEG format support.
2. **Launch** — `start_ustreamer()` (`S50webcam:118-131`) execs `/usr/bin/ustreamer --device=<dev> --format=MJPEG --encoder=HW --resolution=1920x1080 --desired-fps=30 --host=127.0.0.1 --port=8080`, backgrounded via `start-stop-daemon`, `oom_score_adj=300` set on the child (an early-OOM-kill candidate relative to Klipper/Moonraker).
3. **V4L2 open/mmap/STREAMON** — `us_capture_open()` (`vendor/k1-ustreamer/ustreamer/src/libs/capture.c:198`) opens `O_RDWR|O_NONBLOCK`, mmaps buffers (`~capture.c:915,963`), issues `VIDIOC_STREAMON` (`capture.c:261`) from `_stream_init_loop()` (`vendor/k1-ustreamer/ustreamer/src/ustreamer/stream.c:604`).
4. **HTTP listener** — ustreamer's own libevent HTTP server binds `127.0.0.1:8080` (`main.c:100,108`).
5. **nginx reverse proxy** — `scripts/build/overlay/etc/nginx/nginx.conf:28-31,84-98` proxies `/webcam/` to `127.0.0.1:8080`, buffering disabled (required for live MJPEG).
6. **Moonraker registration** — `S57nebulaos-camera-seed` → `usr/libexec/nebulaos-seed-camera` posts a **database-backed** webcam named `"Nebula"` to `/server/webcams/item` (`service: uv4l-mjpeg`, `stream_url: /webcam/?action=stream`), idempotent via an atomic marker file; current `moonraker.conf` has no `[webcam ...]` config section, consistent with this design.
7. **Clients** — Mainsail consumes the registered stream/snapshot URLs through the nginx proxy (ordinary multipart-MJPEG `<img>` consumption). **GuppyScreen's own camera-viewing behavior cannot be proven from source** — only prebuilt MIPS binaries are vendored (`artifacts/guppyscreen-mips/`), no C/C++ source tree exists anywhere in this repo. The only GuppyScreen-adjacent file available is `scripts/build/overlay/opt/printer_data/config/GuppyScreen/scripts/reload_camera.py`, which just shells out to `S50webcam restart` on a manual on-screen macro — it does not itself open or poll the camera.
8. **Respawn** — `S50webcam`'s `supervise()` loop (lines 143-165) polls ustreamer's liveness every 5s via `/proc/$pid` + cmdline match and restarts it if dead — covers crashes and device unplug/replug alike. **Unknown from source**: whether anything restarts the outer supervisor shell itself if that specific process dies (no separate watchdog found).

**Previous node**: `/dev/video3` (before the prior mission's Phase 9 kernel
change removed the internal Ingenic ISP/rotate/vcodec M2M pipeline that
previously claimed `/dev/video0`-`video2` unconditionally). **Current node**:
`/dev/video0`, confirmed live via `ps` after that kernel change (already
established in this project's own record).

---

## 4. SimpleAF camera lifecycle

From `vendor/pellcorp-creality/k1/*` (the only target architecturally
comparable to NebulaOS — `rpi/` uses a separate, unrelated crowsnest-based
design and is out of scope).

- **Streamer**: a vendored **prebuilt stock ustreamer binary** (`k1/packages/ustreamer.tar.gz`, extracted to `/usr/data/ustreamer/` at install time, `k1/installer.sh:479-486`) — not NebulaOS's own fork. SimpleAF's installer actively removes competing streamers it finds pre-installed (stock `cam_app`, entware `mjpg_streamer`) and neutralizes the stock firmware's own webcam auto-launcher (`k1/files/auto_uvc.sh` overwritten to `exit 0`, `installer.sh:495-498`).
- **Boot start**: yes, via a BusyBox/sysvinit-style `S50webcam` init script (`k1/services/S50webcam:41`), same `S`-numbering convention as NebulaOS. **Systemd mismatch confirmed**: `installer.sh` calls `sudo systemctl restart webcam` (e.g. line 2582), but this is a hand-written shim (`k1/tools/systemctl`) translating to `/etc/init.d/S50webcam restart` — SimpleAF's k1 target assumes/papers-over an init system with no real systemd, architecturally similar to what NebulaOS would need to handle if it ever imported this installer verbatim.
- **Open/held-open**: immediate and eager (`S50webcam:41`), held open continuously via `start-stop-daemon -b` with no viewer-count gating anywhere in the init script or config files (`k1/webcam.ini`, `k1/webcam.conf`).
- **Supervisor**: **none** for the camera specifically — plain `start-stop-daemon -b`, no respawn wrapper (contrast: `S99grumpyscreen`/`S58factoryreset` do use a vendored `supervise-daemon`). A crash requires a manual/Moonraker-triggered restart.
- **Device discovery**: dynamic, but only once per start (`v4l2-ctl --list-devices` scan, `S50webcam:24`) — no hotplug re-scan loop.
- **Defaults**: **720p @ 10fps** (`k1/webcam.ini:1-6`), not 1080p30 — lower than NebulaOS's default in both resolution and frame rate.
- **Idle behavior**: minimal — a frontend-only `target_fps_idle: 5` throttle (`k1/webcam.conf:12`, doesn't reduce actual capture) plus opt-in manual pause/throttle macros gated to probing operations (`k1/tools/camera.sh` hitting ustreamer's own `/pause`/`/resume`/`/set_fps` HTTP endpoints, invoked from calibration macros) — not a general or automatic idle-power policy.

| Behavior | NebulaOS | SimpleAF |
|---|---|---|
| Camera service starts at boot | Yes (`S50webcam`) | Yes (`S50webcam`, same convention) |
| Camera opened immediately | Yes | Yes |
| Camera held open without viewers | Yes | Yes |
| Capture active without viewers | Yes (only JPEG encode is client-gated) | Yes (only frontend fps-request is throttled) |
| Dynamic `/dev/videoN` discovery | Yes, every 5s poll | Yes, once per service start only |
| First-frame latency strategy | Pre-open at boot | Pre-open at boot |
| Runtime power management | None (autopm ref held from `open()`, never released) | None automatic; manual pause during probing only |
| Reconnect behavior | Automatic, 5s supervisor poll | None automatic — manual `systemctl restart` shim only |
| USB hotplug interaction | Re-discovered by the 5s poll loop | None — device path resolved once at start |

**Inherited vs. independent**: **independent designs**. NebulaOS uses its own
k1-ustreamer fork with a from-scratch supervisor loop and 1080p30 defaults;
SimpleAF vendors an unmodified stock ustreamer binary with a from-scratch
init script, its own config format, a systemd-shim layer, and 720p/10fps
defaults, with no supervised restart at all. The shared high-level outcome
(always-open, boot-eager) is a common pattern for embedded MJPEG services,
not evidence of copying — no file or config value in either tree references
the other.

---

## 5. Stock/OpenKE camera lifecycle

**Classification: SAME_ALWAYS_OPEN_MODEL, with one honestly-unproven leg.**

Real, device-pulled evidence exists: `vendor/device-backups/printer_data_config/GuppyScreen/scripts/reload_camera.py`
(backed up directly from the real stock device) documents the stock pipeline
as Creality's own closed **`cam_app`** binary (`/usr/bin/cam_app -i
/dev/v4l/by-id/main-video-4 -t 0 -w 1920 -h 1080 -f 15 -c` — **15fps**, half
NebulaOS's 30) feeding **`mjpg_streamer`** (open-source, via
`input_memfd.so`/`output_http.so -p 8080`). Its own comment states, as a
live-confirmed fact: *"Neither cam_app nor mjpg_streamer has a supervisor
watching them (both run with PPID 1, confirmed live — nothing else respawns
them if killed)"* — consistent with the separately-known fact that a full
reboot, not a targeted restart, is what fixes a wedged stock camera pipeline.

What is **not** proven: the exact boot-time launcher script was never
captured (inferred from a code comment, not a captured init.d file); the
one real stock boot-log capture (`vendor/device-backups/stock-boot-reference-log.txt`)
shows no camera start line, but also shows no USB webcam was physically
attached during that specific capture, so this is not a valid negative;
`cam_app`'s internal use of the Ingenic hardware encoder is inferred from
`FIRMWARE.md:465-467`, not independently disassembled; and **no USB
interrupt-rate measurement was ever taken against stock** — the "likely
similar load" conclusion is an analogy (same class of continuously-capturing
UVC pipeline), not a real measured comparison. Confirming any of these three
would require powering on real stock hardware with a webcam attached, which
this mission does not do.

| Behavior | NebulaOS | SimpleAF | Stock/OpenKE |
|---|---|---|---|
| Streamer | k1-ustreamer (fork) | stock ustreamer (unmodified) | `cam_app` (closed) + `mjpg_streamer` |
| Starts at boot | Yes | Yes | Likely (inferred, not directly captured) |
| Camera held open | Yes | Yes | Yes (PPID 1, no supervisor — live-confirmed) |
| Capture active while idle | Yes | Yes | Almost certainly (same reasoning) |
| Expected USB suspend | No | No | No (expected by analogy, unmeasured) |
| Expected first-frame latency | Low (pre-opened) | Low (pre-opened) | Low (pre-opened, by analogy) |

---

## 6. USB topology

```
DWC2 OTG root controller (dr_mode: otg, host-mode active)
  -> internal USB hub
       -> UVC camera (1920x1080@30, hardware MJPEG, high-speed)
```

`power/control` is `auto` on every node; `runtime_status` stays `active`
throughout (previously established, not re-measured here). Section 8 below
explains precisely why, from source.

---

## 7. DWC2 interrupt-source analysis

**SOF is not permanently unmasked — it is gated by the count of active
periodic (isoc/interrupt) queue heads, and the UVC camera's video endpoint is
the only periodic consumer on this bus.**

- Host-interrupt enable masks in only `GINTSTS_DISCONNINT|GINTSTS_PRTINT|GINTSTS_HCHINT`, **not** SOF (`drivers/usb/dwc2/hcd.c:167-184`).
- SOF is unmasked the moment the first periodic QH is added: `dwc2_hcd_qh_add()`, `if (!hsotg->periodic_qh_count) { intr_mask |= GINTSTS_SOF; ... }` (`hcd_queue.c:1723-1731`), and re-masked off when the last one is removed: `dwc2_hcd_qh_unlink()`, `if (!hsotg->periodic_qh_count && !hsotg->params.dma_desc_enable) { intr_mask &= ~GINTSTS_SOF; ... }` (`hcd_queue.c:1764-1771`).
- On this board, `dma_desc_enable` defaults to `false` for host mode (`params.c:242`, never overridden by the board-specific hook), so the re-mask guard is live, not a dead branch.
- High-speed microframe interval is programmed explicitly: `dwc2_calc_frame_interval()`, `if (...HPRT0_SPD_HIGH_SPEED) return 125 * clock - 1;` (`hcd.c:369-371`) — **125µs, and `1/125µs = 8000`, an exact numeric match to the measured rate.**
- The handler `dwc2_sof_intr()` (`hcd_intr.c:110-149`, dispatched at `hcd_intr.c:2240-2241`) fires once per microframe unconditionally, independent of whether that microframe carries payload — this is standard host-controller clocking for an armed periodic endpoint, not a data-triggered event.

```
USB_INTERRUPT_SOURCE: IDENTIFIED
USERSPACE_POLLING_CAUSE: NO
USB_SOF_EXPECTED_BEHAVIOR: YES
CAMERA_HOLDS_USB_ACTIVE: PROVEN
```

Use the required terminology: this is **continuous high-rate USB framing
interrupt load**, not a "storm" — the mask/unmask mechanism is present,
correct, and doing exactly what standard DWC2 host-controller behavior
requires for an armed high-speed periodic endpoint. What static analysis
cannot fully confirm on its own (would need a live register/trace capture):
whether `VIDIOC_STREAMON` was continuously engaged for the entire measurement
window (vs. intermittently) — the source proves the mechanism, not the live
duty-cycle at the moment of measurement, though continuous streaming is
consistent with everything else established in section 3.

---

## 8. UVC runtime-power analysis

- `uvc_v4l2_open()` calls `usb_autopm_get_interface(stream->dev->intf)` (`uvc_v4l2.c:620`) **unconditionally on every open()**, before any streaming request — this alone blocks USB autosuspend of that interface for as long as the fd stays open.
- That reference is released **only** in `uvc_v4l2_release()` via `usb_autopm_put_interface()` (`uvc_v4l2.c:678`), i.e. on `close()` — **not** on `STREAMOFF`. Neither `uvc_video_start_streaming()` nor `uvc_video_stop_streaming()` (`uvc_video.c:2219-2249`) touch the PM refcount at all.
- Isoc URB submission — the thing that actually creates the periodic QH and unmasks SOF — happens only in `uvc_video_start_transfer()`, called from `uvc_video_start_streaming()` (`uvc_video.c:2232`), reached via `VIDIOC_STREAMON`. **Opening the device alone does not generate the SOF load; only active streaming does.**
- `uvc_video_stop_streaming()` → `uvc_video_stop_transfer()` (`uvc_video.c:1758`) tears down the isoc URBs, and the resulting QH unlink should re-mask SOF once `periodic_qh_count` reaches 0 (`hcd_queue.c:1764-1771`, board-satisfied per §7). **So `STREAMOFF` alone should kill the ~8,000/sec load.**
- But `STREAMOFF` alone does **not** release the `usb_autopm` reference taken at `open()` — only `close()` does. So with the fd held open (NebulaOS's actual behavior), the interface — and by the standard USB PM parent/child propagation, the hub/root-hub chain above it — **cannot runtime-suspend regardless of streaming state.** This is the source-proven explanation for "`power/control=auto` but `runtime_status` stays `active`" independent of the interrupt-rate question.
- No `pm_runtime_*` forbid calls or Ingenic-specific quirks block PM in either driver; DWC2 registers only the standard `SET_SYSTEM_SLEEP_PM_OPS` (S3 sleep, `platform.c:659-660`) plus the generic `usb_hcd_driver` bus_suspend/resume hooks (`hcd.c:5015-5016`) — this is normal DWC2 behavior that simply never gets exercised because the UVC open()-time PM reference is never released.

---

## 9. ustreamer no-client behavior

**Classification: SAME_ALWAYS_OPEN_MODEL** for capture; only JPEG encode/serve
is client-gated.

- The capture loop in `us_stream_loop()` (`stream.c:211`) unconditionally calls `us_capture_hwbuf_grab()` every iteration regardless of client count. The only client-count-aware branch, `stream->slowdown` (throttles to ~10 iter/sec, `stream.c:249-250`), is **not enabled** in NebulaOS's actual invocation (`--slowdown` is never passed by `S50webcam`, and it defaults `false`) — so even this throttle is inactive.
- `VIDIOC_STREAMOFF` is only issued inside `us_capture_close()` (`capture.c:299-334`), reached only on process shutdown, a runtime FPS change, an explicit pause, or a capture error — **never** on client count reaching zero.
- Only the encode/serve workers (`_jpeg_thread()`, `stream.c:330-407`, checking `has_clients` at line 368) skip work with no viewers, logging `"JPEG: Passed encoding because nobody is watching"` and dropping the frame uncoded. Given `--encoder=HW`, JPEG compression itself runs on the camera's own ISP, not host CPU — consistent with the audit's <0.2% idle CPU / ~15.3MiB idle RSS for ustreamer.
- mmap'd buffers (`capture.c:915,963`) stay mapped continuously, since nothing triggers `close()`/`munmap()` based on client count.
- **Unused existing features found in the vendored k1-ustreamer/pellcorp/ustreamer source** (`vendor/k1-ustreamer/ustreamer/src/ustreamer/options.c`), none of which `S50webcam` currently passes:
  - `--slowdown`/`-l` (`options.c:187`) — throttles capture to ≤1fps when no clients; does not close the device.
  - `--exit-on-no-clients <sec>` (`options.c:263`, default `0`/disabled, `stream.c:788-804`) — would exit the **whole process** after N idle seconds; nothing in this project currently relaunches it on demand.
  - Local-only HTTP `/pause` and `/resume` endpoints (`http/server.c:608-632`, `REQUIRE_LOCAL_REQUEST`-gated) already drive a **real close()/reopen() cycle** via `stream->paused` (`stream.c:244-247`) — this is the closest thing to a ready-made Variant-C mechanism already in the binary, currently unused by any NebulaOS script.
- Crash/respawn is handled at the init-script layer (`S50webcam`'s 5s supervisor poll), not inside ustreamer itself.

---

## 10. Camera lifecycle alternatives

| Variant | Mechanism (source-grounded) | Verdict |
|---|---|---|
| **A. Current always-open** | Baseline — described above. | Reference point. |
| **B. STREAMOFF while idle, fd stays open** | Per §7/§8: would kill the SOF/IRQ load (periodic QH removed) but **not** release the autopm reference, so no additional hub/controller suspend. **As literally specified this is not achievable via existing ustreamer flags** — the binary only exposes bundled `STREAMOFF`+`close()`+`munmap()` together (via pause or exit-on-no-clients), never a bare `STREAMOFF` with the fd/mmap kept alive. Achieving true "STREAMOFF-only" would require a small source patch to k1-ustreamer's `stream.c`/`capture.c` to decouple the two. |
| **C. fd closes when idle, using the *existing* pause/resume HTTP endpoint** | `/pause` already drives the real `stream->paused` → close() → munmap() → `usb_autopm_put_interface()` path (§9); `/resume` re-triggers `_stream_init_loop()` → reopen → remap → re-STREAMON. **Achievable today with zero ustreamer source changes** — only new orchestration is needed: something that calls `/pause` after N idle seconds and `/resume` on the first new client (e.g. a small watcher added to `S50webcam` or a companion script, driven by nginx access activity or ustreamer's own connection state). | **Best available option from source** — reuses an already-shipped, already-tested code path. |
| **D. Whole process exits when idle** | `--exit-on-no-clients <sec>` already exists and is unused (§9); would need a companion relaunch-on-demand trigger (e.g. an nginx `try_files`/helper trick, or the existing 5s `S50webcam` poll extended to also *start* ustreamer on first request, not just restart it on crash) — this last part does **not exist today** and would be new orchestration logic, more than Variant C needs. | Higher win ceiling (full RSS reclaim), higher implementation/latency cost. |
| **E. DWC2/kernel-only mitigation, camera stays streaming** | Per §7, the SOF mask/unmask logic is already correctly implemented and tied to `periodic_qh_count` — there is no independent kernel-side fix that suppresses SOF while an isochronous transfer remains armed; that would violate the USB protocol requirement for periodic scheduling. **Not technically plausible as a standalone kernel change** — any real reduction collapses into stopping the stream (Variants B/C/D) at the userspace level. | **REJECT_FROM_SOURCE_ANALYSIS** as an independent variant. |
| **F. Hybrid warm-idle (timeout-gated pause + fast reopen for repeat use)** | Same mechanism as Variant C (existing pause/resume), with orchestration logic adding a short "grace period" before pausing, so brief UI dwelling doesn't cause churn. Whether ustreamer exposes a live client-count query (vs. only accepting pause/resume commands) to drive this cleanly is **UNKNOWN — not confirmed from source in this pass**; a companion watcher could instead just track nginx/nc connection activity directly, which does not depend on that. | Best complexity/benefit balance; effectively "Variant C with a smarter trigger," not a new mechanism. |

For every variant: implementation complexity is lowest for C/F (existing
endpoints, new orchestration only), highest for B (needs an actual ustreamer
patch) and D (needs new lazy-relaunch plumbing); USB IRQ reduction potential
is high for B/C/D/F (all stop streaming) and zero for A/E; RAM reduction
potential is meaningful only for D (full process exit) and partial for C/F
(buffers unmapped, process itself stays resident); reconnect
reliability/first-frame-latency cost scales roughly A < C/F < D < B(unbuilt);
GuppyScreen's tolerance for an on-demand camera is **unknown** (source
unavailable, §3) and is a real risk for any variant beyond A, worth
explicitly testing before shipping.

---

## 11. Clear expected gains

Baselines (existing measurements, not re-derived): USB OTG ~8,000-8,150
IRQ/sec; aggregate idle CPU ~10% across 2 cores (also independently measured
at ~12% during this project's own Phase-1 baseline capture, `~1,425-1,470`
ctx switches/sec); ustreamer idle CPU <0.2%; ustreamer idle RSS ~15.3MiB.

### Keep camera always open (Variant A)
```
BASELINE:
    8,000-8,150 IRQ/sec, ~10-12% aggregate idle CPU, 15.3 MiB ustreamer RSS.
EXPECTED_GAIN:
    None — this is the reference baseline, zero implementation risk.
BEST_CASE / WORST_CASE:
    Unchanged in both directions; instant camera availability preserved.
CONFIDENCE:
    PROVEN_FROM_EXISTING_MEASUREMENTS (it's the measured baseline itself).
FEATURE_RISK:
    None.
REQUIRED_LATER_TEST:
    None — only relevant as the control arm for any other variant's A/B.
```

### Pause camera via existing `/pause`+`/resume` endpoints when idle (Variant C/F)
```
BASELINE:
    8,000-8,150 IRQ/sec while streaming; 15.3 MiB ustreamer RSS; USB
    hub/controller never autosuspends (proven, §8).
EXPECTED_GAIN:
    SOURCE_DERIVED_ESTIMATE. Pausing drives a real close(), which both stops
    the SOF-generating isoc transfer (§7) AND releases the usb_autopm
    reference (§8) for the first time — theoretically permitting real
    autosuspend of the UVC interface and, if nothing else on the hub is
    active, the hub/root port above it.
BEST_CASE:
    Near-total elimination of the ~8,000/sec SOF load while no viewer is
    connected; partial RSS reclaim (mmap buffers unmapped on close, process
    baseline remains resident since ustreamer itself doesn't exit); real
    USB autosuspend of the camera interface and possibly the hub.
WORST_CASE:
    The internal USB hub itself lacks functioning runtime-PM support (not
    verified from source — hub driver was out of this pass's scope) and
    never actually suspends even after the interface's PM block is lifted,
    leaving only the IRQ-elimination win; reopen adds real, user-visible
    first-frame latency when a viewer reconnects; GuppyScreen's tolerance
    for a camera that isn't always live is unverified and could be a real
    feature regression if it assumes instant availability.
CONFIDENCE:
    Medium — the close()/PM-release mechanism is proven from source; the
    magnitude of the 10-12% aggregate CPU figure actually attributable to
    USB (vs. other subsystems) was never isolated, so the CPU-percentage
    gain cannot be bounded honestly without a real hardware measurement.
FEATURE_RISK:
    Reopen latency and reconnect reliability on every viewer reconnect;
    GuppyScreen behavior unverified; interaction with the manual
    STOP_CAMERA/START_CAMERA-style pause macros (if NebulaOS ever adds
    SimpleAF-style probe-time pausing) would need to coexist correctly with
    an automatic idle-pause layer.
REQUIRED_LATER_TEST:
    100 pause/resume cycles; 20 camera-service restarts; 20 USB
    insert/remove cycles; 5 warm reboots; 3 cold boots; one combined
    camera+USB-storage load test; a controlled print with the camera
    actively viewed partway through; real /proc/interrupts before/during/
    after idle-pause; GuppyScreen camera-panel behavior specifically.
```

> **SUPERSEDED BY LIVE EVIDENCE (2026-08-01, alpha baseline freeze mission)**:
> the `BEST_CASE` claim above — "near-total elimination of the ~8,000/sec SOF
> load while no viewer is connected" — was a `SOURCE_DERIVED_ESTIMATE`, never
> a proven measurement, and live testing has since disproven it. C2 (the
> shipped implementation of this exact mechanism) was deployed to real
> hardware and exercised through a full pause/resume cycle; `/proc/interrupts`
> was read directly while the controller reported the camera genuinely
> paused. Measured result: **~8,036 IRQ/sec, statistically identical to the
> always-active baseline (~8,000-8,150/sec) measured throughout this entire
> project.** The DWC2 SOF interrupt is a USB bus/controller-level heartbeat,
> not tied to any single endpoint's streaming state — closing the UVC
> endpoint does not stop it. This paragraph is preserved as the original
> source-only prediction, not deleted, precisely because it was wrong in an
> instructive way: the close()/PM-release mechanism itself IS real and
> proven from source (§8 above), but the inference from "the interface can
> now autosuspend" to "the SOF interrupt goes away" does not hold in
> practice on this hardware. See
> `docs/NEBULAOS_ALPHA_MAX_RT_DEPLOYMENT_REPORT.md`'s `C2_PAUSED_IRQ_RATE`
> field for the live measurement, and
> `docs/NEBULAOS_ALPHA_BASELINE.md` for the corrected production guidance.
> C2 remains a legitimate feature — it stops network camera-stream traffic
> and the associated ustreamer JPEG-encode CPU work while idle — it is
> simply not a USB-interrupt-rate mitigation, and must not be described as
> one going forward.

### Exit ustreamer entirely while idle (Variant D)
```
BASELINE:
    15.3 MiB ustreamer RSS; same 8,000-8,150 IRQ/sec while active.
EXPECTED_GAIN:
    PROVEN_FROM_EXISTING_MEASUREMENTS for RSS (a full process exit reclaims
    the entire measured 15.3 MiB, a direct and simple claim); SOURCE_DERIVED
    for IRQ/PM (same close()-triggered mechanism as Variant C, since process
    exit implies close()).
BEST_CASE:
    Full 15.3 MiB RSS reclaimed while idle, plus everything Variant C's
    best case offers.
WORST_CASE:
    Relaunch-on-demand logic does not exist today and must be newly built
    (no existing "start ustreamer on first request" trigger — only
    "restart if crashed" exists); higher first-frame latency than Variant C
    (full process spawn + device rediscovery, not just reopen); a
    relaunch-loop bug could regress camera availability entirely.
CONFIDENCE:
    High for RSS reclaim; Medium for IRQ/PM (same as Variant C);
    UNKNOWN_UNTIL_HARDWARE_AB for relaunch latency/reliability, since no
    such trigger exists yet to measure.
FEATURE_RISK:
    Highest of the camera candidates — full reconnect reliability,
    first-frame latency, and unverified GuppyScreen interaction, plus new
    orchestration code that doesn't exist today.
REQUIRED_LATER_TEST:
    Same list as Variant C, plus explicit relaunch-trigger reliability
    testing and a dedicated GuppyScreen camera-panel check.
```

### DWC2 driver-level mitigation (Variant E)
```
BASELINE:
    8,000-8,150 IRQ/sec while streaming.
EXPECTED_GAIN:
    None identifiable — the SOF mask/unmask logic is already correctly
    implemented and tied to periodic-transfer state (§7); no independent
    kernel change was found that reduces this without also stopping the
    isochronous transfer, which is Variants B/C/D at the userspace level.
CONFIDENCE:
    High confidence in the negative finding — SOURCE_DERIVED_ESTIMATE.
FEATURE_RISK / REQUIRED_LATER_TEST:
    N/A — REJECT_FROM_SOURCE_ANALYSIS.
```

### Kernel subsystem removal already performed (prior mission, not re-counted here)
Already realized or in progress from the separate prior optimization mission
— **not additive to the camera/USB estimates above**, since none of them
touch the USB/camera path:
- ALSA/ASoC, Ingenic ISP/rotate/vcodec, Bluetooth HCI-UART, netfilter/bridge/
  STP/LLC, SFC/MTD, SADC/ADC MFD cells, and select debug options removed from
  the kernel config; the ISP/rotate/vcodec removal specifically is *why*
  `/dev/video0` is now free for the real USB camera (§3) — that one change is
  the sole point of overlap with this report's camera analysis, and its
  gain (freeing a device node, not a CPU/IRQ number) is already fully
  captured there, not double-counted as a USB/camera gain here.
- `c_helper.so` stripped 274,640 → 71,820 bytes (~203KB reclaimed, disk/image
  size, not directly a runtime CPU/RAM gain).
- zstd squashfs selected: ~7% smaller rootfs image, boot-readiness 43.3s
  (matching gzip, no regression) — image-size and boot-time gains, unrelated
  to USB/camera.
- venv seed archives: ~4.9KB vs 25.5MB previously — large first-boot-time and
  image-size reduction, **not yet functionally verified on a genuinely fresh
  first boot** (separately tracked, outside this mission's scope).
- CPU DVFS: investigated and rejected (no variable-voltage regulator hardware
  exists on this board) — zero gain, zero risk taken, not a pending item.

### PREEMPT_RT (separate, latency-only category)
```
BASELINE:
    CONFIG_PREEMPT=y today (.config:90); CONFIG_PREEMPT_RT not set
    (.config:92); HZ=100; DWC2 IRQ currently a hard, non-threaded handler.
PREEMPT_RT_EXPECTED_BOOT_GAIN: NONE
PREEMPT_RT_EXPECTED_RAM_GAIN: NONE (RT infrastructure — per-thread kernel
    stacks for now-threaded IRQs — is a plausible small RAM *cost*, not a
    gain; magnitude UPPER_BOUND_ONLY, not measured)
PREEMPT_RT_EXPECTED_CPU_GAIN: NONE_OR_RANGE — RT is not a throughput
    optimization; the open concern is a CPU/context-switch *cost* from
    force-threading DWC2's ~8,000/sec IRQ (see §13), not a gain.
PREEMPT_RT_EXPECTED_LATENCY_GAIN:
    SOURCE_DERIVED_ESTIMATE that worst-case scheduling latency for
    real-time-sensitive threads (e.g. Klipper's MCU communication path)
    could improve under RT's fully-preemptible model — this is the actual
    target metric RT exists to improve, but the magnitude is entirely
    UNKNOWN_UNTIL_HARDWARE_AB.
CONFIDENCE:
    Medium-High that RT is now cheap to *enable* (Kconfig infrastructure is
    fully present and satisfied, §12); Low/UNKNOWN on any specific
    latency-improvement number.
FEATURE_RISK:
    DWC2's forced IRQ threading at the current ~8,000/sec baseline is a real,
    plausible source of a large context-switch increase (§13) — must be
    measured, not assumed either way.
REQUIRED_LATER_TEST:
    A full PREEMPT vs PREEMPT_RT A/B per §15, held constant against a
    *frozen* camera/USB decision (§14).
```
State explicitly, per the mission's own requirement: **PREEMPT_RT is a
latency experiment, not a boot-time or RAM optimization.**

### Vendor pin closure
Not a runtime-performance gain. Its value is entirely in reproducibility,
A/B experiment validity, release confidence, and the ability to attribute
future benchmark differences to an intended change rather than unnoticed
vendor drift — directly relevant to trusting any of the numbers this report
or a future RT/camera A/B produces.

---

## 12. PREEMPT_RT static analysis

`localversion-rt` contains exactly `-rt23` — confirmed a **genuine,
non-vestigial RT patch lineage**, not a leftover string:

- `kernel/Kconfig.preempt:84-101` defines a fully-formed, selectable
  `config PREEMPT_RT` (`"Fully Preemptible Kernel (Real-Time)"`) inside the
  real `choice "Preemption Model"` block, `depends on EXPERT &&
  ARCH_SUPPORTS_RT`.
- `arch/mips/Kconfig:29` explicitly opts in: `select ARCH_SUPPORTS_RT if
  HAVE_POSIX_CPU_TIMERS_TASK_WORK` — MIPS is one of only 6 architectures in
  this tree carrying `ARCH_SUPPORTS_RT` at all.
- The current `.config` already satisfies every dependency:
  `CONFIG_HAVE_POSIX_CPU_TIMERS_TASK_WORK=y` (line 60), `CONFIG_EXPERT=y`
  (line 150), `CONFIG_ARCH_SUPPORTS_RT=y` (line 467) — only
  `CONFIG_PREEMPT_RT` itself is unset (line 92, an ordinary unselected
  choice member, not a stripped symbol). `CONFIG_PREEMPT=y` (line 90) is
  currently selected.
- Real RT lock-substitution code is present, not just references: 155 real
  `#ifdef`/conditional matches for `PREEMPT_RT` across the tree, plus genuine
  RT infrastructure files (`kernel/locking/spinlock_rt.c`, `rtmutex.c`,
  `rwbase_rt.c`, `ww_rt_mutex.c`, `include/linux/{rtmutex,spinlock_rt}.h`) —
  these do not exist in vanilla mainline 6.6 and only appear in a genuine
  PREEMPT_RT-patched tree.
- `git log` on `Kconfig.preempt`/`localversion-rt` shows only the single
  squashed `a98c2e1f2 "initial release"` commit — the RT series arrived
  pre-integrated in the original vendor drop, with no visible in-repo
  history of its application.

**Conclusion**: this is genuinely a `6.6-rt23`-series-backed vendor kernel.
Enabling `CONFIG_PREEMPT_RT` is very plausibly a Kconfig flip, not a
multi-week backport — this materially *lowers* the estimated difficulty for
a future PREEMPT_RT experiment. This is also consistent with, not
contradicting, this project's own earlier documented correction (`FIRMWARE.md`,
prior mission's Phase 7) that RT was **never actually enabled** despite an
earlier false claim that it was — RT infrastructure being *present and
ready* and RT being *actually turned on* are two separate facts, and both
are now accurately recorded.

---

## 13. RT driver-risk matrix

| Subsystem | RT risk | Evidence | Later test required |
|---|---|---|---|
| DWC2 USB | **High** | Sole IRQ registered via `devm_request_irq(..., dwc2_handle_common_intr, IRQF_SHARED, ...)` (`platform.c:472-474`) — **no `IRQF_NO_THREAD`**, so RT force-threads it. 54 ordinary `spin_lock_irqsave` sites (e.g. `hcd_ddma.c:135`), zero `raw_spinlock`, zero tasklets. A vendor/upstream comment already in-tree (`hcd_queue.c:1894-1900`) explicitly states DWC2 "needs quite spectacular interrupt latency requirements... handle its interrupts completely within 125µs," citing webcam behavior directly. | Live boot with `CONFIG_PREEMPT_RT=y`; measure worst-case IRQ-thread scheduling latency under the ~8,000/sec baseline load; watch for isoc transfer errors implied by the 125µs comment. |
| UVC camera | Medium | No IRQ of its own (0 `request_irq` hits) — runs entirely off USB completion callbacks scheduled from the DWC2 IRQ thread, so its RT exposure is inherited, not independent. 7 ordinary `spin_lock_irqsave` sites, zero raw_spinlock/tasklets. Ingenic HW MJPEG encoder driver was not source-audited for RT markers in this pass. | Frame-drop/latency check once DWC2's IRQ is threaded; a dedicated pass on the HW encoder driver — UNKNOWN otherwise. |
| UART MCU comms | Low | Generic 8250 core + thin Ingenic glue (`8250_ingenic.c`, zero raw_spinlock/IRQF_NO_THREAD/tasklet hits — clock/pinctrl plumbing only); core `8250_port.c` uses `IRQF_SHARED`, no `IRQF_NO_THREAD`, zero raw_spinlock in the whole `8250/` tree. | Confirm MCU/motion-control timing tolerance survives threaded serial IRQ; low baseline rate makes this a minor concern next to DWC2. |
| eMMC | Low | Ingenic glue (`sdhci-ingenic.c`) calls generic `sdhci_add_host()` with none of its own IRQ/locking; core `drivers/mmc/host/sdhci.c` already splits hard/threaded IRQ handling (`sdhci_thread_irq`), zero raw_spinlock, `IRQF_SHARED` with no `IRQF_NO_THREAD` — RT-friendly by design already. | Confirm no throughput/latency regression once its IRQ shares RT's threading model board-wide. |
| Wi-Fi | **UNKNOWN — not derivable from available source** | The vendored `ingenic_sdio.c` glue is for `rtl8723ds_wlan`, but DTS comments indicate the board's actually-used driver is a binary blob (`cywdhd.ko`, Cypress/Broadcom) whose source is **not present** in this tree — only `bcmdhd_101_10_591_x`, `bcmdhd_1_363_125_17`, `bl602`, and `rtl8189fs`/`rtl8723ds` trees exist, and none is conclusively the shipped module. | Identify the actual shipped Wi-Fi module directly on-device before any RT judgment is possible. |
| Display/touch | Low | Panel driver (`panel-openke-general-480x272.c`) has zero interrupt involvement (register-programming only). Touch (`ns2009.c`) is confirmed **polled**, not interrupt-driven (`input_setup_polling`, `ns2009_ts_poll`), so it already runs from a preemptible kernel workqueue — RT changes effectively nothing here. | None significant. |
| Watchdog | Low | The only `request_irq` in `ingenic_wdt.c` is compiled out entirely (`#if IRQ_SWITCH` where `IRQ_SWITCH` is `#define`d `0`) — no live watchdog IRQ handler exists to be affected by RT. | Confirm which of two watchdog driver variants is actually built/loaded; low priority given the IRQ path is disabled either way. |

---

## 14. Required experiment order

```
1. Resolve vendor/source reproducibility gaps (§2) — cheap, no hardware risk.
2. Select and implement a camera/USB mitigation from §10 (Variant C is the
   best-supported starting point; requires only new orchestration, no
   ustreamer source patch).
3. Freeze that camera/USB behavior via real hardware A/B testing (§15).
4. Only then run the PREEMPT vs PREEMPT_RT A/B (§15), holding the frozen
   camera/USB behavior constant.
5. Run final production qualification once, on the combined, frozen result.
```

Source evidence supports this exact ordering, not a different one: DWC2 is
identified (§13) as the single highest-risk, highest-rate RT subsystem, and
its interrupt behavior is directly and provably tied to whether the camera
is actively streaming (§7-8). Running an RT A/B before freezing the camera
decision would conflate two independent variables — any RT-induced
context-switch or latency change could not be cleanly attributed to RT
itself versus a still-undecided, still-always-on camera IRQ load.

```
USB_BEHAVIOR_MUST_BE_FROZEN_BEFORE_RT_AB: YES
```

---

## 15. Later A/B test plan (defined, not executed)

### Camera/USB A/B
**Variants**: A. current always-open vs. B. Variant C from §10 (existing
pause/resume endpoint, idle-timeout-driven).

**Measurements**: USB interrupts/sec; idle CPU; context-switches/sec; idle
temperature; ustreamer RSS; available memory; first-snapshot latency;
first-MJPEG-frame latency; camera reopen success rate; USB-storage hotplug
latency; camera+storage concurrent behavior; warm-reboot recovery; cold-boot
recovery; explicit GuppyScreen camera-panel behavior check.

**Suggested repetition**: 100 camera open/close (pause/resume) cycles; 20
camera-service restarts; 20 USB insert/remove cycles; 5 warm reboots; 3 cold
boots; one combined-load controlled print with the camera actively viewed
partway through.

### PREEMPT_RT A/B
**Variants**: A. `CONFIG_PREEMPT=y` (current) vs. B. `CONFIG_PREEMPT_RT=y`.

**Held constant**: kernel source commit; all non-preemption kernel options;
the frozen camera/USB behavior from the prior A/B; USB mitigation; rootfs;
squashfs codec (zstd, already selected); userspace; application seeds;
config.

**Measurements**: boot readiness; idle CPU; context-switches/sec; interrupt
thread count/behavior (specifically DWC2's IRQ thread); memory; scheduler
worst-case latency; UART/MCU comms statistics; camera performance; USB
storage; Moonraker responsiveness; one combined-load controlled print.

**Cheap rejection thresholds to define before any print test** (not
calculated here — requires the actual A baseline numbers from this A/B, not
assumed): if DWC2's threaded-IRQ context-switch cost measured in isolation
(camera streaming, RT enabled, otherwise idle) exceeds a threshold that would
visibly compete with Klipper's own step-timing budget, reject RT for this
board without proceeding to a print test at all.

---

## 16. Final recommendation matrix

| Candidate | Expected gain | Risk | Hardware test priority | Recommendation |
|---|---|---|---|---|
| Keep camera always open | None (baseline) | None | — (control arm only) | KEEP_CURRENT |
| STREAMOFF-only while idle (bare Variant B) | Would kill SOF IRQ only, no PM/RAM gain | Requires an unbuilt ustreamer source patch | Low, until a patch exists | NEEDS_SMALL_PROTOTYPE |
| Pause via existing `/pause`+`/resume` (Variant C/F) | IRQ elimination + possible real USB autosuspend while idle; partial RAM | Reopen latency, reconnect reliability, unverified GuppyScreen tolerance | **High** | IMPLEMENT_LATER_AB |
| Exit ustreamer while idle (Variant D) | Full 15.3MiB RSS reclaim + same IRQ/PM wins as C | Needs new relaunch-on-demand logic (doesn't exist today); highest latency/reliability risk | Medium | NEEDS_SMALL_PROTOTYPE |
| DWC2 driver mitigation (Variant E) | None identifiable independent of streaming state | N/A | None | REJECT_FROM_SOURCE_ANALYSIS |
| PREEMPT_RT | Latency-only, magnitude unknown; infrastructure is cheap to enable | DWC2 IRQ threading at ~8,000/sec baseline is the dominant open risk | High, but only *after* camera/USB is frozen | IMPLEMENT_LATER_AB (ordered after camera/USB) |
| Vendor pin enforcement (kernel branch pin, orphaned trees, GuppyScreen provenance, manifest coverage) | Reproducibility/attribution confidence, not runtime performance | Low effort, no hardware risk | — | MANDATORY_REPRODUCIBILITY_FIX |

---

## 17. Unknowns requiring hardware evidence

- Whether the USB hub itself has functioning runtime-PM support once the
  UVC interface's PM block is lifted (Variant C's ceiling depends on this;
  the hub driver was not source-audited in this pass).
- The actual fraction of the measured ~10-12% aggregate idle CPU
  attributable to USB/camera specifically, versus other subsystems — the
  audit numbers are aggregate, not USB-attributed.
- Real first-frame/reopen latency numbers for any pause-based variant (C/F)
  or exit-based variant (D) — not measurable from source.
- GuppyScreen's actual camera-viewing behavior and tolerance for an
  on-demand or paused camera — source is entirely unavailable (binary only).
- Stock/OpenKE's actual boot-time camera-start timing and USB interrupt
  rate — never measured, only inferred by analogy.
- ~~The identity of the actual shipped Wi-Fi kernel module (source-unclear,
  §13) and its RT-safety.~~ **Resolved by the Wi-Fi follow-on mission, §18**
  — it is mainline in-tree `brcmfmac`, real source, RT risk rated Low.
- Real DWC2-IRQ-threading context-switch and latency cost under
  `CONFIG_PREEMPT_RT=y` at the current ~8,000/sec baseline — this is the
  central unresolved number the whole RT recommendation hinges on.
- (Wi-Fi, see §18) Actual power/latency effect of disabling Wi-Fi
  power-save; whether the SDIO host/bus electrically supports in-band IRQ
  if `cap-sdio-irq` were added; real DHCP/IP stability once the MAC-
  randomization root cause (§18.11) is addressed; real throughput/reconnect
  numbers under any camera-mode combination (§18.16).

---

## 18. NebulaOS Wi-Fi Source Analysis

Follow-on mission (2026-07-31), source-only, no printer power-on, no live
network commands, no builds. This section documents NebulaOS's Wi-Fi
architecture, reliability, and optimization potential to the same standard
as the camera/USB/RT sections above, and is appended to the same report per
instruction rather than filed separately.

### 18.1 Hardware identity — **PROVEN**

Real chip: **Cypress CYW43438**, a 2.4GHz-only, single-stream, SDIO-attached
Wi-Fi/Bluetooth combo chip. Confirmed via this project's own real hardware
disassembly work (not inferred from a filename): the kernel Kconfig
fragment's own comment states this explicitly ("our real, live-confirmed
chip is a Cypress CYW43438", `artifacts/buildroot-halley5-v30-image/
halley5-nebulaos-fragment.config:171-172` context), and the device-tree's
Bluetooth node uses `compatible = "openke,bcm4343x-bt"` (`halley5_v30.dts:241`)
— the "4343x" family designation matches the CYW43438/BCM43430 silicon
family mainline Linux already recognizes generically. Transport is SDIO on
host controller instance `msc1` (`halley5_v30.dts:450-576`). Combo Bluetooth
is on a separate UART (H5 vendor extension, `uart3`), not SDIO. No
multi-stream/wider-channel capability — this is a 1x1 802.11n-class part;
5GHz is not supported (firmware NVRAM confirms `aa2g=1`, no `aa5g` field,
header comment "2.4 GHz, 20 MHz BW mode" — `scripts/build/overlay/lib/
firmware/brcm/brcmfmac43430-sdio.txt:2,12,18`). Power/reset: shared
`wifi_bt_power` fixed 3.3V regulator (`halley5_v30.dts:121-129`), a dedicated
`WL_REG_ON` GPIO (`gpd 4`) driven by custom raw-GPIO logic inside
`sdhci-ingenic.c` (not the standard `mmc-pwrseq-simple` framework, which was
tried and found unreliable on this platform — `halley5_v30.dts:551-569`), and
a host-wake GPIO (`gpe 2`) that is wired only to the inert vendor `bcmdhd_wlan`
DT node, not to the active mainline driver (§18.15). Clock: a shared 32kHz
RTC reference pin, believed shared with the chip's own sleep clock
(`halley5_v30.dts:477-491`).

### 18.2 Driver identity — **IDENTIFIED**

| Candidate driver | Present in source | Present in rootfs | Referenced by init | Matches firmware | Likely active |
|---|---:|---:|---:|---:|---:|
| `brcmfmac` (mainline in-tree) | Yes, full source (35 `.c` files, `drivers/net/wireless/broadcom/brcm80211/brcmfmac/`) | Yes, built-in (`CONFIG_BRCMFMAC=y`) | Auto-probes at kernel boot (built-in, not modprobed by any init script) | Yes — `brcmfmac43430-sdio.bin`/`.txt` shipped at the exact path/naming brcmfmac expects | **Yes** |
| `bcmdhd_101_10_591_x` / `bcmdhd_1_363_125_17` (vendor out-of-tree) | Yes, source present (`module_drivers/drivers/net/wireless/bcmdhd_*`) | No — `CONFIG_BCMDHD` and `CONFIG_BCMDHD_1_363_125_17` both confirmed unset in the authoritative, git-tracked `artifacts/buildroot-halley5-v30-image/kernel.config:4016-4017` | No | Targets a different chip (BCM43456/AP6256) — does not match this board's real CYW43438/firmware | No |
| `rtl8723ds`/`rtl8189fs` (Realtek) | Yes, source present (`module_drivers/drivers/net/wireless/realtek/`) | No (confirmed unset) | No | No — wrong chip family entirely | No |
| `bl602` | Yes, source present | No | No | No | No |
| Vendor `cywdhd`-branded driver | Not this board's active choice; see §18.4 for stock's own separate use of a same-named binary | — | — | — | Not applicable to NebulaOS |

**Conclusion**: NebulaOS's production image loads **mainline `brcmfmac`**,
built directly into the kernel image, with no competing driver active. This
was cross-verified against the authoritative, git-tracked
`artifacts/buildroot-halley5-v30-image/kernel.config` — not the stale raw
on-disk kernel `.config` inside the vendor tree, which is a leftover
pre-fix artifact and must not be trusted (see the reproducibility addendum
in §2). No further hardware evidence is required to confirm which driver is
active; this is settled from source/build-artifact inspection alone.

### 18.3 Firmware, NVRAM, and calibration — **IDENTIFIED, with one confirmed real defect**

| File | Path | Notes |
|---|---|---|
| Firmware blob | `scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.bin` | Confirmed (prior mission, FIRMWARE.md §57) SHA256-**identical** to stock's own real, board-calibrated `cyw43438-7.46.58.13.bin`, merely renamed to brcmfmac's own naming convention. |
| Board-specific NVRAM/override | `scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.txt` | Also SHA256-identical to stock's real `nvram_azw372.txt` (board id `BCM943430WLSELG`) for every RF/board-electrical field (`boardrev`, `xtalfreq`, `pa2ga0`, `maxp2ga0`, LTECX fields, `ccode=CN`, `aa2g=1`) — **this is genuinely the correct, real, board-specific calibration file, not a generic/mismatched one.** |
| MAC-address fields | same file, lines 12/49 | **Confirmed generic template placeholders** (`macaddr=00:11:22:33:44:55`, `il0macaddr=00:90:4c:c5:12:38`) — inherited unchanged from stock's own NVRAM (stock's copy carries the identical placeholder values, FIRMWARE.md §57), not a NebulaOS-introduced regression. See §18.11 for the real consequence this causes. |

No separate CLM blob is shipped (a dangling `.clm_blob` symlink from the
Buildroot `linux-firmware` package resolves to nothing — already documented
in FIRMWARE.md as non-fatal and deliberately not chased, since brcmfmac
treats a missing CLM blob as non-fatal and never re-requests it). Firmware
provenance is fully accounted for: same blobs as stock, differing only in
filename convention. **No mismatched or generic-wrong-board file exists.**

### 18.4 Stock/OpenKE Wi-Fi model — **IDENTIFIED (partially, for fields with no vendored evidence)**

Stock's driver is the vendor's own out-of-tree **`cywdhd.ko`** (Broadcom/
Cypress "DHD" family, disassembled — no `.c` source exists anywhere in this
repo, only recovered symbol names/behavior: `bcm_wlan_power_on`/
`bcm_wlan_power_off`, `dhd_bus_devreset`). Stock's SDIO host module,
`soc_msc.ko`, was proven by disassembly to be a compiled `sdhci-ingenic.c`
(the *same* driver family NebulaOS uses) — not a different Ingenic MSC
driver, correcting an earlier in-project misidentification. Stock does
**not** instantiate `mmc1` from its own reference device-tree node at all —
live forensics show that node is `status="disabled"` on stock, and stock
instead creates `mmc1` as a bare `platform_device` parameterized entirely by
`soc_msc.ko`'s own module parameters (`msc1_rst=-1 msc1_pwr=-1` — no GPIO
power/reset wired through that path at all); the real WL_REG_ON toggle
happens later, driven directly by `cywdhd.ko`/a userspace `wifi_up.sh`
script (`rfkill unblock wifi` + `ifconfig wlan0 up`), not via devicetree/
pwrseq. Firmware/NVRAM are the same underlying blobs NebulaOS reuses
(§18.3). Country/regulatory and power-save policy for stock are **UNKNOWN —
not derivable from available source** (no wpa_supplicant.conf or equivalent
was captured in the device backups). NebulaOS's choice of mainline
`brcmfmac` over stock's vendor binary is an explicit, already-documented
project decision (favor "a complete open printer" wherever a working
mainline equivalent exists), not an accidental departure — and, contrary to
this mission's own initial working assumption from an incomplete read of
the investigation history, **Wi-Fi association on NebulaOS's custom kernel
was already fully proven working end-to-end on real hardware** in a prior
mission (FIRMWARE.md §53: `iw dev wlan0 link` showing a completed
association to a real AP, DHCP-assigned address, verified bidirectional
ping) — this is existing, established evidence, correctly distinguished
here from the earlier, now-resolved investigation stages that a shallower
read could mistake for the current state.

| Wi-Fi component | NebulaOS | Stock/OpenKE | Difference | Likely impact |
|---|---|---|---|---|
| Driver | mainline `brcmfmac`, in-tree, GPL | `cywdhd.ko`, out-of-tree binary, no source | Deliberate | LIKELY_BENEFICIAL (openness/maintainability) |
| Firmware | `brcmfmac43430-sdio.bin` | `cyw43438-7.46.58.13.bin` | Byte-identical, renamed | NEUTRAL |
| NVRAM | `brcmfmac43430-sdio.txt` | `nvram_azw372.txt` | Byte-identical, renamed | NEUTRAL |
| SDIO bus width/clock | 4-bit, 100MHz via real DT node | Same electrical numbers in the vendor's reference DTS, but not the path stock actually uses | UNKNOWN_UNTIL_HARDWARE_AB | — |
| Power sequencing | Custom raw-GPIO WL_REG_ON inside `sdhci-ingenic.c`, DT+pwrseq path | Driver-orchestrated GPIO toggle inside `cywdhd.ko`/`soc_msc.ko`, bypassing DT/pwrseq entirely | Different mechanism, both now proven to work on their respective paths | NEUTRAL (NebulaOS's path is independently proven working, FIRMWARE.md §53) |
| Country/regulatory | `ccode=CN` in firmware NVRAM (inherited); no cfg80211 `country=` | UNKNOWN — not derivable | Likely same (same NVRAM) | UNKNOWN_UNTIL_HARDWARE_AB |
| Power-save policy | Default firmware PM_FAST, no override | UNKNOWN — not derivable | UNKNOWN | UNKNOWN_UNTIL_HARDWARE_AB |
| Reconnect/recovery | wpa_supplicant default reassociation + udhcpc renew/rebind + brcmfmac's own SDIO watchdog thread | Userspace `wifi_up.sh` (`rfkill unblock` + `ifconfig up`) | Different mechanism | UNKNOWN_UNTIL_HARDWARE_AB |

### 18.5 SimpleAF Wi-Fi model — **IDENTIFIED**

SimpleAF (`vendor/pellcorp-creality/k1/*`) **does not touch the Wi-Fi
driver, firmware, or NVRAM at all** — it fully assumes stock's own driver
stack is already present and working. Its only Wi-Fi-related behavior is
credential management: `k1/services/S58wpa_supplicant` watches for a
user-dropped `wpa_supplicant.conf` on a USB stick, backs up and replaces
`/usr/data/wpa_supplicant.conf`, then conditionally calls external
`wifi_down.sh`/`wifi_up.sh` scripts (not part of this vendored tree — assumed
pre-existing stock scripts) to force a reconnect. `k1/services/
S99keepalive` is a real file (`ping -c1 -W1 8.8.8.8` every 30s, explicitly
commented as an anti-deauth measure "so the phone does not deauth the
printer" for a phone-hotspot-AP scenario, not general connectivity
monitoring) — but **it is never actually installed by `installer.sh`** (no
matching `/etc/init.d` copy step, absent from the Moonraker-visible service
list), making it dead code in this vendored snapshot despite being a real
file. No power-save, regulatory, association-policy, or DHCP-behavior
changes exist anywhere in SimpleAF's `k1/` target.

| Behavior | NebulaOS | SimpleAF | Stock/OpenKE |
|---|---|---|---|
| Driver | mainline brcmfmac | Not touched — assumes stock's driver present | `cywdhd.ko` |
| Firmware | Reused stock blob | Not touched | `cyw43438-7.46.58.13.bin` |
| NVRAM | Reused stock blob | Not touched | `nvram_azw372.txt` |
| Power saving | Default on, no override | Not touched | UNKNOWN |
| Regulatory setup | `ccode=CN` (firmware), no cfg80211 override | Not touched | UNKNOWN (same NVRAM presumed) |
| Association policy | wpa_supplicant default | Only ingests a user-supplied conf | UNKNOWN |
| DHCP behavior | udhcpc default (`-t1 -A3 -b -R`) | Not touched | UNKNOWN |
| Reconnect supervision | wpa_supplicant reassoc + udhcpc renew + brcmfmac watchdog thread | Conditional bounce only on new-conf import; `S99keepalive` is real but never installed | Userspace `wifi_up.sh` |
| Boot ordering | Built-in driver auto-probes at kernel boot; `S01wifi` brings up wpa_supplicant+DHCP before UI services | `S58wpa_supplicant` runs after Klipper/Moonraker, assumes link already up | Stock's own numbering, not vendored |

### 18.6 Device-tree SDIO configuration audit

The `&msc1` node (`halley5_v30.dts:450-576`) sets `bus-width=4`,
`max-frequency=100MHz`, `non-removable`, `keep-power-in-suspend`,
`cap-mmc-highspeed`, and `sd-uhs-sdr104`, but is **missing `cap-sdio-irq`**
and uses the **wrong high-speed capability flag**:

- **`cap-sdio-irq` is absent, and this is the one property that materially
  matters.** Without it, the generic MMC core forces the SDIO IRQ thread
  onto a polling loop (10ms adaptive ceiling) and never calls the host
  driver's `enable_sdio_irq`/`ack_sdio_irq` ops at all — even though the
  generic sdhci core these ops come from is already wired in and functional
  (`sdhci_ops.enable_sdio_irq`/`ack_sdio_irq`, unconditionally set by
  `sdhci_alloc_host()`, never overridden by `sdhci-ingenic.c`). Adding this
  one DT boolean is source-plausible with **zero driver code changes**.
- **`cap-mmc-highspeed` is set instead of `cap-sd-highspeed`** — the generic
  MMC core's SDIO high-speed-switch path (`mmc_sdio_switch_hs()`) checks
  `MMC_CAP_SD_HIGHSPEED` specifically; `MMC_CAP_MMC_HIGHSPEED` is for
  eMMC/MMC cards and is never consulted for an SDIO card. **As currently
  wired, SDIO high-speed mode negotiation for the Wi-Fi chip is never
  attempted at all**, regardless of what the CYW43438 itself supports.
- **`sd-uhs-sdr104` is very plausibly dead weight**, and the DT's own commit
  history admits it was "copied verbatim from [a] reference node for exact
  fidelity" without independent verification. Two independent facts make it
  functionally inert regardless: the only regulator wired to this node
  (`wifi_bt_power`) is a fixed 3.3V-only regulator that can never satisfy a
  UHS 1.8V signaling switch, and the driver's own alternate 1.8V GPIO path
  resolves to a dead placeholder (`ingenic,sdr-gpios = <0>`) that the driver
  itself detects as invalid and bails out on.
- Absence of `wakeup-source`/`broken-cd`/`disable-wp` is a **non-issue** for
  this always-connected, non-removable combo chip: `non-removable` already
  produces the same effective card-detection behavior `broken-cd` would
  add, there is no physical write-protect line to speak of, and
  `wakeup-source` would only matter in combination with `cap-sdio-irq`
  (itself currently unused).

### 18.7 MMC/SDIO host driver audit

`sdhci-ingenic.c` is a genuine glue layer over the generic mainline
`drivers/mmc/host/sdhci.c` core (real `sdhci_alloc_host`/`sdhci_add_host`/
`sdhci_reset` calls, not a from-scratch reimplementation) — this is the same
driver family confirmed to be stock's own real msc1 driver too (§18.4).

- **SDIO in-band IRQ support exists at the generic core level and is simply
  unused**, gated only by the missing DT property above (§18.6) — no driver
  change needed to light it up, only validation that it's electrically safe
  on this board.
- **Runtime PM is nominally wired but never actually reachable — a real
  latent bug, not a design choice.** The runtime-suspend/resume callback
  bodies are no-op stubs, but more importantly, the code that would actually
  call `pm_runtime_enable()` is guarded by `#ifdef CONFIG_PM_RUNTIME` — a
  Kconfig symbol that **does not exist anywhere in this 6.6 kernel tree**
  (folded into plain `CONFIG_PM` in modern kernels; this file still uses the
  pre-3.19-era name in three spots while correctly using `CONFIG_PM`
  elsewhere in the same file). All three `CONFIG_PM_RUNTIME` blocks are
  therefore permanently dead code. This is directly corroborated by finding
  a genuine masked bug inside one of them: `sdhci_ingenic_remove()`
  references an undeclared `pdata` local inside its own dead `#ifdef` block
  — a real compile error that has simply never been triggered, because the
  guard can never evaluate true.
- **A real, separate clock-gating mechanism does exist** —
  `ingenic_mmc_clk_onoff()` performs genuine `clk_prepare_enable`/
  `clk_disable_unprepare` calls, invoked from the same manual-detect glue
  that drives Wi-Fi bring-up/bring-down — but this is a bespoke mechanism
  tied to that specific insert/remove path, not generic Linux runtime PM.
- No error-triggered clock-speed reduction/retry logic exists; none looks
  missing or unusual for this SoC family.
- UHS tuning code (`sdhci_ingenic_en_msc_tuning()` and friends) is real and
  correctly written but realistically unreachable for this SDIO chip, for
  the same reason `sd-uhs-sdr104` is inert (§18.6) — no functional 1.8V
  voltage-switch path exists in this DT+driver combination.
- DMA path uses ADMA by default, with a genuine, non-generic Ingenic erratum
  workaround (`ingenic_sdhci_adma_write_desc()` splits any transfer crossing
  a 128MB physical-address boundary into two descriptors) — real hardware
  attention, not boilerplate.
- RT-safety: the glue driver adds no locks/tasklets/raw-spinlocks of its
  own; it defers entirely to the generic sdhci core's ordinary `spinlock_t`
  and to `sdhci_add_host()`'s own `request_threaded_irq()` registration (no
  `IRQF_NO_THREAD`) — same RT-friendly-by-design posture already established
  for eMMC in the earlier camera/USB/RT analysis, since both instances share
  the same generic core.

**Concrete, source-grounded change candidates** (not implemented): add
`cap-sdio-irq;`; replace `cap-mmc-highspeed` with `cap-sd-highspeed`; fix the
three `CONFIG_PM_RUNTIME`→`CONFIG_PM` guards and the masked `pdata` bug in
`sdhci_ingenic_remove()`. No plausible change found for `sd-uhs-sdr104` or
the runtime-PM stub bodies without first deciding on an idle-power intent.

### 18.8 Wi-Fi power management audit

No explicit Wi-Fi power-save policy is set anywhere in NebulaOS source — a
full repo-wide grep for every relevant term returned zero hits outside a
single unrelated `wpa_cli status` query in a GuppyScreen helper script.
`CONFIG_CFG80211_DEFAULT_PS=y` is set in the kernel config, and brcmfmac has
no dedicated module parameter for power-save — the only real control surface
is the standard `nl80211`/`iw` `set_power_save` path (`iw` is present,
`BR2_PACKAGE_IW=y`), which nothing in this repo currently calls. Practical
effect: the firmware runs its default `PM_FAST` 802.11 power-save mode
unmodified once associated. No SDIO/MMC-level runtime PM is touched by
userspace for the Wi-Fi function specifically (out of scope here, see
§18.7 for the host driver's own — currently broken — runtime-PM story).
Later A/B variants: **A** (current default), **B** (`iw dev wlan0 set
power_save off`, directly available, no new packages needed), **C**
(a genuinely tuned intermediate mode is **UNKNOWN — not derivable**;
brcmfmac's `cfg80211` glue only exposes a binary PM_FAST/PM_OFF toggle, not
an intermediate firmware-level knob).

### 18.9 Regulatory-domain audit

No CRDA (`BR2_PACKAGE_CRDA` unset); the modern signed-firmware regulatory-db
path is used instead (`CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y` +
`wireless-regdb`, `regulatory.db`/`.p7s` baked directly into the kernel
image via `CONFIG_EXTRA_FIRMWARE` — a deliberate fix for a rootfs-not-yet-
mounted timing failure, confirmed by real boot-log evidence to now load
successfully). **No explicit `country=` directive exists anywhere at the
cfg80211/wpa_supplicant layer.** However, **the firmware's own NVRAM
hardcodes `ccode=CN`** (§18.3) — inherited unchanged from stock — meaning
the device does not ship in a "world-safe"/unrestricted regulatory state;
it ships already constrained to China's regulatory rules regardless of
actual deployment location. Per the mission's own guidance, this is not a
case for silently hardcoding a different value without a stated product
policy — but since the current state is not actually ambiguous (it's
already hardcoded, just potentially to the wrong region), the safe model is:
leave it as-is until a product policy on target markets exists, and if
NebulaOS ever adds a setup flow, surface an explicit user-selected
region/country step rather than silently assuming one. 5GHz is not
supported by this hardware at all (§18.1), so DFS-channel concerns don't
apply.

### 18.10 wpa_supplicant configuration audit

The actual runtime config is generated fresh on first boot
(`S01wifi:68-75`) and contains **exactly** `ctrl_interface=` and
`update_config=1` — no `bgscan`, `freq_list`, `bssid`, `priority`,
`ap_scan`, `fast_reauth`, `autoscan` directive, MAC-randomization directive,
or `p2p_disabled` is present (P2P support isn't even built).
`BR2_PACKAGE_WPA_SUPPLICANT_AUTOSCAN=y` is a build-time capability enable
only, distinct from an actual runtime `autoscan=` directive, which is
absent. **Judgment: this is minimal-and-correct for a stationary, single-AP
device, not a gap** — the absence of `bgscan`/roaming tuning is appropriate
(that exists to smooth roam-scans on mobile/multi-AP clients, irrelevant
here), and the absence of MAC-randomization directives is a **positive**,
not an oversight — MAC randomization would actively conflict with any
router-side static-IP/DHCP-reservation setup this device likely depends on.
No inappropriate desktop/roaming-oriented defaults were found.

### 18.11 Boot association and DHCP sequencing

`brcmfmac` is built-in and auto-probes at kernel boot, before userspace ever
runs — `S01wifi` never `modprobe`s/`insmod`s anything. The chip's own
WL_REG_ON power-sequencing (raw-GPIO toggle inside `sdhci-ingenic.c`) is
already fully resolved during kernel/board init, finishing before `S01wifi`
starts — this is a separate, already-settled concern from anything in the
init script itself.

`S01wifi`'s real sequence: seed a minimal default `wpa_supplicant.conf` if
none exists (never touches a previously-saved real config); launch
`wpa_supplicant -i wlan0 -c "$CONF"` backgrounded; `sleep 2`; call
`/sbin/ifup wlan0` once (errors suppressed). `/etc/network/interfaces`
defines `wlan0` as DHCP via BusyBox `udhcpc` with flags `-t1 -A3 -b -R` (one
discovery attempt, 3s retry spacing, background-if-no-lease, release-on-exit)
— no client-id, no hostname option.

**The "double ifup" concern from this mission's briefing does not describe
a real bug.** A second `ifup wlan0` does happen later in boot, but it comes
from Buildroot's own stock `ifupdown-scripts` package (`S40network`, `ifup
-a`), not from `S01wifi` calling itself twice. BusyBox ifupdown's own logic
skips re-configuring an interface already marked "configured" in
`/var/run/ifstate` unless forced — so this later call is a genuine no-op if
`S01wifi`'s own explicit call already succeeded, and only functions as a
real retry if the first call failed. `S01wifi`'s own header comment
describes this relationship correctly as a deliberate "belt-and-suspenders"
design, not an accident.

**The `sleep 2` is a plausible-but-unverified association-timing heuristic,
not tied to hardware timing** (the hardware WL_REG_ON/SDIO-enumeration
timing is already resolved earlier in kernel boot, well before this line
runs). It has no comment of its own justifying the exact value, and real
Wi-Fi association can legitimately take longer than 2 seconds (weak signal,
WPA2 4-way-handshake retries). An event-driven replacement is realistically
identifiable from source — polling `wpa_cli -i wlan0 status` for
`wpa_state=COMPLETED` (the CLI tool is already built and present) — but this
is an assessment only, not a recommendation to change it here.

**Neither SSH nor Moonraker nor GuppyScreen readiness gates on `S01wifi`'s
actual success** — `S01wifi` always exits 0 regardless of association/DHCP
outcome; only init.d S-number ordering sequences these services, and
GuppyScreen's own header explicitly documents running "independent of
network state entirely," degrading gracefully rather than failing outright.

**A real, source-proven candidate root cause for IP/DHCP-address drift
across reboots**: the shipped firmware NVRAM's MAC-address fields are
confirmed generic template placeholders (§18.3), and brcmfmac's own
mainline source has a **hardcoded detection for exactly this known-bad
template value** (`brcmf_default_mac_address`, matching this NVRAM's
`il0macaddr` byte-for-byte) — when detected, the driver logs "Default MAC is
used, replacing with random MAC to avoid conflicts" and generates a **fresh
random MAC address on every boot**, un-persisted, with `NET_ADDR_RANDOM` set.
No `local-mac-address`/`nvmem` device-tree override exists anywhere to pin a
stable MAC. This is a strong, fully source-proven explanation for
previously-observed DHCP/IP drift — genuinely new information from this
mission, not previously documented — and is inherited from stock's own
identical placeholder NVRAM, not a NebulaOS-introduced regression.

### 18.12 Reconnect and failure recovery audit

wpa_supplicant's own default reassociation state machine applies unmodified
(no `bgscan`/`reassociate` tuning exists to interfere with it). BusyBox
`udhcpc`'s standard renew/rebind behavior (not flag-controlled, applies
automatically once a lease exists) covers DHCP-expiry/unavailability without
any extra NebulaOS logic. **No persistent network-link watchdog exists** in
NebulaOS's overlay beyond wpa_supplicant's own reassociation logic, udhcpc's
own renew/rebind, and brcmfmac's own internal SDIO-bus watchdog kernel
thread — a repo-wide grep for watchdog/carrier/reassoc/link-monitor patterns
returned only two unrelated hits (the system-rollback watchdog and a
one-shot static-IP verification helper), neither a continuously-running
Wi-Fi supervisor. **NebulaOS's own overlay correctly avoids gating anything
critical on public-internet reachability** — a repo-wide grep for `ping`
found only the NTP-sync script, which is explicitly non-blocking/best-effort
and documented as failing silently without affecting boot; nothing
(SSH/Moonraker/Klipper/GuppyScreen/Wi-Fi reconnection) depends on internet
reachability, satisfying this mission's own explicit LAN-only requirement.
(SimpleAF's own `S99keepalive` public-host ping loop would have been the
wrong pattern to imitate for this purpose had it been active — but per
§18.5 it isn't actually installed, so this is not a live concern either.)

### 18.13 Driver logging and known failure paths

Real, in-tree source (35 `.c` files, no binary blob) confirms recognizable
failure-path logging exists: SDIO error/abort messages, a named
`BCME_SDIO_ERROR` firmware error string, firmware-crash/halt indication
comments, `BRCMF_BUS_DOWN` state-transition logging, and a dedicated
periodic `brcmf_sdio_watchdog_thread`/`brcmf_sdio_bus_watchdog` health-check
kernel thread. debugfs nodes are confirmed present in source (`reset`,
`console_interval`, plus feature/fws entries under the standard
`/sys/kernel/debug/ieee80211/phyN/brcmfmac/` path). `iw`, `wpa_cli`, and
standard `nl80211` link statistics are all available (packages confirmed
enabled). **Minimal later read-only diagnostic set** (not run here):
`dmesg | grep -i brcmf`; `iw dev wlan0 link` / `station dump`; `wpa_cli -i
wlan0 status`; `cat /sys/kernel/debug/ieee80211/phy0/brcmfmac/
console_interval`.

### 18.14 Driver replacement/upgrade evaluation

**Rejected outright, not merely "not chosen."** The vendored brcmfmac source
is genuinely unmodified mainline (a single squashed "initial release"
commit, zero board-specific patches found via a targeted grep for Ingenic/
board branding — every apparent hit was a false-positive hex literal).
Since it isn't patched, there is nothing to independently "upgrade" —
any newer brcmfmac capability would arrive only via a full kernel-version
bump (a much larger undertaking than a driver swap, out of scope here), not
a standalone driver update. More fundamentally: **there is no second
upstream driver family for this exact chip.** The CYW43438 is a Broadcom/
Cypress FullMAC SDIO part; `brcmfmac` is the one mainline driver family for
it. The in-tree sibling `brcmsmac` targets older SoftMAC PCI parts, not
applicable. The vendor's own out-of-tree BCMDHD is not a viable alternative
(wrong chip, out-of-tree, already correctly rejected for other reasons).
**Classification: NOT_COMPATIBLE** for "replace with a different driver
family" — brcmfmac is already the correct and only sensible choice.

### 18.15 Wi-Fi PREEMPT_RT interaction — updates the existing RT risk matrix

Real source confirms brcmfmac registers **no active hard-IRQ handler on
this board**: its one IRQ registration path (`bcmsdh.c`, SDIO out-of-band
host-wake) is gated on a device-tree compatible string
(`"brcm,bcm4329-fmac"`) that this board's DT never uses — the host-wake GPIO
is wired only to the inert vendor `bcmdhd_wlan` node (§18.1), so that
`request_irq` call is never reached at runtime. Zero `raw_spinlock`/
`local_irq_disable` usage found; all 14 `spin_lock_irqsave` sites guard
ordinary shared queues/rings from thread/workqueue context, not a hard-IRQ
path. brcmfmac's entire RX/TX/event/watchdog pipeline already runs via
workqueues and a dedicated kernel thread (`brcmf_sdio_watchdog_thread`) —
i.e., already in preemptible thread context on a non-RT kernel today, so
RT's main effect (forced IRQ threading) has essentially nothing to change
here. Being real, unmodified in-tree source, a `CONFIG_PREEMPT_RT=y` rebuild
simply recompiles it fresh against RT-patched locking primitives — no
separate rebuild step, vermagic concern, or binary-blob blocker exists,
unlike the scenario this mission originally worried might apply.

**Updated RT driver-risk matrix** (new rows, appended to §13's existing
table):

| Subsystem | RT risk | Evidence | Later test required |
|---|---|---|---|
| brcmfmac (Wi-Fi driver) | **Low** | No active hard-IRQ handler on this board (host-wake IRQ path unwired — DT never matches `brcm,bcm4329-fmac`); 0 raw_spinlock/local_irq_disable; RX/TX/event/watchdog pipeline already runs via workqueues + a dedicated kernel thread, unaffected by RT's IRQ-threading behavior; real in-tree source, no rebuild/vermagic blocker | Live-boot RT test to confirm Wi-Fi association/throughput unaffected once `CONFIG_PREEMPT_RT=y` is actually enabled |
| SDIO host IRQ (msc1, shared with eMMC's own already-assessed core) | Low-Medium (inherits the generic sdhci core's existing threaded-IRQ posture, already RT-friendly by design per §13's eMMC row) | `sdhci-ingenic.c` registers no IRQ of its own; `sdhci_add_host()`'s core `request_threaded_irq()` call (no `IRQF_NO_THREAD`) is the real handler, same code path already assessed for eMMC | Defer to the same live-RT-boot test already planned for eMMC/DWC2; no separate Wi-Fi-specific test needed beyond confirming SDIO throughput/stability |

### 18.16 Camera and Wi-Fi interaction

Analyzed from source/configuration only — no bandwidth numbers are invented
without representative evidence.

- **1080p30 always active (current)**: highest active MJPEG HTTP traffic
  over the same network stack Moonraker's WebSocket and Mainsail's UI share;
  no interaction with the USB-side SOF/IRQ finding (camera traffic is over
  USB to the host, then re-served over Wi-Fi by nginx/ustreamer — the two
  buses are independent transports, so the ~8,000/sec USB SOF rate is
  unaffected by network conditions and vice versa). Actual bandwidth
  consumed depends on real MJPEG frame sizes at 1080p30, which are not
  measured anywhere in this repo — **UNKNOWN_UNTIL_HARDWARE_AB**, no number
  invented here.
- **1080p15 always active**: would proportionally reduce active MJPEG
  HTTP/Wi-Fi traffic and likely reduce ustreamer's own encode-adjacent CPU
  use (though JPEG compression itself is hardware-encoded per the earlier
  camera analysis, so the CPU effect is expected to be small). **Does not
  change the ~8,000/sec USB SOF rate** — that rate is tied to
  `VIDIOC_STREAMON` being active at all (any framerate), not to the
  configured frame rate (§7 of the existing camera analysis). Visible
  frame-rate/smoothness loss is a real, direct feature cost.
- **1080p30 idle pause/resume (Variant C from §10)**: while paused, camera
  network traffic drops to zero. **Correction (2026-08-01)**: this section
  originally also claimed the USB SOF load "drops to near-zero" via the
  same §7-8 mechanism — live testing has since disproven that specific
  claim (see the correction note under §10/Variant C above; measured
  ~8,036 IRQ/sec while genuinely paused, statistically unchanged from the
  always-active baseline). The Wi-Fi-bandwidth point below is independent
  and still holds: pausing removes camera traffic from the shared Wi-Fi
  link entirely while idle, freeing that bandwidth for Moonraker/Mainsail/
  GuppyScreen traffic, with the same reopen-latency and reliability risk
  already documented in §10-11.

Later measurements to define (not invented here): network throughput,
packet loss, latency/jitter, Moonraker WebSocket responsiveness, and
Mainsail/GuppyScreen camera-panel stability, all under each of the three
camera modes combined with active Wi-Fi traffic — see §18.18's Stage D.

### 18.17 Clear expected Wi-Fi gains

```
Candidate: Wi-Fi power-save disabled (Variant B, §18.8)
BASELINE:
    Firmware runs default PM_FAST 802.11 power-save mode, unmodified,
    once associated; no measured latency/jitter/disconnect baseline exists
    in this repo to compare against.
EXPECTED_GAIN:
    SOURCE_DERIVED_ESTIMATE. Disabling power-save typically reduces wake
    latency and can improve WebSocket/streaming responsiveness at a real,
    non-zero idle-power cost, on Wi-Fi hardware generally - no evidence in
    this repo bounds the magnitude for this exact chip/firmware.
BEST_CASE:
    Lower latency/jitter for Moonraker WebSocket and camera streaming
    traffic with no meaningful idle-power cost on this board.
WORST_CASE:
    No measurable responsiveness improvement (firmware-level PM_FAST may
    already be tuned conservatively by Cypress for this exact part), plus a
    real, measurable idle-power/temperature cost with no offsetting benefit.
CONFIDENCE:
    UNKNOWN_UNTIL_HARDWARE_AB.
FEATURE_RISK:
    None to correctness; only a power/temperature trade-off.
REQUIRED_LATER_TEST:
    Stage C of §18.18 - latency/jitter/disconnect/idle-power A/B, current
    vs. power-save-off.

Candidate: Correct firmware/NVRAM (board calibration)
BASELINE:
    Firmware/NVRAM are already confirmed byte-identical to stock's real,
    board-calibrated files (§18.3).
EXPECTED_GAIN:
    None - PROVEN_FROM_SOURCE that no mismatch exists. Do not claim a gain
    here; this candidate is already correctly resolved.
FEATURE_RISK / REQUIRED_LATER_TEST:
    None - KEEP_CURRENT.

Candidate: Fix MAC-address stability (persist a real/generated MAC, §18.11)
BASELINE:
    Shipped NVRAM's macaddr/il0macaddr fields are confirmed generic
    template placeholders (inherited from stock); brcmfmac's own
    known-bad-default detection generates a fresh random MAC every boot,
    un-persisted, with no DT override to pin a stable address.
EXPECTED_GAIN:
    SOURCE_DERIVED_ESTIMATE. A stable MAC would let a DHCP server's own
    sticky-lease-by-MAC behavior (if the router has one) return the same IP
    across reboots, plausibly resolving this project's already-documented
    IP-drift-across-reboots symptom.
BEST_CASE:
    Stable IP address across reboots without any router-side static
    reservation being required to break, since the MAC itself becomes
    the stable identity DHCP servers key on.
WORST_CASE:
    The DHCP server in a given deployment doesn't do sticky-lease-by-MAC at
    all, so IP address still isn't guaranteed stable even after this fix -
    this candidate only removes one specific, source-proven cause, not a
    guarantee of overall IP stability.
CONFIDENCE:
    SOURCE_DERIVED_ESTIMATE that this is A real cause of prior drift;
    UNKNOWN_UNTIL_HARDWARE_AB whether fixing it fully resolves the
    previously observed symptom (depends on the actual router/DHCP server).
FEATURE_RISK:
    Low - a persisted or DT-pinned MAC is a standard, low-risk mechanism;
    must ensure the generated/assigned MAC stays properly random-per-device
    (not identical across every NebulaOS install) to avoid a *new*, worse
    problem (MAC collisions on shared networks).
REQUIRED_LATER_TEST:
    5 warm reboots + 3 cold boots, confirming IP address (and MAC) stability
    each time, on a real router with and without a static DHCP reservation.

Candidate: Correct regulatory country code (ccode=CN → deployment-appropriate)
BASELINE:
    Firmware NVRAM hardcodes ccode=CN, inherited unchanged from stock.
EXPECTED_GAIN:
    SOURCE_DERIVED_ESTIMATE only, and explicitly NOT recommended to silently
    change without a stated product policy per this mission's own guidance.
    A correctly-matched country code could restore full channel/legal
    transmit-power availability for the actual deployment region.
BEST_CASE / WORST_CASE:
    Best: correct legal operation and full channel availability in the
    actual deployment country. Worst: an incorrectly-chosen replacement
    value could create a real regulatory-compliance problem instead of
    fixing one - this must be a deliberate product decision, not a
    default flip.
CONFIDENCE:
    PROVEN_FROM_SOURCE that ccode=CN is currently hardcoded; the "gain" from
    changing it is a policy question, not a technical one.
FEATURE_RISK:
    Regulatory/legal, not technical - real caution warranted.
REQUIRED_LATER_TEST:
    N/A until a product region policy exists; then confirm channel/power
    availability changes as expected post-update.

Candidate: SDIO device-tree fixes (cap-sdio-irq, cap-sd-highspeed, §18.6-7)
BASELINE:
    SDIO IRQ currently polls (10ms adaptive ceiling); SDIO high-speed mode
    is never negotiated at all given the wrong capability flag.
EXPECTED_GAIN:
    SOURCE_DERIVED_ESTIMATE. In-band SDIO IRQ (vs. polling) is a well-known
    general reduction in host-CPU polling overhead and latency for SDIO
    devices; enabling real SDIO high-speed mode could improve achievable
    throughput, if the CYW43438 itself supports it at the negotiated
    voltage (unconfirmed from source alone).
BEST_CASE:
    Meaningfully lower host-side polling overhead from the SDIO IRQ fix;
    higher Wi-Fi throughput from the high-speed-mode fix, both with zero
    driver code changes (DT-only).
WORST_CASE:
    `cap-sdio-irq` doesn't work electrically on this board (the DAT1 line
    routing/signal integrity is unconfirmed from source) and destabilizes
    the link instead of improving it; the high-speed-mode fix makes no
    measurable throughput difference if the real bottleneck lies elsewhere
    (e.g. the single-stream 2.4GHz-only chip itself, not the bus).
CONFIDENCE:
    SOURCE_DERIVED_ESTIMATE that both changes are technically well-motivated;
    UNKNOWN_UNTIL_HARDWARE_AB for real-world impact and electrical safety.
FEATURE_RISK:
    Real - an SDIO DT change touches the exact subsystem eight-plus prior
    sessions spent extensive real-hardware effort stabilizing (FIRMWARE.md
    §44-53). Must be prototyped and tested with the same care, not treated
    as a trivial config tweak.
REQUIRED_LATER_TEST:
    Stage A/B of §18.18 - full boot/association/throughput/stability
    regression pass before and after, plus repeated warm/cold boot cycles,
    before considering this anything but an experimental prototype.

Candidate: Boot sequencing (the `sleep 2` in S01wifi, §18.11)
BASELINE:
    A fixed 2-second sleep between wpa_supplicant launch and DHCP/ifup,
    with no comment justifying the exact value; assessed as plausibly
    real but unverified, not proven load-bearing or provably arbitrary.
EXPECTED_GAIN:
    SOURCE_DERIVED_ESTIMATE only. An event-driven wait (poll `wpa_cli
    status` for `wpa_state=COMPLETED`) could shave boot-to-network time in
    the common case and be more robust in the slow-association case (weak
    signal, WPA2 retries) where 2s isn't actually enough.
BEST_CASE:
    Faster boot-to-network on strong-signal associations; more reliable
    DHCP timing on slow-association ones.
WORST_CASE:
    A polling-based replacement introduces its own new race/timeout-tuning
    problem, trading one heuristic for another with no net improvement.
CONFIDENCE:
    UPPER_BOUND_ONLY - the mechanism for a better wait exists
    (`wpa_cli`/`ctrl_interface` are already present), but no boot-time
    measurement of the current 2s sleep's real necessity exists in this
    repo.
FEATURE_RISK:
    Low-Medium - boot-sequencing changes interact with this project's
    already-hard-won, real-hardware-proven Wi-Fi bring-up; must be
    regression-tested, not just reasoned about.
REQUIRED_LATER_TEST:
    Stage B of §18.18 - boot-to-network timing comparison, current fixed
    sleep vs. an event-driven prototype, across multiple real boots.
```

### 18.18 Later Wi-Fi hardware A/B plan (defined, not executed)

**Stage A — Identification and baseline** (read-only): loaded module,
firmware/NVRAM version, regulatory domain, power-save state, SDIO
negotiated clock/width (if observable), RSSI, link bitrate, retry
statistics, disconnect reason — using the exact command set from §18.13.

**Stage B — Stationary Wi-Fi baseline**: time to association, DHCP, SSH,
Moonraker availability; ping median/P95/P99; packet loss; TCP up/down
throughput; reconnect-after-router-restart; reconnect-after-signal-loss.
Use a local LAN test host, never an internet speed test.

**Stage C — Power-save A/B**: A. current default vs. B. `iw ... set
power_save off` (§18.8/§18.17).

**Stage D — Camera interaction**: A. 1080p30 always-active vs. B. 1080p15
always-active vs. C. 1080p30 idle pause/resume (§18.16), each measured
under one Mainsail client + camera stream + Moonraker WebSocket traffic +
GuppyScreen active + USB storage read.

**Stage E — Weak-signal test**: only if a repeatable, safe fixed physical
test location exists; no antenna-hardware changes during the software
comparison.

**Stage F — Combined production load**: controlled print + Mainsail +
GuppyScreen + camera streaming + USB storage access + local network
traffic, with cheap rejection criteria defined before any print test.

**Additional, DT-specific validation** (beyond the mission's own template,
warranted by §18.6-7's concrete findings): a dedicated `cap-sdio-irq`/
`cap-sd-highspeed` prototype pass — full boot/association/DHCP regression,
throughput comparison, and repeated warm/cold-boot cycles — kept as its own
isolated variant, not bundled into Stage D, since it touches kernel/DT
source directly rather than just userspace policy.

### 18.19 Updated combined experiment order

Supersedes §14's camera/RT-only ordering with the full combined sequence:

```
1. Close vendor and artifact reproducibility gaps (§2, including the newly
   added stale-.config gotcha).
2. Complete Phase 11's first-boot venv validation (still pending from the
   separate production-optimization mission).
3. Resolve Wi-Fi driver/firmware identity - DONE this mission (§18.1-3);
   no further identification work is needed before prototyping.
4. Implement only source-supported Wi-Fi prototype candidates: the SDIO
   DT fixes (§18.6-7) and, separately, a persisted-MAC fix (§18.11) are the
   two highest-value, most source-grounded candidates: everything else
   (power-save, boot-sequencing, regulatory) is lower-risk userspace/policy
   tuning that can follow independently.
5. Run Wi-Fi and camera-mode A/B measurements together (§18.18 Stage D).
6. Select and freeze Wi-Fi configuration.
7. Select and freeze camera behavior (§10-11's own decision).
8. Run PREEMPT vs PREEMPT_RT A/B (§13/§18.15's combined risk matrix; DWC2
   remains the dominant risk, brcmfmac is now confirmed Low risk and does
   NOT block this experiment).
9. Freeze the final production configuration.
10. Run production Phases 13-17 once.
```

Source evidence supports this order: unlike DWC2, brcmfmac carries no
PREEMPT_RT blocker of its own (§18.15), so Wi-Fi's presence in the RT A/B
is a non-issue *for RT specifically* - but Wi-Fi's own configuration (SDIO
DT changes, MAC stability, power-save) should still be settled first simply
because it's independently valuable and because the SDIO DT changes touch
the same kernel-build cycle as any RT experiment, and re-testing both at
once would conflate two sources of change.

### 18.20 Updated final recommendation matrix

Appends to §16's existing table:

| Candidate | Expected gain | Risk | Hardware test priority | Recommendation |
|---|---|---|---|---|
| Keep current Wi-Fi stack | None (baseline) | None | — (control arm) | KEEP_CURRENT |
| Disable wireless power save | Possible latency/jitter improvement, unproven magnitude | Idle-power/temperature cost, unmeasured | Medium | IMPLEMENT_LATER_AB |
| Correct firmware/NVRAM | None - already correct | N/A | None | KEEP_CURRENT |
| Fix MAC-address stability (persist/generate-once) | Plausible fix for known IP-drift symptom | Low, if implemented carefully (must stay per-device-random) | High | NEEDS_SMALL_PROTOTYPE |
| Correct SDIO device-tree settings (`cap-sdio-irq`, `cap-sd-highspeed`) | Possible polling-overhead and throughput improvement | Real - touches a subsystem with a long, hard-won bring-up history | High, but as an isolated, carefully-regression-tested prototype | NEEDS_SMALL_PROTOTYPE |
| Improve boot association sequence (`sleep 2` → event-driven) | Marginal boot-time/robustness improvement, unproven | Low-Medium | Low-Medium | NEEDS_SMALL_PROTOTYPE |
| Improve reconnect supervision | No gap identified - existing wpa_supplicant/udhcpc/brcmfmac-watchdog layers already cover this correctly | N/A | None | KEEP_CURRENT |
| Upgrade current vendor driver | Not applicable - no vendor driver is active | N/A | None | REJECT_FROM_SOURCE_ANALYSIS |
| Replace driver with upstream alternative | None - brcmfmac already is the correct upstream choice, no alternative family exists | N/A | None | REJECT_FROM_SOURCE_ANALYSIS |
| Correct regulatory country code | Policy-dependent, not technical | Regulatory/legal if done wrong | Low until a product policy exists | BLOCKED_BY_HARDWARE_IDENTITY *(blocked on a product/business decision, not a technical unknown)* |
| Camera 1080p30 always-on | See §11 (unchanged by Wi-Fi analysis) | See §11 | See §11 | See §16 |
| Camera 1080p15 always-on | Lower active Wi-Fi bandwidth; no USB SOF-rate change | See §11 | See §11 | See §16 |
| Camera 1080p30 idle pause | No Wi-Fi bandwidth while paused; same USB-IRQ mechanism as §10's Variant C | See §11 | See §11 | See §16 |
| PREEMPT_RT with current Wi-Fi module | Wi-Fi itself adds no new RT blocker (Low risk, real in-tree source) | DWC2 remains the dominant risk, unchanged by this finding | High, after camera/USB is frozen | IMPLEMENT_LATER_AB (unchanged from §16, now confirmed not blocked by Wi-Fi) |

> **Correction (2026-08-01)**: the "Camera 1080p30 idle pause" row's "same
> USB-IRQ mechanism as §10's Variant C" no longer describes a real IRQ-rate
> reduction — live testing disproved that mechanism (see the correction
> note in §10/Variant C above). The row's other claim, "no Wi-Fi bandwidth
> while paused," is unaffected and still holds.

---

## Final required classification

```
PRINTER_POWERED_ON: NO
SOURCE_MODIFICATIONS: NONE
BUILD_PERFORMED: NO
DEVICE_MODIFICATIONS: NONE

VENDOR_PIN_STATUS: GAPS_IDENTIFIED
NEBULAOS_CAMERA_MODEL: IDENTIFIED
SIMPLEAF_CAMERA_MODEL: IDENTIFIED
STOCK_OPENKE_CAMERA_MODEL: IDENTIFIED_OR_PARTIAL

USB_INTERRUPT_SOURCE: IDENTIFIED
USERSPACE_POLLING_CAUSE: NO
USB_SOF_EXPECTED_BEHAVIOR: YES
CAMERA_HOLDS_USB_ACTIVE: PROVEN

CAMERA_IDLE_OPTIONS: ANALYZED
EXPECTED_IRQ_GAIN: RANGE_DEFINED
EXPECTED_CPU_GAIN: RANGE_DEFINED
EXPECTED_RAM_GAIN: RANGE_DEFINED
EXPECTED_LATENCY_COST: RANGE_DEFINED

PREEMPT_RT_DRIVER_RISK: ANALYZED
PREEMPT_RT_EXPECTED_BOOT_GAIN: NONE
PREEMPT_RT_EXPECTED_RAM_GAIN: NONE
PREEMPT_RT_EXPECTED_CPU_GAIN: NONE_OR_RANGE
PREEMPT_RT_EXPECTED_LATENCY_GAIN: RANGE_DEFINED
USB_BEHAVIOR_MUST_BE_FROZEN_BEFORE_RT_AB: YES

READY_FOR_CAMERA_USB_AB_EXPERIMENT: YES
READY_FOR_PREEMPT_RT_AB_EXPERIMENT: YES
READY_FOR_FINAL_PHASES_13_17: NO

LIVE_WIFI_COMMANDS: NONE

WIFI_HARDWARE_IDENTITY: PROVEN
WIFI_TRANSPORT: IDENTIFIED (SDIO, msc1)
WIFI_DRIVER: IDENTIFIED (mainline in-tree brcmfmac, built-in)
WIFI_DRIVER_SOURCE: AVAILABLE (real, unmodified mainline source, 35 .c files)
WIFI_DRIVER_PIN: CLEAN (part of the already-pinned x2000_kernel_6.6 tree; no
  separate vendor tree needed)

WIFI_FIRMWARE: IDENTIFIED (byte-identical to stock's real board-calibrated blob)
WIFI_NVRAM: IDENTIFIED (byte-identical to stock's real board-calibrated file,
  except the MAC-address fields, which are confirmed generic placeholders
  inherited unchanged from stock)
WIFI_CALIBRATION_MATCHES_STOCK: YES (RF/board-electrical fields); MAC fields
  are placeholders on BOTH stock and NebulaOS, not a NebulaOS-introduced
  mismatch
WIFI_REGULATORY_PATH: IDENTIFIED (signed regulatory.db via CONFIG_EXTRA_FIRMWARE,
  confirmed loading successfully; no cfg80211 country= override; firmware
  NVRAM hardcodes ccode=CN, inherited from stock)

SDIO_BUS_WIDTH: IDENTIFIED (4-bit)
SDIO_MAX_FREQUENCY: IDENTIFIED (100MHz)
SDIO_IRQ_SUPPORT: IDENTIFIED_AS_MISSING (cap-sdio-irq absent from DT; core
  driver support exists and is unused)
SDIO_POWER_MANAGEMENT: IDENTIFIED_AS_BROKEN (CONFIG_PM_RUNTIME guards are
  dead code — stale pre-3.19 Kconfig symbol name — masking a real compile-
  time bug in sdhci_ingenic_remove(); a separate bespoke manual clock-gating
  mechanism does work)

WIFI_POWER_SAVE_POLICY: IDENTIFIED (firmware default PM_FAST, no override)
WPA_SUPPLICANT_POLICY: IDENTIFIED (minimal, correct for a stationary
  single-AP device)
DHCP_SEQUENCE: IDENTIFIED
BOOT_WIFI_RACE: NOT_PROVEN (the suspected "double ifup" is a harmless,
  deliberate no-op belt-and-suspenders, not a race; the `sleep 2` is
  plausible-but-unverified, not proven load-bearing or provably arbitrary)
RECONNECT_POLICY: IDENTIFIED (wpa_supplicant default reassociation + udhcpc
  renew/rebind + brcmfmac's own SDIO watchdog thread; no additional
  NebulaOS-level watchdog exists or is needed)

SIMPLEAF_WIFI_MODEL: IDENTIFIED
STOCK_OPENKE_WIFI_MODEL: IDENTIFIED_OR_PARTIAL (driver/firmware/power-
  sequencing identified; country/power-save policy UNKNOWN — not derivable)
NEBULAOS_DIFFERS_FROM_STOCK: YES (driver family and power-sequencing
  mechanism differ by deliberate choice; firmware/NVRAM/calibration reused
  unchanged)

SOFTWARE_FIXABLE_WIFI_GAPS: LISTED (MAC-address stability, cap-sdio-irq,
  cap-sd-highspeed, dead CONFIG_PM_RUNTIME guards, power-save default,
  sleep-based boot sequencing)
HARDWARE_LIMITATIONS: NOT_PROVEN (2.4GHz-only/single-stream is a real,
  inherent chip limitation, not a software gap; no other hardware limitation
  was identified)
EXPECTED_LATENCY_GAIN: RANGE_DEFINED (see §18.17; magnitude UNKNOWN_UNTIL_HARDWARE_AB)
EXPECTED_THROUGHPUT_GAIN: RANGE_DEFINED (see §18.17; magnitude UNKNOWN_UNTIL_HARDWARE_AB)
EXPECTED_RECONNECT_GAIN: RANGE_DEFINED (MAC-stability fix is source-proven
  to address one real cause of IP drift; full resolution UNKNOWN_UNTIL_HARDWARE_AB)
EXPECTED_POWER_COST: RANGE_DEFINED (power-save-disable cost; UNKNOWN_UNTIL_HARDWARE_AB)

CAMERA_1080P15_WIFI_EFFECT: ANALYZED
CAMERA_IDLE_PAUSE_WIFI_EFFECT: ANALYZED

WIFI_PREEMPT_RT_COMPATIBILITY: ANALYZED (Low risk, no blocker)
BINARY_WIFI_MODULE_BLOCKS_RT_AB: NO (real in-tree source, not a binary module)

READY_FOR_WIFI_AB_EXPERIMENT: YES
READY_FOR_CAMERA_WIFI_COMBINED_AB: YES
READY_FOR_PREEMPT_RT_AB: YES
READY_FOR_FINAL_PHASES_13_17: NO
```
