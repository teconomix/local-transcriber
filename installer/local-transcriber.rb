# Homebrew-Cask (Vorlage) – scripts/make-release.sh füllt __VERSION__/__SHA256__/__BASE__ und legt das Ergebnis nach
# dist/homebrew/local-transcriber.rb; von dort ins Tap-Repo github.com/teconomix/homebrew-tap (Casks/).
# Der Cask lädt nur den versionierten Installer und führt ihn aus – der erledigt alles wie beim curl-Weg
# (Prüfsummen, Python-Umgebung, Modelle, App in ~/Applications). brew upgrade = Installer erneut = Update.
cask "local-transcriber" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "__BASE__/download/#{version}/install.sh"
  name "Local Transcriber"
  desc "Transcribe meetings, calls and dictation locally, with speaker recognition"
  homepage "__BASE__/"

  livecheck do
    url "__BASE__/latest.txt"
    regex(/^(\d+(?:\.\d+)+)$/)
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  installer script: {
    executable: "/bin/bash",
    args:       ["#{staged_path}/install.sh", "--yes", "--no-watch"],
  }

  # Läuft auch bei brew upgrade. uninstall.sh erkennt, dass es kein Terminal im Vordergrund hat, und entfernt nur App und
  # Wächter; Programmdaten, Modelle und Stimmdatenbank bleiben. Aufnahmen unter ~/Transcriber bleiben immer.
  uninstall script: {
    executable: "/bin/bash",
    args:       ["-c", 'f="$HOME/.local/share/transcriber/uninstall.sh"; [ -f "$f" ] && bash "$f" || true'],
  }

  caveats <<~EOS
    Transcriber lives in ~/Applications and the menu bar. Your recordings and transcripts
    stay in ~/Transcriber, also after `brew uninstall`.
    Folder watcher (optional, transcribes audio files dropped into ~/Transcriber):
      curl -fsSL __BASE__/install.sh | bash      # answer "y" to the watcher question
    Once set up, brew upgrade keeps it running.
    brew uninstall removes the app and keeps its data. To remove that too, run this first:
      bash ~/.local/share/transcriber/uninstall.sh
  EOS
end
