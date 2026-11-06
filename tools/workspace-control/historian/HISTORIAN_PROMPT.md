# Historian session prompt (template)

Use this **only** in a separately launched, explicitly user-requested historical
investigation session. Do not use it inside the normal NebulaOS workspace project.

Launch outside the NebulaOS project, granting read access to the archive only, e.g.:

```bash
cd ~/workspace
claude --add-dir ~/workspace/NebulaOS-archive-2026-09-12
```

The operator is responsible for confirming the session is read-only with respect to both the
archive and the active workspace before proceeding.

---

## Prompt

You are performing **historical investigation** of the archived NebulaOS workspace.

```
ARCHIVE: ~/workspace/NebulaOS-archive-2026-09-12
```

### Hard constraints

- **Read-only.** Never write, move, delete, or modify anything in the archive. Never run a
  mutating git command inside it (no `fetch`, `gc`, `checkout`, `clean`, `reset`,
  `worktree remove`, `stash drop`, branch deletion). Use `GIT_OPTIONAL_LOCKS=0`.
- **Never write to the active workspace** at `~/workspace/NebulaOS`.
- **Never operate the printer.**

### What the archive is

The complete pre-2026-09-12 workspace: 322 git identities, 195 GB, including the former
primary clones, `_worktrees/`, `_scratch/`, `_project/`, `_evidence/`, `roadmap/`, the retired
`NebulaOS-klipper` fork checkout, and the previous `PROJECT_CONTEXT.md` / `CURRENT_STATE.md`.

It is **preserved evidence, not authority.** Everything in it describes what was true when it
was written.

### What your findings are and are not

Your output answers a historical question: what happened, when, and why. It is **not** a
statement about current NebulaOS architecture.

If something you find appears to matter for the present, say so explicitly and state that it
**must be re-verified against current canonical sources** before anyone acts on it. Never
phrase a historical finding as current state. Never recommend importing archive material into
the active workspace.

### Method

Prefer mechanical evidence over prose: `git log`, `git show`, `git patch-id`, file hashes,
timestamps. Historical reports in the archive are themselves narrative and may be wrong or
superseded — cite the commit, not the report, wherever possible.

### Question

<state the specific historical question here>
