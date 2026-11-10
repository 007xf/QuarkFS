#!/usr/bin/env python3
"""Account-free engine fixture for application lifecycle regression checks."""
import base64
import http.server
import os
import signal
import subprocess
from pathlib import Path
import sys
import time

args = sys.argv[1:]
if args == ["version"]:
    print("rclone test fixture")
elif args == ["help", "backends"]:
    print("quark")
elif args == ["cmount", "--help"] or args == ["nfsmount", "--help"]:
    print("test fixture")
elif args == ["obscure", "-"]:
    # Derived from the input, so a stale or wrong cookie in the runtime
    # configuration is visible to the behaviour checks.
    print("fixture-obscured-" + sys.stdin.read().strip().encode().hex())
elif args[:2] == ["cmount", "quark:"] and (Path(args[args.index("--config") + 1]).parent.parent / "fake-mount-table").exists():
    # Simulated mount for the fake /sbin/mount table used by AppBehaviorChecks.
    support = Path(args[args.index("--config") + 1]).parent.parent
    table = support / "fake-mount-table"
    line = "quark{fixture}: on " + args[2].replace(" ", "\\040") + " (macfuse, nodev, nosuid, read-only)\n"
    if (support / "fake-mount-pipe-holder").exists():
        # Like macFUSE's mount helpers, a child in its own session keeps the
        # engine's output open for a moment after the engine has exited.
        # (Process.terminate() signals the engine's whole process group.)
        subprocess.Popen(["/bin/sleep", "1.5"], start_new_session=True)

    def unmount_and_exit(*_):
        if table.exists():
            table.write_text("".join(entry for entry in table.read_text().splitlines(True) if entry != line))
        os._exit(143)

    signal.signal(signal.SIGTERM, unmount_and_exit)
    (support / "fake-mount-started").write_text(str(os.getpid()))
    mounted = False
    if not (support / "fake-mount-never-ready").exists():
        time.sleep(0.3)
        with open(table, "a") as entries:
            entries.write(line)
        mounted = True
    while True:
        time.sleep(0.1)
        if mounted and line not in table.read_text().splitlines(True):
            sys.exit(0)  # Unmounted by umount; the real engine exits too.
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
    support = Path(args[args.index("--config") + 1]).parent.parent
    # Hold a file in the cache, as the real engine does while serving, and
    # record on SIGTERM whether the cache was still intact when we were stopped.
    cache_file = Path(args[args.index("--cache-dir") + 1]) / "fixture-open-file"
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    cache_handle = open(cache_file, "w")

    def stop(*_):
        state = "cache-present" if cache_file.exists() else "cache-missing"
        (support / "webdav-stop-observation").write_text(state)
        if (support / "webdav-slow-stop").exists():
            time.sleep(0.6)
        os._exit(143)

    signal.signal(signal.SIGTERM, stop)
    # Like rclone serve, require Basic authentication when the engine receives
    # a user and password, and allow anonymous access otherwise.
    user, password = os.environ.get("RCLONE_USER"), os.environ.get("RCLONE_PASS")
    expected_authorization = None
    if user is not None and password is not None:
        expected_authorization = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()

    class Handler(http.server.BaseHTTPRequestHandler):
        def authorized(self):
            if expected_authorization is None or self.headers.get("Authorization") == expected_authorization:
                return True
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="rclone"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return False

        def do_PROPFIND(self):
            if not self.authorized():
                return
            # A running engine that cannot list the drive, for example after
            # Quark rejected the session, or an unrelated non-DAV service.
            failure = support / "webdav-failure-mode"
            failing_port = support / "webdav-failure-port"
            if failing_port.exists() and failing_port.read_text().strip() == port:
                failure = failing_port
            if failure.exists():
                mode = "403" if failure == failing_port else failure.read_text().strip()
                body = b"<html>not WebDAV</html>" if mode == "html" else b""
                self.send_response(200 if mode == "html" else int(mode))
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            body = b'<D:multistatus xmlns:D="DAV:"><D:response><D:propstat><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>'
            self.send_response(207)
            self.send_header("Content-Type", "application/xml")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if not self.authorized():
                return
            # Reproduce the engine's log when Quark refuses a large file to the
            # web client: per-read 23018 errors followed by the VFS giving up.
            name = self.path.strip("/")
            if name.endswith("size-limit.mkv") and "--log-file" in args:
                stamp = time.strftime("%Y/%m/%d %H:%M:%S")
                with open(args[args.index("--log-file") + 1], "a") as log:
                    for _ in range(3):
                        log.write(f'{stamp} ERROR : {name}: vfs cache: failed to download: vfs reader: '
                                  f'failed to write to cache file: quark HTTP error: http_status=400 status=400 '
                                  f'code=23018 message="download file size limit[test]"\n')
                    log.write(f"{stamp} ERROR : {name}: vfs cache: too many errors 11/10: last error: quark HTTP error\n")
            self.send_response(500)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *_):
            pass

    http.server.HTTPServer((host, int(port)), Handler).serve_forever()
else:
    sys.exit(1)
