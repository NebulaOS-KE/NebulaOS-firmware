# Recovery

Four ways back onto a working system, in order of severity. Read against
`NebulaOS-firmware` at `b95b156`; the shipping release is 1.0.2, firmware `3bdf3ff`.

Only the last of these loses data, which is why they are presented in this order - both here
and in the end-user manual.

1. **The automatic trial** - nothing to do; see [Image install and the trial](Image-Install-And-Trial).
2. **Swap the boot slot from the screen** - `machine.nebulaos.system.swap_slot`, which calls
   `nebulaos-slot-swap`. Blocked while printing.
3. **SSH** - both NebulaOS and stock accept `root`. Steps are in
   `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md`.
4. **USB recovery** - the SoC's mask ROM, which works when no system starts at all. Two very
   different operations live here: `tools/recovery/usb-set-boot-slot.sh` rewrites only the
   marker and erases nothing, while writing a full `.ingenic` image rewrites the printer and
   **erases the data partition**. See `docs/DEVELOPER_RECOVERY.md`.



## Before reaching for any of them: why did it stop?

A printer that restarted by itself has already written down what happened.
[The black box](Black-Box) explains `/run/nebulaos/last-reset`, `logs/reset-history.log` and the
crash copies under `logs/crash/`. Reading the verdict first is cheaper than any recovery route,
and it is the difference between a freeze, a crash and somebody's power strip.

## The full procedures

This page is the map. The step-by-step procedures stay in this repository's tracked docs,
which are the maintained copies:

| Route | Document |
|---|---|
| Swapping slots, from the screen or over SSH | `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md` |
| USB recovery, both operations | `docs/DEVELOPER_RECOVERY.md` |
| What the slots and the marker are | [Architecture](Architecture) |

Two corrections those documents now carry, because their older prose predates the code: there
is still **no automatic rollback to stock**, but a stock boot no longer leaves the MCU carrying
Creality firmware until someone intervenes - `S50nebulaos-mcu-guard` and `mcu_restore.py`
reinstall the native build on the way back, bounded and verified. See
[Architecture](Architecture).

## Not covered here

Nothing on this page was performed on a printer by its author. The USB recovery route in
particular is described from `tools/recovery/` and `docs/DEVELOPER_RECOVERY.md`, not from a run.
