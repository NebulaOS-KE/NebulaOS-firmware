# AGENTS.md

Read [`WORKSPACE_RULES.md`](WORKSPACE_RULES.md) — the operational contract. The short form:

## Mode: DEV by default

```
DEFAULT = DEV. RELEASE only when the human explicitly asks for release
preparation, a release candidate, a release freeze or release qualification.
Never infer RELEASE from a previous session, a clean tree, a firmware build,
a package build, or DEV hardware testing.
```

In DEV, work like a normal workspace: edit → targeted test → fix → test → commit whenever
useful. Dirty trees, unpushed commits, branches, `_worktrees/`, `_scratch/` and parallel
sessions are fine. Validate what an operation actually depends on, nothing else.

Strict, in every mode: the printer (§11), the privilege boundary (§12), and RELEASE work once
the human asks for it.

## Hard rules

1. **Shipping authority is `NebulaOS-firmware/manifests/dependencies.conf`.**
   `REPOSITORY_HEAD != SHIPPING_PIN`.
2. **Architecture comes from current source**, the manifest and `tools/verify-architecture.sh`
   — not from historical reports, README prose or memory (auto-memory is disabled).
   The firmware and extensions READMEs were rewritten from source on 2026-10-20; they are
   still informative only.
3. **Never read the archived workspace** (the sibling `*-archive-*` directory) unless the user
   explicitly asks for historical investigation. A denial is the guardrail working.
4. **Host Klipper is pristine upstream `Klipper3d/klipper`**, owned by the firmware build. The
   retired `NebulaOS-klipper` fork is not cloned here.
5. **The printer** is touched only when the user asks, only through
   `tools/run-nebulaos-hardware.sh`. Never raw ssh/scp/dd, OTA markers, MCU serial, motion or
   heaters.
6. **Do the work.** Do everything you are allowed to do yourself. If a human-only step is
   unavoidable, prepare and validate everything first and hand over exactly ONE idempotent
   command that does all of it and verifies the result.

## Builds and hardware

```
tools/run-nebulaos-build.sh <sha>                       # DEV build of any local commit
NebulaOS-firmware/tools/product-inputs.py current-build # is an existing build still current?
tools/run-nebulaos-hardware.sh --device <id> --control <C> install <X> <ximage> <rootfs>
```

The enrolled printer is **`ke-dev`**. Canonical development baseline (adopted 2026-10-08):
firmware **`b62fa18`**, tag `nebulaos-canonical-baseline-2026-10-08-b62fa18`, recorded in
`NebulaOS-firmware/docs/BASELINE-MANIFEST.txt` (Buildroot 2025.02; hardware-tested, not a
fully qualified release). All new work starts from it on `main`; older candidates (`ba3501a`,
`f97e472`, `9cba50f`) are evidence only. "flash" / "install" means: if `product-inputs.py current-build` says
`PRODUCT_BUILD_CURRENT=NO`, build firmware HEAD first; then install it on `--device ke-dev` with
`<X>` = the build's commit, the hashes from its run's `.nebulaos-build-verified`, and `<C>` = full
40-hex firmware HEAD. Do not ask the human for these. Past runs are journaled in
`~/.local/state/nebulaos-hardware/transactions/`.

A host-side tooling change (Hardware Agent, tests, docs) never requires a Buildroot rebuild.

## Agents

One main programmer works directly; it may run both launchers. `nebulaos-build` and
`nebulaos-hardware` are optional operators for long-running work. `nebula-architect` and
`nebula-verifier` are read-only reviewers: optional in DEV (use them for genuinely
architecture-sensitive or large changes), required in RELEASE. No agent teams.

## Derived state

Root `AGENTS.md`, `CLAUDE.md`, `WORKSPACE_RULES.md`, `.claude/` and `tools/*.sh` are installed
from `NebulaOS-firmware/tools/workspace-control/`. Edit the canonical copy and commit; the human
installs with `NebulaOS-firmware/tools/workspace-control/scripts/apply-workspace-control.sh`.
