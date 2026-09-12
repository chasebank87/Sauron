# Homebrew

Sauron ships as a notarized macOS app via GitHub Releases and a **personal tap** cask.

## Build a release zip

```bash
./scripts/package-release.sh 0.1.0
```

Optional notarization (Developer ID + App Store Connect API key in a notarytool profile):

```bash
export NOTARIZE_PROFILE=SauronNotary
export CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./scripts/package-release.sh 0.1.0
```

Upload `dist/Sauron-0.1.0.zip` to a GitHub Release tagged `v0.1.0`.

## Personal tap

1. Create a repo named `homebrew-sauron` (or add `Casks/sauron.rb` to an existing tap).
2. Copy [`Casks/sauron.rb`](../Casks/sauron.rb) and set `version` + `sha256` from the release artifact.
3. Install:

```bash
brew tap chasebank87/sauron
brew install --cask sauron
```

## Official homebrew-cask (later)

After a public notarized release:

1. Fork `Homebrew/homebrew-cask`
2. Add `Casks/s/sauron.rb` with the release URL + sha256
3. Open a PR following [Homebrew cask contributing docs](https://docs.brew.sh/Adding-Software-to-Homebrew)

## Permissions

Sauron is a menu-bar (`LSUIElement`) app. Users must grant:

- Screen Recording (meeting window + system audio)
- Microphone
- Speech Recognition
- Calendar (optional, for Up Next)
