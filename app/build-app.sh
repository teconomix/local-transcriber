#!/bin/zsh
# Baut Transcriber.app ohne Xcode (Command Line Tools genügen) und legt sie nach ~/Applications.
# Build-Zwischenstände liegen außerhalb von Syncthing.
set -euo pipefail
cd "${0:A:h}"
SCRATCH=~/.local/share/transcriber/build/app
swift build -c release --scratch-path "$SCRATCH"
APP=~/Applications/Transcriber.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/release/Transcriber" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"     # Englisch; Deutsch = Quelltext (CFBundleDevelopmentRegion)
# Feste Signatur (selbst signiertes Zertifikat, eigener Schlüsselbund): macOS merkt sich die Freigaben (Mikrofon,
# Bildschirmaufnahme, Bedienungshilfen) über Neubauten hinweg. Ad hoc signiert fragte es nach jedem Bau neu.
# Schlüsselbund-Passwort liegt im Anmelde-Schlüsselbund (Eintrag „transcriber-signing-keychain“), nicht in Dateien.
KC=~/.local/share/transcriber/signing/transcriber-signing.keychain-db
if [[ -f $KC ]]; then
  security unlock-keychain -p "$(security find-generic-password -s transcriber-signing-keychain -w)" "$KC"
  codesign --force --keychain "$KC" --sign "Transcriber Local Signing" "$APP"
else
  echo "WARNUNG: $KC fehlt – signiere ad hoc (Freigaben müssen nach jedem Bau neu erteilt werden)" >&2
  codesign --force --sign - "$APP"
fi
echo "$APP"
