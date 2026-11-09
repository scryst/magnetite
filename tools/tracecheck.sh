#!/bin/bash
# The repository is public. Refuse tracked files and unpushed commits that name a
# person, a private machine or folder, an AI tool, or an internal task ID: such
# names reached the public history once and had to be rewritten out of it.
# The pattern is base64 so this file does not itself carry the names.
# `tools/tracecheck.sh --self-test` proves each part still catches a seeded trace.
set -uo pipefail
cd "$(dirname "$0")/.."
PATTERN="$(printf %s 'bGFrc3xnOTE0fGFudGhyb3BpY3xjbGF1ZGV8bGhhbXJ8aGFtcm96fGFuYWhlaW18cm9sZXBhc3N8KF58W15hLXowLTldKWZsLVswLTldKy1bYS16XXwvVXNlcnMvW0EtWmEtel0=' | base64 -D)"
AUTHOR="scryst@users.noreply.github.com"

# found <rc>: grep's 0 is a hit, 1 is clean, anything else is an error and counts as a hit.
found() { [[ "$1" -ne 1 ]]; }

scan() {  # $1: repository root
  local root="$1" bad=0 range rc
  git -C "$root" grep -nIiE "$PATTERN" -- . >&2; rc=$?
  if found "$rc"; then echo "tracecheck: a tracked file above names a person, machine, AI tool or task ID (grep rc=$rc)" >&2; bad=1; fi
  range="HEAD"
  git -C "$root" rev-parse -q --verify origin/main >/dev/null && range="origin/main..HEAD"
  git -C "$root" log --format='%an <%ae>%n%cn <%ce>%n%B' "$range" | grep -iE "$PATTERN" >&2; rc=$?
  if found "$rc"; then echo "tracecheck: an unpushed commit message above names a person, machine, AI tool or task ID (grep rc=$rc)" >&2; bad=1; fi
  git -C "$root" log --format='%ae%n%ce' "$range" | grep -vxF "$AUTHOR" >&2; rc=$?
  if found "$rc"; then echo "tracecheck: an unpushed commit is authored or committed by someone other than $AUTHOR (grep rc=$rc)" >&2; bad=1; fi
  return "$bad"
}

if [[ "${1:-}" == --self-test ]]; then
  t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
  mk() {
    rm -rf "$t/r"; git init -q "$t/r"
    git -C "$t/r" config user.name scryst; git -C "$t/r" config user.email "$AUTHOR"
    echo ok > "$t/r/a.txt"; git -C "$t/r" add a.txt; git -C "$t/r" commit -qm clean
  }
  word="$(printf %s 'bGFrcw==' | base64 -D)"
  mk; scan "$t/r" 2>/dev/null || { echo "tracecheck self-test: a clean repo was refused" >&2; exit 1; }
  mk; echo "by $word" > "$t/r/b.txt"; git -C "$t/r" add b.txt; git -C "$t/r" commit -qm add
  if scan "$t/r" 2>/dev/null; then echo "tracecheck self-test: a file trace passed" >&2; exit 1; fi
  mk; git -C "$t/r" commit -q --allow-empty -m "fix" -m "Co-Authored-By: $(printf %s 'Q2xhdWRl' | base64 -D) <x@example.com>"
  if scan "$t/r" 2>/dev/null; then echo "tracecheck self-test: a message trace passed" >&2; exit 1; fi
  mk; git -C "$t/r" commit -q --allow-empty -m "Land $(printf %s fl)-18-g-misc-land"
  if scan "$t/r" 2>/dev/null; then echo "tracecheck self-test: a task ID passed" >&2; exit 1; fi
  mk; git -C "$t/r" -c user.email=someone@example.com commit -q --allow-empty -m fix
  if scan "$t/r" 2>/dev/null; then echo "tracecheck self-test: a foreign author passed" >&2; exit 1; fi
  echo "tracecheck self-test: file, message, task-ID and author traces are each refused"
  exit 0
fi

if scan .; then echo "tracecheck: no traces in tracked files or unpushed commits"; else exit 1; fi
