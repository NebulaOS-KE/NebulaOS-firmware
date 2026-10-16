NebulaOS - your printer's files
================================

The four folders that are yours:

  config/    The printer's settings: printer.cfg, moonraker.conf, macros.
             Klipper reads these. Old automatic backups of printer.cfg
             are in config/backups/.
  gcodes/    The files you print. A USB stick shows up in gcodes/USB/.
  logs/      What the printer writes down. nebulaos-state.txt summarises
             versions and state. To report a problem: Settings > System >
             Logs > Save logs to USB on the screen, or download this folder
             as a zip in Mainsail.
  uploads/   Files you hand to NebulaOS:
               boot-logo/            images for the boot logo (PNG, BMP, JPEG)
               mainboard-firmware/   .bin files for the mainboard (MCU)
               system-image/         .img files with a whole system

Everything else here (comms, database, backup, certs, misc, systemd, ...)
belongs to Klipper and Moonraker. Please leave it alone.

This file is rewritten at every start.
