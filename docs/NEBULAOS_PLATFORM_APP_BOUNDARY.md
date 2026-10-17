# Platform / application boundary, and the future app-dependency model

This document records a **design boundary and a recommended direction**. It is
deliberately not an implementation plan for this release. Mission §16/§17 asked
that the Buildroot 2025.02.18 migration not *block* the model below; it does
not ask for the model to be built now, and building it now would be premature.

---

## 1. The two halves

### Platform — firmware-owned, A/B-updated, immutable at runtime

kernel · glibc · the Python interpreter · OpenSSL · nginx · Dropbear ·
wpa_supplicant · eudev · core system libraries · the Buildroot base system ·
every `BR2_PACKAGE_*` in `br2-external/configs/nebulaos_x2000_defconfig`.

These live in the read-only squashfs of one A/B slot. An **application update
must never replace any of them live.** Changing them means shipping a new
firmware image and going through the slot/rollback machinery.

### Application — independently updateable

Klipper · Moonraker · Mainsail · the contents of the per-application venvs
under `/usr/data/nebulaos/envs/{klipper,moonraker}`.

These live on the persistent datastore, survive a slot switch, and are updated
by the update/recovery supervisors without reflashing.

## 2. Why the boundary needs stating at all

The two halves have **different lifetimes and different storage**, and that
asymmetry is load-bearing:

```
/usr/lib/python3.12   image-owned   per-slot     changes on firmware update
/usr/data/.../envs    persistent    slot-shared  survives firmware update AND rollback
```

A venv therefore outlives the interpreter it was built against, in **both**
directions — forward on an OTA, and backward on an A/B rollback.

### Scope for this release: not yet a problem, and deliberately not solved

NebulaOS is **unreleased**, and `/usr/data/nebulaos/` is NebulaOS-owned — stock
firmware does not consume it. There is therefore no deployed device carrying a
Python 3.11 venv that this image must migrate, and no A/B pair in the field
with mismatched interpreter minors. This release consequently does **not**
implement 3.11→3.12 venv migration and does **not** attempt to keep a venv
working across interpreter minors.

What it *does* fix is the provisioning itself: `venv_is_usable` in
`/usr/libexec/nebulaos-venv-lib.sh` replaces an `[ -x bin/python3 ]` guess that
treated a torn, half-created environment as finished, so fresh Python 3.12
provisioning is now **interruption-safe and idempotent**.

### FUTURE REQUIREMENT — first post-release Python ABI transition

At the first Python minor bump after release, version awareness becomes
mandatory, because the lifetime asymmetry above is real and permanent. The
required behaviour:

- compare the venv's `major.minor` against the running `/usr/bin/python3`
- treat a mismatch in **either** direction as "must reprovision" — a one-way
  "upgrade only" design disarms A/B rollback, which is the safety mechanism
- reprovision through the existing staged/verified/atomic path, never in place

The hook is `venv_is_usable`: adding the comparison there is sufficient, and
the staging, swap and recovery machinery it would need already exists and is
already tested. `tests/venv-platform-migration-tests.sh` contains an explicit
assertion that version mismatch does *not* currently reject, so that adding a
version check fails that test and forces this scope decision to be revisited
deliberately rather than drifting in.

## 3. What this release actually ships

Buildroot provides a **complete offline factory baseline**: every dependency
the pinned Klipper and Moonraker need is built into the image, so a
factory-fresh or recovered device is fully functional with no network and no
compiler on the printer.

The venvs are created with `--system-site-packages`, so today they are thin
shims over the image's `site-packages` and contain essentially nothing of their
own. **That is the current state, not a commitment.** It is also the reason a
future application update cannot yet bring its own dependency versions: it
would be resolving against the immutable image.

Nothing in this migration prevents changing that — which was the actual
requirement.

## 4. Recommended future model (NOT implemented here)

```
immutable NebulaOS platform
        +
independently updateable application source
        +
independently versioned application venv
```

The shape that fits this device:

1. **NebulaOS CI builds MIPS/XBurst wheels** using the same toolchain and ABI as
   the firmware — same GCC, same glibc, same `mips32r2` / FPXX / legacy-NaN
   settings. Wheel ABI tags make the compatibility contract explicit and
   machine-checkable rather than implied.
2. **The printer downloads verified prebuilt wheels.** Hashes checked before
   use. **No compiler on the printer** — the device has 208 MiB of RAM and
   compiling `numpy` there is not a realistic operation.
3. **Stage a new venv beside the current one**, install into it, verify it, then
   **atomically activate** source + matching venv together. The staging and
   atomic-swap primitives this needs already exist and are already tested:
   `swap_venv_into_place` and `recover_torn_venv` in
   `/usr/libexec/nebulaos-venv-lib.sh`.
4. **Preserve the previous generation for rollback.** Application rollback
   should restore source *and* its matching venv as one unit; they are a pair,
   and rolling back one without the other reproduces exactly the
   interpreter/venv mismatch this migration fixed.

~~A full package repository is explicitly out of scope.~~ Superseded
2026-10-17 (G50, decided with the user 2026-10-16, architecture review
PASS_WITH_NOTES 2026-10-17): Moonraker's update_manager always runs
`pip install -U -r <requirements>`, and PyPI has no wheels for this ABI, so
every app update whose dependencies move needs a compiled wheel. The
implementation:

- **ABI fingerprint, derived once by the build** (`scripts/build/lib/python-abi.sh`,
  written by post-build to `/usr/share/nebulaos/python-abi`): Python, SOABI,
  platform tag (`linux_mips`), glibc, GCC, `mips32r2`/o32/FPXX/legacy-NaN,
  endianness and the sonames a wheel may link; `id` = sha256 over them. The
  wheel tag `cp312-cp312-linux_mips` encodes none of that, so the id is part
  of the index path.
- **`/etc/pip.conf`** (generated from `NEBULAOS_PACKAGE_INDEX_URL` in
  `manifests/dependencies.conf` + the id): `index-url = <url>/<id>/`,
  `only-binary = :all:`, no extra index. pip never consults PyPI and never
  builds; a missing wheel fails before the venv is touched. Moonraker logs
  that failure and finishes the source update; the supervisor rolls back only
  if the new source then fails its health check.
- **The index** (`coreflake1/nebulaos-packages`, GitHub Actions, GitHub Pages):
  wheels cross-built with the SDK exported from an attested build (on a copy),
  every `.so` checked before publishing (ELF little-endian MIPS, FPXX FP ABI,
  no NaN2008, GLIBC symbol versions <= the fingerprint's glibc, DT_NEEDED only
  glibc + the fingerprint's linkable sonames). Integrity is relative to the
  index (sha256 per file over HTTPS) - not a signature.
- **Venv ABI stamp** (`envs/<app>/.nebulaos-abi`, `nebulaos-venv-lib.sh`):
  a venv stamped for another fingerprint is reprovisioned from the image seed,
  since venvs outlive the image in both directions.
- The firmware build and first boot never use the index.
- **Klipper's `c_helper.so`** (G72, architecture review 2026-10-17). A
  Klipper update that changes `klippy/chelper` needs the library built from
  those sources. One recipe (`scripts/build/lib/build-chelper.sh`) and one
  source hash (`chelper_source_hash` in `/etc/nebulaos-chelper-preflight.sh`:
  sha256 over sorted `<name> <sha256 of content>` lines for every `*.c`,
  `*.h`, `__init__.py` in `klippy/chelper`) - stage 04 and the index CI both
  use them (they travel in the SDK). Index: `NEBULAOS_CHELPER_INDEX_URL` ->
  `/usr/share/nebulaos/chelper-index.url`; `<url>/<id>/index` lines are
  `<source hash> <sha256> <size>`, the file is `<url>/<id>/<hash>/c_helper.so`
  - outside `simple/`. The CI publishes nothing for an ABI unless the
  image's own Klipper rebuilds byte-identical to the shipped library. On the
  printer: a cache `$NEBULAOS_ROOT/cache/chelper/<id>/<hash>/` (bounded, 8
  per ABI), seeded with the image's library (`/usr/share/nebulaos/chelper`
  records its hash and sha256), the library of every known-good pair, and
  every verified download - so a rollback (`git reset --hard`) finds its
  library offline. S05 installs from the cache only (no network before
  Wi-Fi/DNS/NTP); the update supervisor also fetches from the index, inside
  the pre-restart gate. A library is installed only when its source hash and
  sha256 match: temp `*.so` next to it (git-ignored), mtime set to the
  newest source's to the nanosecond (python3 `os.utime`; never "now" - the
  clock may be pre-NTP; BusyBox `ls -t`/`find -newer` only see whole seconds
  while Klipper compares float mtimes, so the check uses `st_mtime_ns` too),
  atomic rename, then the verdict. No match or any error leaves the tree unchanged
  and the fail-closed verdict decides. Same trust as the wheels (HTTPS +
  sha256 from the index, not a signature). Moonraker's own Klipper restart
  after `git pull` still meets the stale library first; that error is
  transient - the supervisor installs the helper and validates the pair.
- **Readiness check** (G73, advisory): `nebulaos-osconfig updates
  check-readiness` takes the target commits from Moonraker's own
  `remote_hash`, runs the app venv's `pip install --dry-run` against the index
  with the target's requirements (`git show`, never `git fetch`), and looks
  the target's chelper source hash up in the cache/index. Refused while
  update_manager is busy or a print runs. The result
  (`$NEBULAOS_ROOT/updates/readiness.json`) shows on the screen's Updates page
  ("waiting for packages") and as a Moonraker warning in Mainsail; the
  supervisor asks for a check every 5 minutes when Moonraker's targets
  changed. It never blocks an update.
- **SDK publishing** (G71): `tools/sdk/publish-sdk.sh <run>` is a separate
  host step after an attested build (never inside the build launcher or
  container). Release `sdk-<id>` with both assets is the idempotency key
  (completed when partial); only builds whose `SOURCE_HEAD` is on the firmware
  repository's `origin/main` are published (releases are first-wins per id).
  It starts the index workflow; it never changes a build's result. A release
  published before the recipe travelled in the SDK gets the small asset
  `nebulaos-chelper-tools-<id>.tar.gz` (recipe, source hash, image record)
  instead; the SDK itself is never replaced.

## 5. Compatibility metadata (sketch)

When an application update needs to state what platform it requires, something
of this shape is sufficient — three fields, declarative, checkable before
anything is written:

```
NEBULAOS_PLATFORM_API=<integer, bumped on breaking platform change>
PYTHON=<major.minor of the interpreter the venv was built against>
OPENSSL=<major.minor>
```

Deliberately **not** implemented now. The two rules that matter:

- An update whose requirements the running platform cannot satisfy must **fail
  cleanly and early**, with the equivalent of `NebulaOS platform update
  required`, leaving the working installation untouched.
- It must **never** attempt to satisfy itself by mutating the immutable OS.

This is the fail-closed direction: refusing an update is recoverable, a
half-mutated platform is not.

## 6. What this migration already contributes to that future

- `venv_is_usable` makes "is this venv actually usable?" an explicit, testable
  predicate instead of an `[ -x bin/python3 ]` guess. The future version check
  slots into the same place.
- `swap_venv_into_place` / `recover_torn_venv` give atomic, power-cut-safe venv
  replacement with a recoverable intermediate state.
- Python paths and the CPython ABI tag are derived from `sysconfig` /
  `EXT_SUFFIX` rather than written down, so a future minor bump does not
  require repeating the 3.11→3.12 cleanup.
- `br2-external/package/` establishes the pattern for adding a target Python
  package with a pinned, hash-verified source and no network access at build
  time — the same discipline a wheel-building CI job would need.
