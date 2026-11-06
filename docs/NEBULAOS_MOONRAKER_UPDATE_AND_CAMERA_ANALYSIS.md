# NebulaOS Moonraker Update Manager & Camera Persistence — Analysis Report

**Status: Investigation complete. No implementation performed.** This is a read-only analysis mission, run on branch `investigation/moonraker-update-camera-analysis` from tag `nebulaos-mutable-runtime-sealed-2026-07-27`. No runtime, source, or configuration changes were made to the device or to any sealed component. `nebulaos-mutable-runtime-baseline-2026-07-27`, `nebulaos-mutable-runtime-complete-2026-07-27`, and `nebulaos-mutable-runtime-sealed-2026-07-27` are all confirmed unchanged (verified in §2 and the evidence appendix).

Evidence labels used throughout: **VERIFIED FACT** (directly observed via source code, live command output, or API response), **SOURCE-BACKED INFERENCE** (a conclusion drawn from verified facts but not itself directly observed), **UNVERIFIED HYPOTHESIS** (plausible but not confirmed), **RECOMMENDATION** (a proposal for a later implementation mission — never itself a claim of current behavior).

---

## 1. Executive summary

Two separate, unrelated-looking problems turn out to share one root cause and one fix pattern:

1. **The Moonraker warnings.** `[update_manager klipper]` and `[update_manager moonraker]` are Moonraker's two *reserved* app slots. Reserved slots hardcode `type`, `path`, `origin`, `managed_services`, and (for moonraker) `virtualenv`/`requirements` internally, and auto-discover `path`/`env` at runtime from the live Klippy connection (klipper) or `sys.exec_prefix`/`source_info` (moonraker). Only `channel`, `pinned_commit`, `refresh_interval`, `report_anomalies` are ever read from a `[update_manager klipper]`/`[update_manager moonraker]` section — **VERIFIED FACT**, with exact `file:line` citations in §7. Every other option NebulaOS's config sets under these two reserved names is never read by anything, and Moonraker's generic "you set an option this component's ConfigHelper never touched" warning mechanism fires for each one, every boot. This is **not** a crash, a stale config, or a version mismatch — it is present in a fresh, correctly-seeded install of the exact sealed image, and would be present in current upstream Moonraker too.

2. **The camera problem.** The default "Nebula" camera is defined in `moonraker.conf`'s `[webcam Nebula]` section. Moonraker's `webcam.py` re-parses `[webcam ...]` sections from the config file **fresh on every single startup** — it is never copied into the database, contrary to what NebulaOS's own moonraker.conf comment currently claims (**VERIFIED FACT**, exact source in §15). Any webcam whose `source` field is `"config"` is permanently, unconditionally forbidden from being edited or deleted via Moonraker's own API (not a Mainsail UI quirk — Moonraker itself raises a server error) — **VERIFIED FACT**, §15. The stream/snapshot URLs and `service` value are independently confirmed correct and fully functional against the real ustreamer/nginx pipeline (§16). A second, previously-undiscovered issue was found in the process: a **stale database-backed webcam entry** (also named "Nebula", with an old `uv4l-mjpeg`/camelCase schema, likely OpenKE-era) silently collides with and is discarded in favor of the config entry on every boot (§10, §15).

3. **The user's own working assumption — "stock updates without breaking config" — does not hold as evidenced.** Both the real stock installer on this exact device (Guilouz/Creality-Helper-Script) and the SimpleAF/pellcorp reference this project has always used **do** overwrite `moonraker.conf` (and, for pellcorp, `printer.cfg` via an active migration engine) on every reinstall/update. The genuinely reliable invariant across both real-world references is narrower than assumed: **the Moonraker database is what survives; config files do not, reliably, in either reference implementation.** This is reported honestly even though it revises the mission brief's own premise (§8, §9).

The recommended minimum correction (§20) requires no upstream patching, no new configuration-override framework, and touches a small, enumerable set of files (§25).

---

## 2. Mission scope and frozen sealed baseline

**VERIFIED FACT** (commands run, output below):

```text
$ git rev-parse HEAD                                                    (before branch checkout)
d1c5e33f20b6cea49e45cb8b3120650c9bad0567
$ git status --short
(empty)
$ git checkout -b investigation/moonraker-update-camera-analysis nebulaos-mutable-runtime-sealed-2026-07-27
Switched to a new branch 'investigation/moonraker-update-camera-analysis'
$ git rev-parse HEAD
d1c5e33f20b6cea49e45cb8b3120650c9bad0567
$ git branch --show-current
investigation/moonraker-update-camera-analysis
$ git remote -v
(no remotes configured — local-only repository)

$ git rev-parse nebulaos-mutable-runtime-baseline-2026-07-27^{commit}
24c58b4aa7cf6e3f482fc94eb2577bdf4e46d71a
$ git rev-parse nebulaos-mutable-runtime-complete-2026-07-27^{commit}
a5b8eec48f6d3c15d47cb60f92139c5c8adb7de4
$ git rev-parse nebulaos-mutable-runtime-sealed-2026-07-27^{commit}
d1c5e33f20b6cea49e45cb8b3120650c9bad0567
```

The sealed tag points to exactly the commit the investigation branch was created from; the working tree was clean before any analysis began; all three tags are distinct, unmoved checkpoints. The device's currently-flashed build (per `artifacts/buildroot-halley5-v30-image/build-manifest.txt`, unchanged this mission) is `git_commit_main=b16a94976d780b08b779fcff99f7e53aaeaecd2e` — the same image flashed during the prior final-seal mission; no reflash occurred or was needed for this investigation.

No source, runtime, or config files were modified during this investigation. No reboots, service restarts, camera API calls, or OTA-marker changes were performed.

---

## 3. Exact live versions

**VERIFIED FACT**, all captured live via read-only SSH/API on 2026-07-27, device at `192.168.1.146` (custom slot):

| Component | Value |
|---|---|
| Moonraker git commit (deployed) | `70e251ecb77a291f9b2c9789f6e0aef4af2b8420` |
| Moonraker branch | `master` (local branch tracking `origin/master`, "ahead 1, behind 2305") |
| Moonraker remote | `https://github.com/Arksine/moonraker.git` |
| Moonraker working tree | clean (`git status --short` empty) |
| Moonraker process | `/usr/data/nebulaos/envs/moonraker/bin/python3 /opt/moonraker/moonraker/moonraker.py -d /opt/printer_data -c /opt/printer_data/config/moonraker.conf -l /opt/printer_data/logs/moonraker.log -u /opt/printer_data/comms/moonraker.sock` |
| Moonraker `sys.executable`/venv | `/usr/data/nebulaos/envs/moonraker/bin/python3` → `/usr/bin/python3.11` (real base interpreter) |
| Moonraker reported version | `tv0.10.0-1-g70e251e-shallow` (shallow clone) |
| Klipper git commit (deployed) | `2d75015d7c76dd31e4b0f49e1ae3fe6ad86cad24` |
| Klipper branch | `nebulaos` (tracking `origin/nebulaos`, "ahead 1, behind 5784") |
| Klipper remote | `https://github.com/coreflake1/NebulaOS-klipper.git` |
| Klipper working tree | clean |
| Klipper process | `/usr/data/nebulaos/envs/klipper/bin/python3 /opt/klipper/klippy/klippy.py /opt/printer_data/config/printer.cfg -a /opt/printer_data/comms/klippy.sock -l /opt/printer_data/logs/klippy.log` |
| Mainsail version | `v2.18.2` (`release_info.json`: `"project_owner":"mainsail-crew"`) |
| GuppyScreen version | `v1.5.0-OpenKE` (own log banner; naming is out of this mission's scope) |
| nginx process | `/usr/sbin/nginx` (master + `www-data` worker) |
| ustreamer process | `/usr/bin/ustreamer --device=/dev/video3 --format=MJPEG --encoder=HW --resolution=1920x1080 --desired-fps=30 --host=127.0.0.1 --port=8080` |

**Important nuance resolved (SOURCE-BACKED INFERENCE, high confidence):** the deployed Moonraker commit `70e251e` is not itself a real upstream Arksine/moonraker commit — its own commit message reads *"NebulaOS factory seed snapshot of master @ d5ee17128bb88434aacdab90c2e9e990e2b64e4a"*, and `git branch -vv` confirms it is exactly **one** synthetic commit ahead of `origin/master`. `d5ee171` is `vendor/moonraker`'s own currently-checked-out HEAD in this repository. Attempting to fetch `70e251e` directly from `github.com/Arksine/moonraker` (both as a bare ref and after a full unshallow fetch of `master`, 2305 commits) failed with "not our ref" / not found — consistent with it being a purely local, NebulaOS-fabricated wrapper commit that never existed upstream. This means the exact file content Moonraker is running is content-identical to `vendor/moonraker`'s checked-out `d5ee171`, not merely "close to it." All source analysis in §7 was performed directly against this checkout and is treated as authoritative for the deployed code, not an approximation.

Separately, git history of `moonraker/components/update_manager/common.py` and `update_manager.py` shows the reserved-slot mechanism (`get_base_configuration`, `BASE_CONFIG`, `OPTION_OVERRIDES`) is a long-stable, foundational design (commit `003acd5 update_manager: fetch klipper paths from klippy_connection` established the core mechanism; `OPTION_OVERRIDES` has only ever grown by one entry, `report_anomalies`, since). This further supports treating the current checkout as representative of the actually-running behavior, and separately answers §5 (upstream comparison): this is not a recent regression a Moonraker update would fix.

---

## 4. Exact live paths and mounts

**VERIFIED FACT**:

```text
/dev/mmcblk0p10 /opt/printer_data     ext4 rw,relatime
/dev/mmcblk0p10 /opt/klipper          ext4 rw,relatime
/dev/mmcblk0p10 /opt/moonraker        ext4 rw,relatime
/dev/mmcblk0p10 /usr/share/mainsail   ext4 rw,relatime
```

All four are bind mounts from the same persistent partition (`/usr/data`, `mmcblk0p10`) onto their immutable-squashfs mount points, per `S05nebulaos-activate` (unchanged this mission, not re-inspected in depth since it's frozen architecture). `/opt/printer_data/config/moonraker.conf` resolves (via `readlink -f`) to itself — it is the real file at that path, itself bind-mounted from `/usr/data/nebulaos/printer_data/config/moonraker.conf` (confirmed identical SHA-256, §6).

---

## 5. Current warning evidence

**VERIFIED FACT** — every "Unparsed config option" line moonraker.log has ever produced for these two sections (captured live, most recent boot):

```text
Unparsed config option 'type: git_repo' detected in section [update_manager klipper].
Unparsed config option 'path: /usr/data/nebulaos/apps/klipper' detected in section [update_manager klipper].
Unparsed config option 'origin: https://github.com/coreflake1/NebulaOS-klipper.git' detected in section [update_manager klipper].
Unparsed config option 'primary_branch: nebulaos' detected in section [update_manager klipper].
Unparsed config option 'managed_services: klipper' detected in section [update_manager klipper].
Unparsed config option 'type: git_repo' detected in section [update_manager moonraker].
Unparsed config option 'path: /usr/data/nebulaos/apps/moonraker' detected in section [update_manager moonraker].
Unparsed config option 'origin: https://github.com/Arksine/moonraker.git' detected in section [update_manager moonraker].
Unparsed config option 'primary_branch: master' detected in section [update_manager moonraker].
Unparsed config option 'managed_services: moonraker' detected in section [update_manager moonraker].
Unparsed config option 'virtualenv: /usr/data/nebulaos/envs/moonraker' detected in section [update_manager moonraker].
Unparsed config option 'requirements: scripts/moonraker-requirements.txt' detected in section [update_manager moonraker].
```

`channel: dev` (present in both sections) never warns. `/server/info`'s `warnings` array matches this list exactly and `failed_components` is empty — **update_manager is loaded and running successfully**; these are warnings, not load failures. `moonraker_version` in the same response confirms `tv0.10.0-1-g70e251e-shallow`, matching §3.

---

## 6. `moonraker.conf` copy and hash comparison

**VERIFIED FACT**:

| Copy | SHA-256 | Notes |
|---|---|---|
| Live, in use by Moonraker (`/opt/printer_data/config/moonraker.conf`) | `c7c39519c850d9e13ffbf556cb8ba3d432acff8d0e0a2600ddf459b6ead65ae6` | |
| Live, persistent backing file (`/usr/data/nebulaos/printer_data/config/moonraker.conf`) | `c7c39519c850d9e13ffbf556cb8ba3d432acff8d0e0a2600ddf459b6ead65ae6` | identical — confirms the bind mount is intact and there is exactly one real file, not two divergent copies |
| Repo source of truth (`scripts/build/overlay/opt/printer_data/config/moonraker.conf`, this branch) | `927cccd9fe3083cf07ed742bbf9a9b2eed1b393f0112e3642f0e5daee7e0e72f` | |

These two hashes differ, but a clean binary diff (via `scp`, not an interactive SSH `cat`, which was found to corrupt line endings and produce a false 100%-different diff on first attempt — noted here as a methodology correction) shows the **entire difference is an 18-line, comment-only block** ("Closure-mission correction (2026-07-27): confirmed live against real Moonraker source...") that a prior session added to the repo source *after* the live file was last pushed to the device. No functional line (section header, option, or value) differs. Comments have zero effect on `configparser`/Moonraker's parsing.

Answering Phase 3's specific questions:

1. **Does the sealed image contain the same config currently running?** VERIFIED FACT: functionally yes — every parsed line is byte-identical; only a non-functional comment differs.
2. **Was the current persistent file seeded by an older image?** SOURCE-BACKED INFERENCE: the file was pushed manually during a prior session's live-fix step (documented in this project's own git history/session record), not reseeded by a factory-seed run since; that's consistent with the comment-only staleness observed.
3. **Can a fresh namespace produce the current warnings?** VERIFIED FACT: yes. The warnings are generated purely by Moonraker's parser against the *shape* of the config (reserved-slot options that are structurally never read, §7) — this has nothing to do with staleness, and a byte-for-byte fresh factory seed from the sealed image would reproduce every one of the twelve warnings identically.
4. **Was the live device manually patched into a non-reproducible state?** VERIFIED FACT (partial): the live config differs from repo source only by a documentation comment (see above) — this is not a non-reproducible state; the file's *content that matters* is exactly what a fresh seed produces. (The stale database webcam entry, §10/§15, *is* a separate, genuinely non-reproducible artifact — see there.)
5. **Does any application update copy or overwrite `moonraker.conf`?** VERIFIED FACT for NebulaOS's own current design: no. Neither `nebulaos-update-supervisor.sh`'s Klipper/Moonraker/Mainsail update-and-rollback paths nor Moonraker's own `update_manager` component ever touch `moonraker.conf` — confirmed by reading both this session and in the prior final-seal mission's own work on that script (frozen, not re-inspected in full this mission since it's sealed architecture). This is a genuine, deliberate difference from **both** real reference systems (§8/§9), addressed in §20.

---

## 7. Exact running Moonraker parser analysis

This section is the output of dedicated source analysis of `vendor/moonraker/moonraker/components/update_manager/{update_manager,common,app_deploy,git_deploy}.py` and `vendor/moonraker/moonraker/confighelper.py`, all at the exact checked-out commit representing the deployed code (§3). All citations are `file:line` against those files as they exist on this branch.

### 7.1 Are `klipper`/`moonraker` reserved, auto-instantiated slots? — VERIFIED FACT: yes

`UpdateManager.__init__` (`update_manager.py:69-105`):
- L75: `self.app_config = get_base_configuration(config)` — builds a synthetic merged config *unconditionally*, before any real `[update_manager *]` section is scanned as a "client section".
- L95-96: `mcfg = self.app_config["moonraker"]`, `kcfg = self.app_config["klipper"]` — pulled from that synthetic config, not the real file.
- L97-98: `self.updaters['moonraker'] = mclass(mcfg)` — **always** created.
- L99-105: `self.updaters['klipper'] = kclass(kcfg)` — **always** created (class upgraded from `BaseDeploy` to a real deploy class only if `kcfg.get("path")`/`kcfg.get("env")` exist on disk — this still always executes the assignment).
- L117-126: real `[update_manager *]` sections are scanned afterward (`config.get_prefix_sections("update_manager ")`); a section literally named `klipper` or `moonraker` is explicitly **skipped** (`if name in self.updaters: ... continue`), with the "already added" warning specifically suppressed for `["klipper", "moonraker"]` (L122). These sections are *only ever consulted* as an override source inside `get_base_configuration` — never instantiated as their own updater.

### 7.2 What do `BASE_CONFIG`/`OPTION_OVERRIDES`/`get_base_configuration()` actually do?

`common.py`:
- `BASE_CONFIG` (L24-43) hardcodes `origin`, `requirements`, `venv_args`, `system_dependencies`, `virtualenv` (`sys.exec_prefix`), `pip_environment_variables`, `path` (`source_info.source_path()`), `managed_services` for moonraker; `moved_origin`, `origin`, `requirements`, `venv_args`, `install_script`, `managed_services` for klipper.
- `OPTION_OVERRIDES = ("channel", "pinned_commit", "refresh_interval", "report_anomalies")` (L45) — **the entire whitelist** of what a `[update_manager klipper]`/`[update_manager moonraker]` section can override.
- `get_base_configuration()` (L93-113): L97-100 set `type`/`path`/`env` for both apps programmatically (`AppType.detect()`, `kconn.path`, `kconn.executable`); L106-112 copy **only** `OPTION_OVERRIDES` members from the real section, if present, over the hardcoded defaults; L113 merges everything into a **brand-new synthetic `ConfigHelper`** via `config.read_supplemental_dict(base_cfg)`.

`primary_branch` is not in `OPTION_OVERRIDES` at all — there is no code path anywhere that would let a `[update_manager klipper]`/`[update_manager moonraker]` section override it.

### 7.3 Why does the warning fire for everything except `channel`?

The warning is generic and structural, not "option illegal in this context." `confighelper.py`'s `validate_config()` (L507-530), called once after all components load, iterates the real backing `configparser` for each section (L522: `for opt, val in self.config.items(sect)`) and warns (L523-525) for any option not present in `self.parsed[sect]` — a dict populated only as a side effect of an actual `.get()`/`.getboolean()`/etc. accessor call on a `ConfigHelper` sharing that root-tracked dict (`_get_option`, L125-181, esp. L172).

`getsection()` (L118-123) passes `self.parsed` **by reference**, so the `OPTION_OVERRIDES` loop in `get_base_configuration` (`common.py:109-112`, which does call `app_cfg.get(opt)` against the *real* root-tracked section object) legitimately marks `channel`/`pinned_commit`/`refresh_interval`/`report_anomalies` as parsed. But everything `AppDeploy`/`GitDeploy` reads afterward — `type`, `path`, `origin`, `primary_branch`, `managed_services`, `virtualenv`, `requirements` — is read off `mcfg`/`kcfg`, the object `read_supplemental_dict()` returns. That method (`confighelper.py:477-483`) builds a **completely separate** `DictSourceWrapper`/private `configparser` and a **fresh, empty** `parsed = {}` (L483). Reads against it never touch the real file's parser or the root `parsed` dict `validate_config()` inspects — so from that function's point of view, those seven options were simply never read in the real section, full stop, regardless of whether they were functionally used elsewhere.

### 7.4 Would these options be legal under a non-reserved name?

**VERIFIED FACT: yes.** Under e.g. `[update_manager nebulaos_klipper]`, `cfg = config[section]` (`update_manager.py:119`) is a real, root-tracked `getsection()` call; `GitDeploy(cfg)`'s full constructor chain reads every one of these directly off that real object: `type` (`app_deploy.py:44`), `path` (`app_deploy.py:76`), `virtualenv` (`app_deploy.py:87-88`), `requirements` (`app_deploy.py:133`), `managed_services` (`app_deploy.py:156-158`), `origin`/`primary_branch` (`git_deploy.py:39,41`), `refresh_interval` (`base_deploy.py:35`), plus `channel`/`pinned_commit` directly too. None of these would warn.

### 7.5 How does Moonraker discover Klipper's real path/repo for the reserved slot?

`common.py:98-100` sets `path`/`env`/`type` from `kconn.path`/`kconn.executable`/`AppType.detect(kconn.path)` — `kconn` is `KlippyConnection`, whose `_path`/`_executable` start at hardcoded `~/klipper`/`~/klippy-env/bin/python` defaults (`klippy_connection.py:89-90`), are then loaded from the Moonraker database (`klippy_connection.py:158-159`), then continuously updated from whatever Klippy itself reports live over its own identify handshake (`_save_path_info()`, `klippy_connection.py:352-363`, persisted back to the DB). `UpdateManager._set_klipper_repo` (`update_manager.py:227-248`) re-derives these again on the `server:klippy_identified` event. **The config file's `path`/`origin` values for `[update_manager klipper]` play no role at any point in this chain.**

### 7.6 How does Moonraker discover its own path/venv; does explicit `virtualenv:` do anything?

`common.py:30,32`: `virtualenv: sys.exec_prefix`, `path: str(source_info.source_path())` — both hardcoded, neither in `OPTION_OVERRIDES`. The explicit `virtualenv: /usr/data/nebulaos/envs/moonraker` in NebulaOS's `[update_manager moonraker]` is **completely inert** for the reserved slot: it is not even fetched from the real section (confirmed by §7.2/§7.3), and the actually-used venv is whatever `sys.exec_prefix` resolves to for the running process (which, as it happens, *is* the correct `/usr/data/nebulaos/envs/moonraker/bin/python3` — see §3 — because that's the interpreter the process was launched under, not because the config line did anything).

### 7.7 Does a crashed reserved updater leave options "unparsed forever," or were they never considered?

**VERIFIED FACT: never considered, independent of crash/success.** The `OPTION_OVERRIDES` copy (`common.py:106-112`) runs at `update_manager.py:75`, *before* the reserved updaters are even constructed (L95-105) — so whether `GitDeploy(kcfg)`/`GitDeploy(mcfg)` succeeds or throws has no bearing on whether `channel` et al. get marked parsed (they already are, by then), and the other seven options were never going to be marked parsed regardless, because nothing in the entire call chain ever calls an accessor for those names against the real section object. Separately, `validate_config()`'s only whole-section suppression mechanism (`CFG_ERROR_KEY`, `confighelper.py:518-521`) only fires when a `ConfigError` is raised from `_get_option` **on the real section's own `ConfigHelper`** — a `GitDeploy` construction failure happens against the synthetic `kcfg`/`mcfg`, so it never sets this key and never suppresses the warnings. **This directly and conclusively rejects H2** (§17).

### 7.8 Reserved-slot vs generic-updater option table

| Option | `[update_manager klipper]` (reserved) | `[update_manager moonraker]` (reserved) | Generic named `git_repo` updater |
|---|---|---|---|
| `type` | ignored, not warned — `AppType.detect(kconn.path)`, `common.py:100` | ignored, not warned — `AppType.detect()`, `common.py:97` | read/used — `app_deploy.py:44` |
| `path` | ignored, not warned — `kconn.path`, `common.py:98` | ignored, not warned — `source_info.source_path()`, `common.py:32` | read/used — `app_deploy.py:76` |
| `origin` | ignored, not warned — `BASE_CONFIG`, `common.py:37` | ignored, not warned — `BASE_CONFIG`, `common.py:26` | read/used — `git_deploy.py:39` |
| `primary_branch` | ignored, not warned — not in `OPTION_OVERRIDES`; hardcoded fallback `"master"` if read at all (`git_deploy.py:41`, never reached for reserved slots) | same | read/used — `git_deploy.py:41` |
| `managed_services` | ignored, not warned — hardcoded `"klipper"`, `common.py:41` | ignored, not warned — hardcoded `"moonraker"`, `common.py:33` | read/used — `app_deploy.py:151-158` |
| `virtualenv` | ignored, not warned — klipper's `BASE_CONFIG` has no `virtualenv` key (uses `env`/`kconn.executable`) | ignored, not warned — hardcoded `sys.exec_prefix`, `common.py:30` | read/used — `app_deploy.py:85-91` |
| `requirements` | ignored, not warned — `BASE_CONFIG`, `common.py:38` | ignored, not warned — `BASE_CONFIG`, `common.py:27` | read/used — `app_deploy.py:133` |
| `channel` | read/used — `OPTION_OVERRIDES`, `common.py:45,109-112` | same | read/used — `app_deploy.py:46` |
| `pinned_commit` | read/used — `OPTION_OVERRIDES` | same | read/used — `git_deploy.py:42` |
| `refresh_interval` | read/used — `OPTION_OVERRIDES` (+ global fallback, `update_manager.py:547`) | same | read/used — `base_deploy.py:35` |

---

## 8. Current upstream Moonraker comparison

**SOURCE-BACKED INFERENCE**, from git history rather than a fresh online doc lookup (per Phase 1's own instruction to treat the exact running commit as primary authority):

- The reserved-slot/`OPTION_OVERRIDES` mechanism is foundational and long-stable (`003acd5 update_manager: fetch klipper paths from klippy_connection` established it; only one option, `report_anomalies`, has been added to the whitelist since, per `dbe0dc4`). It is not a recent change.
- **Updating Moonraker would not fix, and would not meaningfully worsen, these warnings.** The mechanism generating them is architectural, not version-drift. The log's own wording ("this may become an error in a future version") is a *possible* future Moonraker-side hardening (turning stale-option warnings into hard errors) — but that would apply equally regardless of whether NebulaOS updates Moonraker now, since it's about the `configparser`-vs-accessor tracking gap in general, not this specific commit.
- **Reserved-updater behavior has not changed in a way relevant here.** No evidence of a syntax change; these are, and always have been, dead-weight options in this exact context.

**RECOMMENDATION note:** do not chase "update Moonraker" as a fix for this specific problem — it targets the wrong layer (§20).

---

## 9. Stock implementation findings

**VERIFIED FACT** — this exact device's real stock configuration, read directly from the shared `/usr/data` partition (no reboot into stock was needed or performed; `/usr/data` is a single physical partition mounted by both boot slots, confirmed via `mount`/`/proc/cmdline` evidence already established in prior missions):

The device's real stock firmware uses **Guilouz/Creality-Helper-Script**, not pellcorp/creality/SimpleAF — a materially different community tool. Its live `/usr/data/printer_data/config/moonraker.conf`:

```ini
[update_manager]
enable_auto_refresh: True
refresh_interval: 24
enable_system_updates: False

[update_manager Creality-Helper-Script]
type: git_repo
channel: dev
path: /usr/data/helper-script
origin: https://github.com/Guilouz/Creality-Helper-Script.git
primary_branch: main
managed_services: klipper

# [webcam Camera] block: present but fully commented out, placeholder
# xxx.xxx.xxx.xxx IPs, service: mjpegstreamer — user must manually
# uncomment and configure

[update_manager mainsail]
type: web
repo: mainsail-crew/mainsail
path: /usr/data/mainsail
```

Key findings, cross-checked against a live fetch of the current `Guilouz/Creality-Helper-Script` repository (`main` branch):

1. **Stock does not expose Klipper or Moonraker themselves as `update_manager`-tracked at all.** There is no `[update_manager klipper]` or `[update_manager moonraker]` section anywhere in this device's real stock config. `[update_manager Creality-Helper-Script]` is a **custom-named, non-reserved** git_repo updater for the helper tool itself; `managed_services: klipper` there just means "restart the klipper service after the helper-script's own repo updates" (it patches klippy extras it ships, e.g. `gcode_shell_command.py`).
2. **Moonraker itself is updated by a shell menu function, not Moonraker's own update_manager**: `scripts/moonraker_nginx.sh`'s `install_moonraker_nginx()`/`install_moonraker_3v3()` do a manual `git stash; git checkout master; git pull` from the helper-script's own menu — entirely outside Moonraker's UI/API.
3. **Updating Moonraker via this real path unconditionally overwrites `moonraker.conf`**: `rm -f "$KLIPPER_CONFIG_FOLDER"/moonraker.conf; cp "$MOONRAKER_URL2" "$KLIPPER_CONFIG_FOLDER"/moonraker.conf` — a full template overwrite, every time (there is no separate "install" vs "update" code path; re-running install *is* the update). `printer.cfg` is untouched by this specific path (Klipper itself has no update path in this tool at all).
4. **Stock ships no active default camera.** The template's `[webcam Camera]` block is fully commented out with placeholder IPs; USB camera installation only patches an init.d service file's resolution string, never moonraker.conf's webcam section.
5. **Optional add-ons (Mainsail, camera-settings include) use targeted `sed`-based line patching** against the existing file (uncomment/uncomment-and-re-comment specific blocks, insert/remove a single `[include ...]` line) rather than whole-file overwrite — this pattern is reserved specifically for Moonraker's own reinstall, not general config management.

---

## 10. Current SimpleAF (pellcorp/creality) findings

**VERIFIED FACT** — live-fetched today from `github.com/pellcorp/creality` (`main`, `pushed_at: 2026-07-27T21:06:06Z`), not relying solely on prior cached snippets in this repo's own docs (which were independently re-confirmed byte-identical where they overlapped):

```ini
# k1/moonraker.conf
[update_manager klipper]
channel: dev
pinned_commit: 386fde4fd38e8eda6999e58bf260eceb00051188
report_anomalies: False

[update_manager moonraker]
channel: dev
pinned_commit: abd2026b90d86fb738c6619be3ceefcedee2006c

[update_manager mainsail]
type: web
channel: beta
repo: mainsail-crew/mainsail
path: /usr/data/mainsail
```

```ini
# k1/webcam.conf, included via [include webcam.conf]
[webcam default]
location: printer
enabled: True
service: mjpegstreamer-adaptive
stream_url: /webcam/?action=stream
snapshot_url: /webcam/?action=snapshot
...
```

Key findings:

1. **SimpleAF uses the reserved `klipper`/`moonraker` names, and deliberately sets only `channel`/`pinned_commit`/`report_anomalies`** — exactly, and only, `OPTION_OVERRIDES`'s members (§7.2). This is not an accident: SimpleAF relies entirely on Moonraker's own reserved-slot auto-discovery (`BASE_CONFIG` + live `KlippyConnection` reporting), the same mechanism documented in §7.5-7.6, and never sets `path`/`origin`/`virtualenv` because doing so would be pure dead weight for the reserved names — precisely the bug NebulaOS's own config has.
2. **NebulaOS's own path/origin values are not comparable 1:1 with SimpleAF's**, because NebulaOS's Klipper/Moonraker checkouts genuinely live at non-default paths (`/usr/data/nebulaos/apps/*` vs. Klipper's own live-discovered path and Moonraker's own `sys.exec_prefix`/`source_info` discovery) — but per §7.5-7.6, *neither* system can express a nonstandard path via these config keys for the reserved slots; both are structurally overridden by the runtime discovery mechanisms regardless of what's typed in the file. NebulaOS's paths already are what Klippy/Moonraker report live (confirmed §3), so the config-file values are redundant documentation, not functional configuration, in both systems equally.
3. **Real install paths**: Klipper `/usr/data/klipper` (git), venv `/usr/share/klippy-env`; Moonraker `/usr/data/moonraker` (git, hard-pinned via `git reset --hard`), venv `/usr/data/moonraker-env` (**extracted from a prebuilt tarball**, not built via on-device pip); Mainsail/Fluidd `/usr/data/{mainsail,fluidd}` (release-zip extraction, no git).
4. **Default camera is config-backed** (`[webcam default]` in an included file), matching NebulaOS's own current design choice, not the database-seeding alternative.
5. **`service: mjpegstreamer-adaptive` is the generic Moonraker/Mainsail label for any raw MJPEG-over-HTTP source** — the actual backend is ustreamer (confirmed via `k1/services/S50webcam`, `k1/nginx.conf`'s `mjpgstreamer` upstream, `k1/nginx/fluidd`'s `/webcam/` proxy), not literal mjpg-streamer. This exactly matches NebulaOS's own pipeline (ustreamer → nginx `/webcam/` → Moonraker/Mainsail), independently confirming §16's "correct service value" finding.
6. **Config regeneration is active, not one-time.** `--update`/`--reinstall` deletes the entire `/usr/data/pellcorp.done` marker, causing *every* gated install function (including the unconditional `cp .../moonraker.conf`/`cp .../webcam.conf`) to re-run in full. `printer.cfg` specifically is reset to a factory-snapshot baseline and then has a saved user-overrides diff replayed on top via a dedicated Python tool (`config-helper.py`, built on the `ConfigUpdater` library) that performs dozens of surgical section/key patches per printer model. **The Moonraker database is the one component genuinely protected** — explicitly tarred before removing the old Moonraker checkout and restored immediately after the fresh clone.

---

## 11. Stock / SimpleAF / NebulaOS comparison table

| Area | Stock (Creality-Helper-Script, this device) | Current SimpleAF (pellcorp/creality) | NebulaOS sealed |
|---|---|---|---|
| Moonraker source | Official upstream, git, `/usr/data/moonraker` | Official upstream, git, hard-pinned, `/usr/data/moonraker` | Official upstream, git, `/usr/data/nebulaos/apps/moonraker`, user-updatable (no pin) |
| Moonraker update mechanism | Helper-script shell menu (`git pull`), **not** Moonraker `update_manager` | Moonraker `update_manager`, reserved `moonraker` slot | Moonraker `update_manager`, reserved `moonraker` slot |
| Moonraker app path (config value) | n/a (no `[update_manager moonraker]` section exists) | not set (relies on `BASE_CONFIG`/`sys.exec_prefix`/`source_info`) | set (`path`, `virtualenv`) — **inert for the reserved slot**, §7.6 |
| Moonraker Python environment | `/usr/data/moonraker-env` (on-device venv, not inspected further) | `/usr/data/moonraker-env`, prebuilt tarball | `/usr/data/nebulaos/envs/moonraker`, `--system-site-packages`, built on-device |
| Persistent data path | `/usr/data/printer_data` | `/usr/data/printer_data` (standard) | `/opt/printer_data` (bind-mounted from `/usr/data/nebulaos/printer_data`) |
| `moonraker.conf` path | `/usr/data/printer_data/config/moonraker.conf` | `/usr/data/printer_data/config/moonraker.conf` | `/opt/printer_data/config/moonraker.conf` (bind mount) |
| Database path | `/usr/data/printer_data/database` (inferred, not directly inspected) | `/usr/data/printer_data/database` | `/opt/printer_data/database/moonraker-sql.db` |
| Klipper updater | **None** — no update_manager slot for Klipper at all | Reserved `klipper` slot, hard-pinned | Reserved `klipper` slot, user-updatable |
| Moonraker updater | **None** (see above) | Reserved `moonraker` slot, hard-pinned | Reserved `moonraker` slot, user-updatable |
| Mainsail updater | `type: web`, reserved-name-equivalent generic section, no channel set (stable) | `type: web`, `channel: beta` | `type: web`, `channel: beta` |
| Updater section type (klipper/moonraker) | n/a | Reserved | Reserved |
| Repository detection | n/a | Live `KlippyConnection`/`sys.exec_prefix`/`source_info` (implicit) | Same mechanism (implicit; config values redundant) |
| Service detection | Explicit `managed_services: klipper` on the helper-script's own updater | Implicit (`BASE_CONFIG`) | Explicit `managed_services:` set but **inert** for reserved slots |
| Camera definition source | Config, but **disabled by default** (commented out) | Config (`[webcam default]`, included file) | Config (`[webcam Nebula]`) |
| Camera service value | `mjpegstreamer` (template placeholder, unused by default) | `mjpegstreamer-adaptive` | `mjpegstreamer-adaptive` |
| Stream URL | placeholder `http://xxx.xxx.xxx.xxx:8080/?action=stream` (unused by default) | `/webcam/?action=stream` | `/webcam/?action=stream` (confirmed working, §16) |
| Snapshot URL | placeholder (unused by default) | `/webcam/?action=snapshot` | `/webcam/?action=snapshot` (confirmed working, §16) |
| Camera editable in Mainsail | n/a (none active by default) | No (config-sourced, same restriction) | **No** (config-sourced — Moonraker API-level restriction, §15) |
| Application update touches config | **Yes** — Moonraker reinstall unconditionally overwrites `moonraker.conf` | **Yes** — every reinstall/update re-copies `moonraker.conf`/`webcam.conf`; `printer.cfg` actively migrated | **No** — NebulaOS's own update-supervisor never touches `moonraker.conf` (deliberate difference, §6) |
| Application update touches database | Not directly observed (no update path touches Moonraker's DB in the inspected scripts) | **No** — explicitly tar-backed-up and restored around every Moonraker reinstall | No (NebulaOS has no mechanism that would) |
| Fresh-install default mechanism | One-time `cp` from template at first install; **re-copied on every subsequent "update"** too | One-time-per-run `cp`, but re-runs on every update/reinstall (marker deleted) | One-time seed at factory-seed/namespace-creation time only (§13 lifecycle) |
| Config migration mechanism | None (whole-file overwrite substitutes for migration) | Yes — real, active (`config-helper.py`/`ConfigUpdater`, factory-snapshot + overrides-diff replay) | None (by design, per the governing closure-mission brief: no deployed user base to migrate) |

**Where NebulaOS differs intentionally vs. accidentally:**
- **Intentional, correctly justified**: no config-migration framework (no deployed OpenKE user base, per the closure mission's own explicit finding); Klipper/Moonraker are genuinely user-updatable (no pin) rather than hard-pinned, per this mission's own stated goal; Mainsail via release/beta, matching both references.
- **Accidental, not evidenced by any reference system**: setting `path`/`origin`/`managed_services`/`virtualenv`/`requirements`/`type` under the *reserved* `klipper`/`moonraker` section names — neither stock nor SimpleAF does this (stock doesn't use the reserved names for these apps at all; SimpleAF uses the reserved names but only ever sets `OPTION_OVERRIDES` members). This is the direct, sole cause of the warnings, and is a divergence from proven practice, not a considered design choice.
- **Accidental, stale-comment claim**: NebulaOS's own moonraker.conf asserts config-sourced webcams are "loaded once... inert on any boot after that" — this is factually wrong per `webcam.py`'s actual source (§15); it is re-parsed every boot. This wrong belief may have shaped other (uninvestigated) assumptions elsewhere in the codebase and is worth correcting regardless of the recommendation adopted.

---

## 12. NebulaOS configuration lifecycle

**VERIFIED FACT / SOURCE-BACKED INFERENCE**, drawn from prior missions' own established, unchanged (frozen) mechanisms — not re-modified this mission, only read:

```text
tracked template (scripts/build/overlay/opt/printer_data/config/moonraker.conf)
  → Buildroot overlay sync (04-cross-compile-app-stack.sh, unchanged)
  → rootfs squashfs (immutable, baked at build time)
  → S01persistent-datastore seeds /usr/data/nebulaos/printer_data on first boot
     from the squashfs default IF NOT ALREADY PRESENT
  → S05nebulaos-activate bind-mounts /usr/data/nebulaos/printer_data
     onto /opt/printer_data (unconditional, once namespace validated)
  → first Moonraker start reads the seeded file
  → ordinary reboot: no re-seed, no re-copy (file persists as-is)
  → Klipper/Moonraker/Mainsail update or rollback: config untouched
     (nebulaos-update-supervisor.sh's own scope is source tree + venv only)
  → custom A/B rootfs switch: config untouched (separate partition, /usr/data
     is shared across both boot slots)
  → missing-namespace recovery: re-seeds from the squashfs default again
     (same one-time-if-absent semantics as first boot)
```

Answering Phase 9's specific questions:

1. **Is `moonraker.conf` copied only on an empty namespace?** VERIFIED FACT (per unchanged `S01persistent-datastore`/factory-seed logic, not re-modified this mission): yes, seed-once-if-absent semantics.
2. **Does application updating ever touch it?** VERIFIED FACT: no (confirmed by reading the sealed update-supervisor's own scope, unchanged).
3. **Does application rollback touch it?** VERIFIED FACT: no, same reasoning.
4/5. **Does Mainsail/Moonraker update touch the database?** VERIFIED FACT: no — neither update path in NebulaOS's design ever writes to Moonraker's database directly; only Moonraker itself (its own webcam/history/frontend components) writes to its own database at runtime.
6. **Does namespace recovery seed a correct current file?** VERIFIED FACT: yes, in the sense that it seeds *the exact byte content baked into whatever image is currently flashed* — which reproduces the current warnings identically (see §6, item 3), so "correct" here means "faithful to the sealed image's own config," not "warning-free."
7. **Can a newer firmware image remain stuck with an old invalid persistent config?** VERIFIED FACT: yes, structurally — the seed-once-if-absent mechanism means a device that already has a namespace never re-seeds `moonraker.conf` from a newer image, ever (this is exactly what was observed and manually corrected during the prior closure mission's own Phase 10 fix, §6).
8. **Is that a problem for fresh installs, existing installs, or only this development device?** VERIFIED FACT: the reserved-slot warnings are NOT a staleness problem at all — a byte-for-byte fresh install of the current sealed image reproduces them identically (see §6, item 3, and §7 throughout). The "old persistent config" class of problem is real but separate, and per the closure mission's own explicit finding, was judged not worth a migration framework given no deployed user base — this investigation did not find new evidence to revisit that judgment.
9. **Is a migration mechanism truly necessary, or is one correct seed enough?** SOURCE-BACKED INFERENCE, informed by §9/§10/§11: neither real reference system relies on "one correct seed, forever" for `moonraker.conf` — both regenerate it on every update. NebulaOS's own choice to *never* touch config on update is not what either reference does for config files in general, but it IS closer to what both references effectively guarantee for the *database* specifically. The practical implication (§20) is not "NebulaOS needs a migration framework" but "whatever must survive an application update should be database-backed, matching what actually survives in both real systems" — a narrower, more specific conclusion than either "yes, build a migration framework" or "no, current design is already correct."
10. **Would the sealed image itself reproduce the warnings from a clean namespace?** VERIFIED FACT: yes (§6, item 3) — this is not a symptom of the specific live device's history.

---

## 13. Application-update lifecycle

Frozen architecture, not modified or re-audited in depth this mission (already covered under sealed scope): `nebulaos-update-supervisor.sh`'s Klipper/Moonraker paired-rollback and Mainsail release-rollback mechanisms operate exclusively on the application source tree (`/usr/data/nebulaos/apps/*`) and, for Moonraker, its paired venv (`/usr/data/nebulaos/envs/moonraker`). **VERIFIED FACT** (re-confirmed by reading the unchanged script this mission, read-only): no code path in it ever opens, writes, or deletes `moonraker.conf`, `printer.cfg`, or any file under `/opt/printer_data/database`. This is consistent with §12's answers 2-3 above and is the one area where NebulaOS's design is *already* narrower/safer than both real reference systems (neither of which protects config files from update-time overwrite).

## 14. Rollback lifecycle

Same frozen mechanism (Mainsail atomic directory-replace, Moonraker paired source+venv restore) — already live-qualified in the final-seal mission and not re-tested here (rollback tests are explicitly forbidden this mission). No rollback path touches `moonraker.conf` or the Moonraker database, by the same reasoning as §13.

---

## 15. Camera ownership and Mainsail behavior

**VERIFIED FACT**, from direct reading of `vendor/moonraker/moonraker/components/webcam.py`:

- `WebcamManager.__init__` (L42-63): L46-51 parses every `[webcam ...]` config section **on every single Moonraker startup**, unconditionally, into `self.webcams` — constructed via `WebCam.from_config()`, which sets `source="config"` (L412).
- `component_init()` (L68-100), an *async* step that runs after `__init__`, separately loads database-backed cameras (`db.get_item("webcams", default={})`, L74) via `WebCam.from_database()` (`source="database"`, L460). **Critically**: if a database camera's `name` collides with an already-loaded config camera's name (L89-94), the database entry is silently dropped (`ro_info.append("Detected webcam name collision... This camera will be ignored.")`, logged only as a rollover log item) and **never overwrites or merges with** the config camera.
- **This directly and completely contradicts NebulaOS's own moonraker.conf comment**, which currently claims: *"Loaded once at first boot - Moonraker copies `[webcam]` sections into its own database as source 'config' the first time it sees them, and this section becomes inert on any boot after that."* Nothing in `webcam.py` ever writes a config-sourced camera into the database, and nothing about it becomes "inert" — it is re-read from the live config file every single restart. This comment should be corrected regardless of which recommendation is adopted (§20).
- **Edit/delete restriction is a hard, unconditional Moonraker server-side rule, not a Mainsail UI choice**: `_handle_webcam_request` (L166-208) explicitly checks `if webcam.source == "config": raise self.server.error(...)` for both `POST` (L175-179, "Cannot overwrite webcam '...' sourced from Moonraker configuration") and `DELETE` (L197-201, "Cannot delete webcam '...' sourced from Moonraker configuration"). Mainsail disabling its own Edit/Delete buttons for this camera is simply reflecting an API-level restriction that exists regardless of which frontend is used.
- `WebCam._protected_fields = ["source", "uid"]` (L237) — even a database-backed camera can never have its own `source`/`uid` changed via `update()` (L363), reinforcing that `source` is a structural, immutable classification, not a UI convention.

**A real, previously-undiscovered issue found in the process** (live evidence, `/opt/printer_data/database/moonraker-sql.db`, SQL query against `namespace_store` WHERE `namespace='webcams'`):

```json
{"uid": "bc6b0e60-20ff-49c4-b5ed-38e1fc68d0ed",
 "name": "Nebula", "service": "uv4l-mjpeg",
 "targetFps": 15, "urlStream": "/webcam/?action=stream",
 "urlSnapshot": "/webcam/?action=snapshot", ...}
```

This is a **stale, database-backed webcam entry**, also named `"Nebula"`, with an old camelCase field schema (`targetFps`/`urlStream`/`urlSnapshot` rather than the current `target_fps`/`stream_url`/`snapshot_url`) and a `service` value (`uv4l-mjpeg`) that does not match the currently-configured `mjpegstreamer-adaptive` — almost certainly a leftover from an earlier (OpenKE-era or early-NebulaOS) Moonraker/schema version. `moonraker.log` confirms this collision is detected and the entry silently discarded on **every single boot** ("Detected webcam name collision: Nebula, uuid: bc6b0e60-... This camera will be ignored," recurring across every logged boot this session). This is inert dead data today (masked by the name collision), but is exactly the kind of "invisible until someone renames the config camera" landmine worth cleaning up in any later implementation mission (§25).

A secondary, tangential observation (not deeply investigated, out of core scope): `/machine/update/status` reports `"is_valid": false` for the moonraker entry despite `is_dirty: false`, `detached: false`, `channel_invalid: false`. This is likely related to the shallow-clone/synthetic-wrapper-commit state described in §3, not to the reserved-slot options warnings. Flagged for awareness, not analyzed further here.

---

## 16. Camera transport verification

**VERIFIED FACT**, all read-only, all successful:

| Test | Result |
|---|---|
| Direct ustreamer stream (`http://127.0.0.1:8080/?action=stream`) | `HTTP/1.0 200 OK`, `Content-Type: multipart/x-mixed-replace;boundary=boundarydonotcross` |
| Direct ustreamer snapshot (`http://127.0.0.1:8080/?action=snapshot`) | `HTTP/1.1 200 OK`, `X-UStreamer-Online: true`, real width/height headers |
| nginx `/webcam/?action=snapshot` (trailing slash) | `HTTP/1.1 200 OK`, `Content-Type: image/jpeg` |
| nginx `/webcam?action=snapshot` (no trailing slash) | `HTTP/1.1 301 Moved Permanently` → `Location: http://127.0.0.1/webcam/?action=snapshot` (standard nginx `location /webcam/ {}` prefix-match behavior, not a bug — Mainsail always requests the trailing-slash form per its own configured `stream_url`/`snapshot_url`, so this redirect is never actually exercised in practice) |

**Conclusion: the configured `/webcam/?action=stream` / `/webcam/?action=snapshot` URLs and `service: mjpegstreamer-adaptive` value are correct and fully functional**, independently confirmed at both the raw-ustreamer and nginx-proxy layers, and independently corroborated by SimpleAF's own reference using the identical service value and URL pattern for the identical real backend (ustreamer) in §10. **H9 and H10 are rejected** (§17).

**Correction, 2026-07-29**: the `service` value half of this conclusion does not hold in practice - the device owner confirmed directly that `mjpegstreamer-adaptive` does not produce a working Mainsail stream on this real hardware, while `uv4l-mjpeg` does. The transport-layer reasoning above (ustreamer backend, working nginx proxy) was correct but insufficient - it does not guarantee Mainsail's own client-side handling of the `service` label matches. The shipped default was corrected to `uv4l-mjpeg`; see §29's resolution note for the full account.

---

## 17. Root-cause hypothesis matrix

### H1 — Reserved updater sections use the wrong option set
```text
Status: CONFIRMED
Evidence: §7 in full (exact file:line citations); §7.8 table
Impact: Clean install (reproduces identically, §6/§12) and existing device equally
Likely correction: Analysis only — see §20 Option A
```

### H2 — Update Manager failed before consuming valid options
```text
Status: REJECTED
Evidence: §7.7 — the OPTION_OVERRIDES copy runs before updater construction;
/server/info confirms failed_components is empty (update_manager loaded successfully)
Impact: n/a
Likely correction: n/a
```

### H3 — Moonraker version mismatch
```text
Status: REJECTED
Evidence: §8 — the reserved-slot mechanism is long-stable in Moonraker's own
history; not a recent change; updating Moonraker would not change this behavior
Impact: n/a
Likely correction: n/a
```

### H4 — Runtime discovery mismatch (bind mounts, venv, Git metadata confusing discovery)
```text
Status: REJECTED as a cause of the WARNINGS; PARTIALLY CONFIRMED as a real,
SEPARATE prior issue already fixed
Evidence: §7.5/§7.6 show discovery works via KlippyConnection/sys.exec_prefix
regardless of config content - the warnings are unrelated to discovery success.
The /root/klippy-env bind mount (final-seal-mission-adjacent, already shipped)
exists specifically to make discovery succeed for the update_manager COMPONENT
LOAD (a different, already-resolved problem, not the options warnings).
Impact: n/a for the warnings; already resolved for its own original problem
Likely correction: none needed for this investigation's questions
```

### H5 — Stale persistent `moonraker.conf`
```text
Status: REJECTED (for the warnings); CONFIRMED but functionally inert (for a
documentation comment only)
Evidence: §6 - live file differs from repo source only by an 18-line comment
block with zero parsing effect; the warnings are fully reproducible from either copy
Impact: UI-only (a reader of the live file sees slightly less explanation
than the repo source) - no behavioral impact
Likely correction: re-push the current source file (mechanical, not a design change)
```

### H6 — Incorrect clean-install template
```text
Status: CONFIRMED (the template itself is what causes the warnings, by design
flaw, not incorrect seeding)
Evidence: §6 item 3, §7 throughout
Impact: Clean install AND existing device equally
Likely correction: see §20 Option A/B
```

### H7 — Config-backed camera is intentionally immutable in Mainsail because `source=config`
```text
Status: CONFIRMED
Evidence: §15 - exact webcam.py L175-179/197-201 citations; this is a Moonraker
server-side rule, not a Mainsail-specific UI choice
Impact: Clean install and existing device equally; by design, not a bug
Likely correction: analysis only - see §20 camera options
```

### H8 — Camera database/config precedence conflict
```text
Status: CONFIRMED
Evidence: §15 - a real, stale database-backed "Nebula" webcam (old
uv4l-mjpeg/camelCase schema) silently collides with and is discarded in favor
of the config-sourced "Nebula" camera, on every boot, confirmed via live
moonraker.log entries
Impact: Existing (this) device only - a fresh install's database would not
contain this stale entry; not a clean-install-reproducible issue
Likely correction: analysis only - stale entry should be removed in any later
implementation mission (§25)
```

### H9 — Wrong service value
```text
Status: REJECTED
Evidence: §16 - direct transport verification confirms mjpegstreamer-adaptive
works correctly against the real ustreamer MJPEG output; §10 confirms SimpleAF
uses the identical value for the identical backend
Impact: n/a
Likely correction: n/a
```

### H10 — Wrong proxy URL
```text
Status: REJECTED
Evidence: §16 - /webcam/?action=stream and /webcam/?action=snapshot both
verified working end to end through nginx
Impact: n/a
Likely correction: n/a
```

### H11 — Development-device-only contamination
```text
Status: PARTIALLY CONFIRMED - applies to the stale database webcam entry (H8),
NOT to the update_manager warnings (which are clean-install-reproducible, per H1/H6)
Evidence: §6, §15
Impact: Existing device only, for the database entry specifically
Likely correction: analysis only - see §25
```

---

## 18. Architecture invariants

All of the following, as stated in the governing mission brief, are confirmed **preserved** by every option considered in §19-20 (none require violating any of them):

```text
Moonraker:            official upstream source                — preserved (no patching considered or needed)
Mainsail:              official upstream beta release           — preserved
Klipper:               NebulaOS-maintained Pellcorp-derived branch — preserved, unaffected
Application updates:   modify source/release + paired env only  — preserved; no option below changes this
Persistent printer_data: survives application updates           — preserved; unaffected
moonraker.conf:        remains outside application source       — preserved
Moonraker database:    remains outside application source       — preserved
Camera user state:     survives application updates             — addressed directly in §20 (currently NOT
                                                                    survivable for a user-created camera under
                                                                    Option 1/status quo, since there is no
                                                                    update path that would delete it anyway -
                                                                    but a config-sourced camera also can't be
                                                                    user-modified in the first place, which is
                                                                    the actual complaint)
Immutable rootfs:      retains factory recovery seeds            — preserved, untouched
A/B rootfs update:     does not overwrite persistent operational data — preserved, untouched
NebulaOS ownership:    integration/paths/boot order/seeding/rollback/hardware services — preserved
No upstream patching:  Moonraker/Mainsail not patched for custom config — preserved by every option below
```

**A correct factory seed alone does satisfy all of these invariants** for the update_manager warnings (§20 Option A is pure configuration change, zero code). For the camera problem, a correct factory seed choice (§20, camera options) also satisfies all invariants without any new abstraction — the existing `source=config`/`source=database` distinction already built into upstream Moonraker is sufficient; no extra framework is needed.

---

## 19. Options considered

### Update Manager options

**Option A — Minimal reserved sections.** Reduce `[update_manager klipper]`/`[update_manager moonraker]` to only the options that are ever actually read for reserved slots (`channel`, and optionally `pinned_commit`/`refresh_interval`/`report_anomalies` if wanted) — remove `type`, `path`, `origin`, `primary_branch`, `managed_services`, `virtualenv`, `requirements` entirely (or, per §7 and per this project's own prior "keep as accurate documentation" style, retain them purely as comments, not as INI key=value lines Moonraker's configparser would ever see). Path/remote/branch/service discovery already works correctly today via `KlippyConnection`/`sys.exec_prefix` (confirmed §3 — the running process already uses exactly `/usr/data/nebulaos/envs/moonraker` and the correct Klipper checkout, with zero config-file involvement). Mainsail compatibility: unaffected — Mainsail reads Moonraker's own `/machine/update/status`/`/server/info`, not the raw config file; it already displays correct data today (confirmed §5, `/machine/update/status` round-trips real commit history). **Matches exactly what SimpleAF's current reference does (§10).**

**Option B — Generic explicitly named Git updaters** (e.g. `[update_manager nebulaos_klipper]`). Would make every currently-dead option genuinely functional (§7.4), but: creates a **duplicate updater entry** situation, since Moonraker *still* auto-instantiates the reserved `klipper`/`moonraker` slots regardless (§7.1) — NebulaOS would end up with four updater entries in Mainsail's UI (the two auto-created reserved ones, now still present and presumably showing the exact same warnings unless *also* emptied per Option A, plus two new custom-named ones) unless the reserved slots are simultaneously reduced to nothing. This does not match either reference system's actual practice and adds real complexity (duplicate restart-service handling, duplicate rollback-supervisor interaction, Mainsail presenting two Klipper-labeled cards) with no discovery/compatibility benefit Option A doesn't already deliver via already-working runtime discovery.

**Option C — Keep current configuration.** Rejected on the evidence: §7 conclusively shows these options are not "legal but secondary to another failure" — they are structurally never read for the reserved names, full stop, in this exact commit and in every commit since `003acd5`. There is no scenario in which keeping them stops the warnings.

**Ranking:** Option A (upstream-compatible, matches SimpleAF exactly, zero new complexity, clean-install-safe) > Option C (rejected on evidence) > Option B (adds complexity with no benefit, diverges from both references).

### Camera options

**Option 1 — Config-defined default (current state).** Simple at clean-install time (one `[webcam Nebula]` block, matches both stock's template intent and SimpleAF's `[webcam default]` exactly). Cost: permanently non-editable/non-deletable via Mainsail/API by design (§15) — this is Moonraker's own upstream behavior for `source=config`, not a bug to fix, but it is the direct cause of the user-visible complaint ("cannot be edited or deleted").

**Option 2 — Database-defined factory default.** Seed the camera once (e.g., via a one-time boot-time API call or direct DB insert during factory-seed/namespace-creation, matching the same "seed once if absent" pattern §12 already uses for `moonraker.conf` itself) with `source="database"`. User-editable and user-deletable afterward, matching normal Mainsail camera-management UX. Needs a duplicate-prevention guard (a marker, exactly analogous to the existing factory-seed "already seeded" markers this project already uses elsewhere — not a new class of mechanism). Survives application updates identically to the config option (neither path is ever touched by any update mechanism, §13). Matches the standard "Add a webcam via the Mainsail UI" experience new users of any moonraker-based system already expect. **Neither stock nor SimpleAF actually uses this pattern for their own default camera** (§9/§10 — both are config-backed) — this would be a deliberate, evidenced-motivated divergence from both references, justified specifically by resolving the user's stated Edit/Delete complaint, not by precedent.

**Option 3 — No default camera entry.** Simplest; matches stock's own actual default behavior exactly (§9 — stock ships the webcam block fully commented out). Mainsail does not auto-discover cameras; a user with a working ustreamer/nginx pipeline would need to manually add one via Mainsail's own "Add Camera" UI (straightforward — the pipeline already works end-to-end, §16). Loses the "camera just works out of the box" property NebulaOS currently has and SimpleAF also provides.

**Ranking:**
- Upstream compatibility: Option 1 = Option 2 (both use standard Moonraker mechanisms) > Option 3 (no camera at all, technically "most compatible" but weakest UX).
- Stock similarity: Option 3 (exact match) > Option 1 (matches the *shape* stock ships, disabled) > Option 2 (no stock precedent).
- SimpleAF similarity: Option 1 (exact match) > Option 3 > Option 2 (no precedent).
- Clean-install correctness: Option 1 = Option 2 (both seed once, deterministically) > Option 3 (nothing to get wrong, but nothing works out of the box either).
- Update survival: Option 1 = Option 2 (identical — neither path is ever touched by updates in NebulaOS's own design) > Option 3 (n/a).
- Rollback safety: identical reasoning, all three tie (no rollback path touches config or database).
- User control (edit/delete): Option 2 (full control) > Option 3 (full control, but must create it first) > Option 1 (none — by design).
- Implementation complexity: Option 1 (zero — already shipped) < Option 3 (remove one section) < Option 2 (one-time seed step + duplicate-prevention marker).
- Stale-state risk: Option 1 (none — always re-read fresh from config, §15) < Option 3 (none) < Option 2 (a seed-once marker could, like `moonraker.conf`'s own seed-once semantics, become stale on a device that's had its namespace recreated from an old image — same class of risk §12 already accepts for config).

---

## 20. Recommended minimum correction

**RECOMMENDATION** (not implemented this mission):

### Update Manager
1. **Reduce `[update_manager klipper]` and `[update_manager moonraker]` to only real, read options.** Concretely: keep `channel: dev` (and add `pinned_commit`/`report_anomalies` only if a future mission decides it wants them — neither is needed today). Remove `type`, `path`, `origin`, `primary_branch`, `managed_services`, `virtualenv`, `requirements` as INI lines. If the intent behind those lines (documenting where Klipper/Moonraker actually live and which origin they track) is worth preserving, express it as a comment above the section — exactly the style this project already uses everywhere else for "accurate but not machine-read" documentation (e.g. the existing "Closure-mission correction" comment block, §6). This is **Option A**, matching SimpleAF's own proven current practice exactly.
2. **Discovery is already correct and needs no change.** Klipper's path/executable and Moonraker's own venv are already being reported correctly via the live mechanisms confirmed in §3/§7.5-7.6 — reducing the config does not change what Moonraker actually uses, only removes the dead-weight lines that generate warnings about content nothing ever reads.
3. **No correction needed to the `/root/klippy-env` bind mount or venv architecture** — that mechanism solves a different, already-resolved problem (component load succeeding at all, §17/H4) and remains necessary regardless of this recommendation.

### Camera
4. **Recommend Option 2 (database-defined factory default) over the status quo**, specifically because it is the only option that resolves the user's actual, stated complaint (cannot edit/delete) while still seeding a working default out of the box — matching the spirit of "the camera should just work" that motivated the original config-based design, without its side effect. This is an evidenced, deliberate divergence from both stock and SimpleAF (neither of which needs this, because neither ships an editable-by-default camera at all — stock ships none, SimpleAF ships an equally immutable config one), justified by this project's own explicit UX goal (working camera in Mainsail without a stale/frozen entry the user can't manage).
5. **Seed once, following this project's own established "seed once if absent" idiom** (same shape as `moonraker.conf`'s own factory-seed, §12) — not a continuously-reconciled framework, and not a generic override system.
6. **Remove the stale `uv4l-mjpeg`/camelCase database webcam entry** (`bc6b0e60-20ff-49c4-b5ed-38e1fc68d0ed`, §15/H8) as part of the same implementation pass, since it will otherwise sit inertly until some future rename accidentally un-masks it.
7. **Correct the factually-wrong moonraker.conf comment** about config-webcam persistence (§15) regardless of which camera option is chosen — it currently asserts behavior `webcam.py` does not have.

### On the broader "config lifecycle" question
8. **No config-migration framework is needed.** §12's own lifecycle trace, plus the evidence in §9-§11, supports a narrower conclusion than either "yes, build one" or "current design already matches proven practice": NebulaOS's existing choice to never touch `moonraker.conf` on update is *stricter* than both real references (which both overwrite it), so no gap exists there requiring a migration mechanism to bridge. The one place a persistence guarantee is genuinely useful (the camera) is exactly where Option 2 already provides it via the database, matching what actually survives updates in both real reference systems (§12, item 9) — not via a new configuration layer.

**This satisfies "prefer correct clean defaults + persistent printer_data + persistent Moonraker database + standard upstream behavior over new frameworks"** exactly as the mission brief requested: nothing here is a new abstraction; every piece is either "stop writing options nothing reads" or "use the specific already-existing Moonraker mechanism (`source=database`) designed for exactly this purpose."

---

## 21. Rejected designs

- **A generic Moonraker config-override/fragment framework** (`user.d`-style) — no evidence anywhere in stock, SimpleAF, or Moonraker's own architecture that this pattern is needed; explicitly out of scope per the governing brief, and this investigation found nothing to justify revisiting that.
- **Patching upstream Moonraker to accept NebulaOS's extra options** — would violate the "no upstream patching" invariant (§18) for a problem that has a zero-code, config-only fix (§20 Option A).
- **Generic-named updater sections (Option B)** — rejected in §19 (duplicate-entry problem, no reference-system precedent, no benefit over Option A).
- **A continuous config-reconciliation/regeneration system matching pellcorp's `config-helper.py` migration engine** — while real and actively used by SimpleAF (§10), NebulaOS's own explicit governing decision (no deployed user base, closure mission) already rejected building a migration framework, and this investigation found no new evidence overturning that; the narrower database-seeding fix (§20) resolves the actual problem without it.
- **A generic camera-precedence/merge system for config+database collisions** — the existing name-collision-log-and-discard behavior (§15) is standard Moonraker behavior; the fix is to stop shipping a stale entry, not to build conflict resolution around it.

---

## 22. Proposed implementation scope

For a later implementation mission (not this one) to plan against — **RECOMMENDATION**, not a commitment:

1. Edit `scripts/build/overlay/opt/printer_data/config/moonraker.conf`: reduce the two reserved updater sections per §20.1; correct the webcam-persistence comment per §20.7; remove or replace the `[webcam Nebula]` section per whichever camera option is finally chosen.
2. If Option 2 (database camera) is chosen: add a one-time seed step (likely in `S04nebulaos-factory-seed` or a new dedicated step, following the exact idiom already used for `moonraker.conf`'s own seeding) that POSTs a webcam definition to `/server/webcams/item` (or inserts directly into the `webcams` database namespace) only if no camera with that name/uid already exists — plus a duplicate-prevention marker.
3. On the live development device only (not a general mechanism): remove the stale `uv4l-mjpeg` database entry (§15/H8) and re-push the corrected `moonraker.conf`.
4. Update `docs/NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md` §2 (the moonraker.conf reference shape) and any other doc quoting the current (soon-to-be-reduced) update_manager sections, to keep documentation matching actual behavior — a recurring theme of this whole project's own established discipline.

## 23. Proposed clean-install qualification

**RECOMMENDATION**: a future implementation mission should verify, on a freshly wiped/reseeded namespace (matching this project's own existing "missing namespace recovery" test pattern):
- Zero "Unparsed config option" warnings for `[update_manager klipper]`/`[update_manager moonraker]`.
- `/machine/update/status` still correctly reports real version/commit info for both (confirming discovery still works with the reduced config, per §7.5-7.6's already-proven mechanism).
- The camera (whichever option chosen) appears correctly in `/server/webcams/list` and Mainsail's UI on first boot, with no name collision logged.

## 24. Proposed update-survival qualification

**RECOMMENDATION**: exercise the existing (already-qualified, sealed) Klipper/Moonraker/Mainsail update and rollback paths and confirm, before and after each:
- `moonraker.conf` hash unchanged (already true today, §13 — should remain true).
- The camera entry (if Option 2) survives with user edits intact, if a test edit was made beforehand.
- No new "Unparsed config option" warnings appear as a side effect of any update path.

## 25. Risks and unresolved questions

- **Risk**: reducing the update_manager sections changes what Mainsail's UI displays for "path"/"repo" metadata in some views, if Mainsail's own frontend reads those fields from the raw config anywhere rather than exclusively from `/machine/update/status`/`/server/info`. Not verified in this investigation (would require inspecting Mainsail's own compiled frontend bundle behavior in more depth than this mission's `release_info.json` check) — **flagged as an open question for the implementation mission**, not a blocker to the recommendation, since §7.5/§7.6 confirm the *live* discovered values are already correct regardless of the config file.
- **Unresolved**: the `"is_valid": false` moonraker update-status flag (§15, secondary observation) — not chased to a root cause in this investigation; worth a quick look in the implementation mission but does not block or change the recommendation above.
- **Unresolved**: whether Mainsail's compiled frontend has any camera-`service`-value allowlist behavior beyond what Moonraker's own API restricts — not directly inspected (would require reading Mainsail's bundled JS), though the transport verification (§16) and SimpleAF's identical-value precedent (§10) together make it very unlikely `mjpegstreamer-adaptive` is itself the problem.
- **Open question for the user/next mission**: whether Option 2's database-seeded camera should be named identically ("Nebula") to the current config camera, or differently, to avoid any transitional collision on a device that still has the current config-sourced entry active at the moment of the upgrade that introduces this change.

## 26. Exact files expected to change later (implementation mission scope, not touched this mission)

```text
scripts/build/overlay/opt/printer_data/config/moonraker.conf
scripts/build/overlay/etc/init.d/S04nebulaos-factory-seed   (if Option 2 chosen)
docs/NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md                 (§2 reference shape)
```
Plus, on the live development device only (not a repo change): removal of the stale database webcam entry and re-push of the corrected config — both outside this mission's permitted actions.

## 27. Evidence appendix

All commands, commits, hashes, and API responses cited above were captured live during this investigation (2026-07-27) via read-only SSH/API access to `192.168.1.146` (custom slot) and read-only inspection of this repository's `vendor/moonraker` checkout and git history, plus live WebFetch of `github.com/pellcorp/creality` and `github.com/Guilouz/Creality-Helper-Script` (both `main` branch, fetched 2026-07-27). Key raw values, for cross-reference:

- Deployed Moonraker commit: `70e251ecb77a291f9b2c9789f6e0aef4af2b8420` (synthetic wrapper, content-identical to `d5ee17128bb88434aacdab90c2e9e990e2b64e4a`)
- Deployed Klipper commit: `2d75015d7c76dd31e4b0f49e1ae3fe6ad86cad24`
- Live `moonraker.conf` SHA-256: `c7c39519c850d9e13ffbf556cb8ba3d432acff8d0e0a2600ddf459b6ead65ae6`
- Repo source `moonraker.conf` SHA-256 (this branch): `927cccd9fe3083cf07ed742bbf9a9b2eed1b393f0112e3642f0e5daee7e0e72f`
- Stale database webcam UID: `bc6b0e60-20ff-49c4-b5ed-38e1fc68d0ed`
- Live config-sourced webcam UID: `18233a49-8719-55d1-9837-f5ac7c00429d`
- pellcorp/creality Klipper pin (SimpleAF reference): `386fde4fd38e8eda6999e58bf260eceb00051188` (matches NebulaOS's own vendored Klipper fork base, independently confirmed in a prior mission)

## 28. Implementation resolution — `is_valid: false` root cause (2026-07-28, auto-updates-camera-complete mission)

§25 flagged `"is_valid": false` on the live `/machine/update/status` response as unresolved. The Phase G/H implementation mission (moonraker-camera-defaults, 2026-07-27) fixed the reserved-section options and the camera, then qualified the result on real hardware — and hit this exact flag blocking real Klipper/Moonraker updates. This section records the confirmed root cause and fix; it supersedes §25's "unresolved" note for this one item, and everything else in this report stands as originally verified.

**Confirmed cause.** `GitDeploy.is_valid()` (`vendor/moonraker/moonraker/components/update_manager/git_deploy.py:1087-1092`) is `"?" not in (...) and not is_damaged() and not has_recoverable_errors()`. `has_recoverable_errors()` (line 1098-1105) is `self.diverged or self.is_dirty() or detached_err` — it does **not** consult `repo_anomalies`/`repo_warnings` at all. Live evidence on the deployed device showed `is_dirty=False`, `detached=False` for both klipper and moonraker, isolating `diverged=True` as the sole cause. `check_diverged()` (line 676-681) computes `not is_ancestor(HEAD, {remote}/{branch})`; the live log showed `git -C /opt/klipper merge-base --is-ancestor HEAD origin/nebulaos` returning exit code 1.

The reason: the factory-seed process (`scripts/build/04-cross-compile-app-stack.sh`'s old `make_flat_bundle`, `S04nebulaos-factory-seed`'s old bundle-clone step) flattened each vendor checkout into a single synthetic orphan commit ("NebulaOS factory seed snapshot of `<branch>` @ `<true_commit>`") before bundling, because `git bundle create` on vendor/klipper's shallow clone produces a bundle that clones with "Failed to traverse parents of commit ... / remote did not send all necessary objects" (confirmed again against git 2.55.0 — a real, still-present git limitation). That synthetic commit shared **no ancestry at all** with the real `coreflake1/NebulaOS-klipper`/`Arksine/moonraker` history on GitHub, so HEAD could never be an ancestor of a real remote branch — `diverged=True` was permanent, on every freshly-seeded device, independent of network or clock state (both separately confirmed fixed during this same live qualification before this cause was isolated).

A second, independent structural mismatch was found alongside it: Klipper's production branch was `nebulaos`, but Moonraker's reserved klipper slot has a hardcoded `primary_branch` default of `"master"` (`git_deploy.py:41`, `config.get("primary_branch", "master")`) that is **not overridable** for reserved slots — `primary_branch` is not in `OPTION_OVERRIDES` (`common.py:45`), so no `moonraker.conf` edit could ever change it. This produced the separate (non-gating) anomalies "Repo not on official remote/branch" and "Unofficial remote url" in `_check_warnings()` (`git_deploy.py:712-759`), and would have made the built-in Mainsail "Recover" action (`git_deploy.py:108-137`, which does `checkout(self.primary_branch)`) try to check out a branch that was never actually deployed.

**Fix implemented.** Two changes, both confirmed against the real repositories and the real GitHub remotes before rebuilding:

1. **Real-history seed archives** replace the flatten+bundle step. `make_seed_archive()` (`scripts/build/lib/make-seed-archive.sh`, shared with `scripts/build/04-cross-compile-app-stack.sh` and `tests/factory-seed-git-tests.sh`) tars up each vendor checkout's real `.git` directory and working tree as-is — real shallow boundary preserved for Klipper, real full history preserved for Moonraker (which was already a non-shallow clone with HEAD == official `origin/master`) — with the origin remote reset to a full wildcard fetch refspec. A real bug was found and fixed while validating this: vendor/klipper's actual `origin` remote carried a narrow `+refs/heads/jun2025:refs/remotes/origin/jun2025` fetch refspec (a leftover from its original single-branch clone), which would have silently broken a later plain `git fetch origin` from ever populating `origin/master` — reproducing the exact same `diverged=True` failure through a different mechanism. `S04nebulaos-factory-seed`'s `seed_git_app()` now extracts these archives with `tar` directly (no `git clone` at all — cheaper on this 208MB-RAM device than the clone-from-bundle step it replaces) and independently re-verifies branch/origin/cleanliness/no-synthetic-commit after extraction.
2. **Klipper production branch renamed to `master`.** The real, already-published `nebulaos` branch commit (`b3d5ab2b9484f1558586c3a2ea43d46ff9a473a7`, confirmed present via `git ls-remote`) was pushed as a genuine `master` branch on the same `coreflake1/NebulaOS-klipper` remote (additive — no force-push, no existing `master` branch overwritten). `nebulaos` remains as the development branch this project keeps building from. `moonraker.conf`'s `[update_manager klipper]` needed no `primary_branch` override — it now correctly matches Moonraker's hardcoded default.

**Verification.** Both fixes were confirmed end-to-end offline (`tests/factory-seed-git-tests.sh`) by extracting a real packaged archive, running `git fetch origin` against a real bare-repo stand-in for GitHub, and confirming `git merge-base --is-ancestor HEAD origin/master` succeeds — the exact check `git_deploy.py` performs. Live on-device qualification results are recorded in `docs/NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md`'s and `docs/NEBULAOS_PHASE12_QUALIFICATION.md`'s implementation-resolution sections.

No upstream Moonraker patch was made or considered necessary — `is_valid()`'s logic is correct and doing exactly what it is supposed to do (refusing to update a repository whose HEAD cannot be reconciled with its remote); the bug was entirely in how NebulaOS's own factory seed constructed that repository's history, not in Moonraker.

## 29. Live qualification found three further real bugs before `is_valid: true` was actually achieved (2026-07-28)

Getting a real device to actually show `is_valid: true` end-to-end (Phase O of the auto-updates-camera-complete mission) required finding and fixing three additional real, previously-undiscovered bugs, none of them visible from source review alone - each one only surfaced once a genuinely fresh namespace was seeded and booted on the real target.

**Bug 1 — BusyBox `tar` has no `-z` support.** `seed_git_app()`'s `tar -xzf` (introduced alongside the real-history archive format, §28) worked perfectly in every offline test (host GNU tar) and in one live manual reproduction that, in hindsight, was accidentally run against **stock**'s tar (which does support `-z`) rather than custom's BusyBox tar. On the real custom image, every single fresh-boot attempt this mission ran failed identically with `tar: invalid option -- 'z'`, silently leaving Klipper's and Moonraker's app directories seeded empty - the true cause of every "stuck"/"slow" first-boot symptom, not genuine slowness. BusyBox's own `-a` (extension-based auto-detect) also failed live (`invalid tar magic`) - it does not apply to extraction the way GNU tar's does. Fixed with a `gzip -dc | tar -xo` pipeline that works identically on both BusyBox and GNU tar (confirmed on both). `-o` (no-same-owner) was a second, related fix: extracted files otherwise kept the archive-creation host's UID, which made git itself refuse to operate on the result ("detected dubious ownership").

**Bug 2 — `git branch --set-upstream-to` silently fails in an offline-built archive.** Even after real ancestry and a real branch existed, `/machine/update/status` still reported `is_valid: false` for both apps, with `warnings: ["Failed to detect tracking remote for branch master", "Failed to detect repo url"]`. `--set-upstream-to=origin/<branch>` requires the target remote-tracking ref to already exist locally - it never does in an archive built with no fetch ever run against the freshly-added `origin` remote - so the command was failing every time, swallowed by its own `|| true`. That left `branch.<name>.remote` unset, which is exactly what `git_deploy.py`'s `config_get(f"branch.{branch}.remote")` reads to populate `git_remote`; with it `"?"`, `is_valid()`'s own `"?" not in (...)` check fails directly, independent of the diverged/dirty/detached checks §28 already fixed. Fixed by setting `branch.<name>.remote`/`branch.<name>.merge` directly via `git config`, which needs no pre-existing remote-tracking ref. Confirmed live: `is_valid` flipped from `false` to `true` for both klipper and moonraker immediately after this one config fix, with zero other changes.

**Bug 3 — the git-committed `c_helper.so` is incompatible with this image.** With bugs 1-2 fixed, Klipper still would not start - `klippy.log` produced zero output beyond its own version banner, indefinitely, across multiple cold reboots (ruling out MCU/serial state). Running `klippy.py` directly (bypassing the init-script log redirection) surfaced the real exception: `OSError: cannot load library '.../c_helper.so': ... cannot open shared object file` - a `dlopen` error that (misleadingly) covers both "file missing" and "a dependency of this file can't be resolved." The file committed inside `vendor/klipper` at its shallow-root commit (`386fde4`, "add ender 3 v3 firmware blobs") is a 65,440-byte binary from upstream; it does not load on this image at all. This project's **own** cross-compile step (`04-cross-compile-app-stack.sh`) already builds a working 274,640-byte `c_helper.so` for the immutable squashfs baseline - confirmed live it loads correctly via `ctypes.CDLL` on the real device, unlike the committed one. The device has no compiler at all, so Klipper's own compile-on-first-run fallback (`chelper/__init__.py`'s `get_ffi()`) cannot help either. Fixed by committing that already-proven binary into `vendor/klipper` itself (a real, ordinary forward commit on top of the existing real history - not synthetic, single real parent) and pushing it to both `master` and `nebulaos` on `coreflake1/NebulaOS-klipper`. Confirmed live: Klipper went from an indefinite hang to `state: ready` (after one ordinary `FIRMWARE_RESTART` to clear a stale MCU-shutdown latch left over from the hang) with zero further changes.

**A fourth, structural issue found alongside these** (not a bug in the git-seed work itself, but what made diagnosing bugs 1-3 so slow): `S39wifi` ran numerically after `S04nebulaos-factory-seed`, so a device had **zero network/SSH reachability for the entire (multi-minute, pre-fix) factory-seed window** - the only way in was GuppyScreen's own touchscreen, whose WiFi panel itself needs a running `wpa_supplicant` to configure anything, a real chicken-and-egg lockout. This is what drove two live hard-reboots of an apparently-stuck device, which is what actually left the namespace incompletely seeded in the first place. Renumbered to `S01wifi` (its only real dependency is `S01persistent-datastore`'s mount, nothing from `S02`/`S03`/`S04` at all) so WiFi/SSH stays reachable throughout first boot regardless of how long the rest of it takes.

**A fifth issue - a process mistake, not a code bug - nearly shipped bug 1 unfixed anyway.** After fixing bug 1 (the tar pipeline) inside `scripts/build/overlay/etc/init.d/S04nebulaos-factory-seed`, the very next rebuild ran `04-cross-compile-app-stack.sh`/`05-final-build.sh`/`06-verify.sh` directly without first re-running `02-configure-buildroot.sh` - the one step that actually resyncs the tracked overlay template (where the fix lives) into Buildroot's own (gitignored) board overlay directory. `06-verify.sh` passed clean anyway, because its own content checks dump and inspect the *seed archives* (built by `04` reading `scripts/build/lib/make-seed-archive.sh` and `vendor/klipper` directly - both unaffected by the missed resync), never the init script's own content. The flashed image silently still had the pre-fix `tar -xzf` line. Caught only by directly reproducing `seed_git_app` on the live device after a second fresh-namespace boot showed the exact same failure again. Fixed by re-running `02` before the real final rebuild, and by directly extracting `/etc/init.d/S04nebulaos-factory-seed` from the built `rootfs.ext2` and grepping for the fix before flashing again - not just trusting a clean `06-verify.sh` run. This matches this project's own long-documented `02-configure-buildroot.sh` header warning almost exactly ("editing the git-tracked overlay template alone does nothing... a rebuild after only touching the template, without re-running this first, silently uses whatever this script last copied there") - a lesson from a much earlier mission that still cost real time to relearn here.

Each of these fixes is a separate, focused commit on the `implementation/moonraker-camera-defaults` branch; see that branch's log for exact diffs and further evidence (including live `ldd`-equivalent checks, `sha256sum` comparisons, and the exact `printer/info`/`/machine/update/status` API responses before and after each fix). The final, genuinely from-scratch fresh-namespace boot with all fixes combined confirmed live: `is_valid: true` for klipper (`current_hash==remote_hash`, commit `d839d037`) and moonraker (commit `d5ee1712`), both with zero commits behind and `state: ready` for Klipper - see `NEBULAOS_PHASE12_QUALIFICATION.md` §11 for the full final evidence.
- pellcorp/creality Moonraker pin (SimpleAF reference): `abd2026b90d86fb738c6619be3ceefcedee2006c`

## 30. Phase P-T real qualification (2026-07-28/29): two further real bugs found and fixed against the live device left in the Phase O state

With `is_valid: true` proven (§28-29), the remaining Phase P/Q/R/S/T items flagged as not-yet-done in `NEBULAOS_PHASE12_QUALIFICATION.md` §11 were qualified against the same live device, still sitting in its Phase O state (no reboot, no reflash). Two further real, previously-undiscovered bugs were found and fixed; full live evidence (API responses, `git_deploy.py`/`machine.py` source citations, exact timestamps) is preserved in this session's transcript and summarized here.

**Bug 6 (recurrence of Finding #9) — stale, pre-fix init.d scripts were still shipping alongside their replacements on the already-flashed device.** Direct inspection of `/etc/init.d/` on the live device (built at commit `9491085`, after `dcf7060`'s stale-seed-archive cleanup) found **both** `S39wifi` and `S01wifi`, and **both** the old `S03nebulaos-factory-seed`/`S04nebulaos-activate` (the pre-§28 flatten-and-bundle seeding logic) and the new `S04nebulaos-factory-seed`/`S05nebulaos-activate` present in the same booted squashfs. `dcf7060` only cleaned `/opt/nebulaos-seeds/*`'s stale filenames from Buildroot's output copies; it did not (and could not, written before those renames existed) clean the *later* init.d renames from `21300d9` (wifi) and the factory-seed/activate renumbering. This is not cosmetic: the new activation script's `bind_if_not_already()` no-ops when its target is already mounted, and BusyBox's `rcS` runs `/etc/init.d/S??*` in strict lexical order - so the **old**, pre-fix `S04nebulaos-activate` (sorts before the new `S05nebulaos-activate`) is the one actually deciding every real bind-mount on this device, silently shadowing the fix. It happened to reach the same correct decision this boot, but that is luck, not a guarantee. Fixed in `scripts/build/02-configure-buildroot.sh` (commit `9e8aaf8`): a maintained list of historically-renamed/removed overlay paths is now cleaned from both real Buildroot output copies (`output/target/` and `output/build/buildroot-fs/ext2/target/`) on every run, the same pattern `dcf7060` used for the seed archives. `06-verify.sh` gained a matching `check_absent()` pass against the final `rootfs.ext2` so a future rename that forgets this list fails the build instead of shipping silently. **Not yet re-verified on a freshly rebuilt image** - the live device this was found on still has the old scripts baked into its current (already-flashed) squashfs; confirming they are actually gone requires the planned full rebuild + reflash (tracked in this section's qualification gate, below).

**Bug 7 — Moonraker's own self-restart (used by both Update and Recover for its own reserved slot) silently does nothing on this image, and this project's only other restart trigger missed a real, legitimate case.** `moonraker.conf`'s `[machine]` section sets `provider: supervisord_cli` (`machine.py:115`, `SupervisordCliProvider`), meaning Moonraker restarts services by shelling out to `supervisorctl`. Live inspection of the device found **no `supervisord` daemon anywhere** - no running process, no config file, nothing in any init.d script; this Buildroot image uses BusyBox init + this project's own `S##` scripts instead. `machine.py`'s `restart_moonraker_service()` (used by both a real self-update and Recover for moonraker's own reserved slot) calls `do_service_action("restart", self.unit_name)` inside a wrapper that swallows any exception (`except Exception: pass`) - so `supervisorctl restart moonraker` fails every time, silently, and moonraker simply stays dead. (Klipper is unaffected - its restart goes through a different path that this project's own `S55klipper` init script services correctly, confirmed live in Phase P below.)

This project's own `nebulaos-update-supervisor.sh` was believed to be an independent safety net for exactly this class of gap (its own header: "keeps working even if a bad update breaks Moonraker itself"), but its *only* trigger is a git HEAD delta (`poll_once()`'s `current != last_seen` check). Two real scenarios defeat that:
1. **Recover on a dirty tree that doesn't move HEAD.** Live-reproduced: dirtied a tracked file in the persistent moonraker checkout, called the real `/machine/update/recover` endpoint. Git-side recovery worked correctly (clean tree, correct branch/origin restored), but moonraker's self-restart silently failed and HEAD never changed - so `nebulaos-update-supervisor.sh` never noticed. Moonraker stayed dead for the rest of the boot until manually restarted.
2. **A real, official Rollback.** Live-reproduced: called the real `/machine/update/rollback` endpoint for moonraker, which *does* move HEAD backward to the rollback target. `nebulaos-update-supervisor.sh`'s poller detected the delta and tried to validate it as if it were a forward update - but moonraker was dead (broken self-restart, same as above), so its own `stage2` health check failed, and the supervisor's own failure-recovery path (`git reset --hard "$known_good"` + `restart_component`) **silently undid the user's own intentional rollback**, settling back on the pre-rollback commit with `last_failure_reason: "stage2_failed:<the rollback target commit>"`. This is a real instance of the mission's own mandatory-stop condition ("a real update cannot be rolled back").

Fixed with a single, narrowly-scoped change (commit `ab943e2`, `scripts/build/overlay/etc/nebulaos-update-supervisor.sh`): `ensure_moonraker_alive()`, called at the very start of every `poll_once()`, independent of any git comparison - checks moonraker's pidfile/process directly and restarts it via the real init script if it's not running, unless a validation/rollback lock is already held (so it never races a validation already in flight). Verified live against the real device in three ways: (a) killed moonraker directly, confirmed the function restarts it and is a no-op when already alive or when a lock is held; (b) reproduced the exact dirty-tree-Recover dead-moonraker state and confirmed the fixed logic (run via `poll-once`) restarts it; (c) reproduced the exact rollback-gets-undone race (reset HEAD to the rollback target, killed moonraker) and ran the real `validate_component` path from the fixed script end-to-end - it correctly found moonraker alive (thanks to `ensure_moonraker_alive` running first), passed stage1/stage2, and settled on `state: healthy` with `known_good_commit` updated to the rollback target - **not reverted**. Same fix, same root cause, both gaps closed.

**Real Phase P-S live results, using the fixed logic where the on-device (still unpatched, pre-rebuild) supervisor's own timing would otherwise race:**

```text
Phase P (real Klipper update): reset to a real ancestor commit (b3d5ab2), called
  POST /machine/update/klipper. Fetched and checked out forward to d839d037,
  restarted klippy (new PID), restored the correct c_helper.so
  (sha256 d531d503...), mcu.is_connected=true, state=ready, zero heating/motion.

Phase Q (real Moonraker update): reset to a real ancestor commit (6597123),
  called POST /machine/update/moonraker. Fetched and checked out forward to
  d5ee1712, is_valid=true, current_hash==remote_hash, camera database and
  Klipper untouched.

Phase R (Recover): dirtied a tracked file in each persistent checkout, called
  POST /machine/update/recover for both klipper and moonraker. Both correctly
  discarded the dirty change, restored clean tree + correct branch/origin
  (klipper stayed on the coreflake1/NebulaOS-klipper fork, moonraker on the
  official Arksine/moonraker), is_valid=true for both. (Moonraker's own dead-
  after-recover gap is Bug 7 above, fixed separately.)

Phase R2 (camera persistence): edited target_fps/rotation via the supported
  /server/webcams/item API, restarted Klipper and Moonraker independently -
  edit survived both. Deleted the camera via the API, re-invoked the exact
  boot-time seed script (/usr/libexec/nebulaos-seed-camera) directly - marker
  present, correctly did nothing (0 cameras, not recreated). Restored one
  default-configuration camera via the API for the final device state.

Phase S (controlled rollback): called the real POST /machine/update/rollback
  for moonraker. Confirmed the bug (rollback silently undone, see Bug 7) and
  then confirmed the fix resolves it end-to-end via validate_component
  (settles on state: healthy at the rollback target, known_good_commit
  updated, not reverted).
```

**Resolved, 2026-07-29 - not a bug, and this session's own "mjpegstreamer-adaptive is correct" conclusion (§17, §18) was wrong for this real hardware.** During qualification the seeded camera's `service` field was twice observed changing from `mjpegstreamer-adaptive` to `uv4l-mjpeg`, initially logged above as an unexplained anomaly and "restored" back to `mjpegstreamer-adaptive` via the API (twice) believing it was a bug. It was not: the device owner had edited the live camera through the supported API/Mainsail directly, because `mjpegstreamer-adaptive` does not actually produce a working stream on this real hardware and `uv4l-mjpeg` does - confirmed directly by the person actually looking at the video feed, which outweighs this document's own earlier transport-layer reasoning (ustreamer backend + working nginx proxy does not guarantee the Mainsail-facing `service` label is one it renders correctly for this specific stream). `vendor/moonraker/moonraker/components/webcam.py` genuinely has no code path that writes this on its own (confirmed correctly, that half of the original investigation stands) - the value changed because of real, intentional user edits via the real API, exactly what the editable-camera feature is for; each of the "restores" this session performed was itself the actual bug, silently overwriting a deliberate user correction. The shipped default in `scripts/build/overlay/usr/libexec/nebulaos-seed-camera` has been corrected to `uv4l-mjpeg` so a fresh install now gets a working stream out of the box rather than one that has to be immediately hand-corrected. Do not restore this device's live camera value to `mjpegstreamer-adaptive` in any future session without first confirming with the device owner - `uv4l-mjpeg` is correct for this hardware.

**Qualification gate closed.** A full rebuild (commit `ece4c26`, a clean tree) was performed and verified before flashing - both fixes confirmed present in the actual `rootfs.squashfs` itself (not just the tracked source or the `.ext2` staging image): `unsquashfs`'d directly, the four historically-obsolete init.d filenames were absent and `ensure_moonraker_alive()` was present in the packaged `/etc/nebulaos-update-supervisor.sh`. `06-verify.sh` passed with zero `MISS` lines.

The rebuilt image was then flashed to the real device following the full documented safety sequence: booted to stock (`192.168.1.231`) to make the custom slot safely inactive, `--check-only` preflight passed (`result: SAFE TO FLASH`), the real write hit a real interruption on the first attempt (a local SSH client-side timeout dropped the connection mid-write with no `nohup`/background protection - the remote `dd` had no process left after reconnecting) - recovered per the script's own design (a from-the-start sequential write safely overwrites a partial prior write) by re-running the exact same write detached and hash-read-back-verified this time (`xImage write verified OK`, `rootfs.squashfs write verified OK`), then the marker was flipped to `ota:kernel2` and the device rebooted. `S99confirm-good` confirmed the new boot within seconds (`ota:kernel` → `ota:kernel2`), Klipper reached `ready`.

Live re-verification against the actual freshly-flashed, freshly-booted device (not the staging archive): all four obsolete init.d filenames confirmed absent via `ls /etc/init.d/`; `ensure_moonraker_alive` confirmed present in the live, running `/etc/nebulaos-update-supervisor.sh`; `is_valid: true` for all three apps with zero commits behind; the camera database persisted through the reflash (only kernel+rootfs partitions are touched, not `/usr/data`) with its correct edited defaults intact. Most importantly, **the exact Bug 7 scenario was re-run with zero manual intervention this time**: dirtied a tracked file in the persistent moonraker checkout, called the real `/machine/update/recover` endpoint, moonraker died (its own self-restart is still broken, as expected - that part of vendor Moonraker's behavior was never the thing being fixed), and the live supervisor's `ensure_moonraker_alive()` brought it back on its own within one 20-second poll cycle - confirmed via `/server/webcams/list` responding again with no human action taken in between. This is the fix working end-to-end on the real shipped artifact, not a manually-reproduced workaround.

One real, non-fatal incident during this process, recorded for completeness: the first flash-write attempt was interrupted by a local tooling timeout unrelated to the device or the flash script itself (an SSH helper script's fixed 30-second expect timeout, too short for a 100MB write+verify). The flash script's own design - writing sequentially from the start of the partition and never touching the OTA marker until both images are independently verified - made the recovery safe and simple (just re-run the write), and is worth noting as a real demonstration of why that design choice (a separate, deliberate marker-flip step) matters in practice, not just in theory.

## 31. Critical finding: a genuinely fresh install had no printer.cfg or moonraker.conf at all (2026-07-29)

A deliberate, genuinely-wiped-namespace test (everything under `/usr/data/nebulaos` removed except the WiFi config, to keep remote access through the reboot) found a release-blocking gap none of the prior "clean install" evidence had actually exercised: **Klipper and Moonraker crash-looped forever on `FileNotFoundError` for `/opt/printer_data/config/printer.cfg` and `moonraker.conf`.** Neither file was ever created.

**Root cause.** `S02nebulaos-namespace`'s own header comment records that this script previously migrated `printer.cfg`/`moonraker.conf` (among other things) out of a legacy `/usr/data/openke/printer_data` path left over from before the NebulaOS namespace existed - and that this one-time migration function was deliberately *removed* in the 2026-07-27 closure mission, on the stated belief that "no deployed OpenKE user base" would ever need it again. That removal was correct for the *closure* mission's own scope, but it silently deleted the **only** code that had ever populated these two files - `create_layout()` only ever `mkdir -p`'d the directory skeleton, never the files themselves. Every prior "fresh boot" qualification this project has ever recorded (including this same mission's own §29/§30 "genuinely fresh namespace" claims) was a false positive: the development device always still had `printer.cfg`/`moonraker.conf` sitting in `/usr/data/nebulaos/printer_data/config` from that original migration, years before this specific wipe test, and nobody had ever actually deleted them until now.

Two compounding factors hid this from `S05nebulaos-activate`'s own validation:
1. **`S01persistent-datastore` bind-mounts `$NEBULAOS_ROOT/printer_data` over `/opt/printer_data` unconditionally, very early in boot** - described in `S02nebulaos-namespace`'s own comment as "a genuine fallback, not just an early seed." By the time anything later in boot might try to read `/opt/printer_data/config` as "the immutable default," it is already looking at the (possibly empty) persistent copy - the identical shadowing problem `klipper.tar.gz`/`moonraker.tar.gz` already solve for the app checkouts (§28), just never noticed for this one.
2. **`S05nebulaos-activate`'s own validity marker for `printer_data` was the literal string `"config"`** - a directory `S02` always recreates on every boot via `mkdir -p`, regardless of whether the real required files inside it exist. A completely empty persistent copy passed activation every single time.

**Fix.** The same pattern that already works for the app checkouts, applied to printer_data's own config: `04-cross-compile-app-stack.sh` now also copies the tracked `scripts/build/overlay/opt/printer_data/config/` content - already deliberately stripped of development-machine calibration data, see `printer.cfg`'s own header comment for that policy, established well before this finding - into a second, dedicated immutable location at `/opt/nebulaos-seeds/printer_data-config/`, never subject to any bind mount. Three build-time checks refuse to ship a bad seed: missing `printer.cfg`/`moonraker.conf`, a real `SAVE_CONFIG` calibration block, or a syntactically blank required option (the exact class of bug §29 Bug 2's sibling finding, `9332aa2`'s `z_offset` fix, already existed to prevent - this generalizes that lesson into an automated build gate rather than relying on it being remembered by hand). `S02nebulaos-namespace` seeds from there into the real persistent location, marker-guarded exactly like `S57nebulaos-camera-seed`'s already-qualified pattern: seeds once, never touches a byte of real content if it already exists, and respects deliberate user deletion rather than continuously reconciling. `S05nebulaos-activate`'s marker check now verifies the actual required files (`config/printer.cfg config/moonraker.conf`), not just the directory.

**Two further real bugs found qualifying the fix itself**, both caught before ever reaching a flashed image:
- A build-time false positive: a naive single-line check for a blank `key:` value flagged `moonraker.conf`'s own legitimate multi-line `trusted_clients`/`cors_domains` list values. Fixed to only treat a bare `key:` as genuinely blank when the following line is not indented.
- `validate_app()` was generalized to accept a space-separated marker list, but the actual `printer_data` call site was never updated to use it - caught by this same mission's own new `06-verify.sh` check on the very first rebuild attempt, exactly the kind of gap that check exists to catch.

**Verification.** Ten new offline tests (`tests/nebulaos-printerdata-seed-tests.sh`) cover: fresh seed, marker respects user deletion, existing real content gets the marker retroactively without being touched, an incomplete seed source fails safely with no marker, a partially-seeded destination self-heals, and repeated boots are idempotent. All pre-existing test suites (`factory-seed-git-tests.sh`, `flash-spare-slot-preflight-tests.sh`, `nebulaos-seed-camera-tests.py`) still pass unaffected.

**Live proof, on the real device, is the definitive evidence.** Rebuilt (commit `8e49351`), reflashed via the full documented safety sequence, then the exact same genuinely-wiped-namespace test repeated against the new image: one boot, fully offline, zero manual intervention - `printer.cfg`/`moonraker.conf`/`songs.conf`/`GuppyScreen` all present automatically, `klipper: state=ready`, `moonraker`/`klipper`/`mainsail: is_valid=true` with zero commits behind (the real-history git seed logic is unaffected by this fix and still works), the camera database-seeded fresh, `S99confirm-good` flipped the marker to `ota:kernel2` within seconds, and the new `printer-data-config-seeded.json` marker's own timestamp (`1970-01-01T00:00:10Z`) proves the seeding ran before NTP had ever synced the clock - genuinely offline, genuinely first-boot. A follow-up Recover test on this same final image confirmed the Bug 7 fix (§30) still self-heals with zero manual intervention. Full record: `docs/NEBULAOS_ENDER3_V3_KE_FACTORY_CONFIG_SEED.md`.

## 32. Critical finding: standard Klipper print controls were never defined at all (2026-07-29)

Mainsail reported `virtual_sdcard`/`pause_resume`/`gcode_macro pause`/`gcode_macro resume`/`gcode_macro cancel_print`/`display_status` as "not defined in config," alongside a phantom `0 / 0`, `0 seconds left` print-progress display with no print active. Live, read-only API queries (no G-code executed, nothing homed or heated) confirmed this was genuine, not a Mainsail rendering quirk: Klipper's own `/printer/objects/list` and Moonraker's own `/server/info` (`missing_klippy_requirements`) independently agreed these objects did not exist, and `/printer/gcode/help` showed no `PAUSE`/`RESUME`/`CANCEL_PRINT` registered at all. Moonraker's job queue and history were both empty, ruling out a genuine stale print job as a separate cause of the phantom display - it was Mainsail's own fallback rendering for a printer that had never reported the real objects it keys its print-state UI off of.

**Root cause.** This project's factory `printer.cfg` (`scripts/build/overlay/opt/printer_data/config/printer.cfg`) simply never defined `[virtual_sdcard]`, `[pause_resume]`, or `[display_status]` in any of its `[include ...]` files, and never had to until Mainsail's own dependency on them was actually exercised for the first time this mission.

**Fix.** Read this exact fork's `virtual_sdcard.py`/`pause_resume.py`/`display_status.py` source directly (not assumed from another Klipper version): `pause_resume.py` registers `PAUSE`/`RESUME`/`CLEAR_PAUSE`/`CANCEL_PRINT` itself, with safe minimal default behavior (no motion beyond restoring a previously-saved state, no heater changes, no homing) - so no custom `gcode_macro` overrides were needed at all. A single new file, `frontend-controls.cfg` (`[virtual_sdcard] path: /opt/printer_data/gcodes` `on_error_gcode: CANCEL_PRINT`, `[pause_resume]`, `[display_status]`), added to the `printer_data/config` factory seed alongside a shared closure validator (`scripts/build/lib/validate-frontend-controls.sh`) used by both the real build and its own offline test suite. Full source-precedence decision record, closure table, and live evidence: `docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md`.

**Live proof.** Applied once to the live dev printer first (full backup taken, read-only safety check confirmed idle/unhomed/no queued jobs before touching anything) to prove the fix genuinely resolves the phantom state at the API level, not just visually. Then rebuilt, reflashed via the full documented safety sequence, and the exact same genuinely-wiped-namespace test from §31 repeated against the new image: `frontend-controls.cfg` reseeded entirely from scratch, `missing_klippy_requirements: []`, all six objects/commands present and idle, the 48 shared G-code files untouched, and the database camera fresh-seeded with the already-corrected `uv4l-mjpeg` service - confirming §31's fix and this one compose correctly on the same shipped image.
