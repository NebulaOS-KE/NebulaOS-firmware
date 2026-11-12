# Figuring out what actually produced a build

Sometimes you need to answer "what exactly went into this `xImage`/`rootfs.squashfs`?" — maybe it's
a build you just ran, maybe someone handed you a set of files and you want to know where they came
from.

This is a different question from `docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md`, which is about
*third-party* stuff this build pulls in (Mainsail's release zip, WiFi firmware, that kind of thing)
and whether each of those can be reconstructed from its own upstream. This page is about the
build's own identity — which commit, which pinned dependencies, which build image made this
specific output.

## `build-manifest.txt`

Every real build writes `artifacts/buildroot-halley5-v30-image/build-manifest.txt`. This is what
`scripts/flash-spare-slot.sh` checks transferred artifacts against before it'll write anything to
real hardware, and it's also the record you'd want if you're trying to reconstruct exactly what a
given image is without still having the original `vendor/` checkouts around.

Here's what's actually in it:

| Field | What it tells you |
|---|---|
| `built_at` | UTC timestamp of the build |
| `build_image_repo` / `build_image_digest` | Which build container actually produced this — we only started recording this during Final Closure; before that, a shipped artifact had no record of which factory built it |
| `git_commit_main` (+ `_dirty`) | This repo's own commit, and whether the tree was clean when it built |
| `git_commit_kernel`, `git_commit_buildroot`, `git_commit_klipper`, `git_commit_moonraker`, `git_commit_guppyscreen`, `git_commit_pellcorp_creality`, `git_commit_k1_ustreamer`, `git_commit_v4l_utils` (each with `_dirty`) | Exact commit of every vendored source tree |
| `git_submodules_k1_ustreamer` | Submodule pins inside that vendor tree |
| `mainsail_zip_sha256`, `guppyscreen_sha256`, `guppybeep_sha256`, `wifi_firmware_sha256`, `wifi_clm_sha256`, `wifi_nvram_sha256`, `regulatory_db_sha256` | Hashes of the fetched/built binary artifacts |
| `kernel_config_sha256`, `buildroot_config_sha256`, `device_tree_sha256` | Hashes of the actual build configuration used |
| `xImage_sha256` / `xImage_size`, `rootfs_squashfs_sha256` / `rootfs_squashfs_size` | The two artifacts that actually get flashed |

## The qualified baseline

`manifests/dependencies.conf` has one field, `QUALIFIED_BASELINE_TAG`, that names the current
reference explicitly — it's not "whatever tag happens to be newest." We used to auto-select the
newest tag, which turned out to be a real bug, so now it's an explicit value.
`scripts/build/assert-baseline-config.sh` and `scripts/build/baseline-difference-gate.sh` both read
it and fail loudly (printing exactly what they checked against) if it doesn't point at something
real.

## Working backward from just the artifacts

If someone hands you a `build-manifest.txt` and nothing else, here's how to reconstruct where it
came from:

1. Check out `git_commit_main` in `NebulaOS-firmware`.
2. Pull the exact image named in `build_image_repo`/`build_image_digest` — don't assume it still
   matches whatever's currently pinned in `manifests/dependencies.conf`, since that value moves
   forward over time.
3. Cross-check every other `git_commit_*` field against what `manifests/dependencies.conf` pinned
   **at that commit** (`git show <git_commit_main>:manifests/dependencies.conf`), not the current
   tip of the branch.
4. Re-running `./build.sh` at that exact commit, with that exact image digest, reproduces
   `xImage` and `rootfs.squashfs` **byte for byte**: their hashes must equal `xImage_sha256` and
   `rootfs_squashfs_sha256` in the manifest. Measured for release 1.0.2: Build A and Build B
   of firmware `3bdf3ff` gave identical hashes. Not measured: a different host or a different
   image digest. A different commit, even a metadata-only one, gives different bytes, because
   `SOURCE_DATE_EPOCH` is the commit's own committer date. `rootfs.ext2` is not reproducible
   and is not shipped.

   Corrected 2026-11-12: this step used to say the image was not reproducible and that the
   root cause was not established, quoting 1,454,891 differing bytes. That was the measurement
   before `SOURCE_DATE_EPOCH` and the fixes; the causes have since been found and fixed. See
   `docs/REPRODUCIBILITY.md`, which is the canonical record.

## Related docs

- `docs/BUILD_FROM_SOURCE.md` — how to actually produce a build
- `docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md` — third-party artifact provenance
- `docs/A_B_SLOT_MODEL.md` / `docs/DEVELOPER_INSTALL_FROM_STOCK.md` — what `flash-spare-slot.sh` does with `build-manifest.txt`
