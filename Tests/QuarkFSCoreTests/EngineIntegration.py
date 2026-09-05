#!/usr/bin/env python3
"""Real engine checks using disposable local files; never a cloud account."""
import http.client
import pathlib
import socket
import subprocess
import sys
import tempfile
import time

engine = str(pathlib.Path(sys.argv[1]).resolve())


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
    source = root / "Source"
    source.mkdir()
    content = bytes(range(256)) * 4096
    (source / "sample.bin").write_bytes(content)
    for mode, limit in [("off", None), ("full", "5G"), ("full", "20G")]:
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        args = [engine, "serve", "webdav", str(source), "--config", "/dev/null",
                "--addr", f"127.0.0.1:{port}", "--read-only", "--vfs-cache-mode", mode,
                "--cache-dir", str(root / f"Cache-{limit or 'off'}")]
        if limit:
            args += ["--vfs-cache-max-size", limit]
        process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(40):
                try:
                    status, listing = request(port, "PROPFIND", headers={"Depth": "1"})
                    if status == 207:
                        break
                except OSError:
                    pass
                time.sleep(0.1)
            else:
                raise AssertionError("WebDAV did not become ready")
            assert b"sample.bin" in listing
            status, data = request(port, "GET", "/sample.bin", headers={"Range": "bytes=1024-4095"})
            assert status == 206 and data == content[1024:4096], "range read"
            assert request(port, "PUT", "/new.bin", b"test")[0] >= 400, "PUT must be rejected"
            assert request(port, "DELETE", "/sample.bin")[0] >= 400, "DELETE must be rejected"
            assert (source / "sample.bin").read_bytes() == content
            assert not (source / "new.bin").exists()
            print(f"PASS: real WebDAV listing, byte range and read-only protection ({mode}, {limit})", flush=True)
        finally:
            stop(process)

    if "--mount" in sys.argv:
        mount = root / "Mount"
        mount.mkdir()
        process = subprocess.Popen([engine, "cmount", str(source), str(mount), "--config", "/dev/null", "--read-only"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
