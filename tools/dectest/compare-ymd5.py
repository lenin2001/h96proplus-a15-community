#!/usr/bin/env python3
"""Strictly compare saved PTS / Y-plane MD5 / geometry records (not UV)."""
import argparse
import json
from pathlib import Path
import re
import sys


def read_frames(path):
    frames = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        fields = line.split()
        if (len(fields) != 3 or not re.fullmatch(r"-?\d+", fields[0])
                or not re.fullmatch(r"[0-9a-fA-F]{32}", fields[1])
                or not re.fullmatch(r"[1-9]\d*x[1-9]\d*", fields[2])):
            raise ValueError(f"{path}:{number}: malformed frame record")
        pts = int(fields[0])
        if pts in frames:
            raise ValueError(f"{path}:{number}: duplicate PTS {pts}")
        frames[pts] = (fields[1].lower(), fields[2])
    if not frames:
        raise ValueError(f"{path}: no frames; empty runs cannot pass")
    return frames


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hw", type=Path)
    parser.add_argument("sw", type=Path)
    parser.add_argument("--expected-frames", required=True, type=int)
    args = parser.parse_args()
    if args.expected_frames < 1:
        parser.error("--expected-frames must be positive")
    try:
        hw, sw = read_frames(args.hw), read_frames(args.sw)
    except (OSError, ValueError) as error:
        print(f"INVALID: {error}", file=sys.stderr)
        return 2
    only_hw, only_sw = sorted(hw.keys() - sw.keys()), sorted(sw.keys() - hw.keys())
    shared = hw.keys() & sw.keys()
    bad_y = sorted(p for p in shared if hw[p][0] != sw[p][0])
    bad_size = sorted(p for p in shared if hw[p][1] != sw[p][1])
    passed = (len(hw) == len(sw) == args.expected_frames
              and not (only_hw or only_sw or bad_y or bad_size))
    print(json.dumps({
        "result": "PASS_Y_ONLY" if passed else "FAIL",
        "expected_frames": args.expected_frames,
        "hw_frames": len(hw), "sw_frames": len(sw),
        "missing_in_sw": len(only_hw), "missing_in_hw": len(only_sw),
        "y_mismatches": len(bad_y), "geometry_mismatches": len(bad_size),
        "first_problem_pts": sorted(set(only_hw + only_sw + bad_y + bad_size))[:12],
    }, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
