#!/usr/bin/env python3
"""Live gap verification NG1 (2026-10-05): Tornado error responses.

Buildroot's python-tornado 6.4.2 carries 0002-web-Harden-against-invalid-HTTP-
reason-phrases.patch (CVE-2025-67724), backported from Tornado 6.5: web.py now
validates a reason phrase against httputil._ABNF, which only Tornado 6.5's
httputil defines. Every error with a reason phrase then raises in send_error
and the client never gets a response.

Runs a throwaway Tornado app on 127.0.0.1:7199 with the image's own Tornado
(the interpreter given, Moonraker's venv) and requests a handler that raises
HTTPError(404, reason=...), as Moonraker's database handler does:
  image  - Tornado as shipped
  fixed  - the same, with the missing httputil._ABNF.reason_phrase defined
           (RFC 9110 reason-phrase = *( HTAB / SP / VCHAR / obs-text ))
Moonraker itself is not touched.
"""
import re
import sys
import threading
import time
import urllib.error
import urllib.request

import tornado
import tornado.httputil
import tornado.ioloop
import tornado.web

MODE = sys.argv[1]
PORT = 7199


class Missing(tornado.web.RequestHandler):
    def get(self):
        raise tornado.web.HTTPError(404, reason="Key 'x' in namespace 'y' not found")


class Plain(tornado.web.RequestHandler):
    def get(self):
        raise tornado.web.HTTPError(404)


if MODE == "fixed" and not hasattr(tornado.httputil, "_ABNF"):
    class _ABNF:
        reason_phrase = re.compile(r"[\t \x21-\x7E\x80-\xFF]*")
    tornado.httputil._ABNF = _ABNF()

loop_box = {}


def serve():
    import asyncio
    asyncio.set_event_loop(asyncio.new_event_loop())
    app = tornado.web.Application([(r"/missing", Missing), (r"/plain", Plain)])
    app.listen(PORT, "127.0.0.1")
    loop_box["loop"] = tornado.ioloop.IOLoop.current()
    loop_box["loop"].start()


threading.Thread(target=serve, daemon=True).start()
time.sleep(1.0)
print("NG1 mode=%s tornado=%s file=%s has_ABNF=%s" % (MODE, tornado.version, tornado.__file__,
                                                     hasattr(tornado.httputil, "_ABNF")))
for path in ("/missing", "/plain"):
    t = time.monotonic()
    try:
        urllib.request.urlopen("http://127.0.0.1:%d%s" % (PORT, path), timeout=6)
        res = "200?"
    except urllib.error.HTTPError as e:
        res = "http=%d reason=%r" % (e.code, e.reason)
    except Exception as e:  # noqa: BLE001 - the outcome is the measurement
        res = "no_response (%s)" % e
    print("NG1 mode=%s path=%s %s seconds=%.2f" % (MODE, path, res, time.monotonic() - t), flush=True)
loop_box["loop"].add_callback(loop_box["loop"].stop)
