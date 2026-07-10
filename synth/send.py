#!/usr/bin/env python3
# =============================================================================
# PHANTOM-32  --  UART program loader (host side)
# =============================================================================
# Sends a raw program binary to the on-FPGA bootloader (programs/bootloader.S).
# Uses only the standard library (termios), no pyserial needed.
# Close any open `screen` on the port first.
# =============================================================================
import os
import struct
import sys
import termios

def main():
    if len(sys.argv) < 2:
        print("usage: send.py program.bin [/dev/ttyUSB0]")
        return 1
    path = sys.argv[1]
    port = sys.argv[2] if len(sys.argv) > 2 else "/dev/ttyUSB0"

    data = open(path, "rb").read()
    data += b"\x00" * (-len(data) % 4)              # pad to a word boundary
    words = struct.unpack("<%dI" % (len(data) // 4), data)
    csum = sum(words) & 0xFFFFFFFF

    fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
    attr = termios.tcgetattr(fd)
    attr[0] = 0                                     # iflag: raw
    attr[1] = 0                                     # oflag: raw
    attr[2] = termios.CS8 | termios.CREAD | termios.CLOCAL   # cflag: 8-N-1
    attr[3] = 0                                     # lflag: raw
    attr[4] = attr[5] = termios.B115200
    attr[6][termios.VMIN] = 0
    attr[6][termios.VTIME] = 50                     # read timeout: 5 s
    termios.tcsetattr(fd, termios.TCSANOW, attr)
    termios.tcflush(fd, termios.TCIOFLUSH)

    print("waiting for the bootloader prompt '>' (reset the board if needed)...")
    while True:
        b = os.read(fd, 1)
        if not b:
            print("no prompt within 5 s - is the bitstream loaded and the CPU out of reset?")
            return 1
        if b == b">":
            break

    print("sending %s: %d bytes, checksum %08x" % (path, len(data), csum))
    os.write(fd, struct.pack("<I", len(data)))
    os.write(fd, data)
    os.write(fd, struct.pack("<I", csum))
    termios.tcdrain(fd)

    while True:
        b = os.read(fd, 1)
        if not b:
            print("no reply within 5 s - transfer lost?")
            return 1
        if b == b">":                               # stale prompt, keep waiting
            continue
        if b == b"K":
            print("OK - program verified, board is running it :D")
            return 0
        print("bootloader replied %r - checksum mismatch, try again" % b)
        return 1

if __name__ == "__main__":
    sys.exit(main())
