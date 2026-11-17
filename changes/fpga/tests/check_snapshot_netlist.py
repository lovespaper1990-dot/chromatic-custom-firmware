#!/usr/bin/env python3
"""Check the supported Gowin snapshot control wiring in a synthesized .vg file.

This deliberately recognizes the current hierarchical Gowin naming and 17-bit
one-hot state engine. A changed synthesis layout requires manual inspection and
an update to these checks. This is a structural regression check, not a general
Verilog parser or a proof of the complete snapshot implementation.
"""

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys


IDENTIFIER = r"[A-Za-z_][A-Za-z0-9_$]*"
DECLARED_IDENTIFIER = rf"(?:\\[^\s,]+|{IDENTIFIER})"


class AuditError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise AuditError(message)


def layout(condition, message):
    require(condition, f"Unsupported Gowin layout: {message}. Manual inspection required")


def normalized(expression):
    return re.sub(r"\s+", "", expression)


def close_parenthesis(text, opening):
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return index
    raise AuditError("Unsupported Gowin layout: unmatched parentheses. Manual inspection required")


@dataclass
class Instance:
    kind: str
    name: str
    arguments: dict


@dataclass
class Module:
    name: str
    ports: set
    signals: set
    directions: dict
    instances: dict


def parse_module(name, body):
    body = body.strip()
    layout(body.startswith("("), f"module {name} has a changed header")
    header_end = close_parenthesis(body, 0)
    ports = [part.strip() for part in body[1:header_end].split(",")]
    layout(all(re.fullmatch(DECLARED_IDENTIFIER, port) for port in ports),
           f"module {name} has unsupported port names")
    layout(len(ports) == len(set(ports)), f"module {name} has duplicate ports")
    body = body[header_end + 1:].lstrip()
    layout(body.startswith(";"), f"module {name} has a changed port terminator")
    signals = set(ports)
    directions = {}
    for match in re.finditer(r"(?m)^\s*(input|output|inout|wire|reg)\s+([^;]+);", body):
        # Gowin also declares escaped internal names such as \bgpd[1].
        # Strip a packed range only before the names; brackets within an
        # escaped identifier are part of that identifier.
        declaration = match[2].strip()
        declaration = re.sub(r"^(?:(?:wire|reg|signed)\s+)+", "", declaration)
        declaration = re.sub(r"^\[[^\]]+\]\s*", "", declaration)
        names = [part.strip() for part in declaration.split(",")]
        layout(all(re.fullmatch(DECLARED_IDENTIFIER, item) for item in names),
               f"module {name} has an unfamiliar signal declaration")
        signals.update(names)
        if match[1] in ("input", "output", "inout"):
            for item in names:
                directions[item] = match[1]
    layout(set(directions) == set(ports), f"module {name} port declarations do not match its header")

    instances = {}
    pattern = rf"(?m)^\s*({IDENTIFIER})\s+({IDENTIFIER})\s*\("
    for match in re.finditer(pattern, body):
        opening = match.end() - 1
        closing = close_parenthesis(body, opening)
        layout(body[closing + 1:].lstrip().startswith(";"),
               f"module {name}, instance {match[2]} has a changed terminator")
        arguments = {}
        argument_text = body[opening + 1:closing]
        position = 0
        while position < len(argument_text):
            whitespace = re.match(r"\s*", argument_text[position:])[0]
            position += len(whitespace)
            if position == len(argument_text):
                break
            argument = re.match(rf"\.({DECLARED_IDENTIFIER})\s*\(", argument_text[position:])
            layout(argument is not None, f"module {name}, instance {match[2]} uses non-named arguments near "
                   f"{argument_text[position:position + 60]!r}")
            start = position + argument.end() - 1
            end = close_parenthesis(argument_text, start)
            key = argument[1]
            layout(key not in arguments, f"module {name}, instance {match[2]} repeats port {key}")
            arguments[key] = normalized(argument_text[start + 1:end])
            position = end + 1
            position += len(re.match(r"\s*", argument_text[position:])[0])
            if position < len(argument_text):
                layout(argument_text[position] == ",", f"module {name}, instance {match[2]} has changed arguments")
                position += 1
        layout(match[2] not in instances, f"module {name} repeats instance {match[2]}")
        instances[match[2]] = Instance(match[1], match[2], arguments)
    return Module(name, set(ports), signals, directions, instances)


def instance(module, name, kind):
    found = module.instances.get(name)
    layout(found is not None and found.kind == kind,
           f"expected {module.name}.{name} of type {kind}")
    return found


def flip_flop(module, pattern):
    found = [item for item in module.instances.values()
             if item.kind.startswith("DFF") and re.fullmatch(pattern, item.name)]
    layout(len(found) == 1, f"expected one {pattern} flip-flop in {module.name}")
    return found[0]


def pin(item, name):
    layout(name in item.arguments, f"{item.name} lacks pin {name}")
    return item.arguments[name]


def resolve(signal, hierarchy):
    """Resolve a scalar through the actual named instance port connections."""
    layout(re.fullmatch(IDENTIFIER, signal), f"control signal {signal!r} is not scalar")
    for module, parent_instance, path in hierarchy:
        layout(signal in module.signals, f"undeclared signal {path}.{signal}")
        if signal not in module.ports or parent_instance is None:
            return f"{path}.{signal}"
        signal = pin(parent_instance, signal)
        layout(re.fullmatch(IDENTIFIER, signal), f"control port maps to non-scalar {signal!r}")
    raise AuditError("Unsupported Gowin layout: unresolved control hierarchy. Manual inspection required")


def audit(source):
    # Remove comments before recognizing modules, declarations or named pins.
    source = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)
    blocks = {}
    for match in re.finditer(rf"(?ms)^\s*module\s+({IDENTIFIER})\b(.*?)^\s*endmodule\b", source):
        layout(match[1] not in blocks, f"duplicate module {match[1]}")
        blocks[match[1]] = match[2]
    names = ("emu_system_top", "gb", "gb_savestates", "snapshot_control", "speedcontrol", "GBse", "T80")
    layout(all(name in blocks for name in names), "required snapshot hierarchy is missing")
    modules = {name: parse_module(name, blocks[name]) for name in names}
    board = modules["emu_system_top"]
    game = modules["gb"]
    engine = modules["gb_savestates"]
    controller = modules["snapshot_control"]
    clocks = modules["speedcontrol"]
    controller_instance = instance(board, "u_snapshot_control", "snapshot_control")
    game_instance = instance(board, "u_gb", "gb")
    engine_instance = instance(game, "gb_savestates", "gb_savestates")
    clocks_instance = instance(board, "u_speedcontrol", "speedcontrol")
    board_path = [(board, None, "emu_system_top")]
    controller_path = [(controller, controller_instance, "emu_system_top.u_snapshot_control"), *board_path]
    engine_path = [(engine, engine_instance, "emu_system_top.u_gb.gb_savestates"),
                   (game, game_instance, "emu_system_top.u_gb"), *board_path]
    clocks_path = [(clocks, clocks_instance, "emu_system_top.u_speedcontrol"), *board_path]

    abort_ff = flip_flop(controller, r"core_abort_s\d+")
    layout(abort_ff.kind == "DFFRE", f"changed core_abort primitive {abort_ff.kind}")
    abort_net = resolve(pin(abort_ff, "Q"), controller_path)
    errors = []
    for name in ("gb_savestates", "GBse", "T80"):
        timer_signals = sorted(signal for signal in modules[name].signals
                               if re.search(r"secondCounter", signal, re.I))
        if timer_signals:
            errors.append(name + " contains forbidden timer signal(s): " + ", ".join(timer_signals))

    states = [item for item in engine.instances.values()
              if item.kind.startswith("DFF") and re.fullmatch(r"state_\d+_s0", item.name)]
    layout(len(states) == 17 and
           {int(re.fullmatch(r"state_(\d+)_s0", item.name)[1]) for item in states} == set(range(17)),
           "gb_savestates no longer has the supported 17 one-hot state flip-flops")
    sleep = flip_flop(engine, r"sleep_savestates?_s\d+")
    for item in [*states, sleep]:
        layout(item.kind in ("DFFRE", "DFFSE"), f"changed state/sleep primitive {item.kind}")
        reset_pin = "SET" if item.kind == "DFFSE" else "RESET"
        actual = resolve(pin(item, reset_pin), engine_path)
        if actual != abort_net:
            errors.append(f"{item.name}.{reset_pin} resolves to {actual}, expected controller abort {abort_net}")

    frozen = flip_flop(clocks, r"cart_frozen_s\d+")
    layout(frozen.kind == "DFFRE", f"changed cart_frozen primitive {frozen.kind}")
    frozen_data = resolve(pin(frozen, "D"), clocks_path)
    if frozen_data != "emu_system_top.freeze_cart":
        errors.append(f"cart_frozen.D resolves to {frozen_data}, expected emu_system_top.freeze_cart")
    require(not errors, "\n".join(errors))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("netlist", type=Path, help="Gowin evt1_x2.vg synthesis output")
    args = parser.parse_args()
    try:
        source = args.netlist.read_text(encoding="utf-8")
        audit(source)
    except OSError as error:
        print(f"FAIL snapshot netlist: cannot read {args.netlist.name}: {error.strerror}", file=sys.stderr)
        return 1
    except (UnicodeError, AuditError) as error:
        print(f"FAIL snapshot netlist: {error}", file=sys.stderr)
        return 1
    print("PASS synthesized snapshot wiring: controller abort drives 17 state FFs and sleep; "
          "freeze_cart drives cart_frozen; state engine and CPU have no secondCounter")
    return 0


if __name__ == "__main__":
    sys.exit(main())
