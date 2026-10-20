NebulaOS - your printer's files
================================

The three folders that are yours (the same ones Mainsail shows):

  config/    The printer's settings. Klipper reads these.
               printer.cfg, moonraker.conf, songs.conf   your settings
                                     (calibration results are saved at the
                                     bottom of printer.cfg)
               macros/               your own macros (loaded automatically)
               backups/              automatic copies of your settings
               uploads/              files you hand to NebulaOS:
                 boot-logo/            images for the boot logo (PNG, BMP, JPEG)
                 mainboard-firmware/   .bin files for the mainboard (MCU)
                 system-image/         .img files with a whole system
               nebulascreen/         the screen's settings
               nebulaos/             NebulaOS's own Klipper settings - do not
                                     edit, they are replaced at every update;
                                     override them in printer.cfg or macros/
  gcodes/    The files you print. A USB stick shows up in gcodes/USB/.
  logs/      What the printer writes down. nebulaos-state.txt summarises
             versions and state. To report a problem: Settings > System >
             Report a problem on the screen.

Everything else here (comms, database, backup, certs, misc, ...) belongs to
Klipper and Moonraker. Please leave it alone.

This file is rewritten at every start.
