#!/usr/bin/env python3
"""A client of stellar-render's command protocol (docs/render.md section 9).

The renderer listens with `stellar-render --listen [ADDR:]PORT` (or STELLAR_RENDER_LISTEN; a port
alone is localhost). One command per line, one reply line per command, sent when the command is
complete; `frame -` replies `ok frame - W H MS BYTES` and then the PNG's bytes.

    ctl.py [--addr HOST:PORT] COMMAND...        send commands, print the replies
    ctl.py [--addr HOST:PORT] --file FILE       send a file's commands (# comments)
    ctl.py [--addr HOST:PORT] --get OUT.png     render the current view, save the PNG (frame -)
    ctl.py [--addr HOST:PORT] example SAVE OUT_DIR [SYSTEM_ID]
        the scripted example: load the save, three galaxy shots from different angles, focus a
        home system, a system shot; lists the PNGs with their frame times

Standard library only. Exits 1 on an `error` reply.
"""

import os
import socket
import sys
import time

DEFAULT_ADDR = "127.0.0.1:7878"


class Client:
    def __init__(self, addr):
        host, port = addr.rsplit(":", 1)
        self.sock = socket.create_connection((host, int(port)))
        self.buf = b""

    def _line(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("the renderer closed the connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode("utf-8", "replace")

    def _bytes(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("the renderer closed the connection")
            self.buf += chunk
        data, self.buf = self.buf[:n], self.buf[n:]
        return data

    def send(self, command):
        """Sends one command; returns (reply line, PNG bytes or None, seconds)."""
        t0 = time.perf_counter()
        self.sock.sendall(command.strip().encode("utf-8") + b"\n")
        reply = self._line()
        data = None
        words = reply.split()
        if words[:3] == ["ok", "frame", "-"] and len(words) >= 7:
            data = self._bytes(int(words[6]))
        return reply, data, time.perf_counter() - t0

    def check(self, command):
        reply, data, dt = self.send(command)
        print(f"> {command}\n{reply}  ({dt * 1000:.0f} ms round trip)")
        if reply.startswith("error"):
            raise SystemExit(1)
        return reply, data


def example(c, save, out_dir, system_id):
    """The scripted example: three galaxy shots, a home system focused, a system shot."""
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.abspath(out_dir)
    shots = []

    def frame(name):
        path = os.path.join(out, name)
        reply, _ = c.check(f"frame {path}")
        # ok frame PATH W H MS
        w = reply.split()
        shots.append((path, f"{w[-3]}x{w[-2]}", w[-1]))

    c.check(f"load {save}")
    c.check("resize 1600 900")
    c.check("view galaxy")
    frame("example_galaxy_1.png")  # the default camera: the whole galaxy from the south, 60 degrees
    c.check("camera 0 0 0 30 35 900")
    frame("example_galaxy_2.png")  # lower, turned 30 degrees
    c.check("camera -100 0 50 200 70 400")
    frame("example_galaxy_3.png")  # closer, from the north, steep
    c.check(f"focus system {system_id}")
    frame("example_focus.png")  # the galaxy camera over the home system
    c.check(f"view system {system_id}")
    frame("example_system.png")  # the system view
    c.check("state")
    print("\nPNGs:")
    for path, size, ms in shots:
        print(f"  {path}  {size}  {ms} ms")


def main(argv):
    addr = os.environ.get("STELLAR_RENDER_ADDR", DEFAULT_ADDR)
    if len(argv) >= 2 and argv[0] == "--addr":
        addr, argv = argv[1], argv[2:]
    if ":" not in addr:
        addr = "127.0.0.1:" + addr
    if not argv:
        print(__doc__)
        return 2
    c = Client(addr)
    if argv[0] == "example":
        if len(argv) < 3:
            print(__doc__)
            return 2
        example(c, argv[1], argv[2], argv[3] if len(argv) > 3 else "401")
    elif argv[0] == "--file":
        with open(argv[1], encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    c.check(line)
    elif argv[0] == "--get":
        _, data = c.check("frame -")
        with open(argv[1], "wb") as f:
            f.write(data or b"")
        print(f"{argv[1]}: {len(data or b'')} bytes")
    else:
        for command in argv:
            c.check(command)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
