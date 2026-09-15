cask "sauron" do
  version "0.1.15"
  sha256 "1d8f5ef6037d73f4e08750ccec12d7f3ea88ac5df43262c4e4e099bef20f1cd2"

  url "https://github.com/chasebank87/Sauron/releases/download/v#{version}/Sauron-#{version}.zip"
  name "Sauron"
  desc "Menu bar meeting assistant with local capture, transcripts, and memory"
  homepage "https://github.com/chasebank87/Sauron"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "Sauron.app"

  zap trash: [
    "~/Library/Application Support/Sauron",
    "~/Library/Preferences/app.sauron.Sauron.plist",
  ]

  caveats <<~EOS
    Sauron needs Screen Recording, Microphone, and Speech Recognition
    permission on first launch (System Settings → Privacy & Security).
  EOS
end
