#!/usr/bin/env python3
"""Loopback-only subpath adapter for publishing AList behind Tailscale Funnel."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import re

BACKEND = "http://127.0.0.1:5244"
PREFIX = "/alist"

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self): self.forward()
    def do_POST(self): self.forward()
    def do_PUT(self): self.forward()
    def do_PATCH(self): self.forward()
    def do_DELETE(self): self.forward()
    def do_OPTIONS(self): self.forward()
    def do_HEAD(self): self.forward()

    def forward(self):
        # Funnel strips /alist when proxying to this service.
        path = self.path
        if path == "/": path = "/"
        size = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(size) if size else None
        hdr = {k:v for k,v in self.headers.items() if k.lower() not in
               {"host", "connection", "content-length", "accept-encoding", "transfer-encoding"}}
        hdr["Accept-Encoding"] = "identity"
        request = Request(BACKEND + path, data=data, headers=hdr, method=self.command)
        try:
            response = urlopen(request, timeout=90)
        except HTTPError as e:
            response = e
        with response:
            body = b"" if self.command == "HEAD" else response.read()
            ctype = response.headers.get("Content-Type", "")
            if "text/html" in ctype and b"window.ALIST" in body:
                body = body.replace(b"base_path: '/'", b"base_path: '/alist/'")
                body = body.replace(b"cdn: ''", b"cdn: '/alist'")
            self.send_response(response.status)
            for k,v in response.headers.items():
                if k.lower() in {"content-length", "transfer-encoding", "content-encoding", "connection", "location", "server"}:
                    continue
                self.send_header(k,v)
            self.send_header("Content-Length",str(len(body)))
            if response.headers.get("Location"):
                target=response.headers["Location"]
                if target.startswith("/") and not target.startswith(PREFIX+"/"):
                    target=PREFIX+target
                self.send_header("Location",target)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 15244), Handler).serve_forever()
