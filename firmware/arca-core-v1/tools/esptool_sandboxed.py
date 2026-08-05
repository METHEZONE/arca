#!/usr/bin/env python3
"""
Run esptool from a shell where the sandbox denies serial line control.

    python3 tools/esptool_sandboxed.py --chip esp32s3 -p /dev/cu.usbmodem101 \
        --before no_reset --after no_reset write_flash ...

WHAT IS BLOCKED AND WHAT THAT COSTS

  tcsetattr / tcflush / tcdrain   line discipline and buffer flushes.
                                  Meaningless on a USB-CDC endpoint, so making
                                  them no-ops is harmless.
  ioctl(TIOCMBIS/TIOCMBIC)        assert DTR / deassert RTS.
                                  THIS one matters: on the ESP32-S3's native
                                  USB-Serial-JTAG those lines are how esptool
                                  drives the chip into ROM download mode. With
                                  them blocked, esptool reaches the port, sends
                                  the sync frames, and gets silence, because the
                                  application is still running.

  open / read / write on the device are all permitted, so once the chip IS in
  download mode this script can flash it normally.

PUTTING THIS BOARD INTO DOWNLOAD MODE BY HAND

  The ESP32-S3-Touch-LCD-1.83 has no RESET button - PWR goes through the
  AXP2101. So:

      unplug USB-C  ->  hold BOOT  ->  plug USB-C back in  ->  release BOOT

  The chip comes up in download mode. Then flash with --before no_reset
  --after no_reset, and power-cycle afterwards to run the new app.

In an ordinary Terminal none of this is needed: just use ./flash.sh.
"""

import termios, fcntl, sys, runpy


# Every one of these is either a line-discipline tweak or a buffer flush, both
# of which a USB-CDC endpoint does not implement anyway.
def _soften(mod, name):
    real = getattr(mod, name, None)
    if real is None:
        return
    def wrapper(*a, **kw):
        try:
            return real(*a, **kw)
        except Exception:
            return None
    setattr(mod, name, wrapper)

for _fn in ("tcsetattr", "tcflush", "tcdrain", "tcsendbreak", "tcflow"):
    _soften(termios, _fn)
_soft_tcset = termios.tcsetattr

_real_ioctl = fcntl.ioctl
def _soft_ioctl(fd, request, *a, **kw):
    try:
        return _real_ioctl(fd, request, *a, **kw)
    except PermissionError:
        return 0
fcntl.ioctl = _soft_ioctl

import serial.serialposix as sp
for _fn in ("tcsetattr", "tcflush", "tcdrain", "tcsendbreak", "tcflow"):
    if hasattr(sp.termios, _fn):
        setattr(sp.termios, _fn, getattr(termios, _fn))
sp.fcntl.ioctl = _soft_ioctl
sp.Serial._update_dtr_state = lambda self: None
sp.Serial._update_rts_state = lambda self: None

sys.argv = ["esptool"] + sys.argv[1:]
runpy.run_module("esptool", run_name="__main__")
