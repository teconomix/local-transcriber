#!/bin/zsh
# Prüft, ob en.lproj/Localizable.strings genau die Texte abdeckt, die der Compiler als übersetzbar erkennt
# (SwiftUI-Literale, String(localized:)). Schlüssel = deutscher Text; fehlt einer, zeigt die App ihn deutsch an.
# Dynamische Schlüssel (Statuscodes aus dem Kern, Text(LocalizedStringKey(status))) stehen unten in DYNAMIC.
set -euo pipefail
cd "${0:A:h}"
OUT=$(mktemp -d)
swift build -c release --scratch-path ~/.local/share/transcriber/build/app \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null
python3 - "$OUT" Resources/en.lproj/Localizable.strings <<'PY'
import glob, json, plistlib, subprocess, sys
DYNAMIC = {"sicher", "bestätigt"}
keys = set()
for f in glob.glob(sys.argv[1] + "/*.stringsdata"):
    for entries in json.load(open(f)).get("tables", {}).values():
        keys |= {e["key"] for e in entries}
en = plistlib.loads(subprocess.run(["plutil", "-convert", "xml1", "-o", "-", sys.argv[2]], capture_output=True, check=True).stdout)
missing, extra = sorted(keys - en.keys()), sorted(en.keys() - keys - DYNAMIC)
for k in missing: print("fehlt:      ", k)
for k in extra: print("überzählig: ", k)
print(f"{len(keys)} Texte im Code, {len(en)} übersetzt")
sys.exit(1 if missing or extra else 0)
PY
rm -rf "$OUT"
