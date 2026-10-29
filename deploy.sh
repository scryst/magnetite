#!/bin/bash
# Publish the committed site/ tree to the personal, public release repository.
#
# GitHub Pages serves gh-pages while main stays a small release index. The
# payload comes from git, never the working tree, so unfinished local files
# cannot become public. Tests, the local server, and duplicate ZIP files are
# omitted; releases remain the only binary download authority.
#
# Refuses to publish unless HEAD is pushed (an ancestor of, or equal to,
# origin/main) and the GitHub release that install.sh pins exists, is
# published, and carries exactly the bytes the pin names:
#
#   ./deploy.sh            # verify HEAD and the release, publish, verify the public bytes
#   ./deploy.sh --dry-run  # same checks, publish nothing (a failed push or
#                          # release check is a warning here, an error otherwise)
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
command -v gh     >/dev/null || { echo "error: gh not on PATH" >&2; exit 1; }
command -v git    >/dev/null || { echo "error: git not on PATH" >&2; exit 1; }
command -v node   >/dev/null || { echo "error: node not on PATH" >&2; exit 1; }

REF="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short HEAD)"
VERIFY=""
STAGE=""
# Two separate traps. A trapped INT in bash runs the handler and then RESUMES
# the script, so cleanup alone on INT/TERM would delete the scratch folders and
# carry on into a publish. The signal trap only exits; the EXIT trap does the
# cleanup on every way out, including that exit.
cleanup() {
  if [[ -n "$VERIFY" ]]; then
    git worktree remove --force "$VERIFY" 2>/dev/null || rm -rf "$VERIFY"
  fi
  if [[ -n "$STAGE" ]]; then
    rm -rf "$STAGE"
  fi
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM
VERIFY="$(mktemp -d)"
STAGE="$(mktemp -d)"

# A failed push or release check stops a real deploy. A dry run is allowed to
# rehearse before the release exists, so there it only warns.
PREFLIGHT_WARNINGS=0
refuse() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "warning (a real deploy would stop here): $*" >&2
    PREFLIGHT_WARNINGS=1
  else
    echo "error: $*" >&2
    exit 1
  fi
}

# Publishing is from git, so what is published must be what is pushed.
echo "==> checking $SHORT is pushed"
if git fetch --quiet origin +refs/heads/main:refs/remotes/origin/main; then
  # Ancestor-or-equal: origin/main may have moved on, but must never lack HEAD.
  if ! git merge-base --is-ancestor "$REF" refs/remotes/origin/main; then
    refuse "HEAD $SHORT is not on origin/main. Push it first; unpushed commits are never published."
  fi
else
  refuse "could not fetch origin/main to check that $SHORT is pushed."
fi

# The installer pins one release by SHA-256. Publish the installer only if that
# release is real, public, and byte-for-byte what the pin says.
echo "==> checking the pinned release"
INSTALLER="$(git show "$REF:install.sh")"
PIN_VERSION="$(printf '%s\n' "$INSTALLER" | sed -n 's/^PIN_VERSION="\([^"]*\)"$/\1/p')"
PIN_SHA256="$(printf '%s\n' "$INSTALLER" | sed -n 's/^PIN_SHA256="\([^"]*\)"$/\1/p')"
if ! [[ "$PIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$PIN_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  refuse "install.sh at $SHORT has no valid PIN_VERSION/PIN_SHA256 (found '$PIN_VERSION' / '$PIN_SHA256')."
else
  VERSION="$PIN_VERSION"
  if ! APP_VERSION="$(git show "$REF:Resources/Info.plist" | plutil -extract CFBundleShortVersionString raw -o - - 2>/dev/null)"; then
    APP_VERSION=""
  fi
  if [[ "$APP_VERSION" != "$VERSION" ]]; then
    refuse "install.sh pins $VERSION but Resources/Info.plist says '$APP_VERSION'. Stage again with ./build.sh release --stage-release."
  fi
  # The committed archive, from git, not the working tree.
  if ZIP_BLOB="$(git rev-parse --verify --quiet "$REF:site/downloads/Magnetite-$VERSION.zip")"; then
    ZIP_SHA256="$(git cat-file blob "$ZIP_BLOB" | shasum -a 256 | cut -d' ' -f1)"
  else
    ZIP_SHA256="missing"
  fi
  if [[ "$ZIP_SHA256" != "$PIN_SHA256" ]]; then
    refuse "committed site/downloads/Magnetite-$VERSION.zip hashes to $ZIP_SHA256, but install.sh pins $PIN_SHA256."
  fi
  # Draft flag and the zip's digest in one call. A draft is not served at
  # /releases/tags to everyone, so "not found" covers drafts and missing alike.
  if ! RELEASE_ROW="$(gh api "/repos/$REPO/releases/tags/v$VERSION" \
      --jq '[.draft, ([.assets[] | select(.name == "Magnetite-'"$VERSION"'.zip") | .digest] | first // "none")] | @tsv' 2>/dev/null)"; then
    RELEASE_ROW=""
  fi
  if [[ -z "$RELEASE_ROW" ]]; then
    refuse "release v$VERSION was not found in $REPO (or is still a draft). Create it, check its digest, publish it, then deploy."
  else
    RELEASE_DRAFT="${RELEASE_ROW%%$'\t'*}"
    RELEASE_DIGEST="${RELEASE_ROW#*$'\t'}"
    if [[ "$RELEASE_DRAFT" != "false" ]]; then
      refuse "release v$VERSION is still a draft. Publish it first."
    elif [[ "$RELEASE_DIGEST" != "sha256:$PIN_SHA256" ]]; then
      refuse "release v$VERSION's Magnetite-$VERSION.zip digest is '$RELEASE_DIGEST', not 'sha256:$PIN_SHA256' (the committed zip and install.sh's pin)."
    else
      echo "    release v$VERSION is published and its zip digest matches the pin"
    fi
  fi
fi

echo "==> checking committed source $SHORT"
git worktree add --detach --quiet "$VERIFY" "$REF"
(
  cd "$VERIFY"
  node site/test/sitecheck.mjs
)

git archive "$REF:site" | tar -x -C "$STAGE"
rm -rf "$STAGE/test" "$STAGE/downloads"
rm -f "$STAGE/serve.py"
# The installer lives at the repository root, where a clone finds it, and is
# served from the site so the one-line install has a short, stable URL.
git show "$REF:install.sh" > "$STAGE/install.sh"
echo "==> staged $(find "$STAGE" -type f | wc -l | tr -d ' ') public files"

if [[ $DRY_RUN -eq 1 ]]; then
  if [[ $PREFLIGHT_WARNINGS -ne 0 ]]; then
    echo "==> dry run; nothing published (a real deploy would refuse: see warnings above)"
  else
    echo "==> dry run; nothing published"
  fi
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

# The page AND the installer: a deploy that changed only install.sh used to
# "verify" instantly against the old site, since index.html was all it read.
# Both URLs carry the commit as a query string so a CDN or browser cache holding
# the previous deploy cannot answer for this one.
served() {
  local index installer
  index="$(curl -fsSL --max-time 20 "$PROD_URL/?v=$SHORT" | shasum -a 256 | cut -d' ' -f1)" || return 1
  installer="$(curl -fsSL --max-time 20 "$PROD_URL/install.sh?v=$SHORT" | shasum -a 256 | cut -d' ' -f1)" || return 1
  echo "$index+$installer"
}
WANT="$(shasum -a 256 "$STAGE/index.html" | cut -d' ' -f1)+$(shasum -a 256 "$STAGE/install.sh" | cut -d' ' -f1)"
GOT=""
# GitHub Pages can take a couple of minutes: 36 tries, 5 seconds apart.
for _ in {1..36}; do
  if ! GOT="$(served)"; then GOT=""; fi
  [[ "$GOT" == "$WANT" ]] && break
  sleep 5
done

if [[ "$GOT" != "$WANT" ]]; then
  echo "error: GitHub Pages did not serve $SHORT within three minutes" >&2
  echo "  commit  $WANT" >&2
  echo "  serving ${GOT:-unreachable}" >&2
  exit 1
fi

echo "==> verified $PROD_URL at $SHORT ($WANT)"
