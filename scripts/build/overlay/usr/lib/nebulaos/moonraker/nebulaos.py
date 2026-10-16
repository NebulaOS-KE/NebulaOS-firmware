# NebulaOS OS-settings component for Moonraker (GUI/service readiness
# mission, 2026-10-09).
#
# The single GUI-facing path to NebulaOS OS settings: GuppyScreen (and any
# Moonraker client) -> these endpoints -> /usr/libexec/nebulaos/nebulaos-osconfig
# (argv only, one JSON object back, validated, atomic). No second API, no new
# daemon: this runs inside Moonraker's own process.
#
# Lives on the read-only rootfs (/usr/lib/nebulaos/moonraker/nebulaos.py) and
# is composed into the Moonraker checkout by S05nebulaos-activate as an
# excluded symlink, the same mechanism NebulaOS uses for its Klipper extras.
# Configured by [nebulaos] in /etc/nebulaos/moonraker/nebulaos.conf (an
# image-owned include). If it is missing, Moonraker runs without it.
#
# This file may be distributed under the terms of the GNU GPLv3 license.
from __future__ import annotations

import asyncio
import json
import logging
import os

from ..common import RequestType

from typing import TYPE_CHECKING, Any, Dict, List, Optional

if TYPE_CHECKING:
    from ..confighelper import ConfigHelper
    from ..common import WebRequest

DEFAULT_HELPER = "/usr/libexec/nebulaos/nebulaos-osconfig"
# G63 (2026-10-16): files handed to NebulaOS - boot-logo/, mainboard-firmware/,
# system-image/ - live in config/uploads, inside the "config" root: Mainsail's
# upload button only uploads into config, so G62's own root "uploads" could
# not receive files. No root is registered for it (a root under config would
# overlap). S01persistent-datastore creates the folders before Moonraker.
DEFAULT_UPLOADS_DIR = "/opt/printer_data/config/uploads"
READ_TIMEOUT = 20.
# A network change waits for DHCP/ARP verification and a possible revert.
WRITE_TIMEOUT = 150.
# An MCU flash stops Klipper, enters the bootloader, transfers and restarts
# Klipper; the helper bounds it at 600 s itself. Never kill it first.
MCU_FLASH_TIMEOUT = 660.
# Zipping every log onto a USB stick on the MIPS board.
LOGS_SAVE_TIMEOUT = 300.
# Walking the data drive (thousands of files) on the MIPS board.
STORAGE_TIMEOUT = 120.
CLEANUP_TIMEOUT = 600.


class NebulaOS:
    def __init__(self, config: ConfigHelper) -> None:
        self.server = config.get_server()
        self.helper = config.get("helper", DEFAULT_HELPER)
        # One lock per domain: a display wake must never wait behind a
        # network change that is verifying DHCP.
        self.write_locks: Dict[str, asyncio.Lock] = {}
        self.server.register_notification("nebulaos:settings_changed")
        self.uploads_dir = config.get("uploads_dir", DEFAULT_UPLOADS_DIR)
        self.boot_upload_dir = os.path.join(self.uploads_dir, "boot-logo")
        for sub in ("boot-logo", "mainboard-firmware", "system-image"):
            try:
                os.makedirs(os.path.join(self.uploads_dir, sub), exist_ok=True)
            except OSError as exc:
                logging.info(f"nebulaos: cannot create {self.uploads_dir}/{sub}: {exc}")
        routes = [
            ("/machine/nebulaos/info", RequestType.GET, self._info),
            ("/machine/nebulaos/network/status", RequestType.GET, self._net_status),
            ("/machine/nebulaos/network/hostname", RequestType.POST, self._net_hostname),
            ("/machine/nebulaos/network/ipv4", RequestType.POST, self._net_ipv4),
            ("/machine/nebulaos/boot_display/status", RequestType.GET, self._bd_status),
            ("/machine/nebulaos/boot_display/mode", RequestType.POST, self._bd_mode),
            ("/machine/nebulaos/boot_display/image", RequestType.POST, self._bd_image),
            ("/machine/nebulaos/boot_display/reset_image", RequestType.POST,
             self._bd_reset_image),
            ("/machine/nebulaos/boot_display/restore_original_logo", RequestType.POST,
             self._bd_restore_original_logo),
            ("/machine/nebulaos/boot_display/images", RequestType.GET, self._bd_images),
            ("/machine/nebulaos/logs/status", RequestType.GET, self._logs_status),
            ("/machine/nebulaos/logs/level", RequestType.POST, self._logs_level),
            ("/machine/nebulaos/logs/save", RequestType.POST, self._logs_save),
            ("/machine/nebulaos/storage", RequestType.GET, self._storage),
            ("/machine/nebulaos/cleanup/plan", RequestType.GET, self._cleanup_plan),
            ("/machine/nebulaos/cleanup/creality", RequestType.POST, self._cleanup_creality),
            ("/machine/nebulaos/boot_display/preview", RequestType.POST, self._bd_preview),
            ("/machine/nebulaos/boot_display/import_usb", RequestType.POST, self._bd_import_usb),
            ("/machine/nebulaos/boot_display/delete_image", RequestType.POST,
             self._bd_delete_image),
            ("/machine/nebulaos/display/status", RequestType.GET, self._disp_status),
            ("/machine/nebulaos/display/brightness", RequestType.POST,
             self._disp_brightness),
            ("/machine/nebulaos/display/sleep", RequestType.POST, self._disp_sleep),
            ("/machine/nebulaos/display/wake", RequestType.POST, self._disp_wake),
            ("/machine/nebulaos/wifi/status", RequestType.GET, self._wifi_status),
            ("/machine/nebulaos/wifi/scan", RequestType.POST, self._wifi_scan),
            ("/machine/nebulaos/wifi/connect", RequestType.POST, self._wifi_connect),
            ("/machine/nebulaos/wifi/forget", RequestType.POST, self._wifi_forget),
            ("/machine/nebulaos/system/clean_reset", RequestType.POST,
             self._clean_reset),
            ("/machine/nebulaos/system/swap_slot", RequestType.POST, self._swap_slot),
            ("/machine/nebulaos/system/ack_clean_reset", RequestType.POST,
             self._ack_clean_reset),
            ("/machine/nebulaos/system/ack_notice", RequestType.POST,
             self._ack_notice),
            ("/machine/nebulaos/image/list", RequestType.GET, self._image_list),
            ("/machine/nebulaos/image/status", RequestType.GET, self._image_status),
            ("/machine/nebulaos/image/check", RequestType.POST, self._image_check),
            ("/machine/nebulaos/image/install", RequestType.POST, self._image_install),
            ("/machine/nebulaos/image/ack", RequestType.POST, self._image_ack),
            ("/machine/nebulaos/mcu/status", RequestType.GET, self._mcu_status),
            ("/machine/nebulaos/mcu/files", RequestType.GET, self._mcu_files),
            ("/machine/nebulaos/mcu/flash", RequestType.POST, self._mcu_flash),
        ]
        for path, rtype, callback in routes:
            self.server.register_endpoint(path, rtype, callback)

    # -- helper invocation ----------------------------------------------------

    def _env(self) -> Dict[str, str]:
        env = dict(os.environ)
        env["NEBULAOS_BOOT_UPLOAD_DIR"] = self.boot_upload_dir
        return env

    async def _exec(self, args: List[str], timeout: float,
                    stdin: Optional[bytes] = None) -> Dict[str, Any]:
        proc = await asyncio.create_subprocess_exec(
            self.helper, *args,
            stdin=asyncio.subprocess.PIPE if stdin is not None else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            env=self._env())
        try:
            out, err = await asyncio.wait_for(proc.communicate(stdin), timeout)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            raise self.server.error(
                f"nebulaos-osconfig {' '.join(args[:2])} timed out", 504)
        try:
            result = json.loads(out.decode("utf-8", "replace").strip() or "{}")
        except ValueError:
            logging.info(f"nebulaos: helper output not JSON: {err[-500:]!r}")
            raise self.server.error("nebulaos-osconfig returned no result", 500)
        if not result.pop("ok", False):
            code = result.get("error", "FAILED")
            message = result.get("message", "")
            status = 400 if proc.returncode in (1, 64) else 500
            raise self.server.error(f"{code}: {message}", status)
        return result

    async def _read(self, *args: str) -> Dict[str, Any]:
        return await self._exec(list(args), READ_TIMEOUT)

    async def _write(self, domain: str, *args: str,
                     stdin: Optional[bytes] = None,
                     timeout: float = WRITE_TIMEOUT) -> Dict[str, Any]:
        lock = self.write_locks.setdefault(domain, asyncio.Lock())
        async with lock:
            result = await self._exec([domain] + list(args), timeout, stdin)
        self.server.send_event("nebulaos:settings_changed",
                               {"domain": domain, "result": result.get("result")})
        return result

    # -- endpoints ------------------------------------------------------------

    async def _info(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._read("system", "info")

    async def _net_status(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._read("network", "status")

    async def _net_hostname(self, web_request: WebRequest) -> Dict[str, Any]:
        hostname = web_request.get_str("hostname")
        return await self._write("network", "set-hostname", "--hostname", hostname)

    async def _net_ipv4(self, web_request: WebRequest) -> Dict[str, Any]:
        spec: Dict[str, Any] = {"mode": web_request.get_str("mode")}
        if spec["mode"] == "static":
            spec["address"] = web_request.get_str("address")
            spec["prefix"] = web_request.get_int("prefix")
            spec["gateway"] = web_request.get_str("gateway")
            spec["dns"] = web_request.get_list("dns", [])
        return await self._write("network", "set-ipv4", "--json", json.dumps(spec))

    async def _bd_status(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._read("boot-display", "status")

    async def _bd_mode(self, web_request: WebRequest) -> Dict[str, Any]:
        mode = web_request.get_str("mode")
        return await self._write("boot-display", "set-mode", "--mode", mode)

    # G58: these also write the power-on logo into the RTOS partition, so
    # they are refused while printing like the other partition writes.
    async def _bd_image(self, web_request: WebRequest) -> Dict[str, Any]:
        filename = web_request.get_str("filename")
        await self._refuse_while_printing()
        return await self._write("boot-display", "set-image", "--file", filename)

    async def _bd_reset_image(self, web_request: WebRequest) -> Dict[str, Any]:
        await self._refuse_while_printing()
        return await self._write("boot-display", "reset-image")

    async def _bd_restore_original_logo(self, web_request: WebRequest) -> Dict[str, Any]:
        await self._refuse_while_printing()
        return await self._write("boot-display", "restore-original-logo")

    # G61 (2026-10-16): the boot logo page - list, preview, add from USB, delete.
    async def _bd_images(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._read("boot-display", "list-images")

    async def _bd_preview(self, web_request: WebRequest) -> Dict[str, Any]:
        filename = web_request.get_str("filename", "")
        args = ["boot-display", "preview"] + (["--file", filename] if filename else [])
        return await self._exec(args, READ_TIMEOUT)

    async def _bd_import_usb(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._write("boot-display", "import-usb", "--file",
                                 web_request.get_str("file"))

    async def _bd_delete_image(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._write("boot-display", "delete-image", "--file",
                                 web_request.get_str("filename"))

    # G60 (2026-10-16): the general log level and "Save logs to USB".
    async def _logs_status(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._read("logs", "status")

    async def _logs_level(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._write("logs", "set-level", "--level", web_request.get_str("level"))

    async def _logs_save(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._write("logs", "save", timeout=LOGS_SAVE_TIMEOUT)

    # G66: what uses the data drive, and removing the Creality system's data
    # (both walk the drive; the removal is refused while printing).
    async def _storage(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._exec(["system", "storage"], STORAGE_TIMEOUT)

    def _videos_args(self, web_request: WebRequest) -> List[str]:
        return ["--videos"] if web_request.get_boolean("videos", False) else []

    async def _cleanup_plan(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._exec(["system", "cleanup-plan"] + self._videos_args(web_request),
                                STORAGE_TIMEOUT)

    async def _cleanup_creality(self, web_request: WebRequest) -> Dict[str, Any]:
        await self._refuse_while_printing()
        return await self._write("system", "cleanup-creality", *self._videos_args(web_request),
                                 timeout=CLEANUP_TIMEOUT)

    async def _disp_status(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._read("display", "status")

    async def _disp_brightness(self, web_request: WebRequest) -> Dict[str, Any]:
        level = web_request.get_int("level")
        return await self._write("display", "set-brightness", "--level", str(level))

    async def _disp_sleep(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._write("display", "sleep")

    async def _disp_wake(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._write("display", "wake")

    # -- Wi-Fi (Q3, 2026-10-11) -------------------------------------------------

    async def _wifi_status(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._read("wifi", "status")

    async def _wifi_scan(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._write("wifi", "scan")

    async def _wifi_connect(self, web_request: WebRequest) -> Dict[str, Any]:
        # The password goes to the helper on stdin, never on a command line.
        spec = {"ssid": web_request.get_str("ssid"),
                "password": web_request.get_str("password", "")}
        return await self._write("wifi", "connect", "--stdin",
                                 stdin=json.dumps(spec).encode("utf-8"))

    async def _wifi_forget(self, web_request: WebRequest) -> Dict[str, Any]:
        ssid = web_request.get_str("ssid")
        return await self._write("wifi", "forget", "--ssid", ssid)

    # -- clean reset and boot slot (S2/S3, 2026-10-11) ---------------------------
    # Both arm the next boot and reboot at once. Refused while a print is
    # active; if the reboot cannot be started, the change is disarmed again.

    async def _refuse_while_printing(self) -> None:
        kapis = self.server.lookup_component("klippy_apis", None)
        if kapis is None:
            return
        try:
            res = await kapis.query_objects({"print_stats": ["state"]})
        except Exception:
            return      # Klipper not ready: nothing can be printing
        state = (res.get("print_stats") or {}).get("state")
        if state in ("printing", "paused"):
            raise self.server.error("PRINTING: not possible while a print is active", 409)

    async def _reboot_or_undo(self, undo: List[str]) -> None:
        machine = self.server.lookup_component("machine")
        try:
            await machine.get_system_provider().reboot()
        except Exception as exc:
            logging.info(f"nebulaos: reboot failed, undoing {undo}: {exc}")
            await self._write(*undo)
            raise self.server.error(f"REBOOT_FAILED: {exc}; nothing was changed", 500)

    async def _clean_reset(self, web_request: WebRequest) -> Dict[str, Any]:
        await self._refuse_while_printing()
        result = await self._write("system", "clean-reset")
        await self._reboot_or_undo(["system", "cancel-clean-reset"])
        return result

    # -- system images (on-printer updates, 2026-10-14) -------------------------
    # Offered on the touchscreen only (no Mainsail button); refused while a
    # print is active. install only starts the background job - the screen
    # follows it through image/status; the printer reboots at the end.

    async def _image_list(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._read("image", "list")

    async def _image_status(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._read("image", "status")

    async def _image_check(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._write("image", "check", "--file", web_request.get_str("file"))

    async def _image_install(self, web_request: WebRequest) -> Dict[str, Any]:
        await self._refuse_while_printing()
        return await self._write("image", "install", "--file", web_request.get_str("file"),
                                 "--sha256", web_request.get_str("sha256"))

    async def _image_ack(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._write("image", "ack")

    async def _ack_clean_reset(self, web_request: WebRequest) -> Dict[str, Any]:
        # The screen showed the after-reset notice (G2).
        return await self._write("system", "ack-clean-reset")

    async def _ack_notice(self, web_request: WebRequest) -> Dict[str, Any]:
        # G65: the screen showed a notice (e.g. replaced config/nebulaos edits).
        return await self._write("system", "ack-notice", "--id", web_request.get_str("id"))

    async def _swap_slot(self, web_request: WebRequest) -> Dict[str, Any]:
        await self._refuse_while_printing()
        result = await self._write("system", "swap-slot")
        await self._reboot_or_undo(["system", "keep-slot"])
        return result

    # -- MCU firmware (development run 4, 2026-10-11) -----------------------------
    # The helper checks and stages the file and runs `nebulaos-mcu flash`,
    # which refuses while printing, stops Klipper and always restarts it.

    async def _mcu_status(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._read("mcu", "status")

    async def _mcu_files(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._read("mcu", "list")

    async def _mcu_flash(self, web_request: WebRequest) -> Dict[str, Any]:
        file_id = web_request.get_str("file")
        sha = web_request.get_str("sha256")
        lock = self.write_locks.setdefault("mcu", asyncio.Lock())
        if lock.locked():
            raise self.server.error("BUSY: an MCU flash is already running", 409)
        await self._refuse_while_printing()
        return await self._write("mcu", "flash", "--file", file_id, "--sha256", sha,
                                 timeout=MCU_FLASH_TIMEOUT)


def load_component(config: ConfigHelper) -> NebulaOS:
    return NebulaOS(config)
