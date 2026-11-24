#!/bin/bash
# Local sanity lint for templates: no python needed.
cd "$(dirname "$0")/.." || exit 1
fail=0

for f in templates/aarch64/*.Dockerfile; do
  n=$(basename "$f")
  # 1. required labels
  for k in name distro description; do
    grep -q "droidspaces\.$k=" "$f" || { echo "FAIL $n: missing droidspaces.$k"; fail=1; }
  done
  # 2. export stage present
  grep -q "^FROM scratch AS export" "$f" || { echo "FAIL $n: no export stage"; fail=1; }
  # 3. broken continuation  (backslash + space before newline, or doubled backslash)
  if grep -nE '\\ +$|\\\\.*\\\\$' "$f" >/dev/null 2>&1; then
    echo "FAIL $n: broken line continuation"; grep -nE '\\ +$|\\\\.*\\\\$' "$f"; fail=1
  fi
  # 4. heredoc pairing: every <<'TAG' / <<TAG must be closed by TAG alone
  awk -v file="$n" '
    match($0, /<<-?[ ]*.(EOF_RUN|EOF|EOT|INITEOF|VEOF)./) {
      tag = $0; sub(/.*<<-?[ ]*./, "", tag); sub(/[^A-Z_].*/, "", tag); pend[++p] = tag
    }
    /^(EOF_RUN|EOF|EOT|INITEOF|VEOF)$/ { if (p > 0) { delete pend[p]; p-- } }
    END { if (p > 0) { printf "FAIL %s: unclosed heredoc %s\n", file, pend[p]; exit 1 } }
  ' "$f" || fail=1
  # 5. every COPY source exists
  grep -oE '^COPY scripts/[^ ]+' "$f" | awk '{print $2}' | while read -r src; do
    [ -e "$src" ] || echo "FAIL $n: COPY source missing: $src"
  done
done

# 6. every template is aarch64 only
other=$(find templates -mindepth 1 -maxdepth 1 -type d ! -name aarch64 | wc -l)
[ "$other" -eq 0 ] || { echo "FAIL: extra arch dirs present"; fail=1; }

# 7. archs.json keys match template dirs
for d in templates/*/; do
  a=$(basename "$d")
  grep -q "\"$a\"" archs.json || { echo "FAIL: arch $a not in archs.json"; fail=1; }
done

[ $fail -eq 0 ] && echo "ALL TEMPLATE CHECKS PASSED"
exit $fail
