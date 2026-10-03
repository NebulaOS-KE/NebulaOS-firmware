#!/usr/bin/env python3
"""Offline validation of the shipped Moonraker configuration for the Klipper
stack. Phase 1 no-fork migration, Phase J.

This does not run Moonraker. It does something more useful for a config file
that has to be right before a printer boots: it re-implements Moonraker's own
include and parse rules, and then checks every option this project sets
against Moonraker's REAL source at the pinned commit - so "these options are
supported" is verified rather than asserted from memory.

That distinction is not theoretical here. The shipped moonraker.conf already
carries a long comment about a previous round of exactly this mistake: seven
options were set on the reserved [update_manager klipper] slot, every one of
them silently ignored, each surfacing as an "Unparsed config option" warning
on every boot of a byte-for-byte fresh install. The checks below exist so
that cannot happen again quietly.

Moonraker's source is located automatically (vendor/moonraker, or the
workspace's reference clone) and can be pointed at explicitly with
MOONRAKER_SRC. Without it the source-derived checks are reported as skipped
rather than silently passing.

Usage: python3 tests/moonraker-klipper-stack-config-tests.py
"""

import configparser
import os
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG_DIR = REPO_ROOT / "scripts/build/overlay/opt/printer_data/config"
MOONRAKER_CONF = CONFIG_DIR / "moonraker.conf"
PRINTER_CFG = CONFIG_DIR / "printer.cfg"
# Phase 1.5 persistent-namespace mission (2026-08): the managed-pin island
# used to live at printer_data/config/nebulaos/ (a PERSISTENT, synced
# directory) - that directory no longer exists in source. The pin now
# ships as a single IMAGE OWNED file at /etc/nebulaos/moonraker/
# klipper-pin.conf, which lands in the tracked overlay at this path.
MANAGED_DIR = REPO_ROOT / "scripts/build/overlay/etc/nebulaos/moonraker"
# Where an absolute /etc/nebulaos/... include resolves against when there
# is no live rootfs to read from - mirrors exactly how
# scripts/build/04-cross-compile-app-stack.sh's own overlay-copy step
# places overlay/X at /X in the shipped image (1:1), and the same
# convention scripts/build/lib/validate-frontend-controls.sh's own
# overlay_root argument uses.
OVERLAY_ROOT = REPO_ROOT / "scripts/build/overlay"

OFFICIAL_KLIPPER = "https://github.com/Klipper3d/klipper.git"
EXTENSIONS_ORIGIN = "https://github.com/coreflake1/NebulaOS-klipper-extensions.git"

PASS = FAIL = SKIP = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"PASS: {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"FAIL: {msg}")


def skip(msg):
    global SKIP
    SKIP += 1
    print(f"SKIP: {msg}")


def check(cond, good_msg, bad_msg):
    ok(good_msg) if cond else bad(bad_msg)


def find_moonraker_source():
    env = os.environ.get("MOONRAKER_SRC")
    candidates = [pathlib.Path(env)] if env else []
    candidates += [
        REPO_ROOT / "vendor/moonraker",
        REPO_ROOT.parent.parent.parent / "_scratch/ref-moonraker",
    ]
    for c in candidates:
        if (c / "moonraker/components/update_manager/common.py").is_file():
            return c
    return None


def parse_like_moonraker(path, visited=None, overlay_root=None):
    """Mirror ConfigHelper._parse_file's include handling closely enough to be
    meaningful: includes are globbed RELATIVE TO THE INCLUDING FILE's parent,
    an empty glob is a hard error, included sections are not themselves added
    to the parser, and a section repeated within ONE file is an error while
    the same section appearing in two different files is not.

    Phase 1.5 persistent-namespace mission (2026-08): also mirrors
    confighelper.py's real absolute-include handling (verified directly
    against the pinned source, moonraker/confighelper.py's _parse_file:
    `if inc_path[0] == "/": new_path = pathlib.Path(inc_path).resolve();
    paths = sorted(new_path.parent.glob(new_path.name))` - a real,
    intentional feature, not a workaround). There is no live rootfs to
    resolve against here, so an absolute include is resolved against
    `overlay_root` instead (scripts/build/overlay/X -> /X in the shipped
    image, 1:1 - the same convention scripts/build/lib/
    validate-frontend-controls.sh's own overlay_root argument uses)."""
    visited = visited if visited is not None else []
    path = path.resolve()
    if path in visited:
        raise ValueError(f"recursive include: {path}")
    visited.append(path)

    parser = configparser.ConfigParser(interpolation=None, strict=False)
    buffer, seen_here = [], set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.lstrip()[0] in "#;":
            continue
        line = raw.expandtabs(4)
        cmt = re.search(r" +[#;]", line)
        if cmt is not None:
            line = line[: cmt.start()]
        m = re.match(r"\s*\[([^]]+)\]", line)
        if m and m.group(1).startswith("include "):
            inc = m.group(1)[8:].strip()
            if not inc:
                raise ValueError(f"invalid include directive: [{m.group(1)}]")
            if inc[0] == "/":
                if overlay_root is None:
                    raise ValueError(
                        f"absolute include directive [{m.group(1)}] but no "
                        "overlay_root was given to resolve it against"
                    )
                new_path = (overlay_root / inc.lstrip("/")).resolve()
                paths = sorted(new_path.parent.glob(new_path.name))
            else:
                paths = sorted(path.parent.glob(inc))
            if not paths:
                raise ValueError(f"no files matching include directive [{m.group(1)}]")
            if buffer:
                parser.read_string("\n".join(buffer), str(path))
                buffer = []
            for p in paths:
                sub = parse_like_moonraker(p, visited, overlay_root)
                for sect in sub.sections():
                    if not parser.has_section(sect):
                        parser.add_section(sect)
                    for k, v in sub.items(sect):
                        parser.set(sect, k, v)
            continue
        if m:
            if m.group(1) in seen_here:
                raise ValueError(f"duplicate section [{m.group(1)}] in file {path}")
            seen_here.add(m.group(1))
        buffer.append(line)
    if buffer:
        parser.read_string("\n".join(buffer), str(path))
    return parser


# --- 1. the config parses at all, the way Moonraker would parse it ---------

try:
    cfg = parse_like_moonraker(MOONRAKER_CONF, overlay_root=OVERLAY_ROOT)
    ok("moonraker.conf parses cleanly under Moonraker's own include/comment rules")
except Exception as exc:  # noqa: BLE001 - the failure text is the useful part
    bad(f"moonraker.conf does not parse: {exc}")
    cfg = configparser.ConfigParser()

# MEM-T05: the image-owned include bounds uploads (they are spooled on eMMC).
check(
    cfg.has_section("server") and cfg.get("server", "max_upload_size", fallback=None) == "512",
    "server.max_upload_size resolves to 512 MiB through the managed include (MEM-T05)",
    f"server.max_upload_size is {cfg.get('server', 'max_upload_size', fallback=None)!r}, expected '512'",
)

MANAGED_INCLUDE_LINE = "[include /etc/nebulaos/moonraker/klipper-pin.conf]"
check(
    MOONRAKER_CONF.read_text(encoding="utf-8").count(MANAGED_INCLUDE_LINE) == 1,
    "moonraker.conf carries exactly one managed include directive, as an "
    "absolute path (Phase 1.5 persistent-namespace mission: an A/B rollback "
    "shares /usr/data across slots, so the old relative-glob form pointing "
    "into persistent storage could read the wrong slot's copy - an absolute "
    "include into the read-only, slot-owned rootfs cannot)",
    f"expected exactly one '{MANAGED_INCLUDE_LINE}' line in moonraker.conf",
)

managed = sorted(MANAGED_DIR.glob("*.conf"))
check(
    bool(managed),
    f"the managed include's absolute target resolves to real shipped files ({', '.join(p.name for p in managed)})",
    f"{MANAGED_INCLUDE_LINE} resolves to nothing under {MANAGED_DIR} - Moonraker raises "
    "'No files matching include directive' and refuses to start",
)

# --- 2. the reserved klipper slot -----------------------------------------

check(
    cfg.has_section("update_manager klipper"),
    "[update_manager klipper] reaches the parser through the managed include",
    "[update_manager klipper] is missing after include resolution",
)
if cfg.has_section("update_manager klipper"):
    k = dict(cfg.items("update_manager klipper"))
    check(
        "pinned_commit" not in k,
        "Klipper has no pinned_commit — updates independently via upstream master",
        f"Klipper has unexpected pinned_commit: {k.get('pinned_commit')!r}",
    )
    check(
        k.get("channel") == "dev",
        "Klipper channel is dev (tracks upstream master branch)",
        f"Klipper channel is {k.get('channel')!r}, expected 'dev'",
    )
    check(
        "origin" not in k,
        "the reserved klipper slot sets no origin - it cannot be overridden, and "
        "Moonraker's hardcoded value is already official Klipper3d/klipper",
        "the reserved klipper slot sets 'origin', which Moonraker silently ignores",
    )

# --- 3. the extensions section --------------------------------------------

SECT = "update_manager nebulaos_klipper_extensions"
check(
    cfg.has_section(SECT),
    f"[{SECT}] reaches the parser through the managed include",
    f"[{SECT}] is missing after include resolution",
)
if cfg.has_section(SECT):
    e = dict(cfg.items(SECT))
    expectations = {
        "type": "git_repo",
        "origin": EXTENSIONS_ORIGIN,
        "primary_branch": "production",
        "managed_services": "klipper",
        "path": "/usr/data/nebulaos/apps/nebulaos-klipper-extensions",
    }
    for key, want in expectations.items():
        check(
            e.get(key) == want,
            f"extensions section sets {key} = {want}",
            f"extensions section has {key} = {e.get(key)!r}, expected {want!r}",
        )
    check(
        "pinned_commit" not in e,
        "extensions have no pinned_commit — update independently",
        f"extensions have unexpected pinned_commit: {e.get('pinned_commit')!r}",
    )
    check(
        e.get("primary_branch") == "production",
        "primary_branch is set explicitly to the deployed-runtime branch - "
        "Moonraker defaults it to 'master', which this repository does not use, "
        "and 'main' is the DEVELOPMENT branch (audit F-06)",
        "primary_branch must be 'production', the deployed-runtime branch",
    )
    check(
        "virtualenv" not in e and "requirements" not in e,
        "no virtualenv/requirements are declared - a pure-Python extras repo needs neither, "
        "and Moonraker only looks for requirements when a virtualenv is configured",
        "virtualenv/requirements should not be set for a pure-Python extras repo",
    )

# --- 4. build pins vs runtime independence --------------------------------

deps = (REPO_ROOT / "manifests/dependencies.conf").read_text(encoding="utf-8")
check(
    f"KLIPPER_REPO={OFFICIAL_KLIPPER}" in deps,
    "the firmware builds from official Klipper3d/klipper, which is the origin Moonraker's "
    "reserved slot hardcodes anyway - so the 'Unofficial remote url' anomaly the old "
    "fork tripped on every refresh is gone by construction",
    "KLIPPER_REPO is not official Klipper3d/klipper",
)
check(
    "KLIPPER_PIN=" in deps,
    "manifests/dependencies.conf still pins Klipper for BUILD (immutable recovery copy)",
    "KLIPPER_PIN missing from dependencies.conf",
)
check(
    "KLIPPER_EXTENSIONS_PIN=" in deps,
    "manifests/dependencies.conf still pins extensions for BUILD (immutable recovery copy)",
    "KLIPPER_EXTENSIONS_PIN missing from dependencies.conf",
)

# --- 5. printer.cfg ordering and sensor type ------------------------------
#
# Phase 1.5 persistent-namespace mission (2026-08): [nebulaos_compat] and
# [temperature_sensor mcu_temp] no longer live directly in printer.cfg -
# they moved into the IMMUTABLE, slot-owned /etc/nebulaos/klipper/
# platform.cfg and machine.cfg, included with ABSOLUTE paths. Checking
# printer.cfg's raw text alone would silently stop testing anything real
# once those sections moved out of it, so this builds the RESOLVED include
# closure first (printer.cfg + its /etc/nebulaos/klipper/*.cfg includes,
# resolved against OVERLAY_ROOT for the absolute ones - same resolution
# rule as scripts/build/lib/validate-frontend-controls.sh's own
# overlay_root argument and confighelper.py's absolute-include handling
# mirrored above) and checks the closure, not the unresolved entrypoint.


def resolve_printer_cfg_closure(entry, overlay_root, visited=None):
    """Concatenates entry's own content followed by each of its includes'
    resolved content, in include order - deliberately the same simple
    "closure is a concatenation, not a flattened single config" shape
    scripts/build/lib/validate-frontend-controls.sh's
    frontend_controls_resolve_closure produces, so section-order checks
    below reflect the same real load order Klipper itself would see."""
    visited = visited if visited is not None else set()
    entry = entry.resolve()
    if entry in visited:
        raise ValueError(f"recursive include: {entry}")
    visited.add(entry)
    text = entry.read_text(encoding="utf-8")
    chunks = [text]
    for m in re.finditer(r"(?m)^\[include ([^\]]+)\]", text):
        inc = m.group(1).strip()
        if inc.startswith("/etc/nebulaos/"):
            target = (overlay_root / inc.lstrip("/")).resolve()
        elif inc.startswith("/"):
            raise ValueError(
                f"absolute include outside /etc/nebulaos/: {inc} - this project's "
                "build never expects a config to reach outside its own overlay"
            )
        else:
            target = entry.parent / inc
        if not target.is_file():
            raise ValueError(f"include target does not exist: {inc} -> {target}")
        chunks.append(resolve_printer_cfg_closure(target, overlay_root, visited))
    return "\n".join(chunks)


try:
    printer_closure = resolve_printer_cfg_closure(PRINTER_CFG, OVERLAY_ROOT)
    ok("printer.cfg's /etc/nebulaos/klipper/*.cfg include closure resolves cleanly")
except Exception as exc:  # noqa: BLE001 - the failure text is the useful part
    bad(f"printer.cfg's include closure did not resolve: {exc}")
    printer_closure = ""

raw_printer = PRINTER_CFG.read_text(encoding="utf-8")
top_includes = [m.group(1) for m in re.finditer(r"(?m)^\[include ([^\]]+)\]", raw_printer)]
check(
    bool(top_includes) and top_includes[0] == "/etc/nebulaos/klipper/platform.cfg",
    "printer.cfg's FIRST include is platform.cfg, so [nebulaos_compat] loads before "
    "any other NebulaOS-provided module (machine.cfg's nebulaos_temperature_mcu "
    "sensor, GuppyScreen/guppy_cmd.cfg's gcode_shell_command sections)",
    f"printer.cfg's first include is {top_includes[0] if top_includes else 'MISSING'}, "
    "expected /etc/nebulaos/klipper/platform.cfg first",
)

# Real (non-[include ...] pseudo-) sections only, in the closure's own load
# order - this is what actually determines Klipper's load-time behavior.
closure_sections = [
    m.group(1)
    for m in re.finditer(r"(?m)^\[([^]]+)\]", printer_closure)
    if not m.group(1).startswith("include ")
]
check(
    "nebulaos_compat" in closure_sections,
    "the resolved closure declares the [nebulaos_compat] preflight section "
    "(from /etc/nebulaos/klipper/platform.cfg)",
    "the resolved closure is missing [nebulaos_compat]",
)
if "nebulaos_compat" in closure_sections:
    idx = closure_sections.index("nebulaos_compat")
    later = closure_sections[idx + 1:]
    check(
        any(s.startswith("temperature_sensor ") for s in later),
        "[nebulaos_compat] precedes every [temperature_sensor] section in the "
        "resolved closure",
        "a [temperature_sensor] section precedes [nebulaos_compat] in the "
        "resolved closure",
    )
check(
    "sensor_type: nebulaos_temperature_mcu" in printer_closure,
    "the resolved closure uses the NebulaOS GD32 sensor type",
    "the resolved closure still uses sensor_type: temperature_mcu, which official "
    "Klipper raises config_error on for GD32 - Klippy would refuse to start",
)
check(
    not re.search(r"(?m)^sensor_type:\s*temperature_mcu\s*$", printer_closure),
    "no bare 'sensor_type: temperature_mcu' remains anywhere in the resolved closure",
    "a bare sensor_type: temperature_mcu is still present in the resolved closure",
)

# --- 6. every option is checked against Moonraker's REAL pinned source ----

src = find_moonraker_source()
if src is None:
    skip(
        "Moonraker source not found (set MOONRAKER_SRC) - the source-derived option "
        "checks below did not run"
    )
else:
    common = (src / "moonraker/components/update_manager/common.py").read_text(encoding="utf-8")
    m = re.search(r"OPTION_OVERRIDES\s*=\s*\(([^)]*)\)", common)
    overrides = set(re.findall(r'"([^"]+)"', m.group(1))) if m else set()
    check(
        overrides == {"channel", "pinned_commit", "refresh_interval", "report_anomalies"},
        f"read OPTION_OVERRIDES from Moonraker's real source: {sorted(overrides)}",
        f"OPTION_OVERRIDES has changed at this pin: {sorted(overrides)}",
    )
    if cfg.has_section("update_manager klipper"):
        used = set(dict(cfg.items("update_manager klipper")))
        check(
            used <= overrides,
            f"every option on the reserved klipper slot is genuinely overridable: {sorted(used)}",
            f"these options would be silently ignored by Moonraker: {sorted(used - overrides)}",
        )
    check(
        re.search(r'"origin":\s*"https://github\.com/Klipper3d/klipper\.git"', common) is not None,
        "Moonraker's hardcoded klipper origin at this pin IS Klipper3d/klipper",
        "Moonraker's hardcoded klipper origin is not what this design assumes",
    )

    git_dep = (src / "moonraker/components/update_manager/git_deploy.py").read_text(encoding="utf-8")
    app_dep = (src / "moonraker/components/update_manager/app_deploy.py").read_text(encoding="utf-8")
    both = git_dep + app_dep
    if cfg.has_section(SECT):
        for opt in sorted(dict(cfg.items(SECT))):
            pattern = rf'(get|getboolean|getlist|getchoice|getint|getdict|has_option)\(\s*[\'"]{re.escape(opt)}[\'"]'
            check(
                re.search(pattern, both) is not None,
                f"'{opt}' is really read by GitDeploy/AppDeploy at the pinned Moonraker",
                f"'{opt}' is NOT read by GitDeploy/AppDeploy - it would be an unparsed option",
            )
        m = re.search(r"svc_choices\s*=\s*\[([^\]]*)\]", app_dep)
        choices = m.group(1) if m else ""
        check(
            '"klipper"' in choices,
            "'managed_services: klipper' is a genuinely supported value, so an extensions "
            "update restarts Klippy natively with no NebulaOS code involved",
            f"'klipper' is not among the supported managed_services values: {choices}",
        )

print()
print(f"moonraker-klipper-stack-config-tests: {PASS} passed, {FAIL} failed, {SKIP} skipped")
sys.exit(1 if FAIL else 0)
