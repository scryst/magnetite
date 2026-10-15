# Magnetite

Free, open-source Spotify and Apple Music controls in your MacBook notch,
with ferrofluid that moves to your music.

[![Magnetite turns the MacBook camera notch into sound-driven black ferrofluid.](https://magnetite.app/og.png)](https://magnetite.app/)

**[Download the latest release](https://github.com/scryst/magnetite-releases/releases/latest)**
· [See the app](https://magnetite.app/)
· [Source, features and FAQ](https://github.com/scryst/magnetite)

Requires **macOS 26 or later on Apple silicon**. Notchless displays use a floating
pill. This repository holds official binaries and release notes; development
happens in [scryst/magnetite](https://github.com/scryst/magnetite).

## Install or update

Download the ZIP, then open it the first time like this:

1. Open the ZIP, drag Magnetite to Applications, then double-click it.
2. macOS says it can't verify Magnetite. That's expected for a free app that
   isn't in Apple's paid programme. Click Done.
3. Open System Settings → Privacy & Security and scroll down to Security. Click
   Open Anyway next to Magnetite, then confirm with Touch ID or your password.
4. Look for the M in the menu bar. Play something in Spotify or Music and hover
   the notch. Allow the two permission prompts: one to control Spotify or Music,
   one to record system audio for the visualiser.

You only do this once. The build is ad-hoc signed and not notarised by Apple,
so only open a download you trust.

Prefer to skip the warning? [Inspect the installer](https://github.com/scryst/magnetite/blob/main/install.sh),
then paste this into Terminal (Spotlight → Terminal):

```sh
curl -fsSL https://magnetite.app/install.sh | sh
```

It downloads the latest official release, checks the published SHA-256 and code
signature, then installs and opens the app. The checksum and signature confirm
the download is intact; Apple hasn't reviewed it. Run it again to update. The M menu holds
settings and Quit.

## Verify a manual download

Put only this release's ZIP and matching `.sha256` file in a fresh folder, open
Terminal in that folder, and run:

```sh
shasum -a 256 -c Magnetite-*.sha256
```

The matching ZIP must report `OK`. Do not install if the checksum fails.

## Help and source

- [Features, requirements, permissions and troubleshooting](https://github.com/scryst/magnetite#readme)
- [Report a bug](https://github.com/scryst/magnetite/issues)
- [Private security reporting](https://github.com/scryst/magnetite-releases/security/policy)
- [Privacy](https://magnetite.app/privacy.html) · [Terms](https://magnetite.app/terms.html)
- [Source and MIT licence](https://github.com/scryst/magnetite)

No Magnetite account, analytics or audio uploads. Optional Spotify authorization
and artwork requests are described in the privacy notice.
