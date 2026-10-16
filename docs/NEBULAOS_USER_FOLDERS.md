# User folders (G62, 2026-10-16)

One folder for users, the same over SFTP and in Mainsail: `/opt/printer_data`
(the persistent `/usr/data/nebulaos/printer_data`, bind-mounted). SFTP opens
there (`/usr/libexec/sftp-server` wrapper; root's home stays `/root`).

| Folder | Mainsail root | Who reads it |
|---|---|---|
| `config/` | config | Klipper (`printer.cfg` and its includes), Moonraker (`moonraker.conf`), the screen (`guppyscreen/`) |
| `config/backups/` | config | nobody - Klipper's SAVE_CONFIG copies, moved here by the retention job, newest 10 kept |
| `gcodes/` (USB stick in `gcodes/USB/`) | G-code files | Klipper, the screen |
| `logs/` (+ `nebulaos-state.txt`) | logs | users; "Save logs to USB" and Mainsail's zip download |
| `uploads/boot-logo/` | uploads | boot logo page (`bootdisplay.py`) |
| `uploads/mainboard-firmware/` | uploads | MCU page (`mcu.py`, `nebulaos-mcu`) |
| `uploads/system-image/` | uploads | System image page (`image.py`) |

Moonraker's own folders (`comms`, `database`, `backup`, `certs`, `misc`,
`systemd`) stay where Moonraker puts them. `README.txt` in the folder is
rewritten at every boot.

## Migration and the other slot

`S04nebulaos-migrate` (`migrate_user_uploads`, every boot, idempotent) moves
files from the old places - `config/firmware/mcu`, `config/firmware/os`,
`/usr/data/nebulaos/boot/uploads` - never overwriting ("name (2).ext"), and
removes the old folders when empty. No symlinks: Moonraker roots must not
overlap (architecture review 2026-10-16). An older NebulaOS in the other slot
re-creates its old, empty folders and boots normally.

`config/GuppyScreen/` is no longer created; it is removed only when empty
(older `printer.cfg` files may still include from it).
