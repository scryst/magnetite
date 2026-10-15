# Magnetite

Free, open-source Spotify and Apple Music controls in your MacBook notch,
with ferrofluid that moves to your music.

**[Download the latest release](https://github.com/scryst/magnetite-releases/releases/latest)**
· [See the app](https://magnetite.app/)
· [Source, features and FAQ](https://github.com/scryst/magnetite)

Requires **macOS 26 or later on Apple silicon**. Notchless displays use a floating
pill. This repository holds official binaries and release notes; development
happens in [scryst/magnetite](https://github.com/scryst/magnetite).

## Install or update

Download the ZIP, unzip it and drag Magnetite.app to Applications. The current
build is ad-hoc signed and not Apple-notarised: after trying to open it, approve
it under System Settings → Privacy & Security → Open Anyway if you trust it.

Or [inspect the installer](https://github.com/scryst/magnetite/blob/main/install.sh),
then run:

```sh
curl -fsSL https://magnetite.app/install.sh | sh
```

It downloads the latest official release, checks the published SHA-256 and code
signature, then installs and opens the app. Those checks verify integrity, not
Apple notarisation. Rerun it to update. Start Spotify or Music on this Mac and
hover the notch; the M menu holds settings and Quit.

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
