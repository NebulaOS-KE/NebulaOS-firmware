# NebulaOS Display Hardware & OS Path Analysis

**Mission**: Autonomous NebulaOS Display Hardware and OS Analysis Mission - Full Offline Audit
of Panel, DPU, Framebuffer, Backlight, Touch, Power Management, and Boot Handoff.
**Date**: 2026-08-01. **Mode**: fully offline - printer powered off throughout; no SSH,
network, flash, reboot, register reads, or physical contact with the printer at any point in
this mission. **Scope**: kernel/OS-only. GuppyScreen was never modified and no
application-specific behavior was designed - GuppyScreen exists in this repo only as a
prebuilt MIPS binary (`artifacts/guppyscreen-mips/guppyscreen`), no source is vendored, so its
internal behavior (e.g. whether it calls `FBIO_WAITFORVSYNC` before panning) is genuinely
unknown from source and is flagged as such wherever relevant.

Every claim below carries one of: **PROVEN_FROM_SOURCE**, **PROVEN_FROM_ARTIFACT**,
**PROVEN_BY_COMPILE_TEST**, **SUPPORTED_INFERENCE**, **UNKNOWN_UNTIL_HARDWARE**. Full
machine-readable evidence lives under `build-work/display-analysis/*.txt`/`*.tsv` (gitignored
scratch, cited by exact file:line throughout this document and its own sources).

This mission builds on and does not reopen: [functional-gui-baseline-2026-07-25](GUI_WORKSTREAM_HANDOFF.md)
(RGB565 wire format, touch GPIO fix - both re-verified here, not re-litigated), and the alpha
integration baseline tag `nebulaos-alpha-baseline-rt-w3-p1-c2-2026-08-01` (preserved unchanged;
see the important correction in §7 about what that tag's tracked kernel.config actually
contains).

---

## 1. Hardware topology (Phase D2)

**SOC_HARDWARE**: Ingenic X2000, DPU (Display Processing Unit) at physical base `0x13050000`,
size `0x10000` (64KB register window). Two IRQ lines declared at SoC level: `IRQ_LCD` (the real
scanout/vsync/frame-done source used by this board) and `IRQ_MIPI_DSI` (unused - this board
never wires up MIPI DSI). PROVEN_FROM_SOURCE
(`vendor/x2000_kernel_6.6/kernel/kernel-6.6/module_drivers/dts/x2000/x2000.dtsi:926-936`).

**PANEL_INTERFACE**: parallel RGB (not MIPI DSI) - `LCD_TYPE_TFT` in
`panel-openke-general-480x272.c:170-171`. Driven by a from-scratch GPLv2 driver modeled on the
vendor 4.4.94 SDK's `panel-st7701s-rgb666.c`, replacing Creality's closed
`lcd_general_480x272.ko`/`soc_fb.ko`. PROVEN_FROM_SOURCE.

**FRAMEBUFFER_DRIVER**: `fb_stage/` is the stable, actually-compiled driver
(`CONFIG_FB_INGENIC_STAGE=y`); a second, more advanced `fb_stage_wip/` variant exists in the
same tree but is confirmed genuinely unbuilt
(`# CONFIG_FB_INGENIC_STAGE_WIP is not set`, `artifacts/buildroot-halley5-v30-image/kernel.config:3941`,
identical in the source arch defconfig). PROVEN_FROM_SOURCE. See §5 for what the WIP variant
actually adds and why it is not recommended as a migration target today.

**TOUCH**: NS2009 resistive touch controller on I2C4 (100kHz, implied not explicit - no
`clock-frequency` DT property anywhere), pen-down gated on `pendown-gpios` (GPIOC15/global GPIO
79, active-low) instead of the original always-zero Z1 pressure-ADC threshold. PROVEN_FROM_SOURCE,
see `build-work/display-analysis/touch-path-analysis.txt` for the full trace.

**REAL, SURPRISING, UNRESOLVED FINDING**: stock's own live extracted device tree
(`vendor/device-backups/stock-live-device-tree-decoded.dts:1659`) shows its `dpu@0x13050000`
node with `status = "disabled"`, using compatible string `"ingenic,x2000-dpu"` (different
textually from NebulaOS's `"ingenic,dpu"`) - despite stock having a visually-confirmed working
display. Stock's real display-enablement mechanism is therefore **not** captured by this DT
snapshot at all. Classification: **UNKNOWN_UNTIL_HARDWARE** - a genuinely open question, not
resolved by this offline pass, and not a contradiction of the disassembly-based timing evidence
below (a wholly separate, still-valid evidence source). See
`build-work/display-analysis/device-tree-display.txt` for full detail.

---

## 2. Panel identification & timing (Phases D3, D4)

480x272 parallel-RGB TFT. All timing values (margins/sync widths = 20 uniformly, pixclock =
10,753 KHz stored) were extracted in a prior session by disassembling the real stock closed
`.ko` binaries pulled off the live printer - PROVEN_FROM_ARTIFACT, not re-derived speculatively.
RGB565 wire format is PROVEN_FROM_ARTIFACT via a live `DC_TFT_CFG` register read (physical
`0x13059010`) from that same prior session, documented in `GUI_WORKSTREAM_HANDOFF.md`.

| Metric | Value | Basis |
|---|---|---|
| Resolution | 480x272 | PROVEN_FROM_ARTIFACT |
| htotal / vtotal | 540 / 332 | calculated from margins+sync (all =20) |
| Stored pixel clock | 10,753 KHz | PROVEN_FROM_ARTIFACT |
| Computed pixel clock (htotal*vtotal*60Hz) | 10,756.8 KHz | calculated |
| Discrepancy | 0.035% | PROVEN_FROM_SOURCE - immaterial, likely integer-truncation artifact in the original disassembled arithmetic, not investigated further |
| Effective refresh (from stored pixclock) | 59.9788 Hz | calculated |
| Frame period | 16.673 ms | calculated |
| Active-pixel duty ratio (combined H*V) | 72.82% | calculated |
| Wire format | RGB565 (`TFT_LCD_MODE_PARALLEL_565`) | PROVEN_FROM_ARTIFACT |
| Framebuffer format (in-memory) | 32bpp/XRGB8888 | PROVEN_FROM_SOURCE (`lcd_panel.bpp = 32`) |

**NEBULAOS_REFRESH_RATE**: 59.98Hz (effectively 60Hz). **STOCK_REFRESH_RATE**: identical by
construction (NebulaOS's own timing values were reverse-engineered directly from stock's
compiled binaries - there is no independent second source to diverge from).
**TIMING_MATCH**: MATCHES BY CONSTRUCTION. No panel datasheet exists anywhere in this repo, so
there is no independent ceiling to reason about overclock headroom against - see §8's REJECT
verdict on refresh-rate overclocking. Full detail:
`build-work/display-analysis/panel-timing-comparison.txt`.

---

## 3. Framebuffer memory & bandwidth (Phase D6)

Triple-buffered (`CONFIG_FB_INGENIC_NR_FRAMES=3`) at the real configured 32bpp:
3 x 522,240 bytes = 1,566,720 bytes (1.49 MiB) total. Scanout bandwidth at 32bpp/59.98Hz is
31.323 MB/s (or 15.662 MB/s lower bound if the DPU's internal read path is format-aware for
RGB565 output - UNKNOWN_UNTIL_HARDWARE which applies). **SUPPORTED_INFERENCE**: this bandwidth
is almost certainly immaterial relative to any modern embedded DDR bus (typically hundreds of
MB/s to multiple GB/s). More likely bottlenecks, if any exist, are cache-attribute behavior
(see below) and userspace software composition cost, not raw DMA bandwidth. **This analysis
does not recommend switching to an RGB565 in-memory framebuffer for memory-size reasons** - see
`candidate-ranking.tsv`'s explicit REJECT-for-memory-savings / DEFER-for-real-benefit
treatment of that idea. Full detail: `build-work/display-analysis/framebuffer-memory-analysis.txt`.

**FRAMEBUFFER_BUFFERS**: 3 (triple-buffered), allocated as one contiguous
`dma_alloc_coherent()` region (not a reserved-memory/CMA carve-out - see §7's boot-handoff
asymmetry finding). Descriptor memory (RDMA chain descriptors, composer frame/layer
descriptors) does NOT use the DMA-mapping API at all - it uses a manual MIPS
cached-to-uncached-alias trick (`devm_kzalloc()` + `virt_to_phys()` + `CKSEG1ADDR()` +
`dma_cache_wback_inv()`, `dpu_ctrl.c:2034-2070,2087-2154`) - a non-standard but functioning
vendor-BSP pattern. PROVEN_FROM_SOURCE. Userspace mmaps the framebuffer with MIPS
"Write-Accelerate" cache policy (`_CACHE_CACHABLE_WA`, since `CONFIG_FB_USING_CACHABLE` is
unset), while the kernel's own `dma_alloc_coherent()` mapping is plain uncached - two different
cache policies on the same physical memory, worth knowing if any future cache-coherency issue
ever surfaces. PROVEN_FROM_SOURCE for the code; SUPPORTED_INFERENCE for standard MIPS
`dma_alloc_coherent` semantics specifically.

---

## 4. Page-flip, VSYNC, and a real acknowledged race (Phase D7)

**PAGE_FLIP_SUPPORT**: `FBIOPAN_DISPLAY` -> `ingenicfb_pan_display()` (`ingenicfb.c:854-875`) ->
`dpu_ctrl_rdma_change()` writes `DC_RDMA_CHAIN_ADDR`/`DC_RDMA_CHAIN_CTRL` directly and
immediately - a real, working hardware register update, not a stub. X-panning is explicitly
unsupported (`-EINVAL` if `xoffset` changes); only Y-panning (frame switching via
yoffset-as-frame-index) works, the standard triple-buffer convention. PROVEN_FROM_SOURCE.

**VSYNC_SUPPORT**: `FBIO_WAITFORVSYNC` is real and correctly wired - `wait_event_interruptible_timeout()`
on a waitqueue woken from the DPU IRQ handler's `DC_SRD_START` branch (start-of-frame-scan
event), not a stub or busy-poll. A vsync-skip throttle (`CONFIG_FB_VSYNC_SKIP=9`) delivers
roughly 1-in-10 vsync events to the waitqueue by default. PROVEN_FROM_SOURCE.

**REAL, ACKNOWLEDGED, UNRESOLVED RACE**: `dpu_ctrl_rdma_change()` (the function `FBIOPAN_DISPLAY`
calls) **never waits for VSYNC or the in-flight frame's scan-out to complete** - it only checks
(as a warning, not a gate) whether the hardware's active descriptor site still matches the
*previous* frame, logs a warning if not, and proceeds to write the new address regardless
(`dpu_ctrl.c:1363-1380`). The driver's own source comment (`dpu_ctrl.c:1365`, translated from
the original) states: *"things that may change (format, size etc.) - exactly when the switch
actually takes effect is still uncertain."* PROVEN_FROM_SOURCE. Whether this is user-visible on
this specific panel/refresh-rate combination is UNKNOWN_UNTIL_HARDWARE (GuppyScreen's own
pan-display calling pattern cannot be inspected - binary-only). See `candidate-ranking.tsv`'s
MEDIUM_PRIORITY "auto vsync-gate before FBIOPAN_DISPLAY" candidate and
`hardware-test-matrix.tsv` HT-04.

---

## 5. DPU capabilities, layers, and the fb_stage_wip variant (Phase D8)

The stable driver's hardware capability far exceeds what this project's userspace actually
uses: **4 layers** (`CONFIG_FB_INGENIC_NR_LAYERS=4`), real alpha blending, scaling, z-ordering,
and writeback support all exist and are wired to sysfs attributes - but only reachable through
the composer/layer path, which nothing in this project currently drives beyond the single
`/dev/fb0` RDMA channel. YUV/tiled pixel formats exist in the register-format enum but are only
exercisable through `CONFIG_HW_COMPOSER_V4L2_M2M`, which is unset in this build - present in
registers, unreachable at runtime. Hardware dimension ceiling is 4095x4095 (12-bit
width/height fields) - far beyond this panel's 480x272. PROVEN_FROM_SOURCE. This unused
capability is noted as available for a future, separately-scoped userspace/GuppyScreen
mission - out of this mission's kernel/OS-only scope (see `candidate-ranking.tsv`'s DEFER
entry).

`fb_stage_wip/` is a full alternative driver (2394 vs 3163 lines in `dpu_ctrl.c`, a 1254-line
diff of pure additions), substantially rewriting the composer pipeline into a real linked-list
frame/layer-request queue - but its `README.en.md` is unfilled Gitee boilerplate
(`{When you're done, you can delete the content...}`), confirming it was never finished or
documented. **Critically, the one real gap found in §4 (no vsync-wait before `rdma_change`)
exists identically in both drivers** - migrating to `fb_stage_wip` would not even fix that
issue, since it only touches the composer path, not the primary RDMA/`/dev/fb0` path this
project actually uses. Classification: **REJECT** as a migration target (see
`candidate-ranking.tsv`). PROVEN_FROM_SOURCE.

**Interrupt handling**: exactly one live IRQ handler exists for this board's display path at
runtime, `dpu_ctrl_irq_handler` (`dpu_ctrl.c:428`, flags=0, no `IRQF_NO_THREAD`). Underrun
(`DC_TFT_UNDR`) and writeback-overrun (`DC_WDMA_OVER`) IRQ branches only increment a silent
debug counter today - no recovery action, no userspace-visible signal. PROVEN_FROM_SOURCE. See
`candidate-ranking.tsv`'s LOW_PRIORITY "DPU IRQ diagnostics" candidate.

---

## 6. Backlight (Phase D9) - the clearest gap found in this entire audit

**BACKLIGHT_HARDWARE**: **no software-controlled backlight exists anywhere in the compiled
tree.** Confirmed by grepping the fully-preprocessed, actually-compiled DTS for "backlight" -
zero hits. `CONFIG_BACKLIGHT_CLASS_DEVICE`/`_PWM`/`_GPIO` are all already `=y`, but with no
consuming DT node, `/sys/class/backlight/` is empty at runtime. PROVEN_FROM_SOURCE. This is not
newly discovered - already recorded as an unfixed gap in `FIRMWARE.md` sec 40; no later commit
ever adds a backlight node.

Real `pwm-backlight` DT nodes DO exist in this repo, but only in two unused MIPI reference
`.dtsi` files gated by Kconfig options that are off for this board (`CONFIG_STAGE_FW050`/
`CONFIG_STAGE_ZC50289HSHD02`). The real PWM controller driver is `pwm-ingenic-v2.c` (Kconfig
symbol `CONFIG_PWM_INGENIC_V2`, matching compatible `"ingenic,x2000-pwm"`) - the generic
mainline `pwm-jz4740.c`'s match table does not include that compatible string and could never
bind here even if referenced. This project's own `&pwm` DT override claims the WRONG pin
(GPC-1/channel1, zero consumers anywhere) instead of GPC-0/channel0 - the pin stock's own live
GPIO dump labels `backlight_pwm0` and stock's own `pwm_backlight.sh` script drives at 50kHz
(alongside a separate PC22 enable line). GPC-0 is confirmed genuinely free on this board: the
DTS's own 2026-07-23 stock-parity comment documents that the only other claim on it (an earlier
`&msc2` `ingenic,sdr-gpio` property) is itself overridden to `status="disabled"` later in the
same file. PROVEN_FROM_SOURCE.

**Real documentation contradiction found (flagged, not corrected - out of this mission's
scope)**: `docs/BOARD_CAPABILITY_MATRIX.md:15` states "Backlight | supported | PWM0-driven,
confirmed live" - this directly contradicts the compiled-DTS evidence above and
`FIRMWARE.md`'s own sec 40 entry, with no reconciling commit found anywhere. No evidence
anywhere in the repo backs the "confirmed live" claim. This row is stale/incorrect and should
be corrected in a future, separately-scoped documentation pass.

Whether the panel is currently (a) at a fixed backlight brightness with no software control
possible, or (b) tied to an always-on rail with no PWM ever applied, is
**UNKNOWN_UNTIL_HARDWARE** - it depends on the real backlight circuit downstream of
GPC-0/GPC-22, never captured in this project's device tree. See §9's DISPLAY-P1 prototype and
`hardware-test-matrix.tsv` HT-01/HT-09 for the read-only-first investigation plan. Full detail:
`build-work/display-analysis/backlight-path-analysis.txt`.

---

## 7. Blanking, suspend/resume, and boot handoff (Phases D10, D11, D12, D15)

**BLANKING_IMPLEMENTATION**: `fb_blank()` collapses all four non-`UNBLANK` modes (`NORMAL`,
`VSYNC_SUSPEND`, `HSYNC_SUSPEND`, `POWERDOWN`) into one identical suspend path
(`ingenicfb_blank()`, `ingenicfb.c:898-910`) - there is no distinction between "light sleep" and
"deep powerdown" today. PROVEN_FROM_SOURCE.

"Blank" stops RDMA scanout (`dpu_ctrl_rdma_stop`, a real quick-DMA-halt) and gates both DPU
clocks (`gate_lcd`/`div_lcd`) - it does NOT touch any panel GPIO (`panel_ops->disable()` is
never called from this path, only from module unload) and does NOT lose framebuffer memory
contents. "Unblank" fully re-programs DPU timing/config registers from scratch and - a real,
previously-undocumented finding - **re-pulses the panel reset GPIO (PB16) on every single
unblank/resume event**, not just first boot (`panel_ops->enable()`: 10ms low, 10ms high pulse,
inside `dpu_ctrl_resume()`'s call chain). System suspend/resume is proven to be the **exact
same code path** as userspace-triggered blanking (`ingenicfb_suspend`/`_resume` just call
`fb_blank(FB_BLANK_POWERDOWN/UNBLANK)`) - so a resume from suspend also re-pulses reset.
Whether this causes any visible glitch/flash on real hardware is UNKNOWN_UNTIL_HARDWARE.
PROVEN_FROM_SOURCE for the code path. Full detail:
`build-work/display-analysis/power-management-analysis.txt`.

**BOOT_HANDOFF**: no bootloader source tree is vendored anywhere in this repo (only an opaque,
already-flashed blob), so the true panel/framebuffer continuity at the U-Boot-to-kernel
transition is UNKNOWN_UNTIL_HARDWARE. A real, documented incident (`FIRMWARE.md:2215-2247`)
captured a static U-Boot splash persisting during an early boot *failure*, explicitly caveated
at the time as inconclusive without a serial console - UART was subsequently wired up, but no
later doc entry re-ran this same observation on a *successful* boot with UART instrumented.
`docs/NEBULAOS_PRODUCTION_PERFORMANCE_ANALYSIS.md:97-104` independently confirms every
bootloader-stage timing milestone is explicitly marked "Unmeasured."

**Real asymmetry found**: camera/ISP/rotate DT nodes (`&felix`, `&helix`, `&ispcam0/1`,
`&rotate`) all reference the board's `reserved_memory` carve-out via `memory-region =
<&reserved_memory>` - the DPU node's board override (`&dpu { status = "okay"; };`) does **not**.
The display framebuffer is allocated dynamically at probe time via ordinary
`dma_alloc_coherent()`, not a static boot-reserved region. Combined with `CONFIG_CMA` being off
(`CONFIG_DMA_CMA` therefore unreachable), the framebuffer's physical-contiguity guarantee rests
entirely on that allocation succeeding early in boot before memory fragments -
SUPPORTED_INFERENCE that this is a plausible (not proven) contributor to any first-boot display
flakiness. Full detail: `build-work/display-analysis/boot-handoff-analysis.txt`.

**Important correction discovered during this mission (kernel-config audit, Phase D17)**: the
git-tracked, currently-shipped `artifacts/buildroot-halley5-v30-image/kernel.config` has
`CONFIG_PREEMPT_RT` **unset** (plain `CONFIG_PREEMPT=y`) - even at the exact commit tagged as
the RT-inclusive alpha integration baseline (`nebulaos-alpha-baseline-rt-w3-p1-c2-2026-08-01`).
Independently re-verified this session directly against git history (`git show
HEAD:artifacts/.../kernel.config`), not merely inferred. A separate, git-ignored experimental
package (`build-work/deploy-packages/NEBULAOS-ALPHA-MAX-RT-*`) does carry `CONFIG_PREEMPT_RT=y`
and was proven live in a genuine prior A/B experiment. This does **not** reopen or modify the
alpha-baseline tag - it clarifies which file is authoritative for "what currently ships" (plain
PREEMPT) vs. what was tested experimentally. See
`build-work/display-analysis/kernel-config-display.txt` for full detail.

---

## 8. PREEMPT_RT display-path risk (Phase D16)

Framed as "if/when PREEMPT_RT is ever enabled" given §7's correction. The sole live display IRQ
(`dpu_ctrl_irq_handler`) has no `IRQF_NO_THREAD` and would be force-threaded under RT; its one
lock is a plain (non-raw) `spinlock_t`, only ever taken from within that one handler - no
deadlock class exists, only latency/jitter exposure (a delayed IRQ-thread wakeup could delay a
vsync-driven composer restart, risking a dropped/torn frame under scheduling pressure).
**PREEMPT_RT_DISPLAY_RISK: Low-to-Medium**, SUPPORTED_INFERENCE (deadlock-safety is
PROVEN_FROM_SOURCE; the actual jitter magnitude needs a live RT boot to measure - see
`hardware-test-matrix.tsv` HT-08). No documented hard real-time deadline exists in-tree for
this DPU IRQ (unlike DWC2's explicit 125us USB-isoc comment from the prior camera/USB/RT
analysis). NS2009 touch has no IRQ at all (pure polling), so RT force-threading is moot for it;
the PWM driver has no IRQ or locking of any kind. Full detail:
`build-work/display-analysis/preempt-rt-display-analysis.txt`.

---

## 9. Compile-only prototype: DISPLAY-P1 (backlight class)

One functional idea, never enabled as a baseline default, never deployed. Toggle script:
`scripts/build/display-backlight-variant.sh <S0|S1>` (S0 = today's default, no backlight node;
S1 = adds a real `pwm-backlight` DT node on `pwms = <&pwm 0 20000>` [channel 0, 20000ns/50kHz
period, matching stock's real wiring] and repoints the existing `&pwm` override from the unused
channel-1 pin to the real channel-0 pin). Idempotent, same pattern as the project's existing
`preempt-variant.sh`/`wifi-sdio-variant.sh`. 8 offline tests
(`tests/display-backlight-variant-tests.sh`), all passing, verify: clean S0 baseline, correct
single-node addition under S1, correct pin repoint, correct channel/period, idempotent
re-application, and clean reversion back to S0.

**Compile-test honesty note**: a full `make dtbs` build via the real vendor kernel build tree
(`vendor/buildroot-x2000/output/build/linux-custom`) was attempted to earn a genuine
`PROVEN_BY_COMPILE_TEST` classification, but that tree is a pre-existing, root-tainted local
build cache (gitignored, regenerated by the project's own `03-build-kernel-and-rootfs.sh`) and
the attempt failed on a permission error unrelated to this prototype, incidentally deleting a
locally-generated `include/generated/autoconf.h` in that same gitignored cache (regenerated
automatically by the next real build - no tracked file was affected, confirmed via `git
status`). A lighter cpp+dtc syntax check was then attempted with a stubbed `generated/autoconf.h`
in an isolated scratch directory (no tracked or cached files touched) and failed only on a
pre-existing, unrelated macro (`INGENIC_DMA_TYPE` in a config-conditional SPI node) that
requires the real kernel `.config` to expand correctly - not a defect in this prototype's own
added lines. **Given this, DISPLAY-P1's DT syntax is validated by exact structural
pattern-matching against the two already-compiled MIPI reference `pwm-backlight` nodes
elsewhere in this same file (identical `compatible`/`pwms`/`brightness-levels`/
`default-brightness-level` property shape) and by the 8 passing script/idempotency tests, but
NOT by a completed full kernel `make dtbs` in this session** - classify the DT syntax itself as
SUPPORTED_INFERENCE (well-justified, pattern-matched, not independently compiled end-to-end)
rather than overclaiming PROVEN_BY_COMPILE_TEST. See
`docs/NEBULAOS_DISPLAY_OFFLINE_IMPLEMENTATION_PLAN.md` for the acceptance criteria a real build
must pass before this prototype could ever be considered for production.

No other prototypes (P2-P5) were built this session - every other candidate identified in
`candidate-ranking.tsv` either has a hard prerequisite on DISPLAY-P1 landing first
(backlight-only blanking, deep powerdown), needs a live measurement to justify the engineering
cost before writing code (vsync-gate, IRQ-driven touch, boot-handoff memory-region), or is a
REJECT (see §5, §8, and the ranking file for full rationale per candidate).

---

## 10. Summary tables

**TOP_5_OS_DISPLAY_IMPROVEMENTS** (see `build-work/display-analysis/candidate-ranking.tsv` for
the full list with rationale):
1. Kernel backlight-class + DT integration (DISPLAY-P1) - HIGH_PRIORITY
2. Auto vsync-gate before `FBIOPAN_DISPLAY` - MEDIUM_PRIORITY (DEFER pending a live tearing test)
3. IRQ-driven touch pen-down - MEDIUM_PRIORITY (DEFER pending a live latency measurement)
4. Backlight-only blanking state - MEDIUM_PRIORITY (hard prerequisite: DISPLAY-P1)
5. DPU IRQ diagnostics (surface underrun/overrun counts) - LOW_PRIORITY, low risk, aids future
   live qualification

**COMPILE_ONLY_PROTOTYPES**: 1 (DISPLAY-P1), never enabled by default, never deployed.

**TESTS_RUN**: 8 (`tests/display-backlight-variant-tests.sh`). **TESTS_PASSED**: 8.
**TESTS_FAILED**: 0 (one real bug - unescaped BRE metacharacters in the toggle script's own
marker-strip logic, causing non-idempotent duplicate blocks - was found and fixed during this
session before being counted as passing).

**PRINTER_CONTACTED**: NO. **PRINTER_MODIFIED**: NO. **ALPHA_BASELINE_CHANGED**: NO (tag
untouched; the PREEMPT_RT finding in §7 is a documentation clarification about what that tag's
tracked kernel.config already contained, not a change to it).

See `docs/NEBULAOS_DISPLAY_OFFLINE_IMPLEMENTATION_PLAN.md` and
`docs/NEBULAOS_DISPLAY_LIVE_QUALIFICATION_PLAN.md` for next steps, and
`build-work/display-analysis/hardware-test-matrix.tsv` for the exact read-only-first test
sequence required before any powered-on work begins.

---

## 11. Powered-on follow-on mission (2026-08-01) - live confirmation + genuine compile tests

A follow-on mission performed the read-only live investigation this document's §10 called for,
plus prepared and genuinely compile-tested two additional prototypes (DISPLAY-V1, TOUCH-I1)
beyond DISPLAY-B1 (renamed from DISPLAY-P1 for consistency with that mission's naming). Full
detail: `docs/NEBULAOS_DISPLAY_LIVE_READ_ONLY_REPORT.md`,
`docs/NEBULAOS_DISPLAY_PROTOTYPE_READINESS.md`, and the updated
`docs/NEBULAOS_DISPLAY_OFFLINE_IMPLEMENTATION_PLAN.md`.

**Live confirmation of every key §6/§7/§8 finding**: identity confirmed on the real printer
(`192.168.1.243`, CID-derived MAC exact match, custom `rootfs2` slot). No backlight DT node or
class device exists live (`/sys/class/backlight/` empty), independently corroborated by a boot-
log line neither prior pass had quoted: `openke_panel: invalid gpio vdd_en: -2`. Touch has zero
IRQ lines anywhere in the live `/proc/interrupts` table (poll-only, confirmed system-wide, not
just via the pendown GPIO). The DPU/vsync IRQ measured ~60.3Hz over a live 10-second sample,
matching the ~59.98Hz offline baseline. `/sys/kernel/realtime=1` confirms PREEMPT_RT is genuinely
active on the currently-running image (the NEBULAOS-ALPHA-MAX-RT deployment from the
pre-qualification mission, left running).

**A real correction to this document's own §4/§8**: re-reading `ingenicfb_set_vsync_value()`
directly while designing DISPLAY-V1 shows `wake_up_interruptible(&fbdev->vsync_wq)` fires
unconditionally in both branches of its skip-map decision - the skip-map only throttles which
events get a precise timestamp recorded for `FBIO_WAITFORVSYNC`, not which ones wake waiters.
The "roughly 1-in-10 vsync events delivered to the waitqueue" characterization in this document's
earlier text was **incorrect** and should be read as corrected by this section.

**All three prototypes now have genuine `PROVEN_BY_COMPILE_TEST` status** (upgraded from
`SUPPORTED_INFERENCE`), each verified via a real `docker run --user root ... make` invocation
against the actual vendor kernel build system with real generated headers - not a syntax-only
check:
- **DISPLAY-B1**: a real `make dtbs` produced `halley5_v30.dtb`; decompiling it back confirms
  `nebulaos_backlight { compatible="pwm-backlight"; pwms=<&pwm 0 20000>; ... }` is present
  exactly as designed.
- **DISPLAY-V1**: `module_drivers/drivers/video/fbdev/ingenic/fb_stage/ingenicfb.o` compiled
  cleanly with the new Kconfig option selected - zero errors, zero warnings.
- **TOUCH-I1**: `drivers/input/touchscreen/ns2009.o` compiled cleanly with its new Kconfig
  option selected - zero errors, zero warnings.

**Readiness classifications** (full rationale in `NEBULAOS_DISPLAY_PROTOTYPE_READINESS.md`):
- **DISPLAY-B1: BLOCKED_PENDING_HARDWARE_PROOF.** Compile now proven, but the real electrical
  backlight-circuit behavior downstream of GPC-0/GPC-22 remains UNKNOWN_UNTIL_HARDWARE (this
  kernel's debugfs GPIO/pinctrl interfaces are absent, so even live investigation could not read
  the raw pin state) - the mission's own "real hardware path proven" bar is not yet met.
- **DISPLAY-V1: READY_FOR_ISOLATED_DEPLOYMENT.** Every stated criterion is met: vsync IRQ
  semantics proven (live + source), locking reviewed, bounded timeout, safe fallback, compile
  succeeds, 10/10 tests pass, only the pan-display path changes. A full authoritative
  W3+R1+DISPLAY-V1 build was produced and packaged (see the prototype readiness doc for the
  package location and SHA256SUMS).
- **TOUCH-I1: BLOCKED_PENDING_HARDWARE_PROOF.** Per the mission's own explicit rule ("when
  wiring remains ambiguous, mark it blocked") - the exact GPIO79 IRQ trigger polarity was never
  proven (deliberately worked around via a both-edges request, not confirmed), and this kernel's
  debugfs gap prevented a live pinctrl/GPIO read. The design's graceful, self-limiting fallback
  makes it safe to test regardless, but formal readiness requires the hardware proof step first.

**A real process mistake, disclosed in full**: while preparing DISPLAY-V1/TOUCH-I1, the vendor
kernel checkout was edited directly while a background build against that same checkout was in
flight, twice. `05-final-build.sh`'s own source-tree fingerprint check correctly detected this
both times and refused to trust the resulting artifacts - both times the already-copied tracked
`artifacts/buildroot-halley5-v30-image/*` snapshot files were reverted via `git checkout`
immediately upon discovery, and the build was re-run against a stable, untouched tree
afterward. See the offline implementation plan for the full account.

**PRINTER_CONTACTED (this follow-on mission)**: YES (read-only SSH only - no writes, no flash,
no reboot, no register writes; see the live read-only report for the full command list and
safety-check gate). **PRINTER_MODIFIED**: NO. **ALPHA_BASELINE_CHANGED**: NO (the tag remains
untouched; a fresh W3+R1 build was produced for validation purposes and its tracked
`kernel.config`/`halley5_v30.dts`/fragment snapshots now more accurately reflect that
composition than the possibly-stale copies checked in previously - left as an uncommitted,
disclosed local change for the user to decide whether to commit separately, since refreshing
the alpha-baseline's own artifact snapshot is outside this display mission's own scope).
