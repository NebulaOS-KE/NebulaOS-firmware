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

from typing import TYPE_CHECKING, Any, Dict, List

if TYPE_CHECKING:
    from ..confighelper import ConfigHelper
    from ..common import WebRequest

DEFAULT_HELPER = "/usr/libexec/nebulaos/nebulaos-osconfig"
# Moonraker file root for boot-image uploads (server.files.upload
# root=nebulaos_boot). Its own folder, never the printer config tree.
BOOT_UPLOAD_ROOT = "nebulaos_boot"
DEFAULT_BOOT_UPLOAD_DIR = "/usr/data/nebulaos/boot/uploads"
READ_TIMEOUT = 20.
# A network change waits for DHCP/ARP verification and a possible revert.
WRITE_TIMEOUT = 150.


class NebulaOS:
    def __init__(self, config: ConfigHelper) -> None:
        self.server = config.get_server()
        self.helper = config.get("helper", DEFAULT_HELPER)
        # One lock per domain: a display wake must never wait behind a
        # network change that is verifying DHCP.
        self.write_locks: Dict[str, asyncio.Lock] = {}
        self.server.register_notification("nebulaos:settings_changed")
        self.boot_upload_dir = config.get("boot_upload_dir", DEFAULT_BOOT_UPLOAD_DIR)
        try:
            os.makedirs(self.boot_upload_dir, exist_ok=True)
        except OSError as exc:
            logging.info(f"nebulaos: cannot create {self.boot_upload_dir}: {exc}")
        fm = self.server.lookup_component("file_manager", None)
        if fm is None or not fm.register_directory(
                BOOT_UPLOAD_ROOT, self.boot_upload_dir, full_access=True):
            logging.info("nebulaos: boot image upload root not registered")
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
            ("/machine/nebulaos/display/status", RequestType.GET, self._disp_status),
            ("/machine/nebulaos/display/brightness", RequestType.POST,
             self._disp_brightness),
            ("/machine/nebulaos/display/sleep", RequestType.POST, self._disp_sleep),
            ("/machine/nebulaos/display/wake", RequestType.POST, self._disp_wake),
        ]
        for path, rtype, callback in routes:
            self.server.register_endpoint(path, rtype, callback)

    # -- helper invocation ----------------------------------------------------

    def _env(self) -> Dict[str, str]:
        env = dict(os.environ)
        env["NEBULAOS_BOOT_UPLOAD_DIR"] = self.boot_upload_dir
        return env

    async def _exec(self, args: List[str], timeout: float) -> Dict[str, Any]:
        proc = await asyncio.create_subprocess_exec(
            self.helper, *args, stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            env=self._env())
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout)
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

    async def _write(self, domain: str, *args: str) -> Dict[str, Any]:
        lock = self.write_locks.setdefault(domain, asyncio.Lock())
        async with lock:
            result = await self._exec([domain] + list(args), WRITE_TIMEOUT)
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

    async def _bd_image(self, web_request: WebRequest) -> Dict[str, Any]:
        filename = web_request.get_str("filename")
        return await self._write("boot-display", "set-image", "--file", filename)

    async def _bd_reset_image(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._write("boot-display", "reset-image")

    async def _disp_status(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._read("display", "status")

    async def _disp_brightness(self, web_request: WebRequest) -> Dict[str, Any]:
        level = web_request.get_int("level")
        return await self._write("display", "set-brightness", "--level", str(level))

    async def _disp_sleep(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._write("display", "sleep")

    async def _disp_wake(self, web_request: WebRequest) -> Dict[str, Any]:
        return await self._write("display", "wake")


def load_component(config: ConfigHelper) -> NebulaOS:
    return NebulaOS(config)
