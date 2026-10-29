# Installing NebulaOS from stock firmware or OpenKE

NebulaOS installs with Creality's own updater, the one already on every Ender-3 V3 KE. It writes
NebulaOS into the printer's second system slot and starts it; your current system stays in the
first slot.

Tested on ke-dev on 2026-10-29: OpenKE (stock 1.1.0.15 base) to NebulaOS 0.9.0 over SSH.

## What you need

- The release file `NebulaOS-Ender3V3KE-<version>.img` from
  [Releases](https://github.com/NebulaOS-KE/NebulaOS/releases). **Keep its name.** The updater
  finds the files inside by the file name; a renamed file stops with
  `failed to get .../ota_config.in`.
- Check the download: `sha256sum -c NebulaOS-Ender3V3KE-<version>.img.sha256`.

## Coming from OpenKE (no touchscreen GUI): over SSH

1. Copy the file to the printer (password: your printer's root password):

   ```
   scp NebulaOS-Ender3V3KE-<version>.img root@<printer-ip>:/usr/data/
   ```

2. Run Creality's updater on it:

   ```
   ssh root@<printer-ip> /etc/ota_bin/local_ota_update.sh /usr/data/NebulaOS-Ender3V3KE-<version>.img
   ```

   It unpacks the file, checks every part, then writes the kernel, the root filesystem and the
   boot logo, with percentages. It ends with `ota update ok`. The line
   `sh: 1.1.0.15: bad number` is normal (the updater's version check; it does not stop anything).

3. Restart the printer with a **soft reboot**:

   ```
   ssh root@<printer-ip> reboot
   ```

   The updater does not restart by itself. Do not switch the printer off and on instead: a stock
   system that starts from power-on can flash old firmware into the mainboard.

4. NebulaOS starts (the first start takes about a minute). Then delete the copy (133 MB):
   `ssh root@<printer-ip> rm /usr/data/NebulaOS-Ender3V3KE-<version>.img`

## Coming from the stock Creality firmware: with its touchscreen

Copy `NebulaOS-Ender3V3KE-<version>.img` (name unchanged) to the root of a FAT32 USB stick, put
it into the printer and start the update from Creality's screen. Creality's screen runs the same
updater as above and restarts the printer when it is done.

Not tested on hardware yet (ke-dev runs OpenKE in its stock slot).

## If it stops

Every check runs before anything is written: if the updater prints `ota: error` before
`ota: started`, nothing changed and the printer keeps running the old system. Send the output.

## Going back

The old system stays in slot 1. NebulaOS: Settings > Reset > Swap boot slot.
