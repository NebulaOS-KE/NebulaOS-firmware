# Build reproducibility — what is established, what is not

This is the canonical record. Earlier statements about build reproducibility in
this repository were wrong in a specific, repeated way, and several places
restated the error independently. **If you find another copy of a retracted
claim, correct it and point it here.** Do not add a count of how many copies
remain: successive passes each asserted they had found the last one and each
was wrong.

```
GUPPYSCREEN_REPRODUCIBLE_FOR_A_FIXED_PIN    YES (measured, three builds)
FULL_GUPPYSCREEN_BYTE_REPRODUCIBILITY       NOT ESTABLISHED
IMAGE_REPRODUCIBLE (xImage, rootfs.squashfs) YES for one commit + one build-container digest
                                            (measured: release 1.0.2, two builds on one host)
IMAGE_REPRODUCIBLE across hosts             NOT ESTABLISHED (never measured)
IMAGE_NON_DETERMINISM_ROOT_CAUSE            ESTABLISHED (measured, 15 causes)
```

The earlier value of `IMAGE_NON_DETERMINISM_ROOT_CAUSE` was `NOT ESTABLISHED`,
and section 3 below said so at length; it is kept as the record of the
measurement before the fix. Every cause has since been read out of the
differing bytes and fixed (section 3b).

`IMAGE_REPRODUCIBLE` is measured, not inferred from the causes being fixed.
Release 1.0.2 (firmware `3bdf3ff`) was built twice, as Build A and Build B
(`tools/run-nebulaos-build.sh`, one fresh workspace per run, the same
build-container digest `sha256:a6ba57c6…`), on 2026-11-09. Both produced the
same bytes:

```
xImage           14a47aa8c0e1b3da0aa148278e6e164a6bf571ad189d4f6ec0b3757616e8f160
rootfs.squashfs  df65c72487389f84017b67b1d6320e9e5728d0b7fe3ab7e22c2e01707b510966
```

`scripts/package/check-packaging-reproducibility.sh` is the release check
that compares two such builds (`docs/RELEASE_ARTIFACTS.md`, "Reproducibility").

What this does **not** establish: that a build on a different host, or with a
different build-container digest, gives the same bytes. Both 1.0.2 builds ran on
one machine (the published 1.0.2 `release-manifest.txt` names `BUILD_MODE=candidate`
and carries exactly the two hashes above). The NebulaOS repository's
`.github/workflows/release.yml` builds A and B as two separate GitHub runner jobs
and runs `scripts/release/compare-builds.sh` before packaging; it has run once
(2026-10-29) and did not build 1.0.2. And a
different commit gives different bytes by design: `SOURCE_DATE_EPOCH` is the
commit's committer date (section 4).

`rootfs.ext2` is still not reproducible (the two 1.0.2 builds differ). It is
not a delivery artifact: no release format contains it.

## 1. The retracted claim

Several places asserted, in varying words, that build outputs "are NOT
deterministic across builds (the toolchain embeds a build timestamp), even from
byte-identical source", and used that to justify not comparing binary hashes.

Two things were wrong with it:

- **The cause was a guess presented as fact.** "The toolchain embeds a build
  timestamp" was never measured. For `guppyscreen` the real cause was specific
  and fixable. For `xImage` the guess is refuted below.
- **It was applied to `guppybeep`, where it was never true.** `guppybeep` does
  not link libhv, embeds no date string, and has reproduced byte-for-byte
  throughout. A `guppybeep` hash change is a real finding, not a benign
  rebuild artifact.

The deeper error is the pattern, not the fact: an observation was attributed to
a guessed cause, the guess was promoted to "expected", and the expectation was
then used to justify not checking. That is what to avoid restating.

## 2. GuppyScreen — cause found, fixed, and measured

`libhv` expands the compiler `__DATE__`/`__TIME__` macros:

```
libhv/base/htime.c      hv_compile_datetime()   sscanf(__DATE__, ...) / sscanf(__TIME__, ...)
libhv/base/hversion.c   hv_compile_version()    builds a version string from it
```

`libhv.a` links into `guppyscreen` but not into `guppybeep` — exactly the
observed asymmetry. The 2026-08-28 reference binary contains the literal string
`Aug 28 2026`, its own build date.

`scripts/build/04-cross-compile-app-stack.sh` now pins `SOURCE_DATE_EPOCH` to
the committer date of `GUPPYSCREEN_PIN` (not vendor `HEAD`), refuses to build if
the pin is unset or the checkout is not at the pin, and **asserts after the
build** that the binary embeds the expected date. It also clears
`libhv/build-mips` and `spdlog/build-mips`, without which a stale `libhv.a`
would relink and the fix would be a silent no-op on a persistent checkout.

Measured result — three builds, three different firmware commits, three fresh
clones, one fixed pin and container digest:

```
guppyscreen  1b34e7b72f95c4e98538ca8cc0d8cf0feeac03d092eb96c61effa41f7d0a2e31   (all three)
guppybeep    fe2a7d3b37aadfdb19f8357ca25efb37e776d785ca270f4553800d3002b1702c   (all three)
```

**What this does and does not establish.** It refutes "differs from build to
build despite identical pinned source". It does **not** establish full
byte-reproducibility across differing hosts, toolchain images or pins. The
check is a substring match on one date string; archive member ordering,
embedded build paths and the parallel-object behaviour of `build-mips.sh`
remain untested for byte-stability. `scripts/build/05-final-build.sh` says so
deliberately and should not be "upgraded" to a stronger claim without evidence.

## 3. The image before the fix (historical: superseded by 3b)

This section records the measurement as it stood on 2026-09-24, before any of
the causes in 3b were fixed. It is kept because the distinction it draws -
hypotheses are not results - is the point of this file. It no longer describes
the current build.

`xImage` and `rootfs.squashfs` differed between builds whose `kernel.config`,
`buildroot.config` and `halley5_v30.dts` are byte-identical, from the same
container digest, with no input change that reaches the image.

Measured on `xImage` (a u-boot legacy uImage, magic `27 05 19 56`):

- the header embeds wall-clock build time at bytes 8-11, big-endian
  (`1790212162` = `2026-09-24T01:09:22Z` vs `1790217506` = `02:38:26Z`, each
  inside its own build window); bytes 4-7 are the header CRC and follow it;
- **skipping the 64-byte header entirely, 1,454,891 bytes of ~5.5 MB still
  differ.** The compressed payload is itself non-deterministic.

So "a kernel build embeds its own build timestamp" is not a sufficient
explanation, and a header-only fix would not make `xImage` reproducible.

**The above was the state of the record until the causes were measured. They
now have been, and the paragraph that used to follow here - listing `UTS_VERSION`,
`__DATE__`/`__TIME__` and squashfs ordering as unverified "usual suspects" - has
been replaced by section 3b rather than deleted, so that the distinction it was
making (hypotheses are not results) is not lost.** None of those suspects turned
out to be the xImage cause.

## 3b. The causes, measured

Each was read out of the differing bytes of two builds whose `kernel.config`,
`buildroot.config` and `halley5_v30.dts` were byte-identical. None was guessed.

| # | Artifact | Producer |
|---|---|---|
| 1 | ~1100 `.pyc` | CPython timestamp-invalidation header carries the source mtime |
| 2 | `opt/nebulaos-seeds/*.tar.gz` | tar member mtimes, readdir order, builder uid/gid |
| 3 | version/seed/config manifest JSON | `build_date=$(date -u …)` in stage 04 |
| 4 | `.nebulaos-chelper-verdict.json` | `now=$(date -u …)` in the chelper preflight |
| 5 | `etc/shadow` | Buildroot salts a plaintext root password randomly per build |
| 6 | `bin/busybox` | build time embedded in the banner |
| 7 | `usr/lib/libcrypto.so.3` | OpenSSL `built on:` string |
| 8 | `usr/lib/libpython3.11.so.1.0` | CPython `getbuildinfo` `__DATE__`/`__TIME__` |
| 9 | `rootfs.squashfs` superblock | mksquashfs creation time |
| 10 | `xImage` | `arch/mips/boot/zcompressed/Makefile` ran `gzip` **without `-n`**, storing the payload's name and mtime in the gzip header |
| 11 | `opt/nebulaos-seeds/*.tar.gz` (again) | the archived `.git/index` (per-file stat data) and `.git/logs/HEAD` (reflog timestamps) |
| 12 | `opt/nebulaos-seeds/klipper.tar.gz` | one stale `__pycache__/*.pyc` copied in from the vendor tree: PEP 552 flag word 0 (timestamp-based), header carrying the source mtime. `__pycache__` is gitignored so the clean-tree guard never saw it, and untracked files survive a sparse checkout even when their `.py` source does not |
| 13 | `opt/nebulaos-seeds/moonraker.tar.gz` | `git pack-objects` delta compression is multithreaded, so the pack is timing-dependent; two builds produced packs with different names, and a pack is named by its own content hash |
| 14 | `opt/nebulaos-seeds/moonraker.tar.gz` (again) | the repack ran only for SHALLOW clones, so a non-shallow seed shipped the pack **the remote server sent**, which is not a function of the repository's content |
| 15 | `opt/nebulaos-seeds/moonraker.tar.gz` (third time) | `pack-objects` REUSES deltas and compressed object data from the existing pack by default - and that pack came from the server, so its bytes leaked into the locally-built one even after the repack became unconditional |

Cause 14 has an exact control. klipper HAS `.git/shallow`, so the repack ran
for it and klipper came out byte-identical; moonraker has none, so it shipped
the server's pack and alternated between two pack names across builds - same
12310 objects, same 9144/3166 delta/base split, only the delta CHOICES
differing. The repack is now unconditional, so every seed's pack is built
locally from its own objects rather than by whichever bytes a server happened
to send.

Making that repack unconditional then broke the build, which is worth
recording rather than smoothing over. The repack packs only objects reachable
from REFS and deletes the clone's pack; a reflog entry can name an object no
ref reaches (`checkout -B` strands the previous branch tip exactly so), and
`git fsck` - which runs afterwards and is load-bearing - then reported
`invalid reflog entry` and the packaging guard correctly refused moonraker.
The shallow path had always deleted the reflogs just before repacking, which
is why klipper never hit it. Reflogs are now dropped before the repack for
every seed, and unreachable loose objects are pruned afterwards, so the
archived object store is exactly one locally-built pack.

Causes 12 and 13 were found by the two-build proof itself, after causes 1-11
were fixed: xImage matched byte for byte and `rootfs.squashfs` was down to
three differing files, of which one was `seed-manifest.json`, derived from the
other two. Cause 12 was a single `.pyc`, two bytes apart, out of 1233 files.

Cause 10 is the whole of the xImage difference. The 1,454,891 differing bytes
above were measured BEFORE `SOURCE_DATE_EPOCH` existed; once it did, xImage came
down to **10 differing bytes** - one four-byte gzip mtime field plus the header
and data CRCs that follow from it. Upstream's own generic compression rule
already passes `-n`; this Ingenic-local rule did not.

Cause 11 was found only because a *functional* test built the same commit twice
and compared bytes. The grep-level assertion for the tar flags passed the whole
time: the variation was inside the member contents, where deterministic tar
flags cannot reach.

### The fixes

1. `build.sh` derives one `SOURCE_DATE_EPOCH` from the firmware commit's
   committer date and exports it into the container. A non-git or unreadable
   tree fails the build rather than falling back to `date +%s`.
2. `BR2_REPRODUCIBLE=y` (covers 1, 2, 9).
3. `scripts/build/nebulaos-post-build.sh` pins the `/etc/shadow` root hash with
   a fixed salt. **Same password** - only the salt stops being random. It is a
   post-build script because `.config` is included by make, which expands `$5`
   before Buildroot's already-hashed test can match it, and because `/etc/shadow`
   is mode 0600, which git cannot express through the overlay.
4. `build_date` and the preflight's `checked_at` derive from the epoch. The
   preflight still uses the wall clock at boot, because it runs there too.
5. The kernel itself carries `-n` in the zboot rule: NebulaOS-kernel commit
   `b31be02d9` ("mips: zboot: gzip -n for a deterministic payload header"),
   contained in `KERNEL_PIN`. `scripts/build/01-apply-kernel-patches.sh`
   refuses to build unless the line `gzip -nv9f $(obj)/vmlinux.bin` is
   present. (An earlier revision of this list named a
   `kernel-gzip-determinism-variant.sh`; no such script exists.)
6. `make_seed_archive()` sorts members, fixes owner/mtime, drops the reflog and
   rebuilds `.git/index` from HEAD with zeroed stat data.

`make_seed_archive()` takes its mtime from the archived tree's **own HEAD commit
date**, not from `SOURCE_DATE_EPOCH`. It is a shared function - the tests and
offline fixtures call it directly - and requiring a build-time variable broke
every caller outside `build.sh`. The commit date is also the more honest value:
the archive *is* that commit.

There are deliberately **two** epochs: the image epoch above, and the GuppyScreen
epoch derived from `GUPPYSCREEN_PIN`, because GuppyScreen should track its pin
rather than the firmware commit.

`tests/reproducibility-assertions-tests.sh` asserts all of it (31 assertions).
Four of them are functional rather than grep-level, and each assertion was
verified to FAIL when its fix is reverted - an assertion that cannot go red
proves nothing.

One of them guards a defect these fixes themselves introduced. The first
version of the sparse skip-worktree step used `read -r -d ''`, a bashism. These
scripts are `#!/bin/sh` and `build.sh` runs the pipeline with `sh`, which is
dash in the container; dash's `read` has no `-d`, so the loop body never ran,
the bits were never re-applied, and the packaging guard correctly refused a
tree it now saw as entirely deleted. It failed closed, but it failed a real
build. The tests did not catch it because they source the library into **bash**,
where `read -d` works, and `bash -n` cannot see this class of defect at all. A
`shellcheck -s sh` gate over every `#!/bin/sh` script under `scripts/build` now
does, and it was verified against the exact construct that broke the build.

## 3a. Corrections to claims made while producing this record

This series exists to stop unverified claims being restated. Two of its own
commit messages contained measurably wrong numbers. Published history is not
rewritten for this; the corrections live here.

- **"all 19 assertions" is wrong. The number is 17.** Stated in the commit
  messages of `36e83c1` and `40762c2`. Measured across all three modes against
  the real repository: pre-build 17, candidate-post-build 17, post-build 17
  (plus 3 baseline comparisons). The count is static in
  `scripts/build/assert-baseline-config.sh` — 15 `check()` sites plus 2 inline
  PASS/FAIL blocks per section — so it does not vary with the build and no real
  build can produce 19. The figure had no source in the repository.

- **"byte-identical to the baseline tag" is wrong. They are SEMANTICALLY
  identical.** Stated in the commit message of `40762c2` about the recorded
  artifacts. Measured by blob SHA against
  `nebulaos-canonical-baseline-2026-08-14-prtouch-qualified`: only
  `halley5_v30.dts` is byte-identical; `kernel.config` and `buildroot.config`
  differ, in exactly the two documented excluded fields
  (`CONFIG_CC_VERSION_TEXT`, `CONFIG_EXTRA_FIRMWARE_DIR`) and nothing else. The
  gate that produced the wording says "semantically" itself. The substantive
  conclusion — that the recorded artifacts are the 2026-08-14 eight-variant
  snapshot and predate the ninth — is unaffected.

Both were caught by independent verification, not by the author. That is the
same failure mode this file documents: a number repeated until it sounds
established.

## 3c. One consequence to carry into hardware qualification

`BR2_REPRODUCIBLE=y` clamps target-filesystem mtimes to `SOURCE_DATE_EPOCH`.
That flattens the chelper sources and the prebuilt `c_helper.so` to the **same**
timestamp, which removes the margin `chelper_enforce_mtime`'s bare `touch` used
to provide - its own comment still describes a "now" that is no longer there.

It is safe, but it is now safe by exact equality rather than by margin, because
both rebuild checks are strictly greater-than:

```
klippy/chelper/__init__.py   max(src_times) > min(obj_times)
chelper_check_mtime          find ... -newer "$target"
```

Equal mtimes therefore produce no rebuild. If either ever becomes `>=`, every
device would try to invoke a gcc it does not have, at boot. Both halves are
asserted in `tests/reproducibility-assertions-tests.sh`.

This is not a defect and it does not block reproducibility. It belongs on the
hardware-qualification list because `BR2_REPRODUCIBLE=y` changes the shipped
rootfs bytes, so the resulting image is by definition **not** the one qualified
on 2026-08-14.

## 4. Consequence for release qualification

A rebuild of the **same** commit, with the same build-container digest,
reproduces `xImage` and `rootfs.squashfs` byte for byte (measured above). A
**different** commit does not, even a metadata-only one: `SOURCE_DATE_EPOCH`
is that commit's committer date, and it reaches the image (for example the
version manifest's `build_date` and the squashfs timestamps). Therefore:

```
REBUILD_OF_THE_SAME_COMMIT_EQUALS_THE_QUALIFIED_ARTIFACT  YES  (same container digest)
ANY_OTHER_COMMIT_EQUALS_THE_QUALIFIED_ARTIFACT            NO   (structurally)
```

Hardware evidence can be carried to a rebuild of the exact qualified commit by
comparing hashes, and to nothing else. Baseline promotion that adds a commit is
not a no-op for the image: flash and qualify the artifact that will ship.
