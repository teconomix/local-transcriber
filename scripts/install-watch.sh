#!/bin/zsh
# Ordnerüberwachung (~/Transkription) als LaunchAgent einrichten bzw. mit „--remove“ entfernen.
set -euo pipefail
P=~/Library/LaunchAgents/net.teconomix.transcriber.watch.plist
launchctl bootout gui/$(id -u) "$P" 2>/dev/null || true
if [[ "${1:-}" == "--remove" ]]; then rm -f "$P"; echo "entfernt"; exit 0; fi
mkdir -p ~/Library/LaunchAgents
sed "s#__HOME__#$HOME#g" "${0:A:h}/net.teconomix.transcriber.watch.plist" > "$P"
launchctl bootstrap gui/$(id -u) "$P"
echo "läuft – Log: ~/.local/share/transcriber/watch.log"
