"""Check resize ownership and restoration without changing a real display."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("desktop_size", Path(__file__).resolve().parents[1] / "scripts" / "desktop-size.py")
display = importlib.util.module_from_spec(spec)
spec.loader.exec_module(display)
baseline = display.read_display("""Screen 0: minimum 320 x 200, current 1280 x 800, maximum 16384 x 16384
eDP connected primary 1280x800+0+0 right (normal left inverted right x axis y axis)
    Transform: 1.000000 0.000000 0.000000
               0.000000 1.000000 0.000000
               0.000000 0.000000 1.000000
DisplayPort-0 disconnected (normal left inverted right x axis y axis)
""")

with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, XDG_RUNTIME_DIR=folder, XAUTHORITY="test-session"):
    state = copy.deepcopy(baseline)
    changes = []

    def apply(next_state):
        global state
        state = copy.deepcopy(next_state)
        changes.append(copy.deepcopy(next_state))

    with patch.object(display, "current", lambda: copy.deepcopy(state)), patch.object(display, "apply", apply), patch.object(display.subprocess, "Popen") as child:
        child.return_value.wait.return_value = 0
        child.return_value.poll.return_value = 0
        assert display.run(1920, 1080, ["capture"]) == 0
        assert changes[0]["fb"] == [1920, 1080]
        assert changes[0]["matrix"][0] == 1.5 and changes[0]["matrix"][4] == 1.35
        assert state == baseline and not (Path(folder) / "deckusb-display.json").exists()
        changes.clear()
        assert display.run(640, 400, ["capture"]) == 0 and not changes
        child.return_value.wait.return_value = 17
        assert display.run(1920, 1200, ["capture"]) == 17 and state == baseline
        # A previous SIGKILL left our exact resize active; recover before reuse.
        enlarged = copy.deepcopy(changes[-2])
        state = enlarged
        (Path(folder) / "deckusb-display.json").write_text(json.dumps({"session": "test-session", "original": baseline, "applied": enlarged}))
        display.run(1280, 800, ["capture"])
        assert state == baseline
        # Do not overwrite a layout the user selected while capture ran.
        def user_change():
            state["fb"] = [1600, 1000]
            return 0
        child.return_value.wait.side_effect = user_change
        display.run(1920, 1200, ["capture"])
        assert state["fb"] == [1600, 1000]
        child.return_value.wait.side_effect = None
        state = copy.deepcopy(baseline)
        # A partially applied XRandR operation must still roll back immediately.
        def partial(next_state):
            apply(next_state)
            if next_state["fb"] == [1920, 1200]:
                raise display.subprocess.CalledProcessError(1, "xrandr")
        with patch.object(display, "apply", partial):
            try:
                display.run(1920, 1200, ["capture"])
                assert False
            except display.subprocess.CalledProcessError:
                pass
        assert state == baseline
print("Desktop resize, aspect ratio, crash recovery, and restoration: PASS")
