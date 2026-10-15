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

  # uninstall.sh fragt nach, ob Stimmdatenbank und Whisper-Modell gelöscht werden sollen; ohne Terminal-Eingabe
  # bleiben beide liegen. Aufnahmen unter ~/Transcriber bleiben immer.
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
  EOS
end
