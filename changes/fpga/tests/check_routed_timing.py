#!/usr/bin/env python3
"""Check the current Gowin plain-text static timing report before copying a bitstream."""

import argparse
from decimal import Decimal
from pathlib import Path
import re
import sys


def check(report):
    lines = report.splitlines()

    def heading(name):
        if lines.count(name) != 1:
            raise ValueError(f"missing or duplicated {name}")
        return lines.index(name)

    def field(name):
        prefix = f"<{name}>:"
        values = [line[len(prefix):].strip() for line in lines if line.startswith(prefix)]
        if len(values) != 1:
            raise ValueError(f"missing or duplicated {name}")
        return values[0]

    if field("Part Number") != "GW5A-EV25UG256CC1/I0" or field("Device Version") != "A":
        raise ValueError("unexpected target device")
    for name in ("Paths Analyzed", "Endpoints Analyzed", "Setup Violated Endpoints", "Hold Violated Endpoints"):
        value = field(f"Numbers of {name}")
        if not re.fullmatch(r"[0-9]+", value):
            raise ValueError(f"invalid {name}: {value}")
        if name.endswith("Analyzed") and int(value) == 0:
            raise ValueError(f"{name}: {value}")
        if "Violated" in name and int(value) != 0:
            raise ValueError(f"{name}: {value}")

    tables = [f"3.1.{n} {kind} Paths Table" for n, kind in enumerate(
        ("Setup", "Hold", "Recovery", "Removal"), 1)]
    tables += ["3.2 Minimum Pulse Width Table", "3.3 Timing Report By Analysis Type"]
    indices = [heading(name) for name in tables]
    if indices != sorted(indices) or heading("3.8 Timing Constraints Report") <= indices[-1]:
        raise ValueError("incomplete timing report")
    minima = []
    for name, begin, end in zip(tables, indices, indices[1:]):
        section = [line.strip() for line in lines[begin + 1:end] if line.strip()]
        if len(section) < 4 or "Slack" not in section[1] or not re.fullmatch(r"[= ]+", section[2]):
            raise ValueError(f"missing rows in {name}")
        slacks = []
        for number, row in enumerate(section[3:], 1):
            columns = row.split()
            if (len(columns) < 3 or columns[0] != str(number)
                    or not re.fullmatch(r"[+-]?[0-9]+\.[0-9]+", columns[1])):
                raise ValueError(f"invalid row {number} in {name}")
            slack = Decimal(columns[1])
            if slack.is_signed():  # A displayed -0.000 can be a rounded violation.
                raise ValueError(f"{name}: negative slack {slack} ns")
            slacks.append(slack)
        worst = min(slacks)
        minima.append(str(worst))
    return minima


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    try:
        worst = check(args.report.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        sys.exit(f"FAIL routed timing: {error}")
    print("PASS routed timing (setup/hold/recovery/removal/min-pulse ns): " + " / ".join(worst))
