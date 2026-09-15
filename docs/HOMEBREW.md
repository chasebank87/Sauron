# Homebrew

Sauron ships as a notarized macOS app via GitHub Releases and a **personal tap** cask.

## Install

```bash
brew tap chasebank87/sauron https://github.com/chasebank87/Sauron
brew install --cask sauron
```

`brew tap chasebank87/sauron` with **no URL** clones `chasebank87/homebrew-sauron`. Sauron’s cask lives in **this** repo, so the install command must pass the GitHub URL above.

## Upgrades

Homebrew does **not** auto-upgrade from a GitHub Release alone. It upgrades when the **cask file** in the tap has a newer `version` + `sha256` than the installed copy.

**Users:**

```bash
brew update
brew upgrade --cask sauron
```

**Maintainers (each new release):**

1. Build + notarize: `./scripts/package-release.sh X.Y.Z` (with `CODE_SIGN_IDENTITY` + `NOTARIZE_PROFILE`)
2. Publish GitHub Release `vX.Y.Z` with `Sauron-X.Y.Z.zip`
3. Bump `version` and `sha256` in [`Casks/sauron.rb`](../Casks/sauron.rb) in this repo (the custom tap)
4. Push this repo; users’ next `brew update && brew upgrade --cask sauron` picks it up

`livecheck` (GitHub latest) lets `brew livecheck --cask sauron` detect new tags. Do **not** run `brew bump-cask-pr` against official Homebrew taps.

## Build a release zip

```bash
./scripts/package-release.sh 0.1.0
```

Notarization (Developer ID + notarytool profile):

```bash
export NOTARIZE_PROFILE=SauronNotary
export CODE_SIGN_IDENTITY="Developer ID Application: Chase Elder (MZSC4FTLNA)"
./scripts/package-release.sh 0.1.0
```

Upload `dist/Sauron-0.1.0.zip` to a GitHub Release tagged `v0.1.0`.

## Permissions

Sauron is a menu-bar (`LSUIElement`) app. Users must grant:

- Screen Recording (meeting window + system audio)
- Microphone
- Speech Recognition
- Calendar (optional, for Up Next)

For speaker-echo reject without headphones, install the **Sauron Audio** virtual device from Settings and set the meeting app’s speaker to it. See [VIRTUAL_AUDIO.md](VIRTUAL_AUDIO.md).
