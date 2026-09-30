#!/usr/bin/env python3
"""Redirect the stable dsh entry point to the current per-process launch URL."""

import argparse
import http.server
import pathlib
import re
from urllib.parse import quote


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/":
            self.send_error(404)
            return

        try:
            match = self.server.token_pattern.fullmatch(
                self.server.token_file.read_text().strip()
            )
        except OSError:
            match = None

        if match is None:
            self.send_error(503, "dsh is not ready; start or restart dsh-web")
            return

        self.send_response(302)
        self.send_header(
            "Location",
            self.server.public_url + "/?token=" + quote(match.group(1)),
        )
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()

    def log_message(self, _format, *_args):
        # Never log launch tokens, redirect locations, or request URLs.
        pass


def main():
    # All endpoint facts arrive as argv, built by modules/dsh.nix from the
    # dsh.* options (ADR 0011). No constant here may mirror the declaration:
    # the old listen-port / capture-regex pair lived here as a "must match"
    # comment contract across languages, and this file no longer has one.
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--token-file", required=True, type=pathlib.Path)
    ap.add_argument("--entry-port", required=True, type=int)
    ap.add_argument("--upstream", required=True,
                    help="the dsh web authority the capture is expected to hold, e.g. http://127.0.0.1:PORT")
    ap.add_argument("--public-url", required=True,
                    help="the port-less site origin to redirect to, e.g. https://NAME")
    args = ap.parse_args()

    # Accept ONLY the exact token form the declared capture writes: the
    # pattern derives from --upstream, so dsh.port stays single-owned.
    token_pattern = re.compile(
        r"\A" + re.escape(args.upstream) + r"/\?token=([A-Za-z0-9_-]+)\Z"
    )

    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.entry_port), Handler)
    server.token_file = args.token_file
    server.token_pattern = token_pattern
    server.public_url = args.public_url.rstrip("/")
    server.serve_forever()


if __name__ == "__main__":
    main()
