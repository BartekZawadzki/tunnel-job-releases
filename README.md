# Tunnel Job releases

Installers of **Tunnel Job**, a 5 v 5 heist game on a destructible block grid for Windows.

- Download `TunnelJob-Setup.exe` from the [latest release](../../releases/latest) and run it. It installs for the current
  user only and asks for no administrator rights.
- `SHA256SUMS.txt` lists the checksums of the files of a release.
- An installed game updates itself: when a newer release appears here, the main menu offers it, downloads the installer,
  checks it against the checksum list and installs it.

This repository holds releases only. It has no source code.

The macOS disk image of each release is signed with a Developer ID, notarized by Apple and stapled by the
`Sign macOS dmg` workflow (`.github/workflows/sign-mac.yml`, script `mac/sign-release.sh`) shortly after the release is
published; it replaces `Breachworks-macOS.dmg` and only that file's line in `SHA256SUMS.txt`.
