# NebulaOS-firmware documentation

The 100+ files here are of three kinds: documentation of how things work now, reference material
that may lag the code, and reports from earlier work kept as evidence. **When a document and the
code disagree, the code wins** (and `manifests/dependencies.conf` for what ships).

For users, the guides are in the
[NebulaOS wiki](https://github.com/NebulaOS-KE/NebulaOS-nebulascreen/wiki) (installing, updating,
calibration, recovery, every screen setting).

## Start here (checked against the code in October 2026)

| Topic | Document |
|---|---|
| Installing NebulaOS from stock or OpenKE (Creality's updater) | [INSTALL_FROM_STOCK.md](INSTALL_FROM_STOCK.md) |
| The two system slots and the boot marker | [A_B_SLOT_MODEL.md](A_B_SLOT_MODEL.md) |
| Switching slots, USB recovery | [DEVELOPER_RECOVERY.md](DEVELOPER_RECOVERY.md), [HOW_TO_SWITCH_STOCK_AND_CUSTOM.md](HOW_TO_SWITCH_STOCK_AND_CUSTOM.md) |
| Building from source | [BUILD_FROM_SOURCE.md](BUILD_FROM_SOURCE.md), [NEBULAOS_BUILD_ENVIRONMENT.md](NEBULAOS_BUILD_ENVIRONMENT.md) |
| What a release contains (`.img`, `.ingenic`) | [RELEASE_ARTIFACTS.md](RELEASE_ARTIFACTS.md), [NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md](NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md) |
| How a release is built (GitHub) | `scripts/release/` here and the NebulaOS repository's [release workflow](https://github.com/NebulaOS-KE/NebulaOS/blob/main/.github/workflows/release.yml) |
| Proving what produced a build | [BUILD_PROVENANCE.md](BUILD_PROVENANCE.md), [REPRODUCIBILITY.md](REPRODUCIBILITY.md) |
| Working on a real printer (Hardware Agent) | [HARDWARE_AGENT.md](HARDWARE_AGENT.md) |
| Upstream Klipper without a fork | [NEBULAOS_KLIPPER_COMPOSITION.md](NEBULAOS_KLIPPER_COMPOSITION.md), [NEBULAOS_PRISTINE_KLIPPER.md](NEBULAOS_PRISTINE_KLIPPER.md) |
| Who updates what (image, apps, screen) | [NEBULAOS_UPDATE_OWNERSHIP.md](NEBULAOS_UPDATE_OWNERSHIP.md), [NEBULAOS_UPDATER_AUDIT.md](NEBULAOS_UPDATER_AUDIT.md) |
| Persistent data and its lifecycle | [NEBULAOS_PERSISTENT_LIFECYCLE.md](NEBULAOS_PERSISTENT_LIFECYCLE.md), [NEBULAOS_PERSISTENT_NAMESPACE.md](NEBULAOS_PERSISTENT_NAMESPACE.md) |
| Platform vs apps, public APIs | [NEBULAOS_PLATFORM_APP_BOUNDARY.md](NEBULAOS_PLATFORM_APP_BOUNDARY.md), [NEBULAOS_CORE_PUBLIC_API.md](NEBULAOS_CORE_PUBLIC_API.md) |
| Changing the root password | [CHANGING_THE_ROOT_PASSWORD.md](CHANGING_THE_ROOT_PASSWORD.md) |

## Reference (true when written; the code may have moved on)

- Updates and rollback: [NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md](NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md),
  [NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md](NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md),
  [NEBULAOS_EXTENSIONS_BRANCH_STRATEGY.md](NEBULAOS_EXTENSIONS_BRANCH_STRATEGY.md)
- Configuration: [NEBULAOS_CONFIG_MATERIALIZATION.md](NEBULAOS_CONFIG_MATERIALIZATION.md),
  [NEBULAOS_CALIBRATION_CONFIG_OWNERSHIP.md](NEBULAOS_CALIBRATION_CONFIG_OWNERSHIP.md),
  [NEBULAOS_CALIBRATION_PUBLIC_API.md](NEBULAOS_CALIBRATION_PUBLIC_API.md),
  [NEBULAOS_RUNTIME_MACRO_PROVENANCE.md](NEBULAOS_RUNTIME_MACRO_PROVENANCE.md),
  [NEBULAOS_USER_FOLDERS.md](NEBULAOS_USER_FOLDERS.md),
  [VIRGIN_FIRST_BOOT_CONTRACT.md](VIRGIN_FIRST_BOOT_CONTRACT.md)
- System behaviour: [NEBULAOS_MEMORY_RESILIENCE.md](NEBULAOS_MEMORY_RESILIENCE.md),
  [NEBULAOS_RETENTION_POLICY.md](NEBULAOS_RETENTION_POLICY.md),
  [KERNEL_USERSPACE_HANDOFF.md](KERNEL_USERSPACE_HANDOFF.md)
- Hardware: [BOARD_CAPABILITY_MATRIX.md](BOARD_CAPABILITY_MATRIX.md),
  [PIN_OWNERSHIP_MAP.md](PIN_OWNERSHIP_MAP.md), [BEEPER_CONTROL_PATH.md](BEEPER_CONTROL_PATH.md),
  [NEBULAOS_MAINSAIL_SENSOR_INVENTORY.md](NEBULAOS_MAINSAIL_SENSOR_INVENTORY.md)
- MCU: [MCU_LIFECYCLE_GUARD.md](MCU_LIFECYCLE_GUARD.md), [mcu-flash-layout.md](mcu-flash-layout.md)
- Load cell and Z: [NEBULAOS_RAW_CONTACT_BRIEF.md](NEBULAOS_RAW_CONTACT_BRIEF.md),
  [z_compensate_status_api.md](z_compensate_status_api.md),
  [NEBULAOS_SIMPLEAF_BACKEND_INTEGRATION.md](NEBULAOS_SIMPLEAF_BACKEND_INTEGRATION.md)
- Planned work: [DEFERRED_POST_RELEASE_WORK.md](DEFERRED_POST_RELEASE_WORK.md)

## Superseded

| Document | Replaced by |
|---|---|
| [NEBULAOS_OTA_FLOW.md](NEBULAOS_OTA_FLOW.md) (2026-08, `scripts/release.sh`) | The GitHub release workflow; [RELEASE_ARTIFACTS.md](RELEASE_ARTIFACTS.md) |
| [DEVELOPER_UPDATE.md](DEVELOPER_UPDATE.md) (2026-08) | The wiki's [Updating NebulaOS](https://github.com/NebulaOS-KE/NebulaOS-nebulascreen/wiki/Updating-NebulaOS) |
| [DEVELOPER_INSTALL_FROM_STOCK.md](DEVELOPER_INSTALL_FROM_STOCK.md) (2026-08, raw partition writes) | [INSTALL_FROM_STOCK.md](INSTALL_FROM_STOCK.md); developers use the Hardware Agent |

## History (reports and investigations; evidence, not instructions)

Mission reports, qualification runs and investigations from July to October 2026, kept so that a
decision can be traced back. Project story: [HISTORY.md](HISTORY.md). Among them: the Buildroot
2025 migration (`BUILDROOT_2025_*`), display and touch bring-up (`NEBULAOS_DISPLAY_*`,
`NEBULAOS_TOUCH_*`, `NEBULAOS_BACKLIGHT_*`, `GUI_WORKSTREAM_HANDOFF.md`), Wi-Fi/camera/real-time
qualification (`NEBULAOS_WIFI_*`, `NEBULAOS_COMBINED_*`, `NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md`,
`USB_WEBCAM_MISSION_STATUS.md`), the retired PRTouch (`NEBULAOS_PRTOUCH_*`, `prtouch_diagnostics.md`),
early load-cell work (`NEBULAOS_LOADCELL_*`), baselines and qualifications (`NEBULAOS_ALPHA_*`,
`KNOWN_GOOD_PRODUCTION_BASELINE.md`, `NEBULAOS_PHASE*`, `NEBULAOS_QUALIF*`,
`NEBULAOS_CANONICAL_DEPLOYMENT_QUALIFICATION.md`, `NEBULAOS_VIRGIN_FLASH_*`), and the
reconciliations (`*-reconciliation.md`, `*-investigation.txt`).
