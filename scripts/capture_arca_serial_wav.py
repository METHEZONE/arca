#!/usr/bin/env python3
import os
import re
import sys
import termios
import time
from pathlib import Path


def configure(fd, baud=115200):
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = attrs[2] | termios.CLOCAL | termios.CREAD
    attrs[3] = 0
    speed = getattr(termios, f"B{baud}")
    attrs[4] = speed
    attrs[5] = speed
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def read_until(fd, needle, timeout=20):
    data = bytearray()
    deadline = time.time() + timeout
    while time.time() < deadline:
        chunk = os.read(fd, 1)
        if chunk:
            data += chunk
            if needle in data:
                return bytes(data)
        else:
            time.sleep(0.01)
    raise TimeoutError(f"Timed out waiting for {needle!r}; got {data[-200:]!r}")


def read_exact(fd, size, timeout=45):
    data = bytearray()
    deadline = time.time() + timeout
    while len(data) < size and time.time() < deadline:
        chunk = os.read(fd, min(8192, size - len(data)))
        if chunk:
            data += chunk
            print(f"\rread {len(data)}/{size} bytes", end="", flush=True)
        else:
            time.sleep(0.005)
    print()
    if len(data) != size:
        raise TimeoutError(f"Expected {size} bytes, got {len(data)}")
    return bytes(data)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: capture_arca_serial_wav.py /dev/cu.usbmodemXXXX out.wav")
    port = sys.argv[1]
    out = Path(sys.argv[2])
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
    try:
        configure(fd)
        time.sleep(0.5)
        os.write(fd, b"r")
        prelude = read_until(fd, b"ARCA_WAV_BEGIN ", timeout=20)
        line = prelude + read_until(fd, b"\n", timeout=5)
        match = re.search(rb"ARCA_WAV_BEGIN (\d+)", line)
        if not match:
            raise RuntimeError(f"No size marker in {line!r}")
        size = int(match.group(1))
        wav = read_exact(fd, size)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(wav)
        print(f"saved {out} ({len(wav)} bytes)")
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
