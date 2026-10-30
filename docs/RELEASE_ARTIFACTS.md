# NebulaOS release artifacts

One build. Three ways to deliver it. This explains what each one is, which to
reach for, and what each costs you.

## The shape of a release

```
                     one source commit
                            |
                      Buildroot build
                            |
                  the canonical core
              xImage + rootfs.squashfs
                            |
        +-------------------+-------------------+
        |                   |                   |
     native              .img               .ingenic
   (developers)     (stock updater)     (USB recovery)
```

Every format carries the **same two payload files, byte for byte**. Nothing is
recompiled to produce a delivery format, and each validator proves it by
extracting the payload back out and comparing SHA-256 against the canonical
files. `release-manifest.txt` records the source commit and both digests, so all
three artifacts in a release directory can be shown to be the same build.

## Which one do I want?

| Situation | Use |
|---|---|
| You have a working printer and want a newer NebulaOS | **Neither.** Use `scripts/flash-spare-slot.sh` — it writes two partitions and touches nothing else |
| You are on stock and want to install NebulaOS | `.img` through the stock updater |
| You are developing and want to flash by hand | native `xImage` + `rootfs.squashfs` |
| The printer will not boot and you cannot reach it over the network | `.ingenic` through the Ingenic USB Cloner |

The `.img` and `.ingenic` are **installation and recovery** media. Routine
updates do not need either.

---

## A. Native artifacts

```
xImage
rootfs.squashfs
build-manifest.txt
```

The canonical payload, exactly as the build produced it. This is what
`flash-spare-slot.sh` writes and what the other two formats wrap.

`build-manifest.txt` records every component commit, both artifact digests and
the builder image digest.

---

## B. `.img` — the Creality F005 OTA package

**A `.img` is not a disk image.** It is the package the *stock Creality updater*
consumes. The extension is checked by that updater; it says nothing about the
contents. Inside is an encrypted 7z archive holding metadata and both payloads
split into 1 MiB chunks.

### Installing it

Through the touchscreen or a USB drive, the normal stock firmware-update flow.
For a first test, the CLI entrypoint is more legible about what went wrong:

```sh
/etc/ota_bin/local_ota_update.sh /path/to/NebulaOS-Ender3V3KE-<version>.img
```

### Where it lands — read this before you use it

The stock updater writes whichever A/B slot is **inactive**, then flips the OTA
marker to point at what it just wrote.

```
booted stock  (ota:kernel)   ->  writes kernel2 + rootfs2, sets ota:kernel2
booted custom (ota:kernel2)  ->  writes kernel  + rootfs,  sets ota:kernel
```

So the destination is a property of **which slot your printer is running**, not
of the file. Applied while NebulaOS is booted, a NebulaOS `.img` **overwrites
the stock slot**. If you want to keep stock as a fallback, apply the `.img` only
while booted into stock.

Nothing prevents overwriting stock. There is no vendor-signature check and no
comparison of a partition's existing contents against a Creality release. That
is not the same as "no checks" — the updater validates package extraction,
version, metadata, partition capacity, every chunk's MD5 and the declared full
sizes, and a package that fails any of them is rejected rather than half
installed. What is absent is an *authenticity* check, which is exactly why
custom F005 firmware can be installed through the stock path at all.

### What Creality's updater actually checks (read from a KE, 2026-10-29)

`/etc/ota_bin/local_ota_update.sh` (captured in the workspace as
`_scratch/run23/stock-updater*.txt`), proven by the first install through it
(ke-dev, from OpenKE):

- It unpacks `<file>.img` and reads `<file>/ota_config.in`: **the top directory
  is the file name without `.img`**. A renamed package stops before anything is
  written. `build-img.py` names the directory after `--out`.
- `ota_config.in` must carry `current_version=<v>`. The payloads live in
  `ota_v<v>/` and `ota_update.in`'s `ota_version` must equal `<v>` exactly.
- The "already newest" check compares `<v>` with `/etc/ota_info`'s
  `ota_version` through `[ -ge ]`. With dotted versions (`1.1.0.15`) that test
  errors, which counts as "not newer", so the install goes ahead: a NebulaOS
  `0.9.0` installs over stock `1.1.0.15`. No inflated version number is needed.
- It writes kernel, rootfs and rtos of the other slot plus the marker, prints
  `ota update ok`, and **does not reboot**: Creality's touchscreen does that;
  over SSH it is a soft `reboot`.

`validate-img.py` checks the three package rules. `ota_config.in` is still
synthesised (no vendor one to copy); `--ota-config-template` takes one if
obtained.

---

## C. `.ingenic` — the Ingenic Cloner recovery package

A ZIP consumed by the **Ingenic USB Cloner** with the board in X2000E USB-boot
(mask-ROM) mode. This is the panic button: it works when the printer will not
boot and nothing on the network answers.

It is **not** flashed from a U-Boot command line, and it is not something the
Hardware Agent drives.

### How it is built

NebulaOS does not build one from scratch. It substitutes the canonical payloads
into the official `Ender-3_V3_KE_1.1.0.12.ingenic`, pinned by content in
`manifests/dependencies.conf`, and carries the other 274 archive entries through
untouched: SPL/U-Boot, the MBR/GPT, the per-SoC firmware and DDR descriptors,
the Cloner files, the security keys.

Preserving vendor boot infrastructure is deliberate. The job is to install a
qualified kernel and rootfs, not to take ownership of the bottom of the boot
chain. The validator compares every carried-through entry against the template
individually — a package that embeds the right kernel but a re-encoded U-Boot is
not one to put a printer into mask-ROM for.

### Default layout

```
Slot A:  stock xImage, stock rootfs, stock RTOS      (untouched)
Slot B:  NebulaOS xImage2, rootfs2.squashfs, RTOS copy
marker:  ota:kernel2   ->  boots NebulaOS
```

Stock survives, so you keep a way back. That is a *choice*, not a limit —
`--slot a` overwrites the stock slot instead, and the Cloner programs whatever
its policy names.

### `sn_mac` is preserved

The vendor erase policy is

```
erase_list = "0x0,0x1fffff;0x300000,0xffffffff;"
```

which erases `0x0..0x1fffff` and `0x300000..end`, leaving `0x200000..0x2fffff`
alone. That hole is the `sn_mac` partition, holding your printer's **per-unit
factory MAC address and serial number** — on the reference unit,
`26096911004C14;FCEE11004C14;F005;NEBULA V1.0.0.1`. Stock reads its `wlan0` MAC
from there. The value is programmed per unit, exists nowhere else, and cannot be
regenerated.

Both the packager and the validator parse the erase list and refuse if that hole
is ever closed. Do not widen the erase range.

### This is the more destructive path

`.ingenic` programs whole partitions according to its Cloner policy. It has none
of the narrow safety semantics of the normal update path: no slot-2-only
ownership, no refusal to write the slot you are booted from, no armed/disarm
transaction. Reach for it when the alternatives are gone.

---

## The human boundary

Two physical actions cannot be automated, by anyone:

1. putting the board into mask-ROM mode — power off, hold both buttons for three
   seconds, release reset first, then boot;
2. the power cycle or reset that leaves recovery mode afterwards.

Everything between those is software. Claims that the whole recovery is
autonomous are wrong: the mask-ROM entry is a physical act on a physical button.

---

## Building a release

```sh
# 1. a clean candidate/release build from published source
tools/run-nebulaos-build.sh --candidate <40-char-sha>

# 2. package that one core three ways
scripts/package/package-release.sh \
    --build-run /var/tmp/nebulaos-build/<sha>/run-<id> \
    --template  /path/to/Ender-3_V3_KE_1.1.0.12.ingenic \
    --ota-version <version>
```

Packaging never compiles. It refuses a build that carries no attestation, and it
refuses a core whose bytes disagree with its own build manifest. Both validators
run as part of assembly and a validator failure fails the run.

The vendor `.ingenic` template is 124 MB of redistributed vendor firmware and is
deliberately not committed. `manifests/dependencies.conf` records its SHA-256;
verify any copy you obtain against it.

## Reproducibility

```sh
scripts/package/check-packaging-reproducibility.sh \
    --build-run-a <run-1> --build-run-b <run-2> \
    --template /path/to/template.ingenic
```

The two formats are held to different, explicit standards:

| Artifact | Standard | Why |
|---|---|---|
| `xImage`, `rootfs.squashfs` | byte-identical | the build is reproducible |
| `.ingenic` | byte-identical | plain ZIP, every entry keeps the template's own metadata |
| `.img` | same size + bit-identical extracted tree | see below |

The `.img` **cannot** be byte-identical. The Creality envelope is an encrypted
7z, and AES uses a fresh random salt and IV for every archive, so two archives
over identical plaintext differ in about 99.6% of their bytes. No 7z option pins
the IV. The check therefore requires identical archive *size* — which is what
proves the compressed stream itself is deterministic — plus a bit-identical
extracted content tree, and it records

```
IMG_BYTE_IDENTICAL=NO
IMG_BYTE_IDENTICAL_REASON=encrypted-7z-random-aes-iv
IMG_CONTENT_IDENTICAL=YES
```

rather than redefining byte identity until it passes.

`rootfs.ext2` remains non-reproducible for unrelated ext2 metadata reasons. It is
not a delivery artifact and no release format contains it. See
`docs/REPRODUCIBILITY.md`.

## Related

- `docs/A_B_SLOT_MODEL.md` — the partition and marker mechanics
- `docs/DEVELOPER_UPDATE.md` — updating a working printer (the normal path)
- `docs/DEVELOPER_RECOVERY.md` — what to do when it will not boot
- `docs/DEFERRED_POST_RELEASE_WORK.md` §2 — scope limits and remaining gaps
- `manifests/dependencies.conf` — the pinned template and usbboot revision
