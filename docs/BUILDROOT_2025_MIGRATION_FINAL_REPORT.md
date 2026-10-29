# NEBULAOS_BUILDROOT_2025_MIGRATION — final report

> **`MISSION_STATUS=PARTIAL`.** The migration is functionally complete and the
> candidate builds green, but §27 reproducibility is **not proven** and the
> final candidate SHA has **not been built at all**. See REPRODUCIBILITY and
> BUILD below for exactly what is and is not evidenced.

## MISSION RESULT

```
MISSION=NEBULAOS_BUILDROOT_2025_MIGRATION
MISSION_STATUS=PARTIAL
BRANCH=buildroot-2025.02-migration
HEAD=9d5ca86bc39460a2258d914c60c5da083e633848
WORKTREE_CLEAN=YES
CANONICAL_WORKSPACE=untouched, main @ fd4a365, clean, single worktree
BASE=fd4a365e9cc2b7dd478547bde00a272decee220e
COMMITS=11
```

## PLATFORM

```
BUILDROOT=2025.02.18  (buildroot/buildroot @ d030e36bbc9669230c015be971b14b6e062cfdde)
GCC=13.4.0
BINUTILS=2.43.1
GLIBC=2.41-161-g5dd252cf1d113644b3679f5a158e9ef20217865e  (Buildroot default)
PYTHON=3.12.14
OPTIMIZATION=-Os   (BR2_OPTIMIZE_S=y, plus an independent -Os in the app-stack cross-compile)
ARCH=mipsel / xburst / MIPS32R2 / OABI32 / FPXX / legacy NaN
```

All five toolchain/arch values were read back from the **built artifacts**, not
from the configuration that requested them.

## PARITY

```
OLD_BUILDROOT_CAPABILITIES_INVENTORIED=YES
UNACCOUNTED_CAPABILITIES=0
PARITY_GATE=PASS   (tests/buildroot-defconfig-parity-tests.sh: 240 assertions, 0 failures)
```

Of 546 symbols set in the old configuration, **3** are absent from 2025.02.18:
two are hidden capability flags for packages that were never enabled (midori,
mongrel2), and `BR2_TARGET_ROOTFS_EXT2_REV` is a derived value whose selector
`BR2_TARGET_ROOTFS_EXT2_2r1` still exists and is still set. All **264**
previously-enabled packages still exist; **194** real packages are asserted
enabled by value in the gate (the other 70 are auto-derived capability flags).

Full classification: `docs/BUILDROOT_2025_MIGRATION_PARITY.md`.

### Intentional differences

| Change | Why |
|---|---|
| GCC 12.3.0 → 13.4.0 | mission target; also the 2025.02.18 default |
| binutils 2.40 → 2.43.1 | 2.40 was **removed** upstream; its symbol survives only as a legacy stub that selects `BR2_LEGACY`, and Buildroot refuses to build in that state |
| Python 3.11.6 → 3.12.14 | mission target |
| `BR2_GLOBAL_PATCH_DIR` dropped | its only content was three kernel patches **proven never applied** (`OVERRIDE_SRCDIR` ⇒ rsync, not extract+patch; `.stamp_rsynced` present, `.stamp_patched` absent) |
| `BR2_ROOTFS_POST_IMAGE_SCRIPT` dropped | inherited `board/qemu/post-image.sh` cruft |
| matplotlib 3.4.3 → 3.10.0, numpy from stock | retires a vendored `.mk` overwrite and a cp311 wheel |

Nothing was removed for size or tidiness (§19).

## PYTHON

- **Remaining `python3.11` references: 0 in executable code.** What remains are
  historical mentions inside comments and in `FIRMWARE.md`/`docs/` narrative,
  describing what the old build did.
- Target paths and the CPython ABI tag are **derived**, never written down:
  `sysconfig`/`EXT_SUFFIX` at build time, and 06-verify discovers the
  interpreter from the image.
- **Klipper**: builds and ships; `c_helper.so` present; venv provisioned.
  Python 3.12 runtime behaviour is **NOT TESTED** (needs hardware).
- **Moonraker**: builds and ships. `importlib_metadata` and `zipp` retained —
  `moonraker/utils/source_info.py` imports the **backport**, which stdlib
  `importlib.metadata` does not satisfy.
- **Native extensions**: 128 modules, **all** `cpython-312-mipsel-linux-gnu`,
  gated by 06-verify. `streaming_form_data/_parser` confirmed ELF 32-bit MIPS32
  rel2. Zero x86-64 objects in the target.
- **48/48** Python distributions from the old image are accounted for.

## VENV

Scope corrected mid-mission: NebulaOS is unreleased and `/usr/data/nebulaos` is
NebulaOS-owned, so there is no deployed 3.11 venv to migrate. What ships is
**interruption-safe, idempotent provisioning** of fresh 3.12 venvs.

- **Detection**: `venv_is_usable` requires the interpreter to exist, be
  executable, actually run, have a `pyvenv.cfg`, and satisfy the component's
  import smoke test. It replaces `[ -x bin/python3 ]`, which treated a
  half-created environment as finished.
- **Atomicity**: `swap_venv_into_place` renames the old aside, moves the new in,
  then deletes — removing a window in which the machine had **no** environment
  and a power cut was unrecoverable.
- **Recovery**: `recover_torn_venv` triggers on ".old exists AND the env is
  unusable", never on the env being absent — `S02nebulaos-namespace` recreates
  it empty before S04 runs, so an absence test could never fire.
- **Tests**: `tests/venv-platform-migration-tests.sh`, 14 cases, sourcing the
  real library. They caught a POSIX shell scoping bug (all three helpers used
  `_envdir`, so the callee clobbered its caller and recovery addressed
  `<env>.old.old`) that would have silently failed to restore the only
  surviving copy of a user's environment.
- **Future**: version-aware migration is a documented requirement for the first
  post-release Python ABI transition — `docs/NEBULAOS_PLATFORM_APP_BOUNDARY.md`.

## APP UPDATE ARCHITECTURE

Documented, not implemented (§16/§17 asked only that this migration not block
it): CI-built ABI-matched wheels, staged and atomically activated per-app venvs,
source and venv rolled back as a pair. Platform stays firmware/A-B-owned; an
update needing a newer platform must fail cleanly rather than mutate the OS.

## BUILD

```
06-verify   264 OK, 1 MISS, 0 FATAL   (at 8bbe8eb; the MISS is fixed in c6bf193, unbuilt)
candidate gate   17 PASS / 0 FAIL     (at 8bbe8eb)
regression suites   67 PASS / 11 FAIL / 2 SKIP   (80 suites)
```

The 11 failures are **pre-existing and environmental** — identical set on a
pristine `fd4a365` clone run under the same conditions (they need `vendor/`
trees a fresh clone lacks; `plr-tombstone-tests` writes to `/tmp`). **Zero
regressions.** The 2 SKIPs are reported as SKIP, never PASS.

### Defects found and fixed during the migration

1. **Stage 04 wrote the app payload to the wrong directory** (mine). Would have
   produced a clean build with **no printer software in the image**.
2. **`contourpy` shipped a host-tagged extension.** Correct MIPS object,
   filename CPython cannot import ⇒ matplotlib broken at runtime from a *green*
   build. Upstream bug; fixed via `local.mk`, no upstream file touched.
3. **Seven test suites regressed** by a hardcoded library path — caught only by
   comparing the full suite against the baseline.
4. **POSIX shell scoping bug** in the venv helpers (above).

## ARTIFACTS

See the reproducibility section — artifact hashes belong to the two clean builds
of the final candidate SHA, not to any intermediate build.

## REPRODUCIBILITY

```
IMAGE_REPRODUCIBILITY=NO
REASON=BLOCKED - neither build of the pair was run
FINAL_CANDIDATE=tip of buildroot-2025.02-migration (pushed, UNBUILT)
LAST_ATTESTED_BUILD=8bbe8eb85d560bdbf84dfc0bed9468cf066aa32e  (an ancestor, not the candidate)
```

This is not a claim that reproducibility failed. It is a statement that **the
two builds were never run**, so nothing about reproducibility is known either
way. Build A was launched twice and terminated by an API session rate limit
before the build began; the second attempt did not get past its identity gate.
No workspace exists for `9d5ca86`, and no partial state was left behind.

### What has actually been built

The only SHA on this branch with a build attestation is **`8bbe8eb`**, four
commits back. It passed cleanly: exit 0, 06-verify `OK=264 MISS=1 FATAL=0`,
candidate gate 17/0, GCC 13.4.0 / binutils 2.43.1 / Python 3.12.14, and the
application stack confirmed present in the shipped `rootfs.squashfs`.

```
SOURCE_HEAD=8bbe8eb85d560bdbf84dfc0bed9468cf066aa32e
XIMAGE_SHA256=d139733af462d425eccacc22dcd645541058ea528ea4456b7b5cfd82c14813ff   5505088
ROOTFS_SQUASHFS_SHA256=a2f819044d907e8fa9076ff15679b17d27cb3d4280e4e8150fb4eb6f1a412d1c  129503232
BUILDER_DIGEST=sha256:a6ba57c69fa1ea630b037a1d1f55cf0c044a7f5a403bde9b155ea54bca1cceba
SOURCE_DATE_EPOCH=1790534256
```

**Those hashes belong to `8bbe8eb`, not to the candidate, and must not be used
to qualify `9d5ca86`.** Two later commits change the image or its verification:

| Commit | Changes the image? |
|---|---|
| `c6bf193` stop staging the defconfig into the upstream tree | No — but it is what clears the single `MISS=1`, so `MISS=0` is **expected, not demonstrated** |
| `b80bcd6` venv helper library resolution in S04/S05 | **Yes** — both scripts are in the rootfs overlay |
| `702ae67`, `9d5ca86` | No — docs and a build-independent tool |

So the candidate carries one unbuilt overlay change and one unverified
pristineness fix. Neither is speculative in intent, and both are covered by
tests that pass, but neither has been through a real build.

### To complete this, sequentially and on the same SHA

Take the branch tip and use **the same SHA for both builds**. Do not hardcode a
SHA from this document: docs-only commits move the tip, and because
`SOURCE_DATE_EPOCH` is derived from the commit, they change the artifact hashes
without changing behaviour. What matters is that A and B are the same commit.

```
SHA=$(git ls-remote https://github.com/NebulaOS-KE/NebulaOS-firmware.git \
        refs/heads/buildroot-2025.02-migration | cut -f1)

tools/run-nebulaos-build.sh --candidate "$SHA"     # Build A
tools/run-nebulaos-build.sh --candidate "$SHA"     # Build B   (after A finishes)
```

Never concurrently: both bind-mount the Buildroot download cache at
`$HOME/.cache/nebulaos/buildroot-dl`. Then compare `XIMAGE_SHA256`,
`XIMAGE_SIZE`, `ROOTFS_SQUASHFS_SHA256` and `ROOTFS_SQUASHFS_SIZE` between the
two attestations. Identical on all four ⇒ `IMAGE_REPRODUCIBILITY=PROVEN`.

Expect `06-verify` to report `MISS=0` and `check_vendor_pin buildroot-x2000` to
show exactly `?? local.mk`. If either differs, that is a finding.

Caveat to carry into the proof: the download cache is **not** freshened per run.
Every tarball is sha256-verified on use, so this is not a correctness risk, but
"fresh clone" does not mean "fresh downloads", and the proof covers
build determinism given identical inputs — not input acquisition.

**Reproducibility must never be inferred from an incremental build, from the
two earlier `fd4a365` builds, or from `8bbe8eb` passing.**

## PERFORMANCE

**No runtime performance measurement was taken. RAM, CPU, boot time and latency
are NOT TESTED.**

Changes that could plausibly affect runtime, listed without any claim about
direction or magnitude: GCC 12.3.0 → 13.4.0 code generation; Python 3.11 → 3.12
interpreter; matplotlib/numpy version jumps; rootfs 99 758 080 → 129 503 232
bytes (+29.8%).

The size increase is **not** a prediction of higher RAM use: squashfs is
demand-paged, and 46 MB of the growth is `matplotlib/tests`, which is never
imported.

Qualification command (read-only, operates nothing):

```
tools/qualification/nebulaos-qualify.sh > baseline.txt   # current firmware
tools/qualification/nebulaos-qualify.sh > candidate.txt  # candidate
diff -u baseline.txt candidate.txt
```

It distinguishes a real value, `ABSENT`, `UNAVAILABLE` and `FAILED`, and never
reports an untaken reading as 0. Interrupt counters are cumulative counts, not
rates — difference two captures against `UPTIME_SECONDS`.

## DEFERRED CLEANUP (none actioned)

- `matplotlib/tests` — 46 MB uncompressed, never imported. Largest single item.
- `BR2_DOWNLOAD_FORCE_CHECK_HASHES` — blocked only by the kernel's custom-version
  tarball having no hash file; 234 of 236 download artifacts are already hashed.
- `python-wheel-target` — shipped for parity; nothing imports it.
- libqmi, libgudev, strace, rsync, git, usbutils, eudev, libcurl, unused
  `brcmfmac` firmware variants, OpenSSL legacy crypto.
- LTO, GCC 14, USB interrupt optimisation, daemon trimming.

## HARDWARE

```
HARDWARE_QUALIFIED=NO
HARDWARE_TESTING=NOT_ATTEMPTED
```

Nothing contacted the printer. Procedure prepared in
`docs/BUILDROOT_2025_ATTENDED_HARDWARE_TEST_PLAN.md`.
