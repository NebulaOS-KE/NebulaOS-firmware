# How to switch between stock and custom firmware

Your printer's little computer (the Nebula Pad) can hold **two complete operating systems at the
same time**, on two separate storage slots:

- **Stock** — the original Creality software that came with the printer.
- **Custom** — this project's own firmware (real Klipper, Moonraker, Mainsail, GuppyScreen).

Only one runs at a time. A tiny file tells the printer which one to boot next time it powers on.
Nothing you do here ever deletes or overwrites the other one — they're on completely separate
storage, so you can always go back.

There are two ways to do the switch: an **easy way** you'll use almost every time, and a **hard
way** that only matters if the easy way is unavailable (e.g. the printer won't connect to Wi-Fi).

---

## From the touchscreen (NebulaOS to the other slot)

On NebulaOS: **Settings → Reset → Swap boot slot (A/B)**. After you confirm, NebulaOS sets
the boot marker to the other slot and restarts at once. It refuses while a print is running.

This only goes one way. To come back, use **Method 1** from the other system (Creality's own
switcher, step 3), or **Method 2** if you can't reach it over the network.

**Do not switch the printer off and on while the other slot is running.** A real power cycle
lets Creality's firmware re-flash the printer board with its own MCU firmware (see the warning
in Method 1). A plain `reboot` is safe.

---

## Method 1: The easy way (SSH) — use this one

You need: a computer, and the printer connected to your Wi-Fi network (either OS can be running
right now — it works the same either way).

**What it does, in plain terms:** you connect to the printer over the network, run one command
that flips a switch, then reboot the printer. Two minutes, no tools, no opening the case.

### Step by step

1. **Find the printer's IP address.** It's shown on the printer's own screen under Wi-Fi settings,
   or check your router's device list. (In this project's own testing sessions, stock and custom
   showed up as *different* IP addresses on the same network — that's normal. If SSH suddenly
   won't connect after a switch, that's usually just this: try the *other* address, or check your
   router's device list again.)

2. **Connect over SSH** (Terminal on Mac/Linux, or PowerShell/PuTTY on Windows):
   ```
   ssh root@<the-ip-address>
   ```
   Password: `openke` on **custom**. Stock's root password is different (this project doesn't
   control or change it) - a real "Permission denied" was hit live confirming `openke` does not
   work on stock; check with whoever set up the printer if you don't already have it.

3. **Tell it which one to boot next.** Run exactly one of these two commands:

   To boot **stock** next:
   ```
   sh -c '. /etc/ota_marker.sh; write_ota_marker "ota:kernel"'
   ```

   To boot **custom** next:
   ```
   sh -c '. /etc/ota_marker.sh; write_ota_marker "ota:kernel2"'
   ```

   (`/etc/ota_marker.sh` only exists on the **custom** side. If you're currently on **stock** and
   want to switch to custom, use stock's own equivalent, built-in tool instead — this is Creality's
   own pre-existing switcher, not something NebulaOS added, and it does the same job:
   ```
   sh -c '. /etc/ota_bin/ota_local_method.sh; local_set_next_boot_device'
   ```
   Note this one **toggles** between stock and custom rather than taking an explicit target — it
   flips to whichever one you're not currently on. If you're on stock, that's exactly what you want
   here. Verified working this way live, including for the very first stock→custom switch on a
   freshly-flashed device.)

4. **Reboot:**
   ```
   reboot
   ```

5. **Wait about a minute.** The printer will restart and boot into whichever one you picked. Watch
   its screen or try reconnecting to confirm.

That's the whole thing. If you ever want to switch back, repeat the same steps with the other
command.

**Switching to stock while native MCU firmware is installed:** a plain `reboot` does **not** reset
the separate GD32F303 motor/heater-controller chip - only a real, physical power cycle (unplug and
replug, or the power switch) does. Stock's own automatic MCU flasher (`S13mcu_update`) can only
catch that chip during a genuine cold power-on; against a chip that's still running NebulaOS's
native application (as it will be right after a plain `reboot`), its handshake simply fails
(`"identify fail"` in `/tmp/mcu_update.log`) and it does nothing - confirmed live on hardware twice
(2026-08-28 and 2026-08-31). So a plain `reboot` into stock is safe with respect to the MCU. A
**hard power cycle** right after switching to stock is a different story - see the warning just
below.

### What happens if custom firmware fails to start?

**Important change (Phase 1.8B):** custom firmware no longer automatically falls back to stock on
failure. The automatic stock fallback was removed because a genuine power cycle while booted into
stock Creality firmware lets it auto-flash the printer's MCU (motor/heater controller) with old
firmware, which destroys the qualified MCU build and can leave the printer in a worse state than
the original problem. (A plain `reboot` into stock does not trigger this - see the note above - but
the automatic fallback path could not guarantee a power cycle wouldn't happen in between, so it was
removed rather than relying on that.)

If a custom boot fails (Klipper doesn't start, screen is unresponsive, etc.), the printer stays on
custom firmware. You'll need to recover manually — usually by SSHing in and either fixing the
problem or switching to stock deliberately using Method 1 above. If SSH is also unavailable, use
Method 2 (USB recovery).

The manual recovery commands from Method 1 still work exactly the same way. The only change is that
the printer no longer does the stock switch *for you* automatically.

---

## Method 2: The hard way (USB recovery mode) — only if Method 1 doesn't work

Use this only if the printer won't connect to Wi-Fi/SSH at all (for example, if a custom firmware
attempt fails to boot far enough to even bring up the network). This is a real, tested fallback,
but it's more involved: it needs a computer, a USB cable, and physically touching two small
buttons on the board.

**Heads up:** this method is really a "**panic button back to stock**," not a general switch —
the tool used here is built to force the printer back to stock specifically, not to send it to
custom. If you're in a spot where you need this, you're recovering, not casually switching.

### What you need
- A USB cable connected from your computer to the Nebula Pad's MicroUSB port.
- The [`ballaswag/ingenic-usbboot`](https://github.com/ballaswag/ingenic-usbboot) tool — credit to
  that project, this whole recovery path only works because it exists. Built from source on your
  computer:
  ```
  git clone https://github.com/ballaswag/ingenic-usbboot
  cd ingenic-usbboot
  make
  ```
  **The compiled binary is named `usbboot`, not `ingenic-usbboot`** (that's just the repo/folder
  name) - real mistake made live doing this recovery: `./ingenic-usbboot --force-swap-ota` fails
  with "No such file or directory". Run `./usbboot ...` from inside that directory instead.

### Step by step
1. Power off the printer.
2. Find the two small buttons on the Nebula Pad's circuit board, right next to the MicroUSB port
   (you may need to open the case).
3. **Hold both buttons down together for 3 seconds.** Then **release the reset button first**,
   and let go of the boot button right after. This puts the board into a special USB recovery mode
   instead of a normal boot — nothing runs yet, it's just waiting for instructions from your
   computer.
4. On your computer, confirm it's detected (optional, but reassuring):
   ```
   lsusb
   ```
   You're looking for `ID a108:eaef Ingenic Semiconductor Co.,Ltd Ingenic USB BOOT DEVICE`.
5. **Load u-boot first, then swap the marker** - a real sequencing mistake made live: running the
   swap command before `--uboot` fails with `Could not open USB device` or `Request 0x14 failed,
   only transfered: -9`. At the raw mask-ROM stage (before u-boot is loaded), the device does not
   support the marker-swap vendor request at all - only after u-boot is running does it work.
   Needs `sudo` (plain USB access without it fails with a permissions error):
   ```
   sudo ./usbboot --uboot
   sudo ./usbboot --swap-ota
   ```
   There is no `--force-swap-ota` flag in the upstream tool (that name appeared in an earlier draft
   of this doc, tested live, and does not exist) - `--swap-ota` **toggles** between `kernel` and
   `kernel2`, it does not force a specific target. It also prints "Current OTA points at ..."
   *before* switching and "Switched OTA to ..." after - read that output to know which state
   you're leaving and which you're landing on.
6. **Don't trust the printed status alone - verify the real bytes.** Real, confusing behavior
   found live: two consecutive `--uboot` + `--swap-ota` invocations both printed "Current OTA
   points at kernel. Switching OTA to kernel2" - i.e. neither call's printed message reflected the
   other's actual effect, which strongly suggests the raw mask-ROM/USB-boot session doesn't
   reliably preserve state between separate tool invocations the way the printed text implies.
   Confirm the *actual* on-flash marker directly instead of trusting the printed message:
   ```
   sudo ./usbboot --uboot
   sudo ./usbboot -o 0x100000 -s 0x1000 --dump-partition ./ota.out
   xxd ./ota.out | head -3
   ```
   You want to see `ota:kernel` (stock) in the output. If you see `ota:kernel2` instead, run
   `--swap-ota` again and re-dump until the real bytes confirm `ota:kernel`.
7. Power the printer off and on again normally (or press reset) to leave recovery mode and do a
   real boot. It will come up on stock.

---

## Method 3: The "start completely over" option — last resort only

Creality also publishes official, ready-made recovery images and a USB flashing tool that
reinstalls *everything* (bootloader, kernel, rootfs — the whole board) back to a totally fresh,
factory-original state. This is not really "switching" — it's a full factory reset, and it uses
the same USB recovery mode described in Method 2. Only reach for this if both other methods have
failed and you want to guarantee a clean stock printer to start from again. It's not something to
do casually, and it's outside the scope of this guide — if you ever need it, treat it as its own
careful, deliberate step, not a quick fix.

---

## Quick summary

| Situation | Use |
|---|---|
| Normal, everything's working, just want to switch | **Method 1** (SSH) |
| Printer won't connect to Wi-Fi/network at all | **Method 2** (USB recovery, back to stock) |
| Something's badly broken and you want a clean slate | **Method 3** (full factory restore — ask for help first) |

You can always tell which one is currently running by checking `/proc/cmdline` over SSH: stock
shows `root=/dev/mmcblk0p7`, custom shows `root=/dev/mmcblk0p8`.
