# Deferred post-release work

Work that is understood, scoped, and deliberately **not** being done in the
current release cycle. Each entry says why it was deferred and what it needs
before it can start — a deferral without a reason is just a forgotten task.

---

## 1. Identity-gate fast-path consolidation

**Status:** deferred to post-release.
**Requires:** Architecture Guardian (`nebula-architect`) review **before**
implementation.

### What

Consolidate the offline fast path of `tools/verify-workspace-identity.sh`
(`--hook` / `--local`) so that it runs as a single process instead of ~88
forked commands.

### Why it is worth doing

The PreToolUse hook runs this gate before **every** `Bash`, `Edit`, `Write` and
`NotebookEdit`. Measured on this host:

| | before | after the batching fix | remaining |
|---|---|---|---|
| gate `--hook` | 195 ms | 137 ms | ~88 forks |
| PreToolUse, no-op `Bash` | 250 ms | 190 ms | |
| PreToolUse, `Edit` | 249 ms | 189 ms | |

The batching fix already landed: the control-file loop forked `sha256sum`+`awk`
twice per manifest line (60 processes for 15 files) and now issues two
`sha256sum` calls over the same files, comparing the same SHA-256 values —
62 ms → 2 ms in isolation.

What remains is diffuse. Every fork costs ~1.5 ms because the gate runs inside
bubblewrap, and the cost is spread over ~36 `git` invocations plus ~52
`grep`/`sed`/`cut`/`wc` calls with no single hot spot left. Consolidating the
whole offline path into one process is estimated at ~30–40 ms, but it means
rewriting a 640-line security-critical script.

### Why it was deferred

Two reasons, both structural rather than about effort:

1. **It is architecture-sensitive work.** `AGENTS.md` requires
   `nebula-architect` review *before* implementation for changes to the
   workspace authority layer. How the identity gate is evaluated is exactly
   that.
2. **It sits immediately before hardware qualification.** The gate is what
   makes every other guarantee in this workspace checkable. Rewriting it in the
   same cycle that freezes a release candidate trades a bounded, measured
   annoyance for an unbounded correctness risk.

### Constraints any implementation must keep

Non-negotiable, and the reason this cannot be a casual refactor:

- **Fail closed.** Every error path denies. A gate that cannot prove the
  workspace is sound must refuse, including "the gate itself is broken".
- **No weakening of** archive isolation, agent privilege binding, launcher
  content binding, or release identity checks.
- **Keep the mode split.** The fast local gate is for per-tool-call use; the
  full online gate (`--full`) stays mandatory at commit/push/build/flash/release
  boundaries. These must not converge.
- **Hashing stays hashing.** An mtime/size fingerprint cache was considered and
  rejected: it is cheaper but strictly weaker than comparing content, and this
  is a security boundary, not a build system.
- The existing fail-closed behaviours must keep their tests — drift detected on
  a tampered file, and a short read (an unreadable file) refusing the *whole*
  control layer rather than silently checking fewer files than the manifest
  lists.

---

## 2. Release artifact packaging formats

**Status:** IMPLEMENTED (2026-09-28, universal-release mission), for the two
formats below. The rest of this section's original list is still deferred.

- Creality F005 OTA `.img` packaging — **implemented and validated**
- Ingenic Cloner `.ingenic` packaging — **implemented and validated**
- DarKE port — still deferred, not started
- OpenKlipperEdition Recovery port — not needed as a port; its
  `rebuild_ingenic.py` is the reference this implementation follows

### Why it was deferred, and what changed

The original reasoning stands and is unaffected: introducing new release
artifact formats immediately before hardware qualification would mean qualifying
bytes that no prior cycle has produced. **The artifacts frozen for hardware
qualification remain the canonical core set (`xImage`, `rootfs.squashfs`).**

What changed is that both formats are now *packaging of that same core* rather
than new things to qualify. Neither packager compiles anything; both embed the
already-built `xImage` and `rootfs.squashfs` byte-for-byte, and both validators
prove it by extracting the payload back out and comparing SHA-256 against the
canonical files. `QUALIFIED_INPUT_ARTIFACTS_MODIFIED=NO` is recorded in every
generated manifest and asserted by the test suite.

### `.img` — the Creality F005 OTA package

Not a raw disk image. It is the package the **stock** Creality updater consumes,
from USB, the touchscreen, or
`/etc/ota_bin/local_ota_update.sh <file>`. The `.img` extension is checked by
the updater; it says nothing about the contents.

Inside is an encrypted 7z envelope holding `ota_config.in`, a versioned
`ota_v<version>/` directory, `ota_update.in`, a `.ok` marker, and both payloads
split into 1 MiB chunks under a chained-MD5 filename scheme — chunk `0000`
carries the digest of the *whole* payload, and every later chunk carries the
digest of its *predecessor*. The envelope secret is derived
(`mkpasswd -m md5 "F005C3_7e_bz" -S cxswfile`) and asserted against its
known-good value rather than pasted in as a constant.

**Where it installs is a property of the printer, not of the package.** The
stock updater writes whichever A/B set is *inactive* and then flips the marker
to it. Applied while NebulaOS is booted, a NebulaOS `.img` overwrites the
**stock** slot. There is no vendor-signature check and no comparison of the
target's existing contents against a Creality release. That is not the same as
"there are no checks": the updater validates extraction, version, metadata,
capacity, per-chunk MD5 and declared sizes, and this packager satisfies all of
them. What is absent is an *authenticity* check, which is precisely why custom
F005 firmware installs through the stock path at all.

`ota_config.in` is still synthesised (`IMG_OTA_CONFIG_PROVENANCE`), but since
2026-10-29 its rules come from the real updater script and a real install
through it (see RELEASE_ARTIFACTS.md, "What Creality's updater actually
checks").

### `.ingenic` — the Ingenic Cloner recovery package

A ZIP consumed by the Ingenic USB Cloner in X2000E USB-boot (mask-ROM) mode.
**Not** flashed from a U-Boot command line, and not a Hardware Agent transport.

NebulaOS does not build one from scratch. It substitutes the canonical payloads
into the official `Ender-3_V3_KE_1.1.0.12.ingenic`, pinned by content in
`manifests/dependencies.conf`, and carries the other 274 entries through
untouched — SPL/U-Boot, the MBR/GPT, the per-SoC firmware and DDR descriptors,
the Cloner files, the security keys. The validator compares every one of them
against the template entry by entry, because a package that embeds the right
kernel but silently re-encoded U-Boot is not one to put a printer into mask-ROM
for.

Default layout is stock in slot A, NebulaOS in slot B, marker `ota:kernel2`.
That is the safer first install, not a constraint: `--slot a` overwrites the
stock slot, and the Cloner programs whatever its policy names.

**`sn_mac` is preserved, and that is asserted rather than assumed.** The vendor
erase policy is `"0x0,0x1fffff;0x300000,0xffffffff;"`, which leaves
`0x200000..0x2fffff` — the per-unit factory MAC and serial — untouched. Both the
packager and the validator refuse if that hole is ever closed.

### Unexpected benefit: the real partition geometry

The Cloner profile inside the vendor package names every partition and its
absolute offset (`ota` 0x100000, `sn_mac` 0x200000, `rtos` 0x300000, `rtos2`
0x700000, `kernel` 0xb00000, `kernel2` 0x1300000, `rootfs` 0x1b00000, `rootfs2`
0x20f00000). The derived sizes reproduce, exactly, the two constants
`scripts/flash-spare-slot.sh` arrived at independently: 8388608 and 524288000.
That closed a long-standing evidence gap — `tools/emmc/nebulaos_layout.py` now
records 29 verified facts where it previously had none for offsets at all.

`tools/maintenance/build-cache-gc.sh` already refuses to collect `.img` and
`.ingenic` files, so the GC tool still needs no revisiting.

---

## 3. `build-manifest.txt` does not record `source_date_epoch`

**Status:** deferred. Worked around correctly; the manifest gap itself remains.

`scripts/build/05-final-build.sh` writes `build-manifest.txt` with `built_at`,
every component commit and every artifact hash — but never the reproducibility
epoch, even though `build.sh` computes it, exports it, refuses to build without
it, and prints it.

This was found when the build launcher's attestation read the epoch with
`grep '^source_date_epoch='` and silently wrote a blank: through `grep`, a
missing key and an empty value are indistinguishable, so the attestation
recorded nothing while still claiming to be complete.

**Already fixed, in the launcher:** the attestation now derives the epoch from
the committer date of the firmware commit being built — the same derivation
`build.sh` uses, from the same commit, so it is authoritative by construction
rather than dependent on a key that does not exist. The attestation is now also
withheld outright if the epoch (or any other promised field) is blank, because
an attestation that is present but hollow reads as evidence.

**Still worth doing:** have stage 05 record `source_date_epoch` in the manifest
directly, so the manifest is self-describing and any future consumer can read
the epoch from the artifact set without re-deriving it from git.

**Why deferred:** `build-manifest.txt` is shipped in the image and is an input
to `06-verify.sh`'s assertions. Changing its content in the same cycle that
freezes a release candidate would mean qualifying a manifest shape no previous
build produced. The launcher-side derivation is contained and changes no build
output at all.

---

## 4. `rootfs.ext2` metadata reproducibility

**Status:** pre-existing, documented follow-up. Unchanged by the current cycle.

`rootfs.ext2` is not yet byte-reproducible due to filesystem metadata
(timestamps and inode ordering) that the current image generation does not
fully pin. `xImage` and `rootfs.squashfs` **are** byte-reproducible and are what
the reproducibility proof asserts.

This remains a separate follow-up. It is in scope for the current cycle only in
the negative sense: if a change here unexpectedly regressed `rootfs.ext2`
*content* equivalence, that would be a defect to fix now.
