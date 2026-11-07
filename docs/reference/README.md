# NebulaOS firmware - generated developer reference

Generated technical reference for `NebulaOS-firmware`, at commit `a53e129`. The NebulaOS
1.0.0 release is firmware `70ad0b0`, which this is a descendant of.

This sits alongside the repository's existing `docs/` - roughly seventy design and analysis
documents, which remain the place to read *why* things are the way they are. These pages answer
*what exists*, exhaustively and from source.

## The pages

| Page | What it is |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | **Start here.** Two slots and the marker that selects them, the boot order, why there is no automatic rollback to stock, the trial after an image install, recovery in order of severity, the build pipeline |
| [MOONRAKER-API.md](MOONRAKER-API.md) | **59** `machine.nebulaos.*` endpoints: HTTP method, JSON-RPC name, handler, the request parameters each handler reads with defaults, and - for 46 of them - the `nebulaos-osconfig` call they make and the keys that helper returns |
| [OSCONFIG.md](OSCONFIG.md) | **18** `nebulaos_osconfig` helper modules - 189 public functions with the `DOMAIN VERB` that reaches each one and the keys it returns. Where the API reference stops |
| [BOOT-SERVICES.md](BOOT-SERVICES.md) | **35** boot services in boot order, each with its full header and the init verbs it really implements, read from its own `case "$1"` |
| [TOOLING.md](TOOLING.md) | **21** build scripts and **62** host tools, kept as two lists because the line between them is what `product-inputs.py` enforces: host tooling never invalidates a built image |
| [RUNTIME-HELPERS.md](RUNTIME-HELPERS.md) | **57** executables the image installs outside `/etc/init.d`, each with what calls it - found by searching, not inferred - and its own header |

`ARCHITECTURE.md` is hand-written: explanation cannot be extracted. Every factual claim in it
names the file it came from, so any sentence can be re-checked.

The other two are **generated** from source by tools in the central NebulaOS repository
(`documentation/agent/tools/gen_firmware_api_reference.py`,
`gen_firmware_services_reference.py`), parsed with Python's `ast` where the source is Python.
Do not edit them by hand; regeneration overwrites.

## Why these two first

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
- **The 56 runtime helpers** in the overlay outside `init.d`, individually - update supervisor,
  clean reset, network apply and the rest. `ARCHITECTURE.md` covers the ones that matter to
  boot, slots and recovery.
- **Buildroot internals, the filesystem layout, and the kernel's part in the image.**
- **Per-service detail.** `BOOT-SERVICES.md` lists all 35 with each script's own stated
  purpose; it does not explain each one's failure behaviour or dependencies.

Those are tracked in the central repository's `documentation/agent/COVERAGE.md`, which reports
firmware coverage against all 194 discovered items rather than against these two pages.

## Verification state

| | |
|---|---|
| Source commit | `832314d` |
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

Regenerate whenever this repository's tip moves - which during a single day of this work meant
`82e1320`, `c377230` and `832314d`. The endpoint count has changed twice: `47e07af` added the
two `machine.nebulaos.cleanup.nebulaos*` endpoints behind the Storage **Free up space** button,
taking the total from 56 to 58, and the 1.0.0 release added `machine.nebulaos.stats` for the
Statistics page, making 59.

At the 1.0.0 release commit `70ad0b0` the manifest pins extensions `f498796` (branch
`production`) and screen `36490ed`, and both match their repositories' tips.

## Response shapes, and why 16 endpoints do not have them

`MOONRAKER-API.md` now resolves, for each endpoint, which `nebulaos-osconfig` call it makes and
which keys that helper's own `return` statements carry. It is extracted with `ast` along the
chain the page already describes, so nothing is transcribed by hand.

Thirteen endpoints are **not** resolved and say so. Some handlers build their answer inside the
Moonraker component rather than delegating one call; some helpers return a value the extractor
cannot read. Those carry *Result keys not resolved from source* instead of a plausible list,
which is the point: to a reader, an invented response example is indistinguishable from a real
one, so a gap is the safer of the two.
