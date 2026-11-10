#!/usr/bin/env python3
"""Real engine checks using disposable local files; never a cloud account."""
import base64
import http.client
import json
import os
import pathlib
import secrets
import socket
import subprocess
import sys
import tempfile
import time

engine = str(pathlib.Path(sys.argv[1]).resolve())
# Mirrors EngineLogOptions.arguments.
LOG_OPTIONS = ["--log-level", "NOTICE", "--log-file-max-size", "10M", "--log-file-max-backups", "1"]
USER, PASSWORD = "quarkfs", secrets.token_urlsafe(24)
AUTH = {"Authorization": "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()}
WRONG_AUTH = {"Authorization": "Basic " + base64.b64encode(f"{USER}:wrong-password".encode()).decode()}
# Never let a check reach a network service, even by mistake.
OFFLINE = dict(os.environ, HTTP_PROXY="http://127.0.0.1:9", HTTPS_PROXY="http://127.0.0.1:9", NO_PROXY="127.0.0.1")


def request(port, method, path="/", data=None, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        connection.request(method, path, body=data, headers=headers or {})
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)


with tempfile.TemporaryDirectory(prefix="QuarkFS-Engine-") as folder:
    root = pathlib.Path(folder)
    # The engine must read the runtime config exactly as QuarkFS writes it,
    # without any user_agent override.
    obscured = subprocess.run([engine, "obscure", "-"], input="test-only-cookie\n", text=True,
                              capture_output=True, check=True, env=OFFLINE).stdout.strip()
    config = root / "rclone.conf"
    config.write_text(f"[quark]\ntype = quark\ncookie = {obscured}\n")
    dumped = json.loads(subprocess.run([engine, "config", "dump", "--config", str(config)], text=True,
                                       capture_output=True, check=True, env=OFFLINE).stdout)
    assert dumped["quark"]["type"] == "quark", "quark remote"
    assert "user_agent" not in dumped["quark"], "runtime config must not set a user_agent"
    print("PASS: real engine reads the runtime config without a user_agent override", flush=True)

    source = root / "Source"
    source.mkdir()
    content = bytes(range(256)) * 4096
    (source / "sample.bin").write_bytes(content)
    for mode, limit in [("off", None), ("full", "5G"), ("full", "20G")]:
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        log_file = root / f"WebDAV-{mode}-{limit or 'off'}.log"
        args = [engine, "serve", "webdav", str(source), "--config", "/dev/null",
                "--addr", f"127.0.0.1:{port}", "--read-only", "--vfs-cache-mode", mode,
                "--cache-dir", str(root / f"Cache-{limit or 'off'}"), "--log-file", str(log_file)] + LOG_OPTIONS
        if limit:
            args += ["--vfs-cache-max-size", limit]
        # Credentials travel in the environment, as QuarkFS passes them.
        environment = dict(OFFLINE, RCLONE_USER=USER, RCLONE_PASS=PASSWORD)
        process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=environment)
        try:
            for _ in range(40):
                try:
                    status, listing = request(port, "PROPFIND", headers=dict(AUTH, Depth="1"))
                    if status == 207:
                        break
                except OSError:
                    pass
                time.sleep(0.1)
            else:
                raise AssertionError("WebDAV did not become ready")
            assert b"sample.bin" in listing
            assert PASSWORD not in " ".join(args), "the password must not appear in the engine arguments"
            assert request(port, "PROPFIND", headers={"Depth": "1"})[0] == 401, "anonymous listing must be rejected"
            assert request(port, "GET", "/sample.bin")[0] == 401, "anonymous download must be rejected"
            assert request(port, "PROPFIND", headers=dict(WRONG_AUTH, Depth="1"))[0] == 401, "wrong password"
            rebound = {"Host": f"rebind.attacker.example:{port}", "Depth": "1"}
            assert request(port, "PROPFIND", headers=rebound)[0] == 401, "DNS-rebinding request must be rejected"
            status, data = request(port, "GET", "/sample.bin", headers=dict(AUTH, Range="bytes=1024-4095"))
            assert status == 206 and data == content[1024:4096], "range read"
            assert request(port, "PUT", "/new.bin", b"test", headers=AUTH)[0] >= 400, "PUT must be rejected"
            assert request(port, "DELETE", "/sample.bin", headers=AUTH)[0] >= 400, "DELETE must be rejected"
            assert (source / "sample.bin").read_bytes() == content
            assert not (source / "new.bin").exists()
            print(f"PASS: real WebDAV authentication, listing, byte range, read-only protection and log options ({mode}, {limit})", flush=True)
        finally:
            stop(process)

    if "--mount" in sys.argv:
        mount = root / "Mount"
        mount.mkdir()
        process = subprocess.Popen([engine, "cmount", str(source), str(mount), "--config", "/dev/null", "--read-only",
                                    "--log-file", str(root / "Mount.log")] + LOG_OPTIONS,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=OFFLINE)
        try:
            for _ in range(100):
                mounts = subprocess.check_output(["/sbin/mount"], text=True)
                if f" on {mount} (" in mounts or f" on {mount.resolve()} (" in mounts:
                    break
                if process.poll() is not None:
                    raise AssertionError("macFUSE is not ready for a real mount")
                time.sleep(0.1)
            else:
                raise AssertionError("mount timed out")
            assert (mount / "sample.bin").read_bytes() == content
            try:
                (mount / "new.bin").write_bytes(b"test")
            except OSError:
                pass
            else:
                raise AssertionError("mount allowed a write")
            subprocess.run(["/sbin/umount", str(mount)], check=True, timeout=10)
            print("PASS: real macFUSE mount, read, write rejection and unmount", flush=True)
        finally:
            stop(process)
