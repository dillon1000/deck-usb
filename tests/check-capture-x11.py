"""Hardware check on an X11 Deck: frame bounds, fallback, and shared-memory cleanup.

Run with DISPLAY/XAUTHORITY set: python3 check-capture-x11.py BINARY WIDTH HEIGHT.
Reads three frames without saving their contents. Does not change the display.
"""
import os
from pathlib import Path
import subprocess
import sys
import time

binary, width, height = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
command = [binary, str(width), str(height), '60']
result = subprocess.run([*command, '3'], capture_output=True, timeout=5)
assert result.returncode == 0, result.stderr
assert len(result.stdout) == width * height * 3 // 2 * 3
result = subprocess.run([binary, str(width+2), str(height), '60', '1'], capture_output=True, timeout=5)
assert result.returncode == 75 and not result.stdout
result = subprocess.run([*command, '1'], env={**os.environ, 'DISPLAY': ':999'}, capture_output=True, timeout=5)
assert result.returncode == 75 and not result.stdout
for args in (['0','2','60'], ['3','2','60'], ['2x','2','60'], ['2','2','0']):
    assert subprocess.run([binary, *args], capture_output=True).returncode == 1

def segments(pid):
    lines = Path('/proc/sysvipc/shm').read_text().splitlines()
    return [r for line in lines[1:] if (r := dict(zip(lines[0].split(), line.split())))['cpid'] == str(pid)]

for killed in (False, True):
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 3
        while not segments(process.pid) and time.monotonic() < deadline:
            assert process.poll() is None
            time.sleep(.05)
        assert segments(process.pid)
        process.kill() if killed else process.terminate()
        process.wait(timeout=3)
        deadline = time.monotonic() + 3
        while segments(process.pid) and time.monotonic() < deadline:
            time.sleep(.05)
        assert not segments(process.pid)
    finally:
        if process.poll() is None:
            process.kill(); process.wait()
print('X11 capture: frame length, unsupported layouts, input bounds, TERM and KILL cleanup: PASS')
