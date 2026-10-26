#!/usr/bin/env python3
"""Fails the build when an error is dropped without being logged.

Swift has no app-wide "uncaught exception" handler for thrown errors: an
error that a `catch` swallows, a `try?` turns into nil, or a `Task { try … }`
never surfaces leaves no trace at all. Every such site must either log
through `Log` (see Packages/Core/Sources/Core/Diagnostics/Log.swift) or
state why dropping it is fine:

1. A `catch` block must log (`Log.`), rethrow (`throw`), hand the error on
   (`finish(throwing:`, `resume(throwing:`), or carry `// nolog: <reason>`.
2. A `try?` is allowed for `Task.sleep` (fails only on cancellation) and
   for `NSRegularExpression` with a literal pattern; anything else needs
   `// nolog: <reason>` on the same line, or `Log.attempt` / `StoredJSON`.
3. A `Task { … }` whose body uses `try` must catch inside it — a throwing
   Task's error is otherwise silently discarded — or, when the Task is
   returned/awaited so its caller gets the error, carry `// nolog:` on the
   line above.

Run by the iOS and macOS targets' build phase; prints Xcode-style
`file:line: error:` so violations show up in the issue navigator.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIRS = ["WebnovelReader", "WebnovelReaderMac", "WebnovelReaderWatch", "Packages/Core/Sources"]
CATCH_HANDLED = re.compile(r"\bLog\.|\bthrow\b|finish\(throwing|resume\(throwing|//\s*nolog:")
TRY_OPTIONAL_ALLOWED = re.compile(r"try\?\s*(await\s+)?Task\.sleep|try\?\s*NSRegularExpression\(pattern:\s*\"")
NOLOG = re.compile(r"//\s*nolog:")


def strip_strings(line):
    """Blank out string literal contents so braces/keywords inside them don't count."""
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', line)


def code_part(line):
    stripped = strip_strings(line)
    i = stripped.find("//")
    return stripped if i < 0 else stripped[:i]


def block_end(lines, row, col):
    """(row, col) of the `{` -> row of the matching `}`."""
    depth = 0
    for r in range(row, len(lines)):
        text = code_part(lines[r])
        start = col if r == row else 0
        for c in range(start, len(text)):
            if text[c] == "{":
                depth += 1
            elif text[c] == "}":
                depth -= 1
                if depth == 0:
                    return r
    return len(lines) - 1


def lint_file(path):
    rel = os.path.relpath(path, ROOT)
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    problems = []
    in_block_comment = False
    for i, raw in enumerate(lines):
        if "/*" in raw:
            in_block_comment = True
        if in_block_comment:
            if "*/" in raw:
                in_block_comment = False
            continue
        code = code_part(raw)
        if raw.strip().startswith("///"):
            continue

        for m in re.finditer(r"\bcatch\b[^{]*\{", code):
            end = block_end(lines, i, m.end() - 1)
            body = "\n".join(lines[i:end + 1])
            body_after_brace = body[body.find("{", m.start()) :]
            if re.match(r"catch\s+is\s+CancellationError", code[m.start():]):
                continue
            if not CATCH_HANDLED.search(body_after_brace):
                problems.append((i + 1, "catch swallows the error without logging it (use Log.error, rethrow, or // nolog: <reason>)"))

        for m in re.finditer(r"try\?", code):
            prev = lines[i - 1] if i > 0 else ""
            if TRY_OPTIONAL_ALLOWED.match(code[m.start():]) or NOLOG.search(raw) or NOLOG.search(prev):
                continue
            problems.append((i + 1, "try? drops the error (use Log.attempt / StoredJSON, or // nolog: <reason>)"))

        for m in re.finditer(r"\bTask(?:\.detached)?(?:\s*\([^)]*\))?\s*\{", code):
            end = block_end(lines, i, m.end() - 1)
            body = "\n".join(code_part(l) for l in lines[i:end + 1])
            body = body[body.find("{", m.start()) :]
            annotated = "\n".join(lines[max(i - 1, 0):end + 1])
            if re.search(r"\btry(?!\?)\b", body) and "catch" not in body and not NOLOG.search(annotated):
                problems.append((i + 1, "Task body uses `try` without catching — a throwing Task discards its error silently"))
    return [(rel, line, msg) for line, msg in problems]


def main():
    problems = []
    for d in DIRS:
        for dirpath, _, files in os.walk(os.path.join(ROOT, d)):
            for name in files:
                if name.endswith(".swift"):
                    problems += lint_file(os.path.join(dirpath, name))
    for rel, line, msg in sorted(problems):
        print(f"{os.path.join(ROOT, rel)}:{line}: error: {msg}")
    if problems:
        print(f"lint-error-handling: {len(problems)} problem(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
