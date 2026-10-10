# Changing the root password

Every NebulaOS printer ships with the same default root password, the one in
[HOW_TO_SWITCH_STOCK_AND_CUSTOM.md](HOW_TO_SWITCH_STOCK_AND_CUSTOM.md). Anyone on
your network who knows it can log in over SSH, so change it if the printer is on
a network you do not fully trust.

The password can only be changed over SSH (decision D7, 2026-10-10).

1. Connect: `ssh root@<printer-ip>` (or `ssh root@nebulaos.local`).
2. Run `passwd` and type the new password twice. Nothing is shown while you type.
3. Done: `root password changed (kept across reboots and updates)`.

`passwd` runs `nebulaos-passwd`, which you can also call directly.

## How it works

The image's `/etc/shadow` is read-only. At boot NebulaOS copies it once to
`/usr/data/nebulaos/system/shadow` (mode 600) and mounts that copy over
`/etc/shadow`. Changing the password rewrites only root's line in the copy and
keeps the previous version as `shadow.prev` next to it. The change survives
reboots and NebulaOS updates.

## Forgot it?

If you can still log in another way, run `passwd` again. Otherwise, switching to
stock and back does not reset it, because the copy lives on the data partition.
To restore the default password, delete `/usr/data/nebulaos/system/shadow` from
any shell that can reach the data partition (for example stock's SSH) and
reboot NebulaOS: it seeds a fresh copy with the default password.
