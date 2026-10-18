@AGENTS.md

# Claude-specific notes

**"continue" from Tim** means: read `CONTINUE.md` in the workspace root first (state, history,
gap list and the next run's scope, written by the previous session), then resume from it.

**Default mode is DEV.** Do not treat ordinary development as release work, and do not carry
"we are in release mode" over from a previous session. Only the human's explicit words start
RELEASE.

**Architecture is not memory.** Derive it from current source, the firmware manifest
(`NebulaOS-firmware/manifests/dependencies.conf` and the build scripts) and
`tools/verify-architecture.sh`. Automatic project memory is disabled on purpose.

**Be autonomous.** Run tests, builds (`tools/run-nebulaos-build.sh <sha>`) and requested
hardware operations yourself. Never hand the user a sequence of commands; if a human-only trust
boundary is genuinely required, give exactly one idempotent command.

Root `AGENTS.md`, `CLAUDE.md`, `WORKSPACE_RULES.md` and `.claude/` are installed from
`NebulaOS-firmware/tools/workspace-control/`. Edit the canonical copy; the human installs it
with `NebulaOS-firmware/tools/workspace-control/scripts/apply-workspace-control.sh`.
