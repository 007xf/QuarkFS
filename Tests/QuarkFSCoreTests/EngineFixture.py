#!/usr/bin/env python3
"""Account-free engine fixture for application lifecycle regression checks."""
import http.server
import os
from pathlib import Path
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
elif args[:2] == ["cmount", "quark:"] and os.environ.get("QUARKFS_TEST_REAL_ENGINE_PATH"):
    # Opt-in local-only integration: forward the production mount options to
    # the actual engine, using a temporary local source and test credentials.
    support = Path(args[args.index("--config") + 1]).parent.parent
    counter = support / "mount-attempt-count"
    attempt = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(attempt))
    always_busy = (support / "mount-failure-mode").exists()
    if always_busy or (attempt == 1 and os.environ.get("QUARKFS_TEST_BUSY_FIRST") == "1"):
        print("mount_macfuse: mount failed test@/dev/macfuse: Resource busy", file=sys.stderr, flush=True)
        sys.exit(1)
    args[1] = str(support / "FixtureRemote")
    args += ["--devname", "quark:"]
    engine = os.environ["QUARKFS_TEST_REAL_ENGINE_PATH"]
    os.execv(engine, [engine] + args)
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
