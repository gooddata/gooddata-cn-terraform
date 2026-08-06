#!/usr/bin/env python3
"""Structure diff between a settings.tfvars.example and a private settings.tfvars.

Every value is redacted to `<value>`, so the output is safe to read and quote:
it surfaces comment drift and missing/extra variables without printing license
keys, Docker Hub tokens, or subscription IDs.

Usage:
    structure_diff.py aws                      # resolves aws/settings.tfvars{.example,}
    structure_diff.py aws azure local          # several envs at once
    structure_diff.py path/to/a.example path/to/b
"""

import difflib
import re
import sys
from pathlib import Path

ASSIGN = re.compile(r"^(\s*)(#\s*)?([a-z_][a-z0-9_]*)\s*=\s*(.*)$")
LEADING_HASH = re.compile(r"^\s*#\s?")

OPENERS = "[{("
CLOSERS = "]})"


def split_code_and_comment(s):
    """Split a line into (code, comment) at the first unquoted `#` or `//`.

    Quote-aware so a `#` inside a string value stays part of the value.
    """
    in_string = escaped = False
    for i, c in enumerate(s):
        if in_string:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
        elif c == "#" or (c == "/" and s[i + 1 : i + 2] == "/"):
            return s[:i], s[i:]
    return s, ""


def depth_delta(code):
    """Net bracket depth change for a line, ignoring brackets inside strings."""
    in_string = escaped = False
    depth = 0
    for c in code:
        if in_string:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
        elif c in OPENERS:
            depth += 1
        elif c in CLOSERS:
            depth -= 1
    return depth


def normalize(text):
    """Redact values and collapse multi-line ones to a single line.

    Multi-line heredocs, lists, and maps are collapsed so the diff stays about
    structure. A commented-out assignment keeps its `#` because commenting a
    variable out is itself a meaningful structural difference. A trailing
    comment survives: it is the developer's rationale, which is exactly the
    kind of drift this diff exists to surface.
    """
    lines = text.splitlines()
    out, names = [], []
    i = 0
    while i < len(lines):
        raw = lines[i]
        m = ASSIGN.match(raw)
        if not m:
            out.append(raw.rstrip())
            i += 1
            continue

        indent, hashmark, name, value = m.groups()
        commented = hashmark is not None
        names.append((name, not commented))
        code, comment = split_code_and_comment(value)
        code = code.strip()
        suffix = f" {comment.strip()}" if comment.strip() else ""
        out.append(f"{indent}{'# ' if commented else ''}{name} = <value>{suffix}")
        i += 1

        if code.startswith("<<"):
            term = (code.lstrip("<-").split() or ["EOT"])[0]
            while i < len(lines) and lines[i].lstrip("# ").strip() != term:
                i += 1
            i += 1  # consume the terminator
            continue

        # Consume the rest of a multi-line collection by tracking bracket depth,
        # so nested maps/lists and openers with trailing comments stay redacted.
        depth = depth_delta(code)
        while depth > 0 and i < len(lines):
            body = LEADING_HASH.sub("", lines[i]) if commented else lines[i]
            depth += depth_delta(split_code_and_comment(body)[0])
            i += 1

    return out, names


def resolve(arg):
    p = Path(arg)
    if p.is_dir():
        return p / "settings.tfvars.example", p / "settings.tfvars"
    return None


def report(example, private):
    print(f"\n{'=' * 72}\n{example} -> {private}\n{'=' * 72}")
    for f in (example, private):
        if not f.exists():
            print(f"MISSING: {f}")
            return

    ex_lines, ex_names = normalize(example.read_text())
    pv_lines, pv_names = normalize(private.read_text())

    diff = list(
        difflib.unified_diff(
            ex_lines, pv_lines, fromfile=str(example), tofile=str(private), lineterm="", n=2
        )
    )
    print("\n".join(diff) if diff else "(structure identical)")

    ex_set = {n for n, _ in ex_names}
    pv_set = {n for n, _ in pv_names}
    only_example = sorted(ex_set - pv_set)
    only_private = sorted(pv_set - ex_set)
    set_in_private = sorted(n for n, is_set in pv_names if is_set)

    print(f"\nIn EXAMPLE, absent from PRIVATE (must be added): {only_example or 'none'}")
    print(f"In PRIVATE, absent from EXAMPLE (deliberate overrides, keep): {only_private or 'none'}")
    print(f"Actively set in PRIVATE ({len(set_in_private)}): {set_in_private}")


def main(argv):
    if not argv:
        print(__doc__)
        return 1

    pairs = []
    if len(argv) == 2 and all(resolve(a) is None for a in argv):
        pairs.append((Path(argv[0]), Path(argv[1])))
    else:
        for a in argv:
            pair = resolve(a)
            if pair is None:
                print(f"not a directory, and not a two-path invocation: {a}")
                return 1
            pairs.append(pair)

    for example, private in pairs:
        report(example, private)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
