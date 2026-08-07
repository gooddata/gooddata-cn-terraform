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

# HCL identifiers allow letters (including non-ASCII), digits, underscores and
# hyphens, and are not lowercase-only. Anything narrower would fall through to
# the raw-line branch below and print the value.
ASSIGN = re.compile(r"^(\s*)((?:#|//)\s*)?([^\W\d][\w-]*)\s*=\s*(.*)$")
# Leading comment marker on the lines of a commented-out block.
LEADING_MARKER = re.compile(r"^\s*(?:#|//)\s?")

OPENERS = "[{("
CLOSERS = "]})"
HEREDOC = re.compile(r"<<-?\s*([A-Za-z_][A-Za-z0-9_]*)")


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


def new_state():
    """Lexer state carried across the lines of one multi-line value."""
    return {"depth": 0, "heredoc": None, "block": False}


def scan_line(line, st):
    """Advance the lexer over one line, updating `st` in place.

    Stateful on purpose: a heredoc body or a `/* */` block comment can contain
    brackets, `#`, or the terminator word, none of which may be mistaken for
    structure. Getting this wrong ends a value early and prints the rest of it.
    """
    if st["heredoc"] is not None:
        if line.strip() == st["heredoc"]:
            st["heredoc"] = None
        return st

    i, n = 0, len(line)
    in_string = escaped = False
    while i < n:
        c = line[i]
        nxt = line[i + 1 : i + 2]

        if st["block"]:
            if c == "*" and nxt == "/":
                st["block"] = False
                i += 2
                continue
            i += 1
            continue

        if in_string:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                in_string = False
            i += 1
            continue

        if c == '"':
            in_string = True
        elif c == "#" or (c == "/" and nxt == "/"):
            return st  # rest of the line is a comment
        elif c == "/" and nxt == "*":
            st["block"] = True
            i += 2
            continue
        elif c == "<" and nxt == "<":
            m = HEREDOC.match(line, i)
            if m:
                st["heredoc"] = m.group(1)
                return st  # heredoc body starts on the next line
            i += 2
            continue
        elif c in OPENERS:
            st["depth"] += 1
        elif c in CLOSERS:
            st["depth"] -= 1
        i += 1
    return st


def incomplete(st):
    """True while the value continues onto further lines."""
    return st["depth"] > 0 or st["heredoc"] is not None or st["block"]


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
            # Backstop: never print a line we failed to parse but that still
            # carries an assignment. Comments and structure pass through as-is.
            code, _ = split_code_and_comment(raw)
            if "=" in code:
                out.append(f"{raw[: len(raw) - len(raw.lstrip())]}<unparsed> = <value>")
            else:
                out.append(raw.rstrip())
            i += 1
            continue

        indent, hashmark, name, value = m.groups()
        commented = hashmark is not None
        names.append((name, not commented))
        _, comment = split_code_and_comment(value)
        suffix = f" {comment.strip()}" if comment.strip() else ""
        marker = hashmark.strip() + " " if commented else ""
        out.append(f"{indent}{marker}{name} = <value>{suffix}")
        i += 1

        # Consume the rest of a multi-line value with one stateful pass, so
        # nested collections, heredoc bodies and block comments all stay
        # redacted no matter what they contain.
        st = new_state()
        scan_line(value, st)
        while incomplete(st) and i < len(lines):
            body = LEADING_MARKER.sub("", lines[i]) if commented else lines[i]
            scan_line(body, st)
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
