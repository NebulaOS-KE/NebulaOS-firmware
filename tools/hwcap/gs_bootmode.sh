#!/bin/sh
# GUI/service readiness acceptance T3/T5 (2026-10-10): select the boot screen
# mode ($MODE: logo|console|blank) through the same path the GUI uses
# (nebulaos-osconfig boot-display set-mode). The mode is a persistent user
# setting that takes effect on the next boot, so these profiles deliberately
# have no undo: the human session sets blank/console, reboots, looks, and
# finishes with the logo profile. Also prints what the previous boot's
# S01splash did.
O=/usr/libexec/nebulaos/nebulaos-osconfig
echo "== previous boot: S01splash"
grep -h 'nebulaos-boot-display' /var/log/messages 2>/dev/null | tail -5 | cut -c1-200
grep 'S01splash' /run/nebulaos-boot-scripts.log 2>/dev/null
echo "== set-mode $MODE"
$O boot-display set-mode --mode "$MODE"; echo "rc=$?"
grep . /usr/data/nebulaos/boot/display.env 2>/dev/null
