# Build provenance: what produced this image

How to answer "what exactly went into this `xImage` / `rootfs.squashfs`?" - for a build you just
ran, or for a set of files somebody handed you. Read against `NebulaOS-firmware` at `b95b156`.

This is the build's **own** identity: which commit, which pins, which container. A different
question from `docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md`, which is about the third-party
material the build pulls in (Mainsail's release zip, Wi-Fi firmware) and whether each of those
can be reconstructed from its own upstream.

## `build-manifest.txt`

Every real build writes `artifacts/buildroot-halley5-v30-image/build-manifest.txt`.
`scripts/flash-spare-slot.sh` checks transferred artifacts against it before writing anything to
hardware, and it is the record to keep if the original `vendor/` checkouts are gone.

| Field | What it tells you |
|---|---|
| `built_at` | UTC timestamp of the build |
| `build_image_repo` / `build_image_digest` | Which container actually produced this. Before this was recorded, a shipped artifact had no record of the factory that built it |
| `git_commit_main` (+ `_dirty`) | This repository's own commit, and whether the tree was clean |
| `git_commit_kernel`, `_buildroot`, `_klipper`, `_moonraker`, `_guppyscreen`, `_pellcorp_creality`, `_k1_ustreamer`, `_v4l_utils` (each with `_dirty`) | The exact commit of every vendored source tree |
| `git_submodules_k1_ustreamer` | Submodule pins inside that vendor tree |
| `mainsail_zip_sha256`, `guppyscreen_sha256`, `guppybeep_sha256`, `wifi_firmware_sha256`, `wifi_clm_sha256`, `wifi_nvram_sha256`, `regulatory_db_sha256` | Hashes of the fetched or built binaries |
| `kernel_config_sha256`, `buildroot_config_sha256`, `device_tree_sha256` | Hashes of the configuration actually used |
| `xImage_sha256` / `_size`, `rootfs_squashfs_sha256` / `_size` | The two artifacts that get flashed |

The `guppyscreen` field names are historical: they carry NebulaScreen's binaries, built from the
`NEBULASCREEN_PIN` commit. See [Building from source](Building-From-Source).

## The qualified baseline

`manifests/dependencies.conf` names the current reference explicitly in `QUALIFIED_BASELINE_TAG`
- not "whatever tag is newest", which was a real bug once. `scripts/build/assert-baseline-config.sh`
and `scripts/build/baseline-difference-gate.sh` both read it and fail loudly, printing exactly
what they checked against, if it does not point at something real. At 1.0.2 (`3bdf3ff`) its
value is `nebulaos-canonical-baseline-2026-08-14-prtouch-qualified`.

## Working backward from the artifacts alone

1. Check out `git_commit_main` in this repository.
2. Pull the exact container named in `build_image_repo` / `build_image_digest` - do not assume it
   still matches what `manifests/dependencies.conf` pins now; that value moves forward.
3. Cross-check every other `git_commit_*` field against what the manifest pinned **at that
   commit** (`git show <git_commit_main>:manifests/dependencies.conf`), not against the tip of
   the branch.
4. Re-running `./build.sh` at that commit with that container digest should get you something
   functionally identical. Whether it is *byte* identical is a separate question - read the next
   section before assuming either answer.

## Reproducibility: what is measured, and what is not

`docs/REPRODUCIBILITY.md` is the canonical record and it is deliberately precise, because this
repository got this wrong before. Its own status block, at 1.0.2 (`3bdf3ff`) and unchanged at
`b95b156`:

```
GUPPYSCREEN_REPRODUCIBLE_FOR_A_FIXED_PIN     YES (measured, three builds)
FULL_GUPPYSCREEN_BYTE_REPRODUCIBILITY        NOT ESTABLISHED
IMAGE_REPRODUCIBLE (xImage, rootfs.squashfs) NOT YET PROVEN at the fixed HEAD
IMAGE_NON_DETERMINISM_ROOT_CAUSE             ESTABLISHED (measured, 15 causes)
```

Read those four lines as one statement. **Every cause of image non-determinism has been read out
of the differing bytes and fixed** - 15 of them, from CPython's `.pyc` timestamp header and
Buildroot's randomly salted root password hash to a `gzip` call in the kernel's zboot Makefile
that ran without `-n`, and three separate ways a git pack's bytes came from a *server* rather
than from the repository's own objects. `build.sh` now derives one `SOURCE_DATE_EPOCH` from the
firmware commit's committer date and fails rather than falling back to `date +%s`.
`SOURCE_DATE_EPOCH` alone took `xImage` from 1,454,891 differing bytes of ~5.5 MB down to
**10** - one four-byte gzip mtime field plus the two CRCs that follow from it - and the `gzip -n`
fix took it to **byte-identical**, at which point `rootfs.squashfs` was down to three differing
files and causes 12 and 13 were found in them.

What is **not** claimed: that two clean builds of the current HEAD have been proven identical.
The causes being found and fixed is a different claim from that proof, and the record refuses to
upgrade one into the other. The proof runs live in a build-evidence tree kept outside this
repository, because it records absolute build paths and per-run hashes.

### For a release: two builds, compared

A release is built **twice from the same commit** and the two builds compared before anything is
packaged. Two routes exist for that, and a developer should know which evidence belongs to
which.

**The comparison itself** is `scripts/package/check-packaging-reproducibility.sh --build-run-a
<run> --build-run-b <run>`, and `docs/RELEASE_ARTIFACTS.md` holds each format to its own explicit
standard - see the next section, because the `.img` cannot meet the byte standard at all.

**There is also a workflow that does the whole thing on GitHub**, and it is worth knowing about
even though the published 1.0.2 was not built by it: `.github/workflows/release.yml` in the
[NebulaOS repository](https://github.com/NebulaOS-KE/NebulaOS) (added 2026-10-29) takes one
commit of this repository and runs a matrix of two independent builds, then
`scripts/release/compare-builds.sh a b` as a job the packaging job depends on. That script is
exact about what must match, and reading it is the quickest way to see what "identical" means
here:

- `xImage` and `rootfs.squashfs`: **byte for byte**, by sha256;
- `build-manifest.txt`: identical on every line **except `built_at`**, the wall clock of the
  build, which is not part of any artifact;
- the attestation's `SOURCE_HEAD`, `BUILDER_DIGEST` and `SOURCE_DATE_EPOCH`: equal and non-empty.

It prints `BUILD_COMPARE=IDENTICAL` or `BUILD_COMPARE=FAIL`, and the packaging job then runs on
**build A** only, producing a *draft* release a human publishes after testing it on a printer.

**What the 1.0.2 artifacts actually record.** The published `release-manifest.txt` carries
`BUILD_MODE=candidate`, `SOURCE_HEAD=3bdf3ff53073aaccd13e6c364e7d2dfca1e14801` and
`BUILD_RUN=/var/tmp/nebulaos-build/3bdf3ff.../run-20261109T131214Z-224824` - a local build run
through the project's own launcher, not a workflow run - and it records **no comparison**: there
is no second build's hashes in it and no `BUILD_COMPARE` line anywhere in the release. So for
1.0.2, "built twice and compared" rests on the project owner's account of how it was built, not
on anything the release publishes. The capability is in the repository and is exact; the
evidence trail for this particular release is the single `BUILD_RUN` and the checksums.

That distinction is the whole reason this page exists: *what the tooling enforces* and *what a
given artifact can prove about itself* are different questions, and conflating them is how a
reproducibility claim grows legs.

**And the download is packaged from one build, not from both** - so "built twice and identical"
is a statement about the core (kernel, root filesystem, build record), never about the `.img` a
user downloads, whose provenance is its checksums and its manifest.

### And a separate check, for the packaging step itself

`scripts/package/check-packaging-reproducibility.sh --build-run-a <run> --build-run-b <run>`
exists for the question the release gate does not ask: whether *packaging* is deterministic.
`docs/RELEASE_ARTIFACTS.md` holds the three formats to explicit, different standards: `xImage`
and `rootfs.squashfs` byte-identical, the `.ingenic` byte-identical (plain ZIP, every entry
keeping the template's own metadata), and the `.img` same-size plus a bit-identical extracted
tree - because Creality's envelope is an encrypted 7z whose fresh random AES salt and IV make
two archives over identical plaintext differ in about 99.6% of their bytes, with no option to
pin the IV. That case records itself honestly: `IMG_BYTE_IDENTICAL=NO`,
`IMG_BYTE_IDENTICAL_REASON=encrypted-7z-random-aes-iv`, `IMG_CONTENT_IDENTICAL=YES`.

The retracted claim worth knowing, because older documents still carry it: that build outputs
"are NOT deterministic across builds (the toolchain embeds a build timestamp), even from
byte-identical source" - which was a guess presented as a fact, and was then used to justify not
comparing hashes at all. If you find another copy of it, correct it and point at
`docs/REPRODUCIBILITY.md`. Do not add a count of how many copies are left: successive passes
each claimed to have found the last one, and each was wrong.

NebulaScreen's two binaries reproduce byte-for-byte across three builds for a fixed
`NEBULASCREEN_PIN` and container digest. `nebulabeep` never had the problem at all - it does not
link `libhv`, so a change in its hash is a real finding rather than a benign rebuild artifact.

One place to read with care: `docs/BUILD_PROVENANCE.md`'s own "Working backward" step 4 still
says the root cause is **not** established and quotes the 1,454,891-byte measurement. That was
true when it was written (corrected 2026-09-24) and is now behind `docs/REPRODUCIBILITY.md`,
which is the canonical record by its own statement. Where the two disagree, the canonical record
wins - and this page follows it. (Both tracked documents are being corrected at the source;
until that lands, this paragraph is the warning.)

Related tracked docs: `docs/BUILD_PROVENANCE.md`, `docs/REPRODUCIBILITY.md`,
`docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md`.
