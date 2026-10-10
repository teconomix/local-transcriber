#!/bin/zsh
# Release bauen: dist/download/<VERSION>/ mit App-Zip, Python-Quellpaket, pyannote-Modell, Deinstaller, Prüfsummen,
# dazu dist/install.sh (Version und Download-Basis eingesetzt). Hochladen: website/deploy.sh.
#   scripts/make-release.sh [BASE-URL]     (Standard: https://transcriber.teconomix.net)
set -euo pipefail
cd "${0:A:h}/.."
V=$(cat VERSION)
BASE="${1:-https://transcriber.teconomix.net}"
OUT="dist/download/$V"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "▸ App bauen ($V)"
SCRATCH=~/.local/share/transcriber/build/app
swift build -c release --package-path app --scratch-path "$SCRATCH" >/dev/null
APP="$OUT/Transcriber.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/release/Transcriber" "$APP/Contents/MacOS/"
sed -e "s#<key>CFBundleShortVersionString</key><string>[^<]*</string>#<key>CFBundleShortVersionString</key><string>$V</string>#" \
    -e "s#<key>CFBundleVersion</key><string>[^<]*</string>#<key>CFBundleVersion</key><string>${V//./}</string>#" \
    app/Resources/Info.plist > "$APP/Contents/Info.plist"
cp -R app/Resources/*.lproj "$APP/Contents/Resources/"   # de (leer, Quelltext) + en
# Signatur wie build-app.sh: festes, selbst signiertes Zertifikat → Freigaben bleiben über Updates erhalten.
KC=~/.local/share/transcriber/signing/transcriber-signing.keychain-db
if [[ -f $KC ]]; then
  security unlock-keychain -p "$(security find-generic-password -s transcriber-signing-keychain -w)" "$KC"
  codesign --force --keychain "$KC" --sign "Transcriber Local Signing" "$APP"
else
  echo "  ! Signatur-Schlüsselbund fehlt – ad hoc signiert (Freigaben gehen bei Updates verloren)"; codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
(cd "$OUT" && ditto -c -k --keepParent Transcriber.app "Transcriber-$V.zip" && rm -rf Transcriber.app)

echo "▸ Python-Quellpaket"
uv build --sdist --out-dir "$OUT" >/dev/null
[[ -f "$OUT/transcriber-$V.tar.gz" ]] || { echo "sdist fehlt"; exit 1; }

echo "▸ pyannote community-1 (CC-BY-4.0, mit Namensnennung)"
SNAP=$(ls -d ~/.cache/huggingface/hub/models--pyannote--speaker-diarization-community-1/snapshots/*/ | head -1)
T=$(mktemp -d); mkdir -p "$T/speaker-diarization-community-1"
cp -RL "$SNAP"/. "$T/speaker-diarization-community-1/"
cat > "$T/speaker-diarization-community-1/LICENSE-NOTICE.txt" <<'TXT'
pyannote/speaker-diarization-community-1 – © pyannoteAI, licensed under CC BY 4.0
(https://creativecommons.org/licenses/by/4.0/). Source: https://huggingface.co/pyannote/speaker-diarization-community-1
Redistributed unmodified as part of Transcriber.
TXT
tar -czf "$OUT/pyannote-community-1.tar.gz" -C "$T" speaker-diarization-community-1; rm -rf "$T"

cp installer/uninstall.sh "$OUT/uninstall.sh"
(cd "$OUT" && shasum -a 256 "Transcriber-$V.zip" "transcriber-$V.tar.gz" pyannote-community-1.tar.gz uninstall.sh > SHA256SUMS)
sed -e "s#__VERSION__#$V#" -e "s#__BASE__#$BASE#" installer/install.sh > dist/install.sh
echo "$V" > dist/latest.txt
echo "▸ fertig:"; ls -la "$OUT" dist/install.sh
