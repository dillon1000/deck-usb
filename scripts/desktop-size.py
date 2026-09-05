#!/usr/bin/env python3
"""Run capture with a larger X11 desktop; restore our display change on exit.

Runs as the Deck user. A runtime snapshot also permits recovery after SIGKILL.
Only one internal panel at the origin is supported; external layouts are left
alone. No game configuration or physical display mode is changed.
"""
import fcntl
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


def read_display(text):
    screen = re.search(r"current (\d+) x (\d+)", text)
    outputs = list(re.finditer(r"^(\S+) connected(?: primary)? (\d+)x(\d+)\+0\+0.*$", text, re.M))
    active = re.findall(r"^\S+ connected(?: primary)? \d+x\d+[-+]", text, re.M)
    if not screen or len(outputs) != 1 or len(active) != 1 or not outputs[0][1].startswith("eDP"):
        raise ValueError("Desktop resizing requires one internal Deck panel at position 0,0")
    output = outputs[0]
    transform = re.search(r"Transform:\s+([\d. -]+)\n\s+([\d. -]+)\n\s+([\d. -]+)", text[output.end():])
    matrix = [float(n) for n in " ".join(transform.groups()).split()] if transform else []
    if len(matrix) != 9 or not all(math.isfinite(n) for n in matrix) or matrix[0] <= 0 or matrix[4] <= 0 or any(matrix[i] for i in (1, 2, 3, 5, 6, 7)) or matrix[8] != 1:
        raise ValueError("Desktop resizing requires a simple panel scale")
    return {"output": output[1], "fb": [int(screen[1]), int(screen[2])],
            "size": [int(output[2]), int(output[3])], "matrix": matrix}


def current():
    return read_display(subprocess.check_output(["xrandr", "--verbose"], text=True, timeout=5))


def apply(state):
    subprocess.run(["xrandr", "--output", state["output"], "--transform",
                    ",".join(str(n) for n in state["matrix"]), "--fb",
                    "%dx%d" % tuple(state["fb"])], check=True, timeout=5)


def same_display(a, b):
    return a["output"] == b["output"] and a["fb"] == b["fb"] and all(
        abs(x-y) < 0.0001 for x, y in zip(a["matrix"], b["matrix"]))


def run(width, height, command):
    if width < 2 or height < 2 or width > 1920 or height > 1200 or width % 2 or height % 2 or not command:
        raise ValueError("Expected even dimensions through 1920 × 1200 and a capture command")
    runtime = Path(os.environ["XDG_RUNTIME_DIR"])
    # Capture restarts can overlap runuser's short shutdown period. Serialize
    # their display changes so the old capture cannot undo the new one's size.
    with (runtime / "deckusb-display.lock").open("a") as lock:
        deadline = time.monotonic() + 5
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("The previous desktop capture has not stopped")
                time.sleep(0.05)
        path = runtime / "deckusb-display.json"
        session = os.environ.get("XAUTHORITY", "")
        before = current()
        if path.exists():
            saved = json.loads(path.read_text())
            if saved["session"] == session and same_display(before, saved["applied"]):
                apply(saved["original"])
                before = current()
            path.unlink()  # A changed session or user-selected layout supersedes it.
        target = dict(before)
        target["fb"] = [max(width, before["fb"][0]), max(height, before["fb"][1])]
        target["matrix"] = list(before["matrix"])
        target["matrix"][0] *= target["fb"][0] / before["size"][0]
        target["matrix"][4] *= target["fb"][1] / before["size"][1]
        changed = target["fb"] != before["fb"]
        verified = False
        child = None

        def stop(signum, _frame):
            raise SystemExit(128 + signum)

        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, stop)
        try:
            if changed:
                temporary = path.with_suffix(".next")
                temporary.write_text(json.dumps({"session": session, "original": before, "applied": target}))
                temporary.replace(path)
                apply(target)
                if not same_display(current(), target):
                    raise RuntimeError("The desktop did not accept the requested render size")
                verified = True
                print("Desktop render size: %d × %d" % tuple(target["fb"]), file=sys.stderr)
            child = subprocess.Popen(command)
            return child.wait()
        finally:
            # The supervisor and runuser can both send TERM. Finish restoration
            # before allowing the second signal to end this process.
            for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                signal.signal(sig, signal.SIG_IGN)
            if child and child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            if changed:
                try:
                    if not verified or same_display(current(), target):
                        apply(before)
                    path.unlink(missing_ok=True)
                except (subprocess.SubprocessError, ValueError):
                    print("Display restoration deferred to the next capture.", file=sys.stderr)


if __name__ == "__main__":
    try:
        sys.exit(run(int(sys.argv[1]), int(sys.argv[2]), sys.argv[3:]))
    except (IndexError, ValueError, OSError, subprocess.SubprocessError, RuntimeError) as error:
        print(f"DeckUSB display: {error}", file=sys.stderr)
        sys.exit(1)
