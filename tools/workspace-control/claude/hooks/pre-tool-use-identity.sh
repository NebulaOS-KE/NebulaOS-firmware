#!/usr/bin/env bash
#
# PreToolUse hook - STRICTNESS AT BOUNDARIES, NOT STRICTNESS EVERYWHERE.
#
# The workspace is in DEV mode unless a human explicitly starts release work
# (WORKSPACE_RULES section 0). Ordinary edits and sandboxed commands are only
# checked for being in the right WORKSPACE (identity gate --dev: no network, no
# clean-tree, branch, worktree or drift requirement). What stays strict here
# is the privilege boundary: who may leave the sandbox, with which file.
#
# FAILS CLOSED on the boundary: if the privilege guard cannot evaluate a
# request that asks for privilege, names a launcher or names an engine, it
# denies.
#
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0

deny(){ printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
        "$(printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '"NebulaOS guardrail: blocked."')"; exit 0; }
allow(){ exit 0; }   # silence = proceed to normal permission handling

INPUT=$(cat 2>/dev/null || true)

ROOT=${CLAUDE_PROJECT_DIR:-}
if [ -z "$ROOT" ]; then
  ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd -P) || \
    deny "NebulaOS guardrail: cannot resolve workspace root. Start Claude from the NebulaOS workspace root."
fi

# --- launch location -------------------------------------------------------
# .claude/settings.json (hooks, permissions, subagents) loads from the PRIMARY
# project directory. If that is one of the five repos rather than the workspace
# root, the root guardrails are not in force.
#
# The root is identified STRUCTURALLY, never by a hard-coded absolute path: it
# is the directory holding both the installed identity gate and the tracked
# canonical control source that gate was installed from. A nested repo has
# neither, so the check below still catches the launch-location mistake it
# exists for. Pinning an absolute path here instead would mean that relocating
# the workspace denies every edit - including the edit that would fix the pin.
RROOT=$(readlink -f "$ROOT" 2>/dev/null || echo "$ROOT")
SELF_ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd -P) || SELF_ROOT=$RROOT
if [ ! -x "$RROOT/tools/verify-workspace-identity.sh" ] \
|| [ ! -f "$RROOT/NebulaOS-firmware/tools/workspace-control/MANIFEST" ] \
|| [ "$RROOT" != "$SELF_ROOT" ]; then
  deny "NEBULAOS_WORKSPACE_ROOT_VALID=NO

Claude's primary project directory is:
  $RROOT

Source modification is blocked because the NebulaOS root guardrails
(identity gate, archive isolation, architecture invariants, reviewers)
load only from the workspace root.

Restart Claude from:
  $SELF_ROOT

Reading for diagnosis is still permitted."
fi
ROOT=$RROOT

# --- archive isolation (Bash route) ----------------------------------------
# The permission deny rules and the sandbox both cover this; this is the third
# layer, and the one that produces an explanatory message.
case "$INPUT" in
  *NebulaOS-archive*)
    deny "NebulaOS guardrail: the archived workspace is out of bounds.

/home/tim/workspace/NebulaOS-archive-* is preserved evidence, not
authority, and normal sessions must not read it. Historical investigation is a
separate, explicitly user-requested session - see
NebulaOS-firmware/tools/workspace-control/historian/README.md."
    ;;
esac

# --- privileged execution boundary -----------------------------------------
# The ONLY way a command escapes Claude sandbox in this build is the Bash tool
# dangerouslyDisableSandbox parameter. Measured on this host: an unsandboxed
# shell regains the user full supplementary group set, gid 972 included, which
# is the container group. So "may reach the container engine" and "may do
# anything as this user" are the same grant.
#
# Enforced here rather than in agent frontmatter because scoped Bash grants
# are not enforced in this build - see the note under read-only reviewers.
#
# Exactly these caller/file pairs may run unsandboxed, each running one file:
#
#   nebulaos-build, main agent     tools/run-nebulaos-build.sh [mode] <40-hex sha>
#   nebulaos-hardware, main agent  tools/run-nebulaos-hardware.sh <semantic operation>
#
# The main agent is the session's own principal: a payload with NO agent_type
# key. A present-but-blank, null, padded or non-string agent_type is not the
# main agent and not any other principal. Reviewers never get either launcher.
# What makes a launcher safe is its fixed, content-bound bytes and its semantic
# grammar, not which agent typed it.
#
# What makes that mechanical is the UNSANDBOXED check, where the whole command
# must be one lone launcher invocation. The sandboxed check of rule 3 is an
# early, explanatory refusal only: it reads the plain command, and wrappers or
# globs can get past it. That does not matter, because a sandboxed launcher
# cannot reach a printer - no network, and the credential store is denied by
# settings.json denyRead.
#
# The control-layer sync is deliberately NOT such a pair. An earlier revision
# granted the main agent an unsandboxed sync, to resolve what looked like a
# deadlock: this build sandboxes .claude/hooks read-only, so a sandboxed sync
# cannot install a hook change, and an agent that edits the canonical hook then
# cannot install it. That read-only path is not only an obstacle - it is the
# property that stops an agent installing its own authority layer. The main
# agent CAN edit canonical hooks, settings, agent definitions and the authority
# documents, because those are ordinary tracked source; before that grant the
# edit was inert, and after it one sanctioned command made it live. Installing
# the authority layer requires a human running the sync out of band. That is
# the control, not a defect, and the installer says so when it fails.
#
# BINDING IS BY CONTENT, NOT BY PATH. Comparing realpath(allowed) against
# realpath(typed) is satisfied by NAMING the path: both sides derive from the
# same string, so it is true for whatever file occupies it. The workspace root
# is not a git repository and tools/ is unversioned derived state that this
# sandbox permits writing, so a path-only check would let any caller overwrite
# the launcher and have this hook run it with host privilege. Before allowing
# the escape, the target bytes are compared against the tracked canonical blob
# at firmware HEAD. An uncommitted or altered launcher is refused.
#
# Rules:
#   1. the container engine invoked directly in COMMAND POSITION is refused for
#      every caller. This is an affordance against accident, NOT containment:
#      indirect forms (xargs, find -exec, sh -c) are not matched, and cannot be
#      in general. The real containment is that a sandboxed caller has no
#      socket, and that the launcher reaches the engine through build.sh as a
#      subprocess this hook structurally never observes.
#   2. dangerouslyDisableSandbox is refused unless the request is the pair
#      above, with verified content, no chaining, no wrapper and no extra
#      arguments.
#   3. each launcher is refused to every caller but its own principals,
#      sandboxed or not: the build launcher to nebulaos-build and the main
#      agent; the hardware launcher to nebulaos-hardware and the main agent.
#   4. the hardware agent is refused device-contact commands outright. It
#      reaches a printer only through its launcher, whose command word is not
#      in the refused set.
#
# Fail-closed SCOPE: if the interpreter cannot run, the request is refused when
# it asked for privilege, OR named a launcher path, OR names an engine. Rules
# that apply to sandboxed requests would otherwise vanish silently along with
# the interpreter.
PRIV_VERDICT=$(printf '%s' "$INPUT" | NEBULA_ROOT="$ROOT" python3 -c '
import json,os,re,shlex,subprocess,sys

BUILD_AGENT="nebulaos-build"
HW_AGENT="nebulaos-hardware"

def out(msg): print("DENY:"+msg); sys.exit(0)

# Exit NON-ZERO on unparseable input so the bash fail-closed net below sees
# it. Exiting 0 meant a truncated payload carrying a privilege request was
# allowed: the interpreter reported no verdict, and the net only fires on a
# non-zero exit. Measured. A guard whose header says it fails closed must not
# have a shape of input that slips through silently.
try: d=json.load(sys.stdin)
except Exception: sys.exit(3)
if not isinstance(d,dict): sys.exit(3)

# agent_type is NOT stripped or coerced. Whitespace must not promote a caller
# to a different principal, and a blank-but-present value must not read as the
# main agent. A non-string is not a principal at all.
agent=d.get("agent_type")
if not isinstance(agent,str): agent=""
# The main agent is a payload with NO agent_type key at all. Present-but-blank,
# null or non-string is not the main agent (see the header).
is_main = "agent_type" not in d
ti=d.get("tool_input") or {}
if not isinstance(ti,dict): ti={}
tool=d.get("tool_name")
if not isinstance(tool,str): tool=""

# Any value that is not absent, False, or an explicitly false string counts as
# a privilege request. Recognising only True and "true" meant an int 1 or a
# "yes" skipped the escape branch ENTIRELY - the bash fail-closed net does not
# catch that, because the interpreter exits 0 with no verdict. Whether this
# client coerces truthy non-booleans upstream is not knowable from in here, so
# the guard does not depend on the answer.
raw=ti.get("dangerouslyDisableSandbox")
if raw is None:               sandbox_off=False
elif isinstance(raw,bool):    sandbox_off=raw
elif isinstance(raw,str):     sandbox_off = raw.strip().lower() not in ("","false","0","no","off")
else:
    try: sandbox_off=bool(raw)
    except Exception: sandbox_off=True

if tool!="Bash":
    if sandbox_off: out("Unsandboxed execution was requested on a non-Bash tool. Refused.")
    sys.exit(0)

cmd=ti.get("command")
if not isinstance(cmd,str): cmd=""
if not cmd.strip():
    if sandbox_off: out("Unsandboxed execution was requested with no command. Refused.")
    sys.exit(0)

root=os.environ["NEBULA_ROOT"]
FW=os.path.join(root,"NebulaOS-firmware")
CANON="tools/workspace-control/scripts/"
def rp(*q): return os.path.realpath(os.path.join(root,*q))
BUILD={rp("tools/run-nebulaos-build.sh"), rp("NebulaOS-firmware/"+CANON+"run-nebulaos-build.sh")}
HW={rp("tools/run-nebulaos-hardware.sh"), rp("NebulaOS-firmware/"+CANON+"run-nebulaos-hardware.sh")}

try: toks=shlex.split(cmd)
except Exception: toks=[]

ENGINES=("dock"+"er","pod"+"man")
PREFIX=("sudo","env","nohup","time","stdbuf","nice","exec","command","builtin")
# Device contact, refused to the hardware agent outright. Three families, and
# the second and third were missing until an adversarial test caught them:
#   1. remote shell / copy        ssh scp sftp rsync lftp ftp tftp sshpass
#   2. HTTP and raw sockets       curl wget nc socat websocat ...  - the printer
#      speaks Moonraker over HTTP on 7125, so an HTTP client IS device contact
#      here, not a generic fetch tool
#   3. LAN discovery and serial   nmap arp-scan arping fping, and the serial
#      terminals plus dd, which is the partition-writing primitive this agent
#      must never use directly (flash-spare-slot.sh owns every write)
#
# This list is defence in depth, not the only barrier. The agent runs sandboxed
# for everything except the launcher, and the sandbox denies network egress by
# policy, so a hand-rolled socket in an interpreter does not reach the printer
# either. What this list adds is a clear, early refusal with a reason, and
# coverage of the unsandboxed-attempt case.
DEVICE=("ssh","scp","sftp","ping","ping6","telnet","nc","ncat","netcat","socat",
        "picocom","minicom","cu","stty","screen","tio","dd",
        "avrdude","dfu-util","esptool.py","esptool",
        "curl","wget","httpie","xh","aria2c","websocat","wscat",
        "rsync","lftp","ftp","tftp","sshpass","ssh-keyscan",
        "nmap","arp-scan","arping","fping","traceroute","tracepath","iperf","iperf3")

SEGSPLIT="[;|&\n\r()"+chr(96)+"]"
def command_words(text):
    words=[]
    for seg in re.split(SEGSPLIT,text):
        if not seg.strip(): continue
        try: st=shlex.split(seg)
        except Exception: st=seg.split()
        k=0
        while k < len(st):
            w=st[k]
            if w.split("/")[-1] in PREFIX or w.startswith("-") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=",w):
                k+=1; continue
            break
        if k < len(st): words.append(st[k].split("/")[-1])
    return words

CW=command_words(cmd)

# --- 1. container engine in command position, any caller -------------------
for base in CW:
    if base in ENGINES:
        out("Direct use of the "+base+" command through the Bash tool is refused for every\n"
            "caller, including the main agent.\n\n"
            "Container access is not granted as a command. It is granted only as the approved\n"
            "build launcher, which reaches the engine through NebulaOS-firmware/build.sh as a\n"
            "subprocess:\n\n"
            "  tools/run-nebulaos-build.sh <expected-firmware-sha>   (nebulaos-build agent only)\n\n"
            "Main agent: delegate the build to the nebulaos-build subagent.")

# --- 4. the hardware agent may not touch a device --------------------------
if agent==HW_AGENT:
    for base in CW:
        if base in DEVICE:
            out("The "+HW_AGENT+" agent is refused the "+base+" command.\n\n"
                "It reaches a printer only through its launcher, which composes every device\n"
                "command in reviewed control code against an enrolled device profile:\n\n"
                "  tools/run-nebulaos-hardware.sh --device <id> --control <40-hex C> <operation>\n\n"
                "Operations: inspect status diagnose capture exercise restart reboot verify install.")

# one plain command: no chaining, redirection, substitution or expansion
bad=set(";&|<>(){}$\n\r"); bad.add(chr(96))
chained=any(c in cmd for c in bad)

t2=list(toks)
if t2 and t2[0] in ("bash","sh","/bin/bash","/bin/sh","/usr/bin/bash","/usr/bin/sh","source","."):
    wrapped=True; t2=t2[1:]
else:
    wrapped=False

target=None; args=[]
if t2:
    script,args=t2[0],t2[1:]
    if os.path.isabs(script): cand=script
    else:
        cwd=d.get("cwd")
        cand=os.path.join(cwd,script) if isinstance(cwd,str) and cwd else None
    if cand:
        try: target=os.path.realpath(cand)
        except Exception: target=None

is_build = bool(target) and target in BUILD
is_hw    = bool(target) and target in HW

# The hardware operation, read past --device/--control. Rule 3 needs it before
# the full grammar check below: the main agent grant excludes install.
def hw_op(a):
    a=list(a)
    while len(a)>=2 and a[0] in ("--device","--control"): a=a[2:]
    return a[0] if a else ""

# --- 3. launchers are bound to their own principals, sandboxed or not ------
if is_hw and agent!=HW_AGENT:
    if not is_main:
        out("The hardware launcher may only be invoked by the "+HW_AGENT+" agent or the\n"
            "main agent. Caller: "+(agent or repr(d.get("agent_type")))+".")

if is_build and agent!=BUILD_AGENT and not is_main:
    out("The approved build launcher may only be invoked by the "+BUILD_AGENT+" agent or\n"
        "the main agent. Caller: "+(agent or repr(d.get("agent_type")))+".\n\n"
        "Reviewers do not build.")

def content_is_canonical(path):
    # The executed bytes must equal the tracked canonical blob at firmware HEAD.
    # Path identity is not enough: the installed copy is unversioned derived
    # state in a directory this sandbox permits writing.
    try:
        with open(path,"rb") as fh: have=fh.read()
    except Exception:
        return (False,"the launcher could not be read")
    try:
        r=subprocess.run(["git","-C",FW,"cat-file","blob",
                          "HEAD:"+CANON+os.path.basename(path)],
                         stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
    except Exception:
        return (False,"the canonical blob could not be read from git")
    if r.returncode!=0:
        return (False,"the launcher is not tracked at firmware HEAD")
    if have!=r.stdout:
        return (False,"the launcher on disk differs from the tracked canonical blob")
    return (True,"")

# --- 2. the sandbox escape -------------------------------------------------
if sandbox_off:
    if not ((agent==BUILD_AGENT and is_build) or (agent==HW_AGENT and is_hw)
            or (is_main and (is_hw or is_build))):
        out("Unsandboxed execution is refused for "+(agent or "the main agent")+" running this\n"
            "command.\n\n"
            "Leaving the sandbox restores this user full host privilege, so it is granted only\n"
            "to these caller/file pairs, each running exactly one file:\n\n"
            "  nebulaos-build, main agent     tools/run-nebulaos-build.sh [--dev|--candidate|--qualified] <40-hex sha>\n"
            "  nebulaos-hardware, main agent  tools/run-nebulaos-hardware.sh --device <id> --control <C> <op>\n\n"
            "The control-layer sync is NOT in that set. Installing the authority layer\n"
            "requires a human running it out of band - that is the control, not a defect.\n\n"
            "Resolved to: "+str(target))
    if chained or wrapped:
        out("Unsandboxed execution must be a lone invocation of the approved launcher - no\n"
            "chaining, redirection, substitution, expansion, or shell wrapper. Refused.")

    def is_sha(x): return len(x)==40 and all(c in "0123456789abcdef" for c in x)
    def is_sha256(x): return len(x)==64 and all(c in "0123456789abcdef" for c in x)

    if is_build:
        # Exactly three accepted argument shapes. The two flags are SEMANTIC MODES
        # that the launcher maps internally, not pass-through options: --candidate
        # sets NEBULAOS_CANDIDATE_BUILD=1 and nothing else. There is no general
        # VAR=value facility and no route to the build.sh options, so the build
        # agent gains one mode, not an environment.
        #
        #   <40-hex sha>              DEV build (the default)
        #   --dev <40-hex sha>        DEV build, explicit
        #   --candidate <40-hex sha>  RELEASE-grade, explicit opt-in
        #   --qualified <40-hex sha>  RELEASE-grade baseline reproduction
        ok_args = (len(args)==1 and is_sha(args[0])) or \
                  (len(args)==2 and args[0] in ("--dev","--candidate","--qualified") and is_sha(args[1]))
        if not ok_args:
            out("The approved build launcher accepts exactly one of:\n\n"
                "  <40-hex sha>              (DEV build)\n"
                "  --dev <40-hex sha>\n"
                "  --candidate <40-hex sha>  (release-grade)\n"
                "  --qualified <40-hex sha>  (release-grade)\n\n"
                "and forwards no build options. Refused - a qualification build states its\n"
                "source identity and its mode up front.")
    else:
        # The hardware launcher. Its grammar is validated HERE as well as inside
        # the launcher, and deliberately NOT merged with the build grammar above:
        # the two are genuinely different, and a shared validator is exactly where
        # a future mistake would hide.
        #
        # THERE IS NO TARGET ADDRESS ARGUMENT AT ALL any more. The target is an
        # ENROLLED DEVICE ID, resolved against a human-created profile store the
        # agent cannot write. That is strictly stronger than the old
        # --host <RFC1918> constraint: an address is not an identity, DHCP moves
        # leases, and the machine answering at a remembered IP may be a different
        # one. Which addresses may be spoken to at all is now a property of the
        # profile, not of anything an agent can type.
        #
        # Note what is NOT relaxed: rule 4 above still refuses ssh/scp/ping/nc/...
        # to this agent. The launcher is reachable because its command word is
        # run-nebulaos-hardware.sh, not because the device set was weakened.
        #
        #   --device <id> --control <40-hex C> inspect
        #   --device <id> --control <40-hex C> status
        #   --device <id> --control <40-hex C> diagnose
        #   --device <id> --control <40-hex C> capture  <profile>
        #   --device <id> --control <40-hex C> exercise <profile> EXERCISE_CONFIRM=<profile>
        #   --device <id> --control <40-hex C> restart <service>
        #   --device <id> --control <40-hex C> reboot REBOOT_CONFIRM=NEBULAOS
        #   --device <id> --control <40-hex C> rtos-logo RTOS_LOGO_CONFIRM=RTOS2
        #   --device <id> --control <40-hex C> rtos-logo-restore <64-hex> RTOS_RESTORE_CONFIRM=RTOS2
        #   --device <id> --control <40-hex C> verify  <40-hex X> <64-hex> <64-hex>
        #   --device <id> --control <40-hex C> install <40-hex X> <64-hex> <64-hex>
        #
        # C is the control commit - the reviewed, published source of every
        # privileged helper - and is stated explicitly so that installing an OLD
        # product commit still uses CURRENT control machinery.
        a=list(args)
        dev=ctl=None
        while len(a)>=2 and a[0] in ("--device","--control"):
            if a[0]=="--device": dev=a[1]
            else: ctl=a[1]
            a=a[2:]
        if a and a[0].startswith("--"):
            out("The hardware launcher accepts only --device and --control.\n\n"
                "Refused: "+a[0]+"\n\n"
                "There is deliberately no --host, --password or --command. The target is an\n"
                "enrolled device id and every device command is composed by reviewed control\n"
                "code, so there is nothing for an agent to point somewhere else.")
        if not dev or not all(c.isalnum() or c in "-_" for c in dev) or len(dev)>64:
            out("--device must name an enrolled device id: letters, digits, '-' and '_',\n"
                "at most 64 characters. It names a directory under the profile store, so\n"
                "anything else is a path traversal.\n\n"
                "Refused: "+repr(dev))
        if not ctl or not is_sha(ctl):
            out("--control must be a full 40-character lowercase hex control commit.\n\n"
                "Refused: "+repr(ctl)+"\n\n"
                "Privileged helper bytes are read from the git objects at that commit, never\n"
                "from the working tree, so a hardware session states which reviewed control\n"
                "generation it is running or it is not a controlled session.")
        HW_READONLY=("inspect","status","diagnose")
        HW_KEYED=("verify","install")
        HW_SERVICES=("klipper","moonraker","guppyscreen","webcam","nginx")
        # capture/exercise take a profile NAME, never a command: lowercase
        # letters, digits and '-', not starting with '-'. The agent refuses
        # names outside its fixed tables. An exercise changes device state
        # reversibly (self-undoing), so it must state its confirmation as the
        # literal third word EXERCISE_CONFIRM=<the same profile>; a lone
        # invocation cannot pipe it on stdin.
        def is_profile(x):
            return 0<len(x)<=64 and x[0]!="-" and \
                   all(c in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in x)
        ok_args = (len(a)==1 and a[0] in HW_READONLY) or \
                  (len(a)==2 and a[0]=="restart" and a[1] in HW_SERVICES) or \
                  (len(a)==2 and a[0]=="capture" and is_profile(a[1])) or \
                  (len(a)==3 and a[0]=="exercise" and is_profile(a[1])
                   and a[2]=="EXERCISE_CONFIRM="+a[1]) or \
                  (len(a)==2 and a[0]=="reboot" and a[1]=="REBOOT_CONFIRM=NEBULAOS") or \
                  (len(a)==2 and a[0]=="rtos-logo" and a[1]=="RTOS_LOGO_CONFIRM=RTOS2") or \
                  (len(a)==3 and a[0]=="rtos-logo-restore" and is_sha256(a[1])
                   and a[2]=="RTOS_RESTORE_CONFIRM=RTOS2") or \
                  (len(a)==4 and a[0] in HW_KEYED
                   and is_sha(a[1]) and is_sha256(a[2]) and is_sha256(a[3]))
        if not ok_args:
            out("The Hardware Agent launcher accepts exactly:\n\n"
                "  --device <id> --control <40-hex C> inspect\n"
                "  --device <id> --control <40-hex C> status\n"
                "  --device <id> --control <40-hex C> diagnose\n"
                "  --device <id> --control <40-hex C> capture  <profile>\n"
                "  --device <id> --control <40-hex C> exercise <profile> EXERCISE_CONFIRM=<profile>\n"
                "  --device <id> --control <40-hex C> restart klipper|moonraker|guppyscreen|webcam|nginx\n"
                "  --device <id> --control <40-hex C> reboot REBOOT_CONFIRM=NEBULAOS\n"
                "  --device <id> --control <40-hex C> rtos-logo RTOS_LOGO_CONFIRM=RTOS2\n"
                "  --device <id> --control <40-hex C> rtos-logo-restore <64-hex> RTOS_RESTORE_CONFIRM=RTOS2\n"
                "  --device <id> --control <40-hex C> verify  <40-hex X> <64-hex> <64-hex>\n"
                "  --device <id> --control <40-hex C> install <40-hex X> <64-hex> <64-hex>\n\n"
                "Refused - verify and install state their target release and BOTH artifact\n"
                "hashes up front, or they are not controlled operations. Motion, heating,\n"
                "calibration and MCU flashing belong to Part 2 and have no operation here.")
    ok,why=content_is_canonical(target)
    if not ok:
        out("Unsandboxed execution is bound to the launcher CONTENT, not to its path.\n\n"
            "Refused: "+why+".\n\n"
            "Naming an allowed path is not enough. tools/ is unversioned derived state that\n"
            "this sandbox permits writing, so a path-only check would let any caller replace\n"
            "the launcher and have this hook run it with host privilege. Commit the launcher\n"
            "and re-sync, then retry.")
' 2>/dev/null); PRIV_RC=$?

# Interpreter failure denies any request that asked for privilege, named a
# launcher, or names an engine - see fail-closed scope above.
if [ "$PRIV_RC" -ne 0 ]; then
  case "$INPUT" in
    *dangerouslyDisableSandbox*|*run-nebulaos-*|*dock"er"*|*pod"man"*)
      deny "NebulaOS guardrail: the privilege guard could not evaluate this request, and the
request asked for unsandboxed execution, named a launcher, or named a container
engine. Refusing." ;;
  esac
fi

case "${PRIV_VERDICT:-}" in
  DENY:*) deny "${PRIV_VERDICT#DENY:}" ;;
esac

# --- read-only reviewers ---------------------------------------------------
# nebula-architect and nebula-verifier have no Edit/Write/NotebookEdit tool,
# but they DO have Bash - and this build's sandbox permits writes inside the
# working directory, which is the workspace. Scoped Bash grants in agent
# frontmatter were tested against this build and are NOT enforced (a command
# outside the granted scope ran normally), so the tool list cannot carry this
# property on its own.
#
# The PreToolUse payload carries agent_type for subagent calls and omits it for
# the main agent, so enforcement happens here. Classification is done in Python:
# shell glob matching got this wrong (it missed `git -C <path> commit`, because
# the -C option breaks token adjacency), and a guard that looks right while
# missing the obvious case is worse than none.
#
# This is a command-pattern guard, deliberately the third layer - behind the
# absent edit tools and the agents' own instructions - not a kernel boundary.
REVIEW_VERDICT=$(printf '%s' "$INPUT" | python3 -c '
import json,shlex,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
# Matched LOOSELY, on purpose, and in the opposite direction to the privilege
# guard above. There, a padded or re-cased agent_type must not be promoted to
# a privileged principal, so matching is strict and anything unexpected is
# demoted. Here, demoting means a reviewer escapes its read-only policy, so
# anything that looks like a reviewer is treated as one. Same threat, opposite
# safe direction.
_at=d.get("agent_type")
_at=_at.strip().lower() if isinstance(_at,str) else ""
if _at not in ("nebula-architect","nebula-verifier"): sys.exit(0)
cmd=(d.get("tool_input") or {}).get("command","") or ""

# ignore redirections that discard output
scan=re.sub(r"[12]?>>?\s*/dev/null","",cmd) if (re:=__import__("re")) else cmd
scan=re.sub(r"[12]?>&[12]","",scan)

def hit(reason): print(reason); sys.exit(0)

if re.search(r"(?<![0-9])>>?", scan): hit("output redirection")
if re.search(r"\btee\b", scan):      hit("tee")
if re.search(r"\bsed\b[^|;&]*\s-(-in-place|i\b)", scan): hit("in-place sed")
if re.search(r"\bperl\b[^|;&]*\s-[a-zA-Z]*i", scan):      hit("in-place perl")

MUT_CMDS={"rm","mv","cp","touch","mkdir","rmdir","truncate","dd","install",
          "chmod","chown","ln","patch","tar","unzip","make","cmake","pip",
          "pip3","npm","yarn"}
GIT_MUT={"commit","push","add","checkout","switch","reset","clean","stash",
         "merge","rebase","tag","worktree","fetch","pull","rm","mv","apply",
         "cherry-pick","revert","update-ref","branch","gc","prune","filter-branch",
         "am","restore","submodule","remote","config","init","clone"}
GIT_SAFE_REMOTE={"ls-remote"}

try: toks=shlex.split(cmd)
except Exception: toks=cmd.split()

# walk tokens, resetting at shell separators so `a && rm b` is still caught
i=0; fresh=True
while i < len(toks):
    t=toks[i]
    if t in (";","&&","||","|","&"): fresh=True; i+=1; continue
    if fresh:
        base=t.split("/")[-1]
        if base in MUT_CMDS: hit(base)
        if base=="git":
            j=i+1
            while j < len(toks):
                g=toks[j]
                if g in ("-C","-c","--git-dir","--work-tree"): j+=2; continue
                if g.startswith("-"): j+=1; continue
                break
            if j < len(toks):
                sub=toks[j]
                if sub in GIT_SAFE_REMOTE: pass
                elif sub in GIT_MUT: hit("git "+sub)
        if base in ("sync-workspace-control.sh",) or "sync-workspace-control.sh" in t:
            hit("workspace-control sync")
        fresh=False
    i+=1
' 2>/dev/null || echo "")

if [ -n "$REVIEW_VERDICT" ]; then
  AT=$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("agent_type",""))
except Exception: print("reviewer")' 2>/dev/null || echo reviewer)
  deny "$AT is READ-ONLY with respect to source; blocked: $REVIEW_VERDICT

This reviewer reports findings, it does not apply them. Return your verdict to
the main agent and let it make the change. If you need to record something, put
it in your reply, not on disk."
fi

# --- DEV workspace gate ---------------------------------------------------
# Only "is this the right workspace" (identity gate --dev). Dirty trees,
# branches, unpushed commits, worktrees, _scratch/ and control-layer drift are
# WARN there, so they never block an edit - including the edit that fixes them.
GATE=$ROOT/tools/verify-workspace-identity.sh
[ -x "$GATE" ] || deny "NebulaOS guardrail: identity gate missing or not executable at $GATE. Failing closed. Ask the human to run NebulaOS-firmware/tools/workspace-control/scripts/apply-workspace-control.sh."

OUT=$("$GATE" --dev 2>&1); RC=$?
if [ "$RC" -ne 0 ]; then
  REASONS=$(printf '%s\n' "$OUT" | grep -E '^\s+FAIL:' | head -12)
  deny "NebulaOS guardrail: this is not a sound NebulaOS DEV workspace.

$REASONS

These are structural problems (a missing canonical repository, an archive or
legacy authority tree in the active root). Fix the workspace layout; do not
switch to another checkout."
fi

allow
