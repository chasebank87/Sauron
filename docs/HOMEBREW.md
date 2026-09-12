# Homebrew

Sauron ships as a notarized macOS app via GitHub Releases and a **personal tap** cask.

## Install

```bash
brew tap chasebank87/sauron
brew install --cask sauron
```

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
3. Bump `version` and `sha256` in:
   - [`Casks/sauron.rb`](../Casks/sauron.rb) (this repo)
   - `chasebank87/homebrew-sauron` (`Casks/sauron.rb`)
   - Official `homebrew-cask` via `brew bump-cask-pr sauron --version X.Y.Z` once accepted upstream
4. Push the tap; users’ next `brew update && brew upgrade --cask sauron` picks it up

`livecheck` (GitHub latest) lets `brew livecheck --cask sauron` and `brew bump-cask-pr` detect new tags.

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

## Official homebrew-cask

After the cask is merged upstream, bump with:

```bash
brew bump-cask-pr sauron --version X.Y.Z
```

## Permissions

Sauron is a menu-bar (`LSUIElement`) app. Users must grant:

- Screen Recording (meeting window + system audio)
- Microphone
- Speech Recognition
- Calendar (optional, for Up Next)
