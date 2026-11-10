# NebulaOS firmware - generated developer reference

Generated technical reference for `NebulaOS-firmware`, at commit `b95b156`. The shipping
release is **NebulaOS 1.0.2**, firmware `3bdf3ff` (tag `v1.0.2`), which this is a descendant
of: `main` carries two commits that are **not** in 1.0.2 (`dc4d9d6`, `b95b156`). Where that
matters, the page says so.

This sits alongside the repository's existing `docs/` - roughly seventy design and analysis
documents, which remain the place to read *why* things are the way they are. These pages answer
*what exists*, exhaustively and from source.

## The pages

| Page | What it is |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | **Start here.** Two slots and the marker that selects them, the boot order, why there is no automatic rollback to stock, the trial after an image install, recovery in order of severity, the build pipeline |
| [MOONRAKER-API.md](MOONRAKER-API.md) | **59** `machine.nebulaos.*` endpoints: HTTP method, JSON-RPC name, handler, the request parameters each handler reads with defaults, and - for 49 of them - the `nebulaos-osconfig` call they make and the keys that helper returns |
| [OSCONFIG.md](OSCONFIG.md) | **18** `nebulaos_osconfig` helper modules - 190 public functions with the `DOMAIN VERB` that reaches each one and the keys it returns. Where the API reference stops |
| [BOOT-SERVICES.md](BOOT-SERVICES.md) | **36** boot services in boot order, each with its full header and the init verbs it really implements, read from its own `case "$1"` |
| [TOOLING.md](TOOLING.md) | **21** build scripts and **62** host tools, kept as two lists because the line between them is what `product-inputs.py` enforces: host tooling never invalidates a built image |
| [RUNTIME-HELPERS.md](RUNTIME-HELPERS.md) | **58** executables the image installs outside `/etc/init.d`, each with what calls it - found by searching, not inferred - and its own header |

`ARCHITECTURE.md` is hand-written: explanation cannot be extracted. Every factual claim in it
names the file it came from, so any sentence can be re-checked.

The other five are **generated** from source by tools in the central NebulaOS repository
(`documentation/agent/tools/gen_firmware_*.py`), parsed with Python's `ast` where the source is
Python. Do not edit them by hand; regeneration overwrites - each carries the generator, the
source commit and the date in an HTML comment on its first line.

## Why the API and the boot order came first

They are the firmware's two public surfaces.

**The API** is how everything outside Klipper changes NebulaOS settings - the touchscreen,
Mainsail, anything else. Getting it wrong, or guessing a parameter name, breaks a client.

**The boot order** is the architecture. These scripts run in numeric order and depend on the
ones before them: revert safety and the persistent datastore come up before anything that
could need undoing, the MCU guard before Klipper, and the image trial and confirm-good steps
last, after everything that could fail has had its chance. Reading that table top to bottom is
the most direct description of how a NebulaOS printer starts.

## What is not here yet

Honest list, so nothing looks finished that is not:

- **Response shapes for the API.** Responses come from the `nebulaos-osconfig` helper at
  runtime, so documenting them from the component source alone would mean inventing them. Read
  `usr/lib/nebulaos/python/nebulaos_osconfig/` for the real shapes, and
  `tests/nebulaos-osconfig-tests.py` for fixtures.
- **Whether the freeze mitigations work.** `ARCHITECTURE.md` describes the black box, the
  lockup panics and the two no-sleep settings as what the image does. Nothing here says the
  freeze is fixed, and nothing should be read as saying it.
- **Buildroot internals, the filesystem layout, and the kernel's part in the image.**
- **Per-service detail.** `BOOT-SERVICES.md` lists all 36 with each script's own stated
  purpose; it does not explain each one's failure behaviour or dependencies.

Those are tracked in the central repository's `documentation/agent/COVERAGE.md`, which reports
firmware coverage against all 194 discovered items rather than against these two pages.

## Verification state

| | |
|---|---|
| Source commit | `b95b156` |
| Release described | 1.0.2, firmware `3bdf3ff` |
| Hardware verification | **none** |

Nothing in this reference was observed on a printer. It is established from the source: that
endpoints are registered, that services exist and in what order, and what each script's own
header says it does. A header comment is the author's description, not an independent analysis
of behaviour.

The firmware's own test suites exist and are worth running, but have not been run for this
reference - the API and service lists do not depend on them.

## Regenerating

From the central NebulaOS repository:

```sh
python3 documentation/agent/tools/gen_firmware_api_reference.py \
    <path-to-NebulaOS-firmware> <path-to>/docs/reference/MOONRAKER-API.md
python3 documentation/agent/tools/gen_firmware_services_reference.py \
    <path-to-NebulaOS-firmware> <path-to>/docs/reference/BOOT-SERVICES.md
```

Regenerate whenever this repository's tip moves. The endpoint count has changed twice:
`47e07af` added the two `machine.nebulaos.cleanup.nebulaos*` endpoints behind the Storage
**Free up space** button, taking the total from 56 to 58, and `machine.nebulaos.stats` for the
Statistics page made 59. **The 1.0.2 work added no endpoint** - it added a boot service
(`S03nebulaos-blackbox`), a runtime helper (`nebulaos-blackbox`) and one osconfig function.

At the 1.0.2 release commit `3bdf3ff` the manifest pins kernel `95d0321e` (branch `openke`),
extensions `178a0c2` (branch `production`), screen `fd47cb6` and upstream Klipper `58bd67db`.
Kernel, extensions and screen all match their repositories' tips, so for those three the
documented code is the shipped code.

## Response shapes, and why some endpoints do not have them

`MOONRAKER-API.md` now resolves, for each endpoint, which `nebulaos-osconfig` call it makes and
which keys that helper's own `return` statements carry. It is extracted with `ast` along the
chain the page already describes, so nothing is transcribed by hand.

The endpoints that are **not** resolved say so. Some handlers build their answer inside the
Moonraker component rather than delegating one call; some helpers return a value the extractor
cannot read. Those carry *Result keys not resolved from source* instead of a plausible list,
which is the point: to a reader, an invented response example is indistinguishable from a real
one, so a gap is the safer of the two.
