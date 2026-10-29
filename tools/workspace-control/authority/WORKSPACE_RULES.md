# WORKSPACE_RULES.md

The operational contract for this workspace. `AGENTS.md` is the short form; this is the detail.

---

## 0. Workspace mode — DEFAULT = DEV

```
NEBULAOS WORKSPACE MODE

DEFAULT = DEV

Agents MUST assume DEV unless the human explicitly requests
release preparation, release candidate creation, release freeze
or release qualification.

Agents MUST NOT infer RELEASE mode from previous sessions.

DEV hardware testing is not release mode.
A clean tree is not release mode.
A firmware build is not release mode.
A package build is not release mode.
```

The guiding rule: **strictness at boundaries, not strictness everywhere.**

| level | when | what is required |
|---|---|---|
| **DEV** | always, by default | nothing beyond the operation's own inputs. Dirty trees, unpushed commits, local branches, worktrees, `_scratch/`, parallel sessions, unfinished code are all normal. Targeted tests, simulators, static checks. |
| **DEV_HARDWARE** | the human asks to test on the enrolled dev printer | the physical-safety checks of §11: enrolled identity, pinned host key, explicit artifact hashes, known partitions, idle, heaters zero, safe Stock transition, write + readback verification. Results read `DEV_INSTALL=YES RELEASE_QUALIFIED=NO HARDWARE_QUALIFIED=NO`. |
| **RELEASE** | only when the human says so ("let's make a release", "freeze", "qualify") | clean intended repos, published exact commits, source freeze, `--release` identity gate, authenticated attestation, independent final verification, isolated release build (ccache off), Build A + Build B, byte reproducibility, packaging, release evidence. |

If source changes after a release freeze: `RELEASE_FREEZE_INVALIDATED=YES`. Return to DEV and
start the release again; never carry old evidence forward.

**Operation-scoped validation.** Unexpected state that can influence THIS operation refuses
this operation; unrelated state never refuses anything. A Hardware Agent unit test cares about
its Python and fixtures; a DEV build cares about the commit it builds and the pins it consumes;
a DEV install cares about PRODUCT_HEAD, artifact hashes, the enrolled device and its state.

**Reviewers.** `nebula-architect` / `nebula-verifier` are tools, not gates, in DEV: use them
when a change is genuinely architecture-sensitive or large. They are required in RELEASE.

## 1. Active repositories

Five NebulaOS development repositories are active here, canonical remotes under
`https://github.com/NebulaOS-KE/` (organisation since 2026-10-29, Run 23; before: `coreflake1`).

| Path | Canonical remote | Default branch | Role |
|---|---|---|---|
| `NebulaOS-firmware/` | `NebulaOS-KE/NebulaOS-firmware` | `main` | Integration & build authority; owns every dependency pin |
| `NebulaOS-klipper-extensions/` | `NebulaOS-KE/NebulaOS-klipper-extensions` | `main` | NebulaOS-owned host Klipper functionality |
| `NebulaOS-klipper-mcu/` | `NebulaOS-KE/NebulaOS-klipper-mcu` | `main` | GD32F303 application firmware development |
| `NebulaOS-kernel/` | `NebulaOS-KE/NebulaOS-kernel` | `openke` | X2000 Linux kernel development |
| `NebulaOS-nebulascreen/` | `NebulaOS-KE/NebulaOS-nebulascreen` (renamed from `NebulaOS-guppyscreen` 2026-10-24; the old URL redirects, never recreate it) | `main` | Touchscreen frontend (NebulaScreen, based on GuppyScreen) |

In DEV any branch may be checked out. The workspace root is deliberately **not** a git
repository.

## 2. Paths

Canonical source is explicit: the five repositories above. Everything else is non-canonical.

Sanctioned DEV space, never canonical source:

```
_worktrees/   git worktrees of the five repos (git worktree add _worktrees/<name> ...)
_scratch/     anything temporary
```

Their presence never invalidates the workspace. Delete them when done.

Never recreate these legacy authority-looking paths in the active root (they are what once let
agents audit the wrong generation; the DEV gate fails on them):

```
_project/   _evidence/   roadmap/   NebulaOS-klipper/   NebulaOS/
RC2-MANIFEST.txt   FINAL-PREHW-RC-MANIFEST.txt   PROJECT_CONTEXT.md
```

## 3. Authority hierarchy

Highest wins.

1. **Current source and the firmware manifest** (`NebulaOS-firmware/manifests/dependencies.conf`
   plus build/integration scripts) — what NebulaOS ships and how it is built.
2. **Canonical GitHub remote** — what is *published*. Matters for RELEASE; in DEV, local
   commits are legitimate.
3. **`CURRENT_STATE.md`** — a human-readable snapshot; re-derive before relying on it.
4. **Historical reports and README prose** — may explain *why*; never override source.

## 4. Development HEAD vs shipping pin

```
REPOSITORY_HEAD != SHIPPING_PIN
```

The firmware manifest decides what ships. A pin that trails its repository HEAD is normal.

**Canonical development baseline.** All new NebulaOS development after 2026-10-08 starts from
canonical baseline `b62fa18` (tag `nebulaos-canonical-baseline-2026-10-08-b62fa18`, identities in
`NebulaOS-firmware/docs/BASELINE-MANIFEST.txt`), unless an explicit migration or baseline
supersession decision is recorded there. Historical candidates such as `ba3501a` and `f97e472` are
evidence and reference points only and must not be the starting source for new feature or bug-fix
branches. The baseline is a development baseline: it does not claim supervised physical
qualification (motion, heating, a real print, power-loss recovery), and it is not the
`QUALIFIED_BASELINE_TAG` the build gates compare against - promoting it to a qualified release is a
separate, explicit step.

## 5. Extensions `main` vs `production`

- `main` — development branch, checked out here.
- `production` — the runtime branch Moonraker follows on the printer.

The firmware manifest declares `KLIPPER_EXTENSIONS_BRANCH=production` and pins the commit. The
RELEASE gate requires the pin to equal the remote `production` tip; `main == production` is
never required.

## 6. Retired repositories

- **`NebulaOS-klipper`** is the retired host-Klipper fork: not the runtime source, never cloned here.
- **Host Klipper** is official upstream `Klipper3d/klipper`, pinned by the manifest and checked
  out by the build into `NebulaOS-firmware/vendor/`. It stays pristine.

## 7. Archive prohibition

The archived previous workspace generation (the sibling `*-archive-*` directory) is preserved
evidence, not authority. Do not read it unless the user explicitly asks for historical
investigation (a separate session, see §15). It is blocked mechanically; a denial is the
guardrail working.

## 8. Identity gate

```
tools/verify-workspace-identity.sh            # DEV (default): fast, offline
tools/verify-workspace-identity.sh --local    # strict audit checks, offline
tools/verify-workspace-identity.sh --release  # strict + every HEAD == canonical remote
```

- **DEV** fails only when this is not a sound workspace: a canonical repo missing, a legacy
  authority path or nested archive in the root, the root itself a git repo. Branches, dirty
  trees, unpushed commits, worktrees, control-layer drift and sentinels are `WARN`. The
  PreToolUse hook runs this mode; it never blocks an ordinary edit.
- **`--local`** adds the strict checks without the network: canonical branches, one worktree,
  clean trees, no drift, sentinels, pin ancestry, MCU sidecar.
- **`--release`** (alias `--full`) adds the canonical-remote comparison. RELEASE work, release
  builds (`--candidate`, `--qualified`) and RELEASE-mode device installs use it. An unresolved
  remote is a failure, never a downgrade.

## 9. PRODUCT vs CONTROL, and the three qualifications

- **`PRODUCT_HEAD`** — the commit whose build produced an image.
- **`CONTROL_HEAD`** — the host-side tooling used to operate on it (Hardware Agent, tests,
  docs, packaging, workspace control).

Moving CONTROL_HEAD never invalidates a built product. `NebulaOS-firmware/tools/product-inputs.py`
classifies paths mechanically (deny-list: everything is a product input unless listed as
host-side) and answers `changed <base> [<head>]` and `current-build [<head>]`. Rebuild only when
product inputs changed.

Keep these separate and never let one imply another:

- **`BUILD_VERIFIED`** — this exact commit was built and passed `06-verify`.
- **`DEV_INSTALL`** — this exact build was installed on the dev printer and passed Part 1.
- **`HARDWARE_QUALIFIED` / `RELEASE_QUALIFIED`** — RELEASE-mode evidence only.

## 10. Builds

```
tools/run-nebulaos-build.sh <40-hex sha>              # DEV build (default)
tools/run-nebulaos-build.sh --candidate <40-hex sha>  # RELEASE-grade, explicit
tools/run-nebulaos-build.sh --qualified <40-hex sha>  # RELEASE baseline reproduction
```

A DEV build clones the **local** firmware repository at that commit (pushed or not), runs
`build.sh` in dev mode, and writes a build record with `BUILD_MODE=dev`. It does not care about
unrelated dirty or unpushed work. Release modes keep the full gate: `--release` identity,
five clean repos, clone from the canonical remote, `build.sh --release`.

Full Buildroot builds are expensive. The development loop is edit → targeted test → fix →
relevant suite. Build only when product inputs changed and you need an image.

## 11. Printer safety (DEV_HARDWARE)

Never touch the printer unless the user asks for a hardware task. The only route is:

```
tools/run-nebulaos-hardware.sh --device <id> --control <40-hex C> <operation>
```

| operation | kind |
|---|---|
| `inspect`, `status`, `diagnose`, `verify` | read-only |
| `capture <profile>` | read-only, fixed profile table (TOOL-01) |
| `exercise <profile> EXERCISE_CONFIRM=<profile>` | reversible, self-undoing; refuses motion/heat/flash/reboot text (TOOL-02) |
| `restart <klipper\|moonraker\|nebulascreen\|guppyscreen\|webcam\|nginx>` | repair |
| `reboot REBOOT_CONFIRM=NEBULAOS` | software reboot of an idle NebulaOS back into NebulaOS (boot timing); refused unless the marker already selects NebulaOS; writes nothing |
| `rtos-logo RTOS_LOGO_CONFIRM=RTOS2` | writes the pinned NebulaOS RTOS image (boot logo) to rtos2 (p4) only, after a verified host backup; idle + marker on NebulaOS; read-back; never rtos (p3) |
| `rtos-logo-restore <backup-sha256> RTOS_RESTORE_CONFIRM=RTOS2` | writes such a backup back to rtos2 |
| `purge-dev-leftovers PURGE_CONFIRM=DEV-LEFTOVERS` | removes the agent's fixed, human-approved list of development leftovers from an idle NebulaOS printer's data partition; each path re-checked on the printer; never slot A's files (2026-10-15) |
| `install <X> <ximage-sha256> <rootfs-sha256>` | flash |

The main agent and `nebulaos-hardware` may run every operation. These stay strict in every
mode, inside the agent: enrolled device, eMMC CID + sn_mac identity, pinned per-OS host keys,
per-device lock, idle + heater-zero proof, Stock way-out proof, known partition layout, hash
and readback verification. The dev policy: preserve Stock, software reboot to Stock, write the
NebulaOS slot, verify, software reboot to NebulaOS, verify.

The device profile's `INSTALL_MODE` (human-owned) selects DEV_INSTALL or RELEASE_INSTALL; a
RELEASE device additionally needs the `--release` gate, published C and X, and an HMAC v2
attestation. Never raw ssh/scp/dd/block devices/offsets/arbitrary commands — they are not part
of the agent interface. Motion, heating, calibration and MCU flashing are not operations.
Enrollment and the credential store are human-only.

## 12. The workspace control layer and the privilege boundary

Root `AGENTS.md`, `CLAUDE.md`, `WORKSPACE_RULES.md`, `.claude/` and `tools/*.sh` are installed
from `NebulaOS-firmware/tools/workspace-control/` (see its `MANIFEST`).

- Edit the canonical copy, commit it, then the human runs **one** command:
  `NebulaOS-firmware/tools/workspace-control/scripts/apply-workspace-control.sh`
  (installs, verifies no drift, runs the control-layer tests; idempotent, fails closed).
- Drift between canonical and installed is a DEV `WARN`, never a block.
- **The privilege boundary is unchanged and small:** leaving the sandbox is allowed only for
  the two launchers, as one lone invocation, with bytes equal to the committed canonical copy,
  and only for the main agent or that launcher's operator agent. Reviewers never. No container
  engine, ssh, dd or sync outside the sandbox. Installing `.claude/` stays a human action.

Any human-only step is delivered as ONE idempotent command that does everything and verifies
itself — never a sequence of instructions.

## 13. Launch location

Start sessions from the workspace root (`/home/tim/workspace/NebulaOS`): `.claude/` loads from
the primary project directory. Each repository carries a git-excluded sentinel
`<repo>/.claude/settings.local.json` that blocks edits when a session is started inside a repo.

## 14. Architecture invariants

`tools/verify-architecture.sh` checks that current source still satisfies the NebulaOS
architecture. Invariants that cannot be checked honestly are reported `DOCUMENTED_ONLY`.

## 15. Historical investigation is a separate session

The archive is blocked for normal sessions (permission deny rules, sandbox `denyRead`, the
PreToolUse hook). Historical investigation is a separately launched, explicitly requested
session: `NebulaOS-firmware/tools/workspace-control/historian/README.md`.
