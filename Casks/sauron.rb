cask "sauron" do
  version "0.1.22"
  sha256 "e82e6d35a382e0d68a9a85f8756ab576cd61820ccc1ee148f571d37cbba7a8ee"

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

    Sauron requires headphones while recording. Without them, the
    meeting's speaker audio leaks into your microphone.
  EOS
end
