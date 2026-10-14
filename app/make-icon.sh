#!/bin/zsh
# App-Symbol erzeugen: website/assets/icon.svg → Resources/AppIcon.icns (alle Größen 16–1024 px, @1x/@2x).
# Nach macOS-Raster: Motiv 824 × 824 px mittig auf 1024 px, sonst setzt macOS 26 es in eine graue Kachel.
# Nur nötig, wenn sich das Symbol ändert; das Ergebnis liegt im Repo.
set -euo pipefail
cd "${0:A:h}"
S=$(mktemp -d); trap "rm -rf '$S'" EXIT
cat > "$S/r.swift" <<'SWIFT'
import AppKit
let a = CommandLine.arguments
guard let svg = NSImage(contentsOf: URL(fileURLWithPath: a[1])) else { fatalError("SVG nicht lesbar") }
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let m = Double(px) * 100 / 1024                       // Rand nach Apple-Raster (100 von 1024)
    svg.draw(in: NSRect(x: m, y: m, width: Double(px) - 2 * m, height: Double(px) - 2 * m))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(a[2])/\(px).png"))
}
SWIFT
swiftc -O "$S/r.swift" -o "$S/r" 2>/dev/null
mkdir -p "$S/png" "$S/AppIcon.iconset"
"$S/r" ../website/assets/icon.svg "$S/png"
for n in 16 32 128 256 512; do
  cp "$S/png/$n.png" "$S/AppIcon.iconset/icon_${n}x${n}.png"
  cp "$S/png/$((n * 2)).png" "$S/AppIcon.iconset/icon_${n}x${n}@2x.png"
done
iconutil -c icns "$S/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns"
