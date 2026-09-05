#!/usr/bin/env python3
"""Account-free engine fixture for application lifecycle regression checks."""
import http.server
import sys

args = sys.argv[1:]
if args == ["version"]:
    print("rclone test fixture")
elif args == ["help", "backends"]:
    print("quark")
elif args == ["cmount", "--help"] or args == ["nfsmount", "--help"]:
    print("test fixture")
elif args == ["obscure", "-"]:
    sys.stdin.read()
    print("fixture-obscured-cookie")
elif "webdav" in args:
    host, port = args[args.index("--addr") + 1].split(":")

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_PROPFIND(self):
            body = b'<D:multistatus xmlns:D="DAV:"><D:response><D:propstat><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>'
            self.send_response(207)
            self.send_header("Content-Type", "application/xml")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    http.server.HTTPServer((host, int(port)), Handler).serve_forever()
else:
    sys.exit(1)
