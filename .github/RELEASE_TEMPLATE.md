# Magnetite v<VERSION>

<One sentence about the user-visible improvement in this release.>

## Changes

- <Specific feature or fix, with a source issue/commit link.>
- <Known limitation that matters to someone updating.>

## Install or update

Requires **macOS 26 or later on Apple silicon**. Download `Magnetite-<VERSION>.zip`,
unzip it and move Magnetite.app to Applications. Or inspect and run the installer:

```sh
curl -fsSL https://magnetite.app/install.sh | sh
```

<State the verified signing and notarisation status of THIS artifact. If it is
not notarised, include System Settings → Privacy & Security → Open Anyway.>

## Verify the download

Keep the ZIP and matching `.sha256` file from this release together, then run:

```sh
shasum -a 256 -c Magnetite-<VERSION>.sha256
```

Expected: `Magnetite-<VERSION>.zip: OK`.

Source revision: <exact source commit URL>
Checks: <actual gate results and rendered/native proof; do not infer from build success>

[Privacy](https://magnetite.app/privacy.html) ·
[Report a bug](https://github.com/scryst/magnetite/issues) ·
[Source](https://github.com/scryst/magnetite)
