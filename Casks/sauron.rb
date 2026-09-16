cask "sauron" do
  version "0.1.23"
  sha256 "6bcf44b2a51e3586668a224860e459bd670e4f3cc154fa3f7b9e97070be535ab"

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
