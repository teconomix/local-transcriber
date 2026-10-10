#!/bin/zsh
# Testet die Umbenennung ~/Transkription → ~/Transcriber aus installer/install.sh mit einem Schein-Home-Ordner.
# Der Block wird aus dem Installer ausgeschnitten (zwischen den Markierungen), damit genau der ausgelieferte Code läuft.
set -euo pipefail
ROOT="${0:A:h:h}"
PY="${TRANSCRIBER_PY:-$HOME/.local/share/transcriber/venvs/app/bin/python}"
S=$(mktemp -d); trap "rm -rf '$S'" EXIT
H="$S/home"; mkdir -p "$H/Transkription/Aufnahmen" "$S/data/venvs/app/bin" "$S/data/jobs"
ln -s "$PY" "$S/data/venvs/app/bin/python"
touch "$H/Transkription/Aufnahmen/Aufnahme 2026-10-10 14-03.m4a"
sqlite3 "$S/data/speakers.db" "CREATE TABLE embeddings(source TEXT); CREATE TABLE jobs(source TEXT, transcript TEXT);
  INSERT INTO embeddings VALUES('$H/Transkription/Aufnahmen/a.m4a'),('/Volumes/Extern/b.m4a'),('$H/Transkription-alt/c.m4a');
  INSERT INTO jobs VALUES('$H/Transkription/Aufnahmen/a.m4a','$H/Transkription/Aufnahmen/a.transcript.json');"
print -r -- "{\"source\": \"$H/Transkription/Aufnahmen/a.m4a\", \"result\": {\"md\": \"$H/Transkription/Aufnahmen/a.md\"}, \"progress\": 1.0}" > "$S/data/jobs/j.json"

sed -n '/# Bis 0.5 hieß der Datenordner/,/mkdir -p "\$HOME\/Transcriber"/p' "$ROOT/installer/install.sh" > "$S/block.sh"
[[ -s "$S/block.sh" ]] || { echo "✗ Umbenennungs-Block im Installer nicht gefunden"; exit 1; }
cat > "$S/run.sh" <<RUN
set -euo pipefail
HOME="$H"; DATA="$S/data"; DE=1
t() { printf '%s' "\$1"; }; ok() { :; }; warn() { echo "WARN: \$*"; }; die() { echo "DIE: \$*"; exit 1; }
launchctl() { :; }
$(cat "$S/block.sh")
RUN
fail() { echo "✗ Installer-Umbenennung: $*"; exit 1; }
bash "$S/run.sh"
[[ -f "$H/Transcriber/Aufnahmen/Aufnahme 2026-10-10 14-03.m4a" && ! -e "$H/Transkription" ]] || fail "Ordner nicht umbenannt"
[[ "$(sqlite3 "$S/data/speakers.db" 'SELECT group_concat(source, "|") FROM embeddings')" == \
   "$H/Transcriber/Aufnahmen/a.m4a|/Volumes/Extern/b.m4a|$H/Transkription-alt/c.m4a" ]] || fail "embeddings falsch"
[[ "$(sqlite3 "$S/data/speakers.db" 'SELECT transcript FROM jobs')" == "$H/Transcriber/Aufnahmen/a.transcript.json" ]] || fail "jobs falsch"
grep -q "$H/Transcriber/Aufnahmen/a.md" "$S/data/jobs/j.json" && ! grep -q Transkription/ "$S/data/jobs/j.json" || fail "Statusdatei falsch"
mkdir "$H/Transkription"; bash "$S/run.sh"                # zweiter Lauf: ~/Transcriber existiert → nichts anfassen
[[ -d "$H/Transkription" ]] || fail "zweiter Lauf hat trotzdem umbenannt"
echo "✓ Installer-Umbenennung"
