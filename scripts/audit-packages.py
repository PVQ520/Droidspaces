#!/usr/bin/env python3
"""
Verify every package name in every template against a package index dump.

  scripts/audit-packages.py --apt    <names-file> [provides-file] [FROM-regex]
  scripts/audit-packages.py --apk    <names-file> [provides-file]
  scripts/audit-packages.py --pacman <names-file>

<names-file>     one real package name per line
<provides-file>  one virtual/provided name per line (optional; apt/apk only)
FROM-regex       only audit templates whose FROM image matches (optional)

How to make the index dumps:

  apt / Ubuntu 26.04:
    curl -sO http://ports.ubuntu.com/ubuntu-ports/dists/resolute/universe/binary-arm64/Packages.gz
    gzip -dc Packages.gz | sed -n 's/^Package: //p' | sort -u > names

  apk / Alpine 3.23:
    tar xzf APKINDEX.tar.gz; sed -n 's/^P://p' APKINDEX | sort -u > names
    sed -n 's/^p://p' APKINDEX | tr ' ' '\\n' | sed 's/=.*//' | sort -u > provides

  pacman / Arch:
    tar tzf core.db extra.db | sed 's|-[^-]*-[^-]*/$||' | sort -u > names

The point of this check: a package name that does not exist does not fail
locally, it fails 20 minutes into a cloud build. Run it after every edit.
"""
import os
import re
import sys

BACKSLASH = chr(92)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TPL = os.path.join(ROOT, "templates", "aarch64")

MARKS = {"--apt": "apt-get install", "--apk": "apk add",
         "--pacman": "pacman -S --noconfirm"}


def load(path):
    if not path:
        return set()
    with open(path, encoding="utf-8") as f:
        return {ln.strip() for ln in f if ln.strip()}


def packages_of(text, mark):
    """Return the package tokens of the first '<mark> ...' block.

    The block starts on a line containing <mark> and continues while each
    physical line ends with a backslash. Lines are de-commented, command flags
    (leading '-') and the command words themselves are dropped.
    """
    lines = text.split("\n")
    out = []
    inblk = False
    for raw in lines:
        if not inblk:
            if mark not in raw:
                continue
            inblk = True
        else:
            pass

        # A pure comment line inside the block is decoration: it carries no
        # packages and must not end the block either.
        if raw.strip().startswith("#"):
            continue

        cont = raw.rstrip().endswith(BACKSLASH)
        body = raw.split("#", 1)[0]
        if mark in body:
            # drop the command itself plus its flags: they are not packages
            body = body.split(mark, 1)[1]
        for tok in body.replace(BACKSLASH, " ").split():
            # flags, shell operators and the cleanup commands that follow the
            # package list are not package names
            if tok.startswith("-") or tok in ("&&", "||", ";", "|"):
                break
            if tok in ("apt-get", "apk", "pacman", "rm", "autoremove",
                       "autoclean", "clean", "upgrade", "update", "install"):
                break
            out.append(tok)
        if not cont:
            break
    return out


def main():
    args = sys.argv[1:]
    if not args or args[0] not in MARKS:
        print(__doc__)
        sys.exit(2)
    eco = args[0]
    mark = MARKS[eco]
    names = load(args[1] if len(args) > 1 else "")
    provides = load(args[2] if len(args) > 2 else "")
    from_filter = args[3] if len(args) > 3 else ""

    if not names:
        print("names file is empty; refusing to report a pass", file=sys.stderr)
        sys.exit(2)

    total = 0
    failures = 0
    for fn in sorted(os.listdir(TPL)):
        if not fn.endswith(".Dockerfile"):
            continue
        path = os.path.join(TPL, fn)
        text = open(path, encoding="utf-8").read()
        if mark not in text:
            continue
        if from_filter:
            m = re.search(r"^FROM\s+(\S+)", text, re.M)
            if not m or not re.search(from_filter, m.group(1)):
                continue

        pkgs = packages_of(text, mark)
        if not pkgs:
            print(f"### {fn}  [{eco}]")
            print("   no packages parsed - PARSER BUG, treat as failure")
            failures += 1
            continue

        print(f"### {fn}  [{eco}]")
        bad = []
        for p in pkgs:
            total += 1
            if p in names or p in provides:
                continue
            bad.append(p)
        if bad:
            for b in bad:
                print(f"   MISSING: {b}")
            failures += 1
        else:
            print(f"   all {len(pkgs)} resolved")

    print()
    if failures:
        print(f"PACKAGE AUDIT FAILED ({failures} template(s), {total} names checked)")
        sys.exit(1)
    print(f"PACKAGE AUDIT PASSED ({total} names checked)")
    sys.exit(0)


if __name__ == "__main__":
    main()
