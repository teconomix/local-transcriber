#!/bin/zsh
# Versionsvergleich des Update-Hinweises (UpdateCheck.isNewer), aus dem App-Code ausgeschnitten und einzeln übersetzt.
set -euo pipefail
ROOT="${0:A:h:h}"
S=$(mktemp -d); trap "rm -rf '$S'" EXIT
{ sed -n '/nonisolated static func isNewer/,/^    }/p' "$ROOT/app/Sources/Transcriber/UpdateCheck.swift" | sed 's/nonisolated static //'
  cat <<'SWIFT'
let cases: [(String, String, Bool)] = [("0.6.0", "0.5.0", true), ("0.5.0", "0.5.0", false), ("0.5.1", "0.5.0", true),
    ("0.10.0", "0.9.1", true), ("0.9.1", "0.10.0", false), ("1.0", "0.99.9", true), ("0.5", "0.5.0", false),
    ("0.4.9", "0.5.0", false)]
let bad = cases.filter { isNewer($0.0, than: $0.1) != $0.2 }
for b in bad { print("✗ isNewer(\(b.0), than: \(b.1)) sollte \(b.2) sein") }
if !bad.isEmpty { exit(1) }
SWIFT
} > "$S/main.swift"
grep -q 'func isNewer' "$S/main.swift" || { echo "✗ isNewer nicht gefunden"; exit 1; }
swiftc -O "$S/main.swift" -o "$S/t" 2>/dev/null && "$S/t"
echo "✓ Update-Versionsvergleich"
