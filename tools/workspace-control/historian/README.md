# Historian — deliberately NOT a normal subagent

The archived workspace is blocked for normal NebulaOS sessions at several layers at once:
project permission deny rules (`Read`/`Edit`/`Write`/`Glob`/`Grep`/`Bash cd`), an OS-level
sandbox filesystem `denyRead`, and the `PreToolUse` hook.

**Subagents inherit those project restrictions.** That is the point, and it is why there is
no `historian` subagent in `.claude/agents/`.

Creating one would require punching an exception through the archive boundary for an agent
that any ordinary session could invoke at any time. A boundary with a general-purpose hole in
it is not a boundary — the normal programming environment would once again be one tool call
away from reasoning about NebulaOS from historical material, which is precisely the failure
this whole guardrail layer exists to prevent.

So this directory ships **documentation and a prompt template only**.

## How historical investigation actually happens

It is a **separately launched, explicitly user-requested session**, started by a human who
has decided that history is the subject of the work — not a side effect of a coding task.

That session:

- is started outside the NebulaOS workspace project, so the NebulaOS project settings
  (and their archive deny rules) are not what governs it
- should be given read-only access to the archive and nothing else
- must never write to the archive, and must never write to the active workspace
- ends when the historical question is answered

Its findings do **not** become architecture authority. If a historical fact turns out to
matter, it must be re-verified against current canonical sources and written into the active
authority layer (`CURRENT_STATE.md`, `docs/architecture/`) as a verified current fact — never
transplanted as narrative. See `WORKSPACE_RULES.md` §7 and §16.

## The rule this preserves

```
The normal programming environment must never consult history automatically.
```

Archive: `~/workspace/NebulaOS-archive-2026-09-12`

`HISTORIAN_PROMPT.md` in this directory is the starting prompt for such a session. It is a
template for a human to use deliberately. Nothing in the normal workspace invokes it.
