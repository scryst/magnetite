#!/bin/bash
# Publish the committed site/ tree to the personal, public release repository.
#
# GitHub Pages serves gh-pages while main stays a small release index. The
# payload comes from git, never the working tree, so unfinished local files
# cannot become public. Tests, the local server, and duplicate ZIP files are
# omitted; releases remain the only binary download authority.
#
#   ./deploy.sh            # verify HEAD, publish, then verify public bytes
#   ./deploy.sh --dry-run  # verify and stage, publish nothing
set -euo pipefail

cd "$(dirname "$0")"

REPO="scryst/magnetite-releases"
REMOTE="https://github.com/$REPO.git"
PROD_URL="https://magnetite.app"

DRY_RUN=0
case $# in
  0) ;;
  1)
    if [[ "$1" == "--dry-run" ]]; then
      DRY_RUN=1
    else
      echo "error: unknown argument '$1'" >&2
      echo "  usage: ./deploy.sh [--dry-run]" >&2
      exit 2
    fi
    ;;
  *)
    echo "error: expected at most one argument, got $#" >&2
    echo "  usage: ./deploy.sh [--dry-run]" >&2
    exit 2
    ;;
esac

command -v gh-axi >/dev/null || { echo "error: gh-axi not on PATH" >&2; exit 1; }
command -v git    >/dev/null || { echo "error: git not on PATH" >&2; exit 1; }
command -v node   >/dev/null || { echo "error: node not on PATH" >&2; exit 1; }

REF="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short HEAD)"
VERIFY="$(mktemp -d)"
STAGE="$(mktemp -d)"
cleanup() {
  git worktree remove --force "$VERIFY" 2>/dev/null || rm -rf "$VERIFY"
  rm -rf "$STAGE"
}
trap cleanup EXIT INT TERM

echo "==> checking committed source $SHORT"
git worktree add --detach --quiet "$VERIFY" "$REF"
(
  cd "$VERIFY"
  node site/test/portcheck.mjs
  node site/test/bandscheck.mjs
)

git archive "$REF:site" | tar -x -C "$STAGE"
rm -rf "$STAGE/test" "$STAGE/downloads"
rm -f "$STAGE/serve.py"
# The installer lives at the repository root, where a clone finds it, and is
# served from the site so the one-line install has a short, stable URL.
git show "$REF:install.sh" > "$STAGE/install.sh"
echo "==> staged $(find "$STAGE" -type f | wc -l | tr -d ' ') public files"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "==> dry run; nothing published"
  exit 0
fi

REMOTE_HEAD="$(git ls-remote "$REMOTE" refs/heads/gh-pages | cut -f1)"
git -C "$STAGE" init -b gh-pages --quiet
git -C "$STAGE" add .
git -C "$STAGE" commit --quiet -m "Publish Magnetite site from $SHORT"
git -C "$STAGE" remote add origin "$REMOTE"

if [[ -n "$REMOTE_HEAD" ]]; then
  # The global pre-push guard scans REMOTE_HEAD..HEAD. This publish repo starts
  # from a fresh root commit, so fetch the advertised old tip before pushing;
  # otherwise Git cannot resolve the range and the secret scan can fail open.
  git -C "$STAGE" fetch --quiet --depth=1 origin "$REMOTE_HEAD"
  git -C "$STAGE" push --quiet \
    --force-with-lease="refs/heads/gh-pages:$REMOTE_HEAD" origin HEAD:gh-pages
else
  git -C "$STAGE" push --quiet origin HEAD:gh-pages
fi
echo "==> published gh-pages from $SHORT"

if gh-axi api "/repos/$REPO/pages" >/dev/null 2>&1; then
  gh-axi api PUT "/repos/$REPO/pages" \
    --field 'source[branch]=gh-pages' --field 'source[path]=/' \
    --field 'cname=magnetite.app' >/dev/null
else
  gh-axi api POST "/repos/$REPO/pages" \
    --field 'source[branch]=gh-pages' --field 'source[path]=/' \
    --field 'cname=magnetite.app' >/dev/null
fi

WANT="$(shasum -a 256 "$STAGE/index.html" | cut -d' ' -f1)"
GOT=""
for _ in {1..12}; do
  if curl -fsSL --max-time 20 "$PROD_URL/" -o "$STAGE/.served-index.html"; then
    GOT="$(shasum -a 256 "$STAGE/.served-index.html" | cut -d' ' -f1)"
    [[ "$GOT" == "$WANT" ]] && break
  fi
  sleep 5
done

if [[ "$GOT" != "$WANT" ]]; then
  echo "error: GitHub Pages did not serve $SHORT within one minute" >&2
  echo "  commit  $WANT" >&2
  echo "  serving ${GOT:-unreachable}" >&2
  exit 1
fi

echo "==> verified $PROD_URL at $SHORT ($WANT)"
