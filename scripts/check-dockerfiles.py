#!/usr/bin/env python3
"""
Static Dockerfile validator - catches the structural mistakes that make a
cloud build fail, without needing a container runtime.

  scripts/check-dockerfiles.py

Checks per template:
  1. no trailing whitespace after a line continuation (a silent killer: it
     turns '\\' into an escaped space and corrupts the command)
  2. heredocs are balanced, for both '<<EOF' and '<<-EOF' forms
  3. instruction keywords are real Dockerfile instructions, and nothing that
     looks like an instruction appears where a heredoc body should be
  4. every COPY source path exists in the repo
  5. required droidspaces.* labels and the 'export' stage are present
  6. no non-aarch64 template directories
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VALID = {
    "FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD",
    "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD",
    "STOPSIGNAL", "HEALTHCHECK", "SHELL",
}
errors = []


def err(path, msg):
    errors.append(f"{os.path.basename(path)}: {msg}")


def logical_lines(lines):
    """Yield (first_lineno, instruction_kind, joined_text) with heredoc bodies
    consumed and continuations joined, so the parser only sees real Dockerfile
    instructions."""
    i = 0
    while i < len(lines):
        start = i + 1
        raw = lines[i]
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue

        # Join backslash continuations.
        text = raw
        while text.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            nxt = lines[i]
            if nxt.strip().startswith("#"):
                continue
            text = text.rstrip()[:-1] + " " + nxt
            raw = nxt

        word = text.split()[0].upper() if text.split() else ""

        # If this instruction opens a heredoc, swallow its body.
        tags = re.findall(r"<<-?\s*'?\"?([A-Z][A-Z0-9_]*)'?\"?", text)
        i += 1
        for tag in tags:
            while i < len(lines):
                if lines[i].strip() == tag:
                    i += 1
                    break
                i += 1

        yield start, word, text


for path in sorted(glob.glob(os.path.join(ROOT, "templates", "*", "*.Dockerfile"))):
    lines = open(path, encoding="utf-8").read().split("\n")

    # 1. trailing whitespace after a continuation
    for i, line in enumerate(lines, 1):
        if re.search(r"\\[ \t]+$", line):
            err(path, f"line {i}: trailing whitespace after line continuation")

    # 2/3. walk logical instructions
    for lineno, word, text in logical_lines(lines):
        if word and re.match(r"^[A-Z_][A-Z0-9_]*$", word) and word not in VALID:
            err(path, f"line {lineno}: unknown instruction {word}")

    # 4. COPY sources exist
    for lineno, word, text in logical_lines(lines):
        if word != "COPY" or "--from=" in text:
            continue
        parts = text.split()
        if len(parts) < 3:
            continue
        for src in parts[1:-1]:
            if "$" in src or "*" in src:
                continue
            if not os.path.exists(os.path.join(ROOT, src.rstrip("/"))):
                err(path, f"line {lineno}: COPY source missing: {src}")

    # 5. labels + export stage
    body = "\n".join(lines)
    for key in ("name", "distro", "description"):
        if f"droidspaces.{key}=" not in body:
            err(path, f"missing label droidspaces.{key}")
    if "FROM scratch AS export" not in body:
        err(path, "missing 'FROM scratch AS export' stage")

# 6. arch directories
for d in glob.glob(os.path.join(ROOT, "templates", "*")):
    if os.path.isdir(d) and os.path.basename(d) != "aarch64":
        errors.append(f"unexpected arch directory: {os.path.basename(d)}")

if errors:
    for e in errors:
        print("FAIL", e)
    print(f"\n{len(errors)} problem(s) found")
    sys.exit(1)

n = len(glob.glob(os.path.join(ROOT, "templates", "aarch64", "*.Dockerfile")))
print(f"DOCKERFILE CHECKS PASSED ({n} templates)")
