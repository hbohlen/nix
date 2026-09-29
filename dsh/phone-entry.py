#!/usr/bin/env python3
"""Redirect the stable dsh entry point to the current per-process launch URL."""

import http.server
import pathlib
import re
import sys
from urllib.parse import quote


# Must match the dsh `--port` in modules/dsh.nix and the system Caddy route in
# docs/dsh-web-endpoint.md. The smoke test asserts the port it checks.
PORT = 3082
TOKEN_URL = re.compile(r"\Ahttp://127\.0\.0\.1:3080/\?token=([A-Za-z0-9_-]+)\Z")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/":
            self.send_error(404)
            return

        try:
            match = TOKEN_URL.fullmatch(self.server.token_file.read_text().strip())
        except OSError:
            match = None

        if match is None:
            self.send_error(503, "dsh is not ready; start or restart dsh-web")
            return

        self.send_response(302)
        self.send_header(
            "Location", "https://dsh.hbohlen.space/?token=" + quote(match.group(1))
        )
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()

    def log_message(self, _format, *_args):
        # Never log launch tokens, redirect locations, or request URLs.
        pass


def main():
    token_file = pathlib.Path(sys.argv[1])
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.token_file = token_file
    server.serve_forever()


if __name__ == "__main__":
    main()
