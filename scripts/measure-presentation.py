#!/usr/bin/env python3
"""Check --trace-present output and summarize each display-sync setting.

Use a fixed stream and window size. Keep the viewer visible during each run.
The last 20 seconds of each setting exclude its first second after switching.
This measures Mac receipt to presentation, not input-to-photon latency.
"""
import argparse
import json
import math
import statistics
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("log", type=Path)
parser.add_argument("--initial-sync", choices=("on", "off"), default="on",
                    help="Initial mode for older traces without a startup marker")
args = parser.parse_args()
phases = [{"display_sync": args.initial_sync, "samples": []}]
for line in args.log.read_text().splitlines():
    if line.startswith("Display sync: "):
        mode = line.rsplit(" ", 1)[1]
        assert mode in ("on", "off"), "Unknown display-sync setting"
        if phases[-1]["samples"] or mode != phases[-1]["display_sync"]:
            phases.append({"display_sync": mode, "samples": []})
    elif line.startswith("Present: "):
        row = list(map(float, line.split()[1:]))
        assert len(row) == 5 and all(map(math.isfinite, row)), "Malformed frame timing"
        assert row[1] <= row[2] <= row[3] <= row[4], "Frame clocks moved backward"
        phases[-1]["samples"].append(row)

results = []
for phase in phases:
    rows = sorted(phase["samples"], key=lambda row: row[4])
    if not rows:
        continue
    # Drop transition frames already submitted under the previous setting.
    cutoff = max(rows[0][4] + 1, rows[-1][4] - 20)
    rows = [row for row in rows if row[4] >= cutoff]
    if len(rows) < 300:
        continue
    seconds = rows[-1][4] - rows[0][4]
    assert seconds > 0, "No presentation interval"
    metrics = {}
    for name, first, last in (("receive_to_render_ms", 1, 2), ("encode_ms", 2, 3),
                              ("submit_to_display_ms", 3, 4), ("receive_to_display_ms", 1, 4)):
        values = sorted((row[last] - row[first]) * 1000 for row in rows)
        metrics[name] = {"median": statistics.median(values), "p95": values[int((len(values)-1)*.95)]}
    results.append({"display_sync": phase["display_sync"], "frames": len(rows),
                    "seconds": seconds, "displayed_fps": (len(rows)-1)/seconds, "metrics": metrics})
assert results, "No setting has at least 300 usable presented frames"
print(json.dumps({"source": str(args.log), "phases": results}, indent=2))
