#!/usr/bin/env bash
# Build the GTNW Chess disk image: archive (Release), export, check the bundle, optionally sign with Developer ID and
# notarize, then copy the DMG to both binaries folders.
#
#   tools/release.sh              ad hoc signed DMG (hardened runtime), copied to both binaries folders
#   tools/release.sh --notarize   Developer ID + notarization + stapling (OFF by default)
#   tools/release.sh --dry-run    every build step and check in a temp folder; signs ad hoc, copies nothing
#
# The bundle check fails the release when:
#   - Contents/MacOS/stockfish is missing, not arm64, not Stockfish 19, or its SHA-256 differs from
#     scripts/stockfish.sha256 (checked before any re-signing, because signing rewrites the binary);
#   - any certificate, key or credential file is inside, or any file contains a PEM certificate or key block, or a
#     known API-key prefix. The two Nova Games CA certificates are excluded from the archive, so a release has no
#     Nova Games play history (that server is on a private network anyway).
#
# --notarize needs, from the environment (nothing secret is read from files):
#   DEVELOPER_ID   the "Developer ID Application: …" identity in your keychain (default: the first one found)
#   NOTARY_PROFILE a notarytool keychain profile (xcrun notarytool store-credentials <name>); the credentials stay
#                  in the macOS Keychain
# Output: <OUT>/<yyyymmdd>-GTNWChess-v<version>/GTNWChess-v<version>-build<N>.dmg for OUT in
#         /Volumes/Data/xcode/binaries and /Volumes/NAS/binaries. Never publishes a GitHub release.
set -euo pipefail

DRY=0 NOTARIZE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --notarize) NOTARIZE=1 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
[[ $DRY == 1 && $NOTARIZE == 1 ]] && { echo "--dry-run never notarizes; drop one of the flags" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTS=(/Volumes/Data/xcode/binaries /Volumes/NAS/binaries)
APP_NAME="GTNW Chess"
# Archive on the internal disk: external volumes ignore ownership and the archive's chown step fails there.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gtnwchess-release.XXXXXX")"
log() { echo "[release] $*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

cd "$ROOT"
settings="$(xcodebuild -project GTNWChess.xcodeproj -scheme GTNWChess -configuration Release -showBuildSettings 2>/dev/null)"
VERSION="$(awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}' <<<"$settings")"
BUILD="$(awk -F' = ' '/ CURRENT_PROJECT_VERSION /{print $2; exit}' <<<"$settings")"
[[ -n "$VERSION" && -n "$BUILD" ]] || fail "could not read MARKETING_VERSION / CURRENT_PROJECT_VERSION"
NAME="GTNWChess-v$VERSION-build$BUILD"
FOLDER="$(date +%Y%m%d)-GTNWChess-v$VERSION"
log "version $VERSION build $BUILD, work dir $WORK$([[ $DRY == 1 ]] && echo ' (dry run)')"

if [[ $DRY == 0 ]]; then
  for d in "${DESTS[@]}"; do [[ -d "$d" && -w "$d" ]] || fail "$d is not mounted or not writable"; done
fi
if [[ $NOTARIZE == 1 ]]; then
  [[ -n "${NOTARY_PROFILE:-}" ]] || fail "--notarize needs NOTARY_PROFILE (xcrun notarytool store-credentials)"
  ID="${DEVELOPER_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
  [[ -n "$ID" ]] || fail "no Developer ID Application identity in the keychain"
fi

log "archiving (Release, without the Nova Games CA certificates)"
xcodebuild archive -project GTNWChess.xcodeproj -scheme GTNWChess -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$WORK/dd" -archivePath "$WORK/GTNWChess.xcarchive" \
  EXCLUDED_SOURCE_FILE_NAMES="games-pg-ca.crt nova-games-ca.crt" > "$WORK/archive.log" 2>&1 \
  || { tail -30 "$WORK/archive.log"; fail "archive"; }

log "exporting the app from the archive"
mkdir -p "$WORK/app"
ditto "$WORK/GTNWChess.xcarchive/Products/Applications/$APP_NAME.app" "$WORK/app/$APP_NAME.app"
APP="$WORK/app/$APP_NAME.app"
SF="$APP/Contents/MacOS/stockfish"

log "checking Stockfish"
[[ -x "$SF" ]] || fail "Contents/MacOS/stockfish is missing (brew install stockfish, or scripts/fetch-stockfish.sh)"
[[ " $(lipo -archs "$SF") " == *" arm64 "* ]] || fail "stockfish is not arm64"
want="$(awk '{print $1; exit}' "$ROOT/scripts/stockfish.sha256")"
got="$(shasum -a 256 "$SF" | awk '{print $1}')"
[[ "$got" == "$want" ]] || fail "stockfish SHA-256 $got does not match scripts/stockfish.sha256 ($want)"
banner="$(echo quit | "$SF" 2>/dev/null || true)"; banner="${banner%%$'\n'*}"
[[ "$banner" == "Stockfish 19 "* ]] || fail "unexpected engine: $banner"
for f in COPYING.txt AUTHORS.txt SOURCE.txt; do
  [[ -f "$APP/Contents/Resources/Stockfish/$f" ]] || fail "Stockfish licence file $f is missing (GPLv3)"
done
log "  $banner, sha256 $got"

check_clean() {  # $1 = app bundle
  local bad
  bad="$(find "$1" -type f \( -iname '*.crt' -o -iname '*.cer' -o -iname '*.pem' -o -iname '*.der' -o -iname '*.key' \
         -o -iname '*.p12' -o -iname '*.pfx' -o -iname '*.keychain*' -o -iname '.env*' -o -iname '*credential*' \
         -o -iname '*secret*' -o -iname '*.netrc' \) -print)"
  [[ -z "$bad" ]] || fail "certificate, key or credential file in the bundle:"$'\n'"$bad"
  # PEM blocks (a header followed by base64 DER, so the parser's own "-----BEGIN CERTIFICATE-----" literal is fine)
  # and well-known API-key prefixes, in every file including the executables.
  bad="$(find "$1" -type f -print0 | xargs -0 perl -0777 -ne \
    'print "$ARGV\n" if /-----BEGIN [A-Z ]*(CERTIFICATE|PRIVATE KEY)-----\s*MI|sk-ant-[A-Za-z0-9_-]{20}|sk-(proj-)?[A-Za-z0-9]{32}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36}|xox[abpr]-[A-Za-z0-9-]{10}|AIza[0-9A-Za-z_-]{35}/')"
  [[ -z "$bad" ]] || fail "certificate, key or API key inside:"$'\n'"$bad"
}
log "checking for certificates and credentials"
check_clean "$APP"

if [[ $NOTARIZE == 1 ]]; then
  log "signing with $ID (hardened runtime, secure timestamp)"
  codesign --force --options runtime --timestamp -s "$ID" "$SF"
  codesign --force --options runtime --timestamp -s "$ID" "$APP"
else
  log "signing ad hoc (hardened runtime)"
  codesign --force --options runtime -s - "$SF"
  codesign --force --options runtime -s - "$APP"
fi
codesign --verify --deep --strict "$APP" || fail "signature does not verify"
# Capture first: `grep -q` would close the pipe early and pipefail would turn codesign's SIGPIPE into a failure.
[[ "$(codesign -d --verbose=2 "$APP" 2>&1)" == *"flags="*"runtime"* ]] || fail "hardened runtime is off"
[[ "$(codesign -d --verbose=2 "$SF" 2>&1)" == *"flags="*"runtime"* ]] || fail "stockfish is not signed with the hardened runtime"
"$APP/Contents/MacOS/$APP_NAME" --selftest >&2 || fail "--selftest (perft and bundled Stockfish) failed"

log "building the disk image"
mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/$APP_NAME.app"
ln -s /Applications "$WORK/dmg/Applications"
if [[ $NOTARIZE == 1 ]]; then
  first="2. Open it from Applications (signed with Developer ID and notarized by Apple)."
else
  first="2. First launch: right-click the app in Applications, choose Open, then Open again
   (the app is ad hoc signed, not notarized)."
fi
cat > "$WORK/dmg/Read Me.txt" <<EOF
GTNW Chess $VERSION (build $BUILD)

1. Drag "GTNW Chess" onto Applications.
$first

Source and docs: https://github.com/kochj23/GTNWChess
Bundles Stockfish 19 (GPLv3); its licence and source offer are in Settings > About.
EOF
hdiutil create -volname "GTNW Chess $VERSION" -srcfolder "$WORK/dmg" -format UDZO -ov "$WORK/$NAME.dmg" >/dev/null

if [[ $NOTARIZE == 1 ]]; then
  codesign --force --timestamp -s "$ID" "$WORK/$NAME.dmg"
  log "submitting to Apple's notary service (usually a few minutes)"
  xcrun notarytool submit "$WORK/$NAME.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$WORK/$NAME.dmg"
fi

log "verifying the image"
MNT="$(mktemp -d "$WORK/mnt.XXXXXX")"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$WORK/$NAME.dmg" >/dev/null
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true' EXIT
[[ -d "$MNT/$APP_NAME.app" && -L "$MNT/Applications" ]] || fail "image layout"
codesign --verify --deep --strict "$MNT/$APP_NAME.app" || fail "signature in the image"
check_clean "$MNT/$APP_NAME.app"
if [[ $NOTARIZE == 1 ]]; then
  gk="$(spctl -a -t exec -vv "$MNT/$APP_NAME.app" 2>&1 || true)"
  [[ "$gk" == *"Notarized Developer ID"* ]] || { echo "$gk" >&2; fail "Gatekeeper does not accept the app"; }
fi
hdiutil detach -quiet "$MNT"; trap - EXIT
SUM="$(shasum -a 256 "$WORK/$NAME.dmg" | awk '{print $1}')"

if [[ $DRY == 1 ]]; then
  for d in "${DESTS[@]}"; do log "dry run: would copy $NAME.dmg to $d/$FOLDER/"; done
  log "dry run OK: $WORK/$NAME.dmg sha256 $SUM"
  exit 0
fi
for d in "${DESTS[@]}"; do
  mkdir -p "$d/$FOLDER"
  cp "$WORK/$NAME.dmg" "$WORK/dmg/Read Me.txt" "$d/$FOLDER/"
  [[ "$(shasum -a 256 "$d/$FOLDER/$NAME.dmg" | awk '{print $1}')" == "$SUM" ]] || fail "copy to $d is corrupt"
  log "copied to $d/$FOLDER/$NAME.dmg"
done
log "done: sha256 $SUM"
