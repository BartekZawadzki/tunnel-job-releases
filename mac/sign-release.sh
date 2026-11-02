#!/bin/bash
# Breachworks: Developer ID signing + notarization + stapling of the macOS dmg of an already published release, on a GitHub
# macOS runner (.github/workflows/sign-mac.yml runs one phase per step). The logic follows tools/mac/sign-notarize-mac.sh of
# the game repo; the entitlements and the signed-variant readmes beside this script are copies of tools/mac/ there.
#
#   bash mac/sign-release.sh <phase>
#     fetch          download Breachworks-macOS.dmg + SHA256SUMS.txt of $TAG, check the hash; output skip=true when the dmg
#                    is already Developer ID signed and stapled (or the release has no dmg)
#     extract        mount the dmg read-only, copy Breachworks.app out with ditto, check its version against the tag
#     keychain       a temporary keychain with the Developer ID certificate (MAC_CERT_P12_BASE64 + MAC_CERT_P12_PASSWORD),
#                    and the App Store Connect API key file (ASC_KEY_P8_BASE64)
#     sign           sign inside out: nested Mach-O first, then the app with the entitlements; hardened runtime, timestamp
#     notarize-app   zip the app, notarytool submit --wait, staple the app
#     dmg            a clean dmg: the app, an Applications link, README.txt + CZYTAJ-MNIE.txt (version filled in); signed
#     notarize-dmg   notarytool submit --wait, staple, stapler validate, spctl
#     smoke          mount the final dmg, verify the app in it, start it headless for ~20 s, fail on a crash
#     publish        replace the dmg asset and the dmg line of SHA256SUMS.txt (every other line byte for byte as it was)
#     cleanup        delete the keychain and the key files (the workflow runs it always)
#
# Environment: TAG (vX.Y.Z), REPO (owner/name, default $GITHUB_REPOSITORY), GH_TOKEN (gh), WORK (default
# $RUNNER_TEMP/bw-sign), TEAM_ID (default GKS78Q935U), ASC_KEY_ID, ASC_ISSUER_ID; DRY_RUN=1 makes publish print the upload
# instead of doing it. No secret is ever printed: only names, the certificate's common name and hashes of public files.
set -euo pipefail

PHASE=${1:?phase: fetch, extract, keychain, sign, notarize-app, dmg, notarize-dmg, smoke, publish or cleanup}
HERE="$(cd "$(dirname "$0")" && pwd)"
TAG=${TAG:?TAG not set}
REPO=${REPO:-${GITHUB_REPOSITORY:-}}
TMPBASE=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
WORK=${WORK:-$TMPBASE/bw-sign}
TEAM_ID=${TEAM_ID:-GKS78Q935U}
DMG_NAME=Breachworks-macOS.dmg
SUMS_NAME=SHA256SUMS.txt
KC="$TMPBASE/bw-signing.keychain-db"
KEYDIR="$TMPBASE/bw-asc"
P8="$KEYDIR/AuthKey.p8"
PUB="$WORK/pub"            # the published files
APP="$WORK/app/Breachworks.app"
OUTDMG="$WORK/out/$DMG_NAME"

die() { echo "::error::$*" >&2; exit 1; }
note() { echo "::notice::$*"; }
output() { echo "output: $1"; if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >> "$GITHUB_OUTPUT"; fi; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

[[ "$TAG" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "TAG must look like v1.2.3, got '$TAG'."
VER=${TAG#v}
[ -n "$REPO" ] || die "REPO not set."
mkdir -p "$WORK"

identity() { # the SHA-1 of the Developer ID Application identity of $TEAM_ID in the temporary keychain
  security find-identity -v -p codesigning "$KC" | grep "\"Developer ID Application: .*($TEAM_ID)\"" | awk '{print $2}' | head -1
}
is_macho() { case "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" in cafebabe|cffaedfe|cefaedfe|feedfacf|feedface|bebafeca) return 0 ;; *) return 1 ;; esac; }
mount_ro() { # mount_ro <dmg> <mountpoint>
  mkdir -p "$2"
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$2" "$1" > /dev/null || die "Cannot mount $1."
}
unmount() { hdiutil detach "$1" -quiet > /dev/null 2>&1 || hdiutil detach "$1" -force -quiet > /dev/null 2>&1 || true; }
signed_and_stapled() { # signed_and_stapled <path>: Developer ID of $TEAM_ID and a valid stapled ticket
  codesign -dvv "$1" 2>&1 | grep -q "^TeamIdentifier=$TEAM_ID$" && xcrun stapler validate "$1" > /dev/null 2>&1
}
asc_args() { echo "--key $P8 --key-id $(printf '%s' "${ASC_KEY_ID:?ASC_KEY_ID not set}" | tr -d '[:space:]') --issuer $(printf '%s' "${ASC_ISSUER_ID:?ASC_ISSUER_ID not set}" | tr -d '[:space:]')"; }
notarize() { # notarize <file> <label>: submit, wait; on anything but Accepted print Apple's log and fail
  local file=$1 label=$2 log="$WORK/notary-$2.log" id status
  [ -f "$P8" ] || die "No API key file: run the keychain phase first."
  echo "Submitting $label to Apple's notary service (usually 2-15 minutes)..."
  set +e
  # shellcheck disable=SC2046
  xcrun notarytool submit "$file" $(asc_args) --wait --timeout 1h 2>&1 | tee "$log"
  set -e
  id=$(awk '/^ *id:/ { print $2; exit }' "$log")
  status=$(awk '/^ *status:/ { s=$2 } END { print s }' "$log")
  echo "NOTARY $label: submission ${id:-?} status ${status:-none}"
  if [ "$status" != Accepted ]; then
    if [ -n "$id" ]; then
      echo "---- notarytool log $id ----"
      # shellcheck disable=SC2046
      xcrun notarytool log "$id" $(asc_args) 2>&1 || true
    fi
    die "Notarization of $label: ${status:-no status} (submission ${id:-?})."
  fi
  output "${label}_submission=$id"
}
staple() { # Apple's CDN can need a minute after Accepted
  local i
  for i in 1 2 3 4 5; do
    xcrun stapler staple "$1" && return 0
    echo "stapler: retrying in 30 s ($i/5)"; sleep 30
  done
  die "Stapling $1 failed."
}

case "$PHASE" in

fetch)
  rm -rf "$PUB"; mkdir -p "$PUB"
  # gh release create uploads the files before it publishes, but wait a little in case a release was published by hand
  for i in $(seq 1 20); do
    names=$(gh release view "$TAG" -R "$REPO" --json assets -q '.assets[].name')
    if echo "$names" | grep -qx "$DMG_NAME" && echo "$names" | grep -qx "$SUMS_NAME"; then break; fi
    [ "$i" -lt 20 ] || { note "$TAG has no $DMG_NAME (or no $SUMS_NAME): nothing to sign."; output skip=true; exit 0; }
    echo "waiting for $DMG_NAME and $SUMS_NAME on $TAG ($i/20)..."; sleep 30
  done
  gh release download "$TAG" -R "$REPO" -p "$DMG_NAME" -p "$SUMS_NAME" -D "$PUB" --clobber
  want=$(tr -d '\r' < "$PUB/$SUMS_NAME" | awk -v n="$DMG_NAME" '$2 == n || $2 == "*" n { print $1 }' | head -1)
  [ -n "$want" ] || die "$SUMS_NAME of $TAG has no $DMG_NAME line."
  got=$(sha "$PUB/$DMG_NAME")
  [ "$got" = "$want" ] || die "The downloaded $DMG_NAME has SHA-256 $got, $SUMS_NAME says $want."
  echo "CHECK published dmg: $got matches $SUMS_NAME"
  if signed_and_stapled "$PUB/$DMG_NAME"; then
    note "$DMG_NAME of $TAG is already Developer ID signed ($TEAM_ID) and stapled: nothing to do."
    output skip=true
  else
    output skip=false
  fi
  ;;

extract)
  MNT="$WORK/mnt-pub"
  mount_ro "$PUB/$DMG_NAME" "$MNT"
  trap 'unmount "$MNT"' EXIT
  [ -x "$MNT/Breachworks.app/Contents/MacOS/Breachworks" ] || die "The published dmg has no Breachworks.app."
  echo "Published volume:"; ls -la "$MNT"
  rm -rf "$WORK/app"; mkdir -p "$WORK/app"
  ditto "$MNT/Breachworks.app" "$APP"
  unmount "$MNT"; trap - EXIT
  xattr -cr "$APP"
  v=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist") || die "Info.plist has no CFBundleShortVersionString."
  [ "$v" = "$VER" ] || die "The app in the $TAG dmg says version $v, not $VER."
  id=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")
  plutil -extract NSLocalNetworkUsageDescription raw "$APP/Contents/Info.plist" > /dev/null 2>&1 || die "Info.plist has no NSLocalNetworkUsageDescription (LAN needs it)."
  echo "CHECK app: Breachworks $v ($id), $(find "$APP" -type f | wc -l | tr -d ' ') files, $(find "$APP" -type l | wc -l | tr -d ' ') symlinks"
  ;;

keychain)
  for v in MAC_CERT_P12_BASE64 MAC_CERT_P12_PASSWORD ASC_KEY_P8_BASE64 ASC_KEY_ID ASC_ISSUER_ID; do
    [ -n "${!v:-}" ] || die "The repository secret $v is not set (the owner runs tools\\mac\\setup-release-signing.ps1 of the game repo once)."
  done
  umask 077
  mkdir -p "$KEYDIR"
  KCPASS=$(openssl rand -hex 24)
  security delete-keychain "$KC" > /dev/null 2>&1 || true
  security create-keychain -p "$KCPASS" "$KC"
  security set-keychain-settings -lut 7200 "$KC"
  security unlock-keychain -p "$KCPASS" "$KC"
  printf '%s' "$MAC_CERT_P12_BASE64" | tr -d '[:space:]' | base64 --decode > "$KEYDIR/cert.p12"
  security import "$KEYDIR/cert.p12" -k "$KC" -f pkcs12 -P "$MAC_CERT_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security > /dev/null \
    || { rm -f "$KEYDIR/cert.p12"; die "security import of the .p12 failed (wrong MAC_CERT_P12_PASSWORD, or not a 3DES/SHA-1 .p12)."; }
  rm -f "$KEYDIR/cert.p12"
  # Apple's Developer ID G2 intermediate, so codesign can build the chain (public, from apple.com)
  curl -fsSL -o "$KEYDIR/DeveloperIDG2CA.cer" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
  security import "$KEYDIR/DeveloperIDG2CA.cer" -k "$KC" > /dev/null 2>&1 || true
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" > /dev/null
  # shellcheck disable=SC2046
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  unset KCPASS
  printf '%s' "$ASC_KEY_P8_BASE64" | tr -d '[:space:]' | base64 --decode > "$P8"
  grep -q 'BEGIN PRIVATE KEY' "$P8" || die "ASC_KEY_P8_BASE64 is not a base64 AuthKey_<KEYID>.p8."
  ID=$(identity)
  [ -n "$ID" ] || die "No \"Developer ID Application: ... ($TEAM_ID)\" identity in the imported .p12."
  echo "Signing identity: $(security find-identity -v -p codesigning "$KC" | grep -F "$ID" | sed 's/^ *[0-9]*) [0-9A-F]* //')"
  ;;

sign)
  ID=$(identity); [ -n "$ID" ] || die "No signing identity: run the keychain phase first."
  ENT="$HERE/Breachworks.entitlements"
  plutil -lint "$ENT" > /dev/null
  CS=(codesign --force --timestamp --options runtime --keychain "$KC" --sign "$ID")
  rm -rf "$APP/Contents/_CodeSignature"
  MACHOS=()
  while IFS= read -r -d '' f; do
    if is_macho "$f"; then chmod 755 "$f"; MACHOS+=("$f"); fi
  done < <(find "$APP/Contents" -type f -print0)
  # nested bundle folders deepest first (their own Mach-O first), then loose Mach-O deepest first, then the app
  NESTED_DIRS=$(find "$APP/Contents" -mindepth 2 -type d \( -name '*.framework' -o -name '*.bundle' -o -name '*.app' -o -name '*.plugin' -o -name '*.xpc' \) \
                | awk '{ print gsub("/","/") "\t" $0 }' | sort -rn | cut -f2-)
  if [ -n "$NESTED_DIRS" ]; then
    while IFS= read -r d; do
      while IFS= read -r -d '' f; do if is_macho "$f"; then "${CS[@]}" "$f"; fi; done < <(find "$d" -type f -print0)
      echo "  bundle  ${d#"$APP/"}"; "${CS[@]}" "$d"
    done <<< "$NESTED_DIRS"
  fi
  for f in "${MACHOS[@]}"; do
    [ "$f" = "$APP/Contents/MacOS/Breachworks" ] && continue
    inside=0
    if [ -n "$NESTED_DIRS" ]; then while IFS= read -r d; do case "$f" in "$d"/*) inside=1 ;; esac; done <<< "$NESTED_DIRS"; fi
    if [ $inside = 0 ]; then echo "$f"; fi
  done | awk '{ print gsub("/","/") "\t" $0 }' | sort -rn | cut -f2- | while IFS= read -r f; do
    echo "  mach-o  ${f#"$APP/"}"; "${CS[@]}" "$f"
  done
  echo "  app     Breachworks.app (+ entitlements)"
  "${CS[@]}" --entitlements "$ENT" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  INFO=$(codesign -dvv "$APP" 2>&1)
  echo "$INFO" | grep -E '^(Authority|TeamIdentifier|Timestamp|Identifier|CodeDirectory)' || true
  echo "$INFO" | grep -q "^TeamIdentifier=$TEAM_ID$" || die "Team ID is not $TEAM_ID."
  echo "$INFO" | grep -qE 'flags=.*runtime' || die "No hardened runtime."
  echo "$INFO" | grep -q '^Timestamp=' || die "No secure timestamp."
  ENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
  for k in allow-jit allow-unsigned-executable-memory disable-library-validation; do
    echo "$ENTS" | grep -q "com.apple.security.cs.$k" || die "Entitlement $k missing from the signature."
  done
  for f in "${MACHOS[@]}"; do
    i=$(codesign -dvv "$f" 2>&1)
    if ! { echo "$i" | grep -q "^TeamIdentifier=$TEAM_ID$" && echo "$i" | grep -qE 'flags=.*runtime' && echo "$i" | grep -q '^Timestamp='; }; then
      die "Not signed with runtime + timestamp: ${f#"$APP/"}"
    fi
  done
  echo "CHECK signed: ${#MACHOS[@]} Mach-O, Team $TEAM_ID, hardened runtime, timestamp, 3 entitlements"
  ;;

notarize-app)
  ZIP="$WORK/Breachworks-app.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP" app
  rm -f "$ZIP"
  staple "$APP"
  xcrun stapler validate "$APP"
  spctl -a -t exec -vv "$APP" 2>&1 | tee "$WORK/spctl-app.txt"
  grep -q 'source=Notarized Developer ID' "$WORK/spctl-app.txt" || die "Gatekeeper does not accept the app."
  ;;

dmg)
  ID=$(identity); [ -n "$ID" ] || die "No signing identity: run the keychain phase first."
  SRC="$WORK/dmgsrc"
  rm -rf "$SRC" "$WORK/out"; mkdir -p "$SRC" "$WORK/out"
  ditto "$APP" "$SRC/Breachworks.app"
  ln -s /Applications "$SRC/Applications"
  for f in README CZYTAJ-MNIE; do
    sed -e "s/@VERSION@/$VER/g" -e 's/\r$//' "$HERE/$f-signed.txt" > "$SRC/$f.txt"
  done
  if grep -q '@VERSION@' "$SRC/README.txt" "$SRC/CZYTAJ-MNIE.txt"; then die "A readme still holds @VERSION@."; fi
  hdiutil create -volname Breachworks -srcfolder "$SRC" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUTDMG" > /dev/null
  codesign --force --timestamp --keychain "$KC" --sign "$ID" "$OUTDMG"
  codesign --verify --verbose=2 "$OUTDMG"
  codesign -dvv "$OUTDMG" 2>&1 | grep -q "^TeamIdentifier=$TEAM_ID$" || die "The dmg is not signed by $TEAM_ID."
  echo "DMG $(stat -f %z "$OUTDMG") bytes"
  ;;

notarize-dmg)
  notarize "$OUTDMG" dmg
  staple "$OUTDMG"
  xcrun stapler validate "$OUTDMG"
  spctl -a -t open --context context:primary-signature -vv "$OUTDMG" 2>&1 | tee "$WORK/spctl-dmg.txt"
  if ! { grep -q 'accepted' "$WORK/spctl-dmg.txt" && grep -q 'Notarized Developer ID' "$WORK/spctl-dmg.txt"; }; then die "Gatekeeper does not accept the dmg."; fi
  ;;

smoke)
  MNT="$WORK/mnt-out"
  mount_ro "$OUTDMG" "$MNT"
  trap 'unmount "$MNT"' EXIT
  ls -la "$MNT"
  [ -L "$MNT/Applications" ] || die "No Applications link in the dmg."
  if compgen -G "$MNT/*.command" > /dev/null; then die "The dmg holds an installer .command."; fi
  for f in README.txt CZYTAJ-MNIE.txt; do grep -q "$VER" "$MNT/$f" || die "$f does not name $VER."; done
  codesign --verify --deep --strict "$MNT/Breachworks.app"
  xcrun stapler validate "$MNT/Breachworks.app"
  RUN="$WORK/smoke"; rm -rf "$RUN"; mkdir -p "$RUN"
  ditto "$MNT/Breachworks.app" "$RUN/Breachworks.app"
  unmount "$MNT"; trap - EXIT
  LOG="$RUN/player.log"
  before=$( { find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'Breachworks*' 2>/dev/null || true; } | wc -l | tr -d ' ')
  # BW_TEST_LAUNCHER: only for the local dry run of this script off a Mac (a stand-in that runs instead of the Mach-O)
  ${BW_TEST_LAUNCHER:+"$BW_TEST_LAUNCHER"} "$RUN/Breachworks.app/Contents/MacOS/Breachworks" -batchmode -nographics -logFile "$LOG" > "$RUN/stdout.txt" 2>&1 &
  pid=$!
  alive=1
  for _ in $(seq 1 20); do sleep 1; kill -0 "$pid" 2> /dev/null || { alive=0; break; }; done
  code=0
  if [ $alive = 1 ]; then kill "$pid" 2> /dev/null || true; sleep 2; kill -9 "$pid" 2> /dev/null || true; wait "$pid" 2> /dev/null || true
  else wait "$pid" || code=$?; fi
  after=$( { find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'Breachworks*' 2>/dev/null || true; } | wc -l | tr -d ' ')
  echo "---- player log (last 40 lines) ----"; tail -40 "$LOG" 2> /dev/null || echo "(no player log)"
  bad=0
  if grep -qE 'Crash!!!|Received signal SIG|Native Crash Reporting|Segmentation fault|Abort trap|Obtained [0-9]+ stack frames' "$LOG" "$RUN/stdout.txt" 2> /dev/null; then echo "SMOKE: crash marker in the log"; bad=1; fi
  [ "$after" -le "$before" ] || { echo "SMOKE: a new crash report in DiagnosticReports"; bad=1; }
  [ $alive = 1 ] || [ $code -lt 128 ] || { echo "SMOKE: killed by a signal (exit $code)"; bad=1; }
  [ $bad = 0 ] || die "The app crashed in the smoke test."
  if [ $alive = 1 ]; then echo "SMOKE: ran 20 s headless, no crash"; else echo "SMOKE: exited by itself with code $code, no crash"; fi
  ;;

publish)
  [ -f "$OUTDMG" ] || die "No signed dmg: run the dmg phases first."
  signed_and_stapled "$OUTDMG" || die "The new dmg is not signed and stapled."
  # SHA256SUMS.txt: only the dmg line changes; every other line keeps its bytes (the Windows updater checks Setup.exe)
  NEWSUMS="$WORK/out/$SUMS_NAME"
  python3 - "$PUB/$SUMS_NAME" "$NEWSUMS" "$DMG_NAME" "$(sha "$OUTDMG")" <<'PY'
import sys
src, dst, name, h = sys.argv[1], sys.argv[2], sys.argv[3].encode(), sys.argv[4].encode()
data = open(src, "rb").read()
lines = data.split(b"\n")
hits = 0
for i, l in enumerate(lines):
    body = l[:-1] if l.endswith(b"\r") else l
    parts = body.split()
    if len(parts) == 2 and parts[1].lstrip(b"*") == name:
        sep = body[64:len(body) - len(parts[1])]          # keep "  " or " *" as published
        lines[i] = h + sep + parts[1] + (b"\r" if l.endswith(b"\r") else b"")
        hits += 1
if hits != 1:
    sys.exit("expected exactly one dmg line, found %d" % hits)
out = b"\n".join(lines)
old_rest = [l for l in data.split(b"\n") if name not in l]
new_rest = [l for l in out.split(b"\n") if name not in l]
if old_rest != new_rest or len(out) != len(data):
    sys.exit("the other lines would change")
open(dst, "wb").write(out)
PY
  echo "SHA256SUMS.txt before:"; cat "$PUB/$SUMS_NAME"
  echo "after:"; cat "$NEWSUMS"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    echo "DRY RUN: would run: gh release upload $TAG $OUTDMG $NEWSUMS -R $REPO --clobber"
    exit 0
  fi
  gh release upload "$TAG" "$OUTDMG" "$NEWSUMS" -R "$REPO" --clobber
  BACK="$WORK/back"; rm -rf "$BACK"; mkdir -p "$BACK"
  gh release download "$TAG" -R "$REPO" -p "$DMG_NAME" -p "$SUMS_NAME" -D "$BACK"
  cmp -s "$BACK/$SUMS_NAME" "$NEWSUMS" || die "SHA256SUMS.txt on the release is not the one uploaded."
  [ "$(sha "$BACK/$DMG_NAME")" = "$(sha "$OUTDMG")" ] || die "The dmg on the release is not the one uploaded."
  echo "Done: $TAG holds the signed $DMG_NAME ($(sha "$OUTDMG"))."
  ;;

cleanup)
  # shellcheck disable=SC2046
  security list-keychains -d user -s $(security list-keychains -d user | tr -d '"' | grep -v "bw-signing.keychain") 2> /dev/null || true
  security delete-keychain "$KC" > /dev/null 2>&1 || true
  rm -rf "$KEYDIR"
  for m in "$WORK"/mnt-*; do [ -d "$m" ] && unmount "$m"; done
  echo "keychain and key files removed"
  ;;

*) die "Unknown phase $PHASE." ;;
esac
