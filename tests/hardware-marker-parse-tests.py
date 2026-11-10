#!/usr/bin/env python3
"""nebulaos_marker.parse (Run 23): the enumerated marker forms, including the
one stock's non-truncating echo leaves over a NebulaOS "ota:kernel2\\n\\n"
(ke-dev 2026-11-05, after stock's USB updater installed NebulaOS).

Run: python3 tests/hardware-marker-parse-tests.py
"""
import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools", "hardware"))
import nebulaos_marker as marker  # noqa: E402


def block(raw):
    return raw + b"\x00" * (marker.SECTOR - len(raw))


class MarkerParseTests(unittest.TestCase):
    def test_accepted_forms(self):
        for raw, want in ((b"ota:kernel\n", marker.KERNEL), (b"ota:kernel\n\n", marker.KERNEL),
                          (b"ota:kernel2\n", marker.KERNEL2), (b"ota:kernel2\n\n", marker.KERNEL2)):
            self.assertEqual(marker.parse(block(raw))[0], want, raw)

    def test_stock_echo_over_a_nebulaos_kernel2_marker(self):
        old = bytearray(block(b"ota:kernel2\n\n"))
        old[:11] = b"ota:kernel\n"          # echo ota:kernel > /dev/mmcblk0p1
        self.assertEqual(bytes(old[:13]), b"ota:kernel\n\n\n")
        self.assertEqual(marker.parse(bytes(old))[0], marker.KERNEL)

    def test_anything_else_stays_indeterminate(self):
        for raw in (b"ota:kernel", b"ota:kernel\n\n\n\n", b"ota:kernel\n\n\nx",
                    b"ota:kernel\n\x01", b"ota:kernelX\n", b""):
            self.assertEqual(marker.parse(block(raw))[0], marker.INDETERMINATE, raw)


if __name__ == "__main__":
    unittest.main()
