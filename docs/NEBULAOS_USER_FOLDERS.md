# User folders (G62 2026-10-16, revised G63/G65 the same day)

One folder for users, the same over SFTP and in Mainsail: `/opt/printer_data`
(the persistent `/usr/data/nebulaos/printer_data`, bind-mounted). SFTP opens
there (`/usr/libexec/sftp-server` wrapper; root's home stays `/root`).

Mainsail's upload button only ever uploads into the `config` root (verified in
the Mainsail 2.18 bundle), so everything a user hands to NebulaOS lives under
`config/`. NebulaOS registers no Moonraker root of its own (G62's `uploads`
root is retired: it could not receive uploads, and a root under `config`
would overlap it).

| Folder | Mainsail root | Who reads it |
|---|---|---|
| `config/printer.cfg`, `moonraker.conf`, `songs.conf` | config | Klipper, Moonraker; calibration is in printer.cfg's SAVE_CONFIG block |
| `config/macros/` | config | Klipper (`[include macros/*.cfg]`) |
| `config/backups/` | config | users - SAVE_CONFIG copies (newest 10), `settings-*` snapshots (newest 5), `nebulaos-changes-*` |
| `config/uploads/boot-logo/` | config | boot logo page (`bootdisplay.py`) |
| `config/uploads/mainboard-firmware/` | config | MCU page (`mcu.py`, `nebulaos-mcu`) |
| `config/uploads/system-image/` | config | System image page (`image.py`) |
| `config/guppyscreen/guppyconfig.json` | config | the screen (bind of the real file, also into the `/opt` view) |
| `config/nebulaos/` | config | Klipper; NebulaOS's materialized settings, replaced per generation, `README.txt` says do not edit |
| `gcodes/` (USB stick in `gcodes/USB/`) | G-code files | Klipper, the screen |
| `logs/` (+ `nebulaos-state.txt`) | logs | users; "Save logs to USB" and Mainsail's zip download |

Moonraker's own folders (`comms`, `database`, `backup`, `certs`, `misc`,
`systemd`) stay where Moonraker puts them. `README.txt` in the folder is
rewritten at every boot.

## Settings snapshots (G65)

`config/backups/settings-<UTC>-<reason>/` holds the user's settings files and
`SNAPSHOT.txt`. Taken by `nebulaos-osconfig settings snapshot`:

- at the first boot of every new or rolled-back system (`S04`, first step,
  keyed on the seed manifest) with a direct copy of Moonraker's database
  (Moonraker is not running yet) into `system/settings-db/<name>/`;
- from the housekeeping loop when the settings changed since the newest
  snapshot, with Moonraker's own `POST /server/database/backup` (writes
  `printer_data/backup/database/<name>.db`; refused while printing - recorded).

Moonraker updates components without a pre-update hook, so the newest
snapshot is what predates the next update. The database holds login data and
API keys and therefore never goes under `config`. Newest 5 kept.

Before `config/nebulaos` is replaced, files that differ from the sha256
recorded at the previous materialization are copied to
`config/backups/nebulaos-changes-<UTC>/` with `WHAT-HAPPENED.txt`, and a
notice for the screen is left in `system/notices/`.

## Migration and the other slot

`S04nebulaos-migrate` (`migrate_user_uploads`, every boot, idempotent) moves
files from the old places - G62's `printer_data/uploads/*`, a stray
`config/boot-logo/` (Mainsail uploads while that root existed),
`config/firmware/mcu`, `config/firmware/os`, `/usr/data/nebulaos/boot/uploads`
- never overwriting ("name (2).ext"), and removes the old folders when empty.
An older NebulaOS in the other slot re-creates its old, empty folders and
boots normally; its screens do not see files in `config/uploads`.

`retire_config_leftovers` moves `static_ip.json` and
`static_ip_dhcp_snapshot.json` to `system/migration-backups/retired-config/`
and removes `config/GuppyScreen/scripts/static_ip.py` only when it is a
version NebulaOS shipped (sha256 list); the empty folders go with it.
