#!/usr/bin/env python3
"""Launch the built app against a pseudo-terminal (standing in for the LED controller) and
check that it lights the strip, then goes dark when terminated — the path taken on logout,
shutdown and `kill`. Briefly shows the menu-bar icon; touches none of your saved settings.

Usage: tests/quit_test.py [path/to/Lumicast.app]
"""
import os, pty, select, signal, subprocess, sys, time, tty

app = sys.argv[1] if len(sys.argv) > 1 else "Lumicast.app"
binary = os.path.join(app, "Contents/MacOS/Lumicast")
COLOR, BRIGHTNESS = (255, 150, 80), 1.0


def lut(v):  # same gamma + brightness curve as gammaLUT() in Core.swift
    return int(max(0.0, min(255.0, (v / 255.0) ** 2.2 * 255.0 * BRIGHTNESS)))


master, slave = pty.openpty()
tty.setraw(slave)
# "-key value" arguments override saved settings for this run only (nothing is written back).
proc = subprocess.Popen([binary, "-port", os.ttyname(slave), "-mode", "solid", "-grb", "NO",
                         "-solidR", str(COLOR[0]), "-solidG", str(COLOR[1]), "-solidB", str(COLOR[2]),
                         "-brightness", str(BRIGHTNESS)])
data, start, killed_at = b"", time.time(), None
while True:
    if select.select([master], [], [], 0.1)[0]:
        data += os.read(master, 65536)
    now = time.time()
    if killed_at is None and now - start > 2.0:
        proc.send_signal(signal.SIGTERM)
        killed_at = now
    if killed_at and (proc.poll() is not None and now - killed_at > 0.5 or now - killed_at > 5):
        break

problems = []
if proc.poll() is None:
    proc.kill()
    problems.append("app did not exit within 5 s of SIGTERM")
elif proc.returncode != 0:
    problems.append(f"exit status {proc.returncode}, expected 0")

if data[:4] != b"Ada\x00":
    problems.append(f"stream does not start with the Ada header: {data[:8]!r}")
else:
    n = (data[4] << 8) | data[5]
    size = 6 + n * 3
    frames = [data[i:i + size] for i in range(0, len(data), size)]
    if len(data) % size or any(f[:6] != data[:6] for f in frames):
        problems.append("stream is not a clean sequence of header + payload frames")
    else:
        lit, last = frames[:-1], frames[-1]
        want = bytes([lut(c) for c in COLOR]) * n
        if len(lit) < 15:
            problems.append(f"only {len(lit)} frames in 2 s")
        if any(f[6:] != want for f in lit):
            problems.append("a lit frame did not carry the configured solid color")
        if any(last[6:]):
            problems.append("final frame before exit was not black")
        print(f"{n} LEDs, {len(lit)} lit frames, then a black frame; exit status {proc.returncode}")

print("FAIL: " + "; ".join(problems) if problems else "PASS: lights on while running, dark on terminate")
sys.exit(1 if problems else 0)
