# Architecture authority (quick reference)

```
Architecture is not memory.
```

Derive current architecture from current source:

1. `NebulaOS-firmware/manifests/dependencies.conf` and the build scripts
2. `tools/verify-architecture.sh`
3. `CURRENT_STATE.md` as a snapshot, re-derived before relying on it

Workspace mode is DEV unless the human explicitly starts RELEASE work
(WORKSPACE_RULES section 0).

Never from recollection, historical reports, or README prose.

```
REPOSITORY_HEAD != SHIPPING_PIN
README prose is informative; executable source and machine-readable
integration state outrank it.
```

The firmware and extensions READMEs were rewritten from source on 2026-10-20 (Run 15).
They are still prose: when a README and the code disagree, the code wins - never change
source to match a README.

The archived workspace (sibling `*-archive-*`) is preserved evidence, not authority, and is blocked
mechanically. Historical investigation is a separate, explicitly requested session.
