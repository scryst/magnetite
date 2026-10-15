#!/bin/bash
# Sandboxed test of install.sh. Nothing real is touched: curl, lsappinfo, open
# (and, for two cases, mv, id, sysctl and sw_vers) are shims on a private PATH,
# the "release" is a tiny ad-hoc-signed app zipped here, and the install folder
# and HOME are throwaway directories. The real codesign, lipo, ditto, shasum and
# PlistBuddy do run, because they are what the installer relies on.
#
#   tools/installcheck.sh              run every case against install.sh
#   tools/installcheck.sh --mutations  prove each case notices its regression:
#                                      break temporary copies of install.sh and
#                                      require the matching case to fail
#   INSTALL_SH=<file>                  test another copy of the installer
#   INSTALLCHECK_ONLY="a b"            run only the named cases
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-$REPO/install.sh}"
VERSION=0.1.3
OTHER_VERSION=0.0.9

if [[ "${1:-}" == "--mutations" ]]; then
  MODE=mutations
elif [[ $# -gt 0 ]]; then
  echo "usage: tools/installcheck.sh [--mutations]" >&2; exit 2
else
  MODE=run
fi

T="$(mktemp -d /private/tmp/magnetite-installcheck.XXXXXX)"
cleanup() {
  # Only literal pids we started, and only while they still look like our sleeper.
  if [[ -f "$T/allpids" ]]; then
    while read -r p; do
      [[ -n "$p" ]] || continue
      case "$(ps -o command= -p "$p" 2>/dev/null)" in
        "sleep 25") kill "$p" 2>/dev/null ;;
      esac
    done < "$T/allpids"
  fi
  rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1${2:+ -- $2}"; }
check() { # check <label> <command...>
  local label="$1"; shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

# ---------------------------------------------------------------- mutations --
if [[ "$MODE" == mutations ]]; then
  bad=0
  # mutate <label> <case that must then fail> <text in install.sh> <replacement>
  mutate() {
    cp "$INSTALL_SH" "$T/mutant.sh"
    FROM="$3" TO="$4" perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/ or die "pattern not found\n"' "$T/mutant.sh" 2>/dev/null \
      || { echo "  FAIL mutation did not apply: $1"; bad=$((bad + 1)); return; }
    judge "$1" "$2" "$T/mutant.sh"
  }
  judge() { # <label> <case> <mutated file>
    if INSTALL_SH="$3" INSTALLCHECK_ONLY="$2" "$0" >"$T/mutant.out" 2>&1; then
      echo "  FAIL NOT caught: $1  (case $2 still passed)"; bad=$((bad + 1))
    else
      echo "  ok   caught: $1  (case $2 failed)"
    fi
  }
  mutate "pin ignored: digest taken from the download itself" checksum_mismatch \
    'EXPECTED="$PIN_SHA256"' 'EXPECTED="$ACTUAL"'
  mutate "checksum comparison removed" checksum_mismatch \
    '[ "$EXPECTED" != "$ACTUAL" ]' 'false'
  mutate "bundle verification skipped" bundle_checks \
    'verify_bundle "$SOURCE_APP" "$EXPECT_VERSION"' ':'
  mutate "old app not restored by the EXIT trap" trap_restore \
    '[ ! -e "${TARGET:-}" ]' 'false'
  mutate "running copy never signalled" running_copy \
    'kill -TERM "$PID" 2>/dev/null || true' ':'
  mutate "no rollback when the new app does not start" launch_failure \
    '[ "$LAUNCHED" -eq 0 ] && [ "$UPDATING" -eq 1 ]' 'false'
  mutate "existing ~/Applications copy ignored (second copy installed)" update_in_place \
    'elif [ -e "$HOME/Applications/$APP" ]' 'elif false'
  mutate "Intel Macs not refused" machine_checks \
    '[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]' 'true'
  mutate "sudo not refused" machine_checks '[ "$(id -u)" -ne 0 ]' 'true'
  mutate "SIGTERM no longer ends the run" signal "trap 'exit 130' INT TERM" ':'
  # Not wrapped in main(): a cut-off download would run whatever arrived.
  cp "$INSTALL_SH" "$T/mutant.sh"
  if perl -0pi -e 's/^main\(\) \{\n//m or die; s/^\}\n\nmain "\$\@"\n\z//m or die' "$T/mutant.sh" 2>/dev/null; then
    judge "script not wrapped in main()" truncated "$T/mutant.sh"
  else
    echo "  FAIL mutation did not apply: script not wrapped in main()"; bad=$((bad + 1))
  fi
  if [[ $bad -eq 0 ]]; then echo "installcheck --mutations: every regression was caught"; exit 0; fi
  echo "installcheck --mutations: $bad mutation(s) went unnoticed" >&2; exit 1
fi

# ------------------------------------------------------------------ fixtures --
mkdir -p "$T/shim" "$T/fake" "$T/zips" "$T/home" "$T/tmp" "$T/bin"
: > "$T/allpids"

echo 'int main(void) { return 0; }' > "$T/bin/main.c"
cc -arch arm64  -o "$T/bin/arm64"  "$T/bin/main.c" || { echo "cannot compile arm64 fixture" >&2; exit 1; }
cc -arch x86_64 -o "$T/bin/x86_64" "$T/bin/main.c" || { echo "cannot compile x86_64 fixture" >&2; exit 1; }

# mkapp <name> <bundle id> <version> <arch> <tamper 0|1>
mkapp() {
  local d="$T/build/$1/Magnetite.app"
  mkdir -p "$d/Contents/MacOS"
  cp "$T/bin/$4" "$d/Contents/MacOS/Magnetite"
  cat > "$d/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleShortVersionString</key><string>$3</string>
<key>CFBundleExecutable</key><string>Magnetite</string>
</dict></plist>
PLIST
  codesign --force --deep --sign - "$d" >/dev/null 2>&1 || { echo "cannot sign fixture $1" >&2; exit 1; }
  [[ "$5" == 1 ]] && printf 'x' >> "$d/Contents/MacOS/Magnetite"
  ditto -c -k --keepParent --sequesterRsrc "$d" "$T/zips/$1.zip" || { echo "cannot zip fixture $1" >&2; exit 1; }
}
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

mkapp good        com.laks.magnetite $VERSION       arm64  0
mkapp other       com.laks.magnetite $OTHER_VERSION arm64  0
mkapp wrongid     com.example.other  $VERSION       arm64  0
mkapp wrongver    com.laks.magnetite 9.9.9          arm64  0
mkapp intel       com.laks.magnetite $VERSION       x86_64 0
mkapp tampered    com.laks.magnetite $VERSION       arm64  1
GOOD_SHA="$(sha "$T/zips/good.zip")"
# A second, different, perfectly valid archive: what a swapped download looks like.
SWAP_ZIP="$T/zips/swapped.zip"; cp "$T/zips/other.zip" "$SWAP_ZIP"

# --------------------------------------------------------------------- shims --
cat > "$T/shim/curl" <<'SH'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    --proto|--connect-timeout|--max-time|--retry) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
echo "curl $url" >> "$FAKE_LOG"
case "$url" in
  *.zip) src="${FAKE_ZIP:-}" ;;
  *.sha256) src="${FAKE_SHA256_FILE:-}" ;;
  *) exit 22 ;;
esac
[ -n "$src" ] && [ -f "$src" ] || exit 22
cp "$src" "$out"
SH
cat > "$T/shim/lsappinfo" <<'SH'
#!/bin/sh
# Shape of the real tool: `find` prints an ASN, `info -only pid <asn>` a pid line.
echo "lsappinfo $*" >> "$FAKE_LOG"
pid=""; [ -f "$FAKE_DIR/pid" ] && pid="$(cat "$FAKE_DIR/pid")"
alive() { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
case "$1" in
  find) alive && echo 'ASN:0x0-0x1234-"Magnetite":' ;;
  info) alive && printf '    pid = %s !cgsConnection\n' "$pid" ;;
esac
exit 0
SH
cat > "$T/shim/open" <<'SH'
#!/bin/sh
echo "open $*" >> "$FAKE_LOG"
[ -z "${FAKE_OPEN_FAIL:-}" ] || exit 0
# "Launching" is a real process, so the installer's liveness check is real.
pid="$(sh -c '(exec sleep 25) >/dev/null 2>&1 & echo $!')"
echo "$pid" > "$FAKE_DIR/pid"
echo "$pid" >> "$FAKE_ALLPIDS"
[ -z "${FAKE_OPEN_KILLS_PARENT:-}" ] || kill -TERM "$PPID"
exit 0
SH
cat > "$T/shim/mv" <<'SH'
#!/bin/sh
case "${FAKE_MV_FAIL:-}$*" in
  1*.Magnetite.app.new*) exit 1 ;;
esac
exec /bin/mv "$@"
SH
cat > "$T/shim/id" <<'SH'
#!/bin/sh
[ -n "${FAKE_ID:-}" ] && { echo "$FAKE_ID"; exit 0; }
exec /usr/bin/id "$@"
SH
cat > "$T/shim/sysctl" <<'SH'
#!/bin/sh
[ -n "${FAKE_SYSCTL:-}" ] && { echo "$FAKE_SYSCTL"; exit 0; }
exec /usr/sbin/sysctl "$@"
SH
cat > "$T/shim/sw_vers" <<'SH'
#!/bin/sh
[ -n "${FAKE_SWVERS:-}" ] && { echo "$FAKE_SWVERS"; exit 0; }
exec /usr/bin/sw_vers "$@"
SH
chmod +x "$T/shim"/*

# ------------------------------------------------------------------ harness --
OUT="$T/out"
reset() { # reset <dest>: fresh install folder, fake state and log
  rm -rf "$1" "$T/fake" "$T/home" "$T/tmp" "$T/sysapps"; mkdir -p "$1" "$T/fake" "$T/home" "$T/tmp" "$T/sysapps"
  : > "$T/fake/log"
}
seed_old() { mkdir -p "$1/Magnetite.app/Contents"; echo old > "$1/Magnetite.app/Contents/OLDMARK"; }
old_intact() { [[ -f "$1/Magnetite.app/Contents/OLDMARK" ]]; }
dest_empty() { [[ -z "$(ls -A "$1")" ]]; }
no_hidden() { [[ -z "$(ls -A "$1" | grep '^\.')" ]]; }
log_has() { grep -q -- "$1" "$T/fake/log"; }
out_has() { grep -q -- "$1" "$OUT"; }
pinned() { # pinned <sha> <name>: temp copy of the installer pinned to <sha>
  cp "$INSTALL_SH" "$T/$2.sh"; "$REPO/tools/pin-installer.sh" "$T/$2.sh" "$VERSION" "$1" >/dev/null
  echo "$T/$2.sh"
}
# runsh <script> <dest> [VAR=val ...]: run it the way `curl | sh` does.
runsh() {
  local script="$1" dest="$2"; shift 2
  local destenv=()
  [[ "$dest" == - ]] || destenv=(MAGNETITE_DEST="$dest")
  cat "$script" | env -i HOME="$T/home" TMPDIR="$T/tmp" LANG=C \
    PATH="$T/shim:/usr/bin:/bin:/usr/sbin:/sbin" \
    FAKE_DIR="$T/fake" FAKE_LOG="$T/fake/log" FAKE_ALLPIDS="$T/allpids" \
    MAGNETITE_SYSTEM_APPS="$T/sysapps" ${destenv[@]+"${destenv[@]}"} "$@" sh -s -- > "$OUT" 2>&1
}
want() { [[ -z "${INSTALLCHECK_ONLY:-}" || " $INSTALLCHECK_ONLY " == *" $1 "* ]]; }
start_sleeper()  { local p; p="$(sh -c '(exec sleep 25) >/dev/null 2>&1 & echo $!')"; echo "$p" >> "$T/allpids"; echo "$p"; }
start_stubborn() { local p; p="$(sh -c '(trap "" TERM; exec sleep 25) >/dev/null 2>&1 & echo $!')"; echo "$p" >> "$T/allpids"; echo "$p"; }
D="$T/dest"

# --------------------------------------------------------------------- cases --
if want fresh_install; then
  echo "good pin installs"
  reset "$D"; S="$(pinned "$GOOD_SHA" fresh)"
  runsh "$S" "$D" FAKE_ZIP="$T/zips/good.zip"; rc=$?
  check "exits 0" [ $rc -eq 0 ]
  check "app installed and signed" codesign --verify --deep --strict "$D/Magnetite.app"
  check "downloads exactly the pinned release zip" \
    [ "$(grep -c '^curl ' "$T/fake/log")" = 1 ]
  check "  ...from the releases repo at v$VERSION" \
    log_has "curl https://github.com/scryst/magnetite-releases/releases/download/v$VERSION/Magnetite-$VERSION.zip"
  check "no /latest lookup, no .sha256 download" bash -c "! grep -Eq 'latest|sha256' '$T/fake/log'"
  check "no hidden leftovers" no_hidden "$D"
  check "launches the installed app" log_has "open $D/Magnetite.app"
  check "last line names the M in the menu bar" \
    [ "$(tail -n 1 "$OUT")" = "Magnetite $VERSION is installed in $D. Look for the M in your menu bar." ]
fi

if want update_in_place; then
  echo "existing install is updated in place"
  reset "$D"; seed_old "$D"; S="$(pinned "$GOOD_SHA" upd)"
  runsh "$S" "$D" FAKE_ZIP="$T/zips/good.zip"; rc=$?
  check "exits 0" [ $rc -eq 0 ]
  check "old bundle replaced" bash -c "! test -e '$D/Magnetite.app/Contents/OLDMARK' && test -x '$D/Magnetite.app/Contents/MacOS/Magnetite'"
  check "no .old left behind, no second copy" no_hidden "$D"
  check "says updated" out_has "is updated in"
  # Without MAGNETITE_DEST the installer finds the existing copy itself.
  echo "  (no MAGNETITE_DEST)"
  reset "$D"; mkdir -p "$T/home/Applications"; seed_old "$T/home/Applications"; S="$(pinned "$GOOD_SHA" upd2)"
  runsh "$S" - FAKE_ZIP="$T/zips/good.zip"; rc=$?
  check "copy only in ~/Applications: updated there, no second copy in /Applications" \
    bash -c "[ $rc -eq 0 ] && ! test -e '$T/home/Applications/Magnetite.app/Contents/OLDMARK' && test -x '$T/home/Applications/Magnetite.app/Contents/MacOS/Magnetite' && [ -z \"\$(ls -A '$T/sysapps')\" ]"
  reset "$D"; mkdir -p "$T/home/Applications"; seed_old "$T/sysapps"; S="$(pinned "$GOOD_SHA" upd3)"
  runsh "$S" - FAKE_ZIP="$T/zips/good.zip"; rc=$?
  check "copy in /Applications: updated there, nothing created in ~/Applications" \
    bash -c "[ $rc -eq 0 ] && ! test -e '$T/sysapps/Magnetite.app/Contents/OLDMARK' && test -x '$T/sysapps/Magnetite.app/Contents/MacOS/Magnetite' && [ -z \"\$(ls -A '$T/home/Applications')\" ]"
  reset "$D"; S="$(pinned "$GOOD_SHA" upd4)"
  runsh "$S" - FAKE_ZIP="$T/zips/good.zip"; rc=$?
  check "no copy anywhere: fresh install goes to /Applications" \
    bash -c "[ $rc -eq 0 ] && test -x '$T/sysapps/Magnetite.app/Contents/MacOS/Magnetite'"
fi

if want checksum_mismatch; then
  echo "checksum mismatch installs nothing"
  reset "$D"; S="$(pinned "$GOOD_SHA" mism)"
  runsh "$S" "$D" FAKE_ZIP="$SWAP_ZIP"; rc=$?
  check "fresh: fails" [ $rc -ne 0 ]
  check "fresh: nothing installed" dest_empty "$D"
  check "fresh: plain-English message" out_has "didn't match the official release, so nothing was installed"
  check "fresh: app never launched" bash -c "! grep -q '^open' '$T/fake/log'"
  reset "$D"; seed_old "$D"
  runsh "$S" "$D" FAKE_ZIP="$SWAP_ZIP"; rc=$?
  check "existing: fails" [ $rc -ne 0 ]
  check "existing: previous app untouched" old_intact "$D"
  check "existing: nothing hidden left in the folder" no_hidden "$D"
fi

if want truncated; then
  echo "truncated script does nothing"
  reset "$D"; S="$(pinned "$GOOD_SHA" trunc)"
  total="$(wc -l < "$S" | tr -d ' ')"
  bad=0; firstbad=""
  for ((n = 1; n < total; n++)); do
    head -n "$n" "$S" > "$T/prefix.sh"
    reset "$D"
    runsh "$T/prefix.sh" "$D" FAKE_ZIP="$T/zips/good.zip"
    if ! dest_empty "$D" || [[ -s "$T/fake/log" ]]; then bad=$((bad + 1)); [[ -n "$firstbad" ]] || firstbad="$n"; fi
  done
  check "every cut-off prefix (1..$((total - 1)) of $total lines) installs, downloads and launches nothing" \
    bash -c "[ $bad -eq 0 ] || { echo '    first bad cut: line $firstbad' >&2; exit 1; }"
  half=$((total / 2))
  head -n "$half" "$S" > "$T/prefix.sh"; reset "$D"
  runsh "$T/prefix.sh" "$D" FAKE_ZIP="$T/zips/good.zip"; rc=$?
  check "first half: fails and does nothing" bash -c "[ $rc -ne 0 ] && [ -z \"\$(ls -A '$D')\" ] && [ ! -s '$T/fake/log' ]"
fi

if want bundle_checks; then
  echo "bundle is verified before install (checksum passes in each case)"
  for spec in "wrongid:wrong app identifier" "wrongver:wrong version" "intel:Apple silicon" "tampered:signature is damaged"; do
    name="${spec%%:*}"; why="${spec#*:}"
    reset "$D"; seed_old "$D"; S="$(pinned "$(sha "$T/zips/$name.zip")" "b_$name")"
    runsh "$S" "$D" FAKE_ZIP="$T/zips/$name.zip"; rc=$?
    check "$name: refused ($why)" bash -c "[ $rc -ne 0 ] && grep -q -- '$why' '$OUT'"
    check "$name: existing app untouched, nothing hidden" bash -c "test -f '$D/Magnetite.app/Contents/OLDMARK' && [ -z \"\$(ls -A '$D' | grep '^\.')\" ]"
  done
fi

if want other_version; then
  echo "MAGNETITE_VERSION other than the pin falls back to the .sha256 with a warning"
  reset "$D"; S="$(pinned "$GOOD_SHA" ver)"
  echo "$(sha "$T/zips/other.zip")  Magnetite-$OTHER_VERSION.zip" > "$T/zips/other.sha256"
  runsh "$S" "$D" FAKE_ZIP="$T/zips/other.zip" FAKE_SHA256_FILE="$T/zips/other.sha256" MAGNETITE_VERSION="$OTHER_VERSION"; rc=$?
  check "installs when the published checksum matches" bash -c "[ $rc -eq 0 ] && test -x '$D/Magnetite.app/Contents/MacOS/Magnetite'"
  check "warns that there is no built-in fingerprint" out_has "doesn't know the official fingerprint"
  check "fetched the .sha256 file" log_has "Magnetite-$OTHER_VERSION.sha256"
  reset "$D"; echo "$(printf 0%.0s {1..64})  Magnetite-$OTHER_VERSION.zip" > "$T/zips/bad.sha256"
  runsh "$S" "$D" FAKE_ZIP="$T/zips/other.zip" FAKE_SHA256_FILE="$T/zips/bad.sha256" MAGNETITE_VERSION="$OTHER_VERSION"; rc=$?
  check "a wrong published checksum installs nothing" bash -c "[ $rc -ne 0 ] && [ -z \"\$(ls -A '$D')\" ]"
  reset "$D"
  runsh "$S" "$D" MAGNETITE_VERSION="1.2; rm -rf /"; rc=$?
  check "a malformed version is rejected before any download" bash -c "[ $rc -ne 0 ] && [ ! -s '$T/fake/log' ]"
fi

if want running_copy; then
  echo "running copy is quit with SIGTERM, never Apple Events"
  reset "$D"; seed_old "$D"; S="$(pinned "$GOOD_SHA" run)"
  pid="$(start_sleeper)"; echo "$pid" > "$T/fake/pid"
  runsh "$S" "$D" FAKE_ZIP="$T/zips/good.zip"; rc=$?
  check "exits 0 and updates" bash -c "[ $rc -eq 0 ] && ! test -e '$D/Magnetite.app/Contents/OLDMARK'"
  check "the running pid is gone" bash -c "! kill -0 $pid 2>/dev/null"
  check "no osascript anywhere in the installer" bash -c "! grep -v '^ *#' '$INSTALL_SH' | grep -q osascript"
  reset "$D"; seed_old "$D"
  pid="$(start_stubborn)"; echo "$pid" > "$T/fake/pid"
  runsh "$S" "$D" FAKE_ZIP="$T/zips/good.zip"; rc=$?
  check "a copy that will not quit: fails with the M-menu advice" bash -c "[ $rc -ne 0 ] && grep -q 'Quit it from the M in your menu bar' '$OUT'"
  check "  ...and the existing app is untouched" old_intact "$D"
  kill "$pid" 2>/dev/null
fi

if want launch_failure; then
  echo "new app that never starts"
  reset "$D"; seed_old "$D"; S="$(pinned "$GOOD_SHA" lf)"
  runsh "$S" "$D" FAKE_ZIP="$T/zips/good.zip" FAKE_OPEN_FAIL=1; rc=$?
  check "update: fails and restores the previous version" bash -c "[ $rc -ne 0 ] && grep -q 'previous version was put back' '$OUT' && test -f '$D/Magnetite.app/Contents/OLDMARK'"
  check "update: nothing hidden left" no_hidden "$D"
  reset "$D"
  runsh "$S" "$D" FAKE_ZIP="$T/zips/good.zip" FAKE_OPEN_FAIL=1; rc=$?
  check "fresh: stays installed and says how to open it" bash -c "[ $rc -eq 0 ] && grep -q \"didn't start by itself\" '$OUT' && test -x '$D/Magnetite.app/Contents/MacOS/Magnetite'"
fi

if want trap_restore; then
  echo "EXIT trap restores the old app when the new one cannot be moved in"
  reset "$D"; seed_old "$D"; S="$(pinned "$GOOD_SHA" tr)"
  runsh "$S" "$D" FAKE_ZIP="$T/zips/good.zip" FAKE_MV_FAIL=1; rc=$?
  check "fails" [ $rc -ne 0 ]
  check "previous app is back" old_intact "$D"
  check "no .old or .new left" no_hidden "$D"
fi

if want signal; then
  echo "a signal ends the run"
  reset "$D"; S="$(pinned "$GOOD_SHA" sig)"
  runsh "$S" "$D" FAKE_ZIP="$T/zips/good.zip" FAKE_OPEN_KILLS_PARENT=1; rc=$?
  check "SIGTERM mid-run exits 130" [ $rc -eq 130 ]
  check "no scratch folder left in TMPDIR" bash -c "[ -z \"\$(ls -A '$T/tmp')\" ]"
fi

if want machine_checks; then
  echo "machine checks"
  S="$(pinned "$GOOD_SHA" mc)"
  reset "$D"; runsh "$S" "$D" FAKE_ZIP="$T/zips/good.zip" FAKE_ID=0; rc=$?
  check "root is refused with a sudo message" bash -c "[ $rc -ne 0 ] && grep -q 'without sudo' '$OUT' && [ ! -s '$T/fake/log' ]"
  reset "$D"; runsh "$S" "$D" FAKE_ZIP="$T/zips/good.zip" FAKE_SYSCTL=0; rc=$?
  check "an Intel Mac is refused (hw.optional.arm64, not uname -m)" bash -c "[ $rc -ne 0 ] && grep -q 'Apple silicon' '$OUT' && [ ! -s '$T/fake/log' ]"
  reset "$D"; runsh "$S" "$D" FAKE_ZIP="$T/zips/good.zip" FAKE_SWVERS=15.4; rc=$?
  check "macOS 15 is refused with the version named" bash -c "[ $rc -ne 0 ] && grep -q 'macOS 26 or newer.*15.4' '$OUT' && [ ! -s '$T/fake/log' ]"
  reset "$D"; runsh "$S" "$D" FAKE_ZIP="$T/zips/good.zip" FAKE_SWVERS=banana; rc=$?
  check "unreadable macOS version does not crash the arithmetic" bash -c "[ $rc -eq 0 ] && ! grep -q 'integer expression' '$OUT'"
fi

if want pin_tool; then
  echo "tools/pin-installer.sh"
  cp "$INSTALL_SH" "$T/pin.sh"
  NEWSHA="$(printf 'ab%.0s' {1..32})"
  "$REPO/tools/pin-installer.sh" "$T/pin.sh" 0.2.0 "$NEWSHA"; rc=$?
  check "rewrites both pin lines" bash -c "[ $rc -eq 0 ] && grep -qx 'PIN_VERSION=\"0.2.0\"' '$T/pin.sh' && grep -qx 'PIN_SHA256=\"$NEWSHA\"' '$T/pin.sh'"
  check "changes nothing else (exactly 2 lines differ)" bash -c "[ \"\$(diff '$INSTALL_SH' '$T/pin.sh' | grep -c '^>')\" -eq 2 ]"
  check "rejects a malformed sha" bash -c "! '$REPO/tools/pin-installer.sh' '$T/pin.sh' 0.2.0 nothex 2>/dev/null"
  check "rejects a malformed version" bash -c "! '$REPO/tools/pin-installer.sh' '$T/pin.sh' 0.2 '$NEWSHA' 2>/dev/null"
  check "the tracked installer still carries a pin" bash -c "grep -Eq '^PIN_VERSION=\"[0-9]+\.[0-9]+\.[0-9]+\"\$' '$INSTALL_SH' && grep -Eq '^PIN_SHA256=\"[0-9a-f]{64}\"\$' '$INSTALL_SH'"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "installcheck: $PASS checks passed"; exit 0; fi
echo "installcheck: $FAIL failed, $PASS passed" >&2; exit 1
