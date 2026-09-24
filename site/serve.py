#!/usr/bin/env python3
"""Static server for the site, with caching turned off.

`python3 -m http.server` sends no cache directives at all, which leaves the
browser free to heuristically cache — and it does, aggressively, for ES modules.
The failure that costs real time is not a slow reload: it is a reload that
silently serves the PREVIOUS module and hands you a screenshot of code you have
already changed. Every byte here is answered `no-store`, so what is on screen is
what is on disk.

    python3 site/serve.py [port]
"""

import os
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class NoCacheHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, fmt, *args):
        # One line per request is noise; only surface what failed.
        #
        # `args[1]` is the status code for the three-argument request log, but
        # this method is also the sink for `log_error`, which calls it with one
        # argument for things like a timed-out request — and indexing [1] there
        # raised IndexError inside the handler thread, taking the connection
        # down with it. The length check comes first; the status test is second.
        if len(args) > 1 and str(args[1]).startswith(("4", "5")):
            super().log_message(fmt, *args)
        elif len(args) <= 1:
            super().log_message(fmt, *args)


def main() -> None:
    # argv wins; PORT is what preview harnesses hand out when several sessions
    # each need their own instance of this server.
    port = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("PORT", "4173"))
    root = Path(__file__).resolve().parent
    handler = partial(NoCacheHandler, directory=str(root))
    with ThreadingHTTPServer(("127.0.0.1", port), handler) as httpd:
        print(f"site: http://localhost:{port}/  (no-store, serving {root})", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
