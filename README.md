# Magnetite

Free, open-source Spotify and Apple Music controls in your MacBook notch, with ferrofluid that moves to your music.

[![Magnetite playing Chrome Funk: album art, playback controls and a liquid outline around the camera notch](site/media/app-open.webp)](https://magnetite.app/media/film.mp4)

[![Latest release](https://img.shields.io/github/v/release/scryst/magnetite-releases)](https://github.com/scryst/magnetite-releases/releases/latest) [![macOS 26 or later](https://img.shields.io/badge/macOS-26%2B-222022)](#requirements) [![MIT licence](https://img.shields.io/badge/license-MIT-222022)](LICENSE)

## Install

**[Download the latest release](https://github.com/scryst/magnetite-releases/releases/latest)** (or [all versions and checksums](https://github.com/scryst/magnetite-releases/releases)), then open it the first time like this:

1. Open the ZIP, drag **Magnetite** to Applications, then double-click it.
2. macOS says it can't verify Magnetite. That's expected for a free app that isn't in Apple's paid programme. Click **Done**.
3. Open **System Settings → Privacy & Security** and scroll down to **Security**. Click **Open Anyway** next to Magnetite, then confirm with Touch ID or your password.
4. Look for the **M** in the menu bar. Play something in Spotify or Music and hover the notch. Allow the two permission prompts: one to control Spotify or Music, one to record system audio for the visualiser.

You only do this once. Magnetite is ad-hoc signed and not notarised by Apple, so only open a download you trust. On macOS 15 and later, right-click → Open no longer skips the warning.

Prefer to skip the warning? [Read the installer](https://github.com/scryst/magnetite/blob/main/install.sh), then paste this into Terminal (Spotlight → Terminal):

```sh
curl -fsSL https://magnetite.app/install.sh | sh
```

The installer checks the published SHA-256 and code signature, installs into `/Applications` (or `~/Applications` if needed), and opens the app. The checksum and signature confirm the download is intact; Apple hasn't reviewed it. Run it again to update.

## See what it does

These frames come from a [31-second screen recording](https://magnetite.app/media/film.mp4). Click one to play that part.

### Music becomes liquid

The black outline around the notch moves with whatever your Mac is playing.

<a href="https://magnetite.app/media/film.mp4#t=0,6"><img src="site/media/app-open.webp" width="520" alt="Expanded player with ferrofluid responding around the notch"></a>

### Credited artists

Featured artists show alongside the lead ("A, B & C"), and each name opens that artist in Spotify or Music. Connected Spotify uses its catalogue credits; Apple Music uses the collaborations named in its artist field. Anything unresolved opens a search.

### Skip with a swipe

Two fingers sideways change tracks; up or down plays or pauses.

[![The player after a two-finger skip changes the track](docs/media/skip.webp)](https://magnetite.app/media/film.mp4#t=1,10)

### Seek on the edge

Drag the player's bottom outline to move through a track.

[![Pointer dragging the progress strip along the bottom of the player](docs/media/seek.webp)](https://magnetite.app/media/film.mp4#t=17,20)

### Back into the menu bar

Move away and the player folds into a mini player: the cover and elapsed time either side of the camera. Hover to open it again, or turn off **Mini Player When Closed** in the **M** menu for a bare notch.

[![Mini player with artwork and elapsed time beside the camera notch](docs/media/retracted.webp)](https://magnetite.app/media/film.mp4#t=21,31)

Film: [Punch Deck](https://punchdeck.bandcamp.com)'s “Chrome Funk,” “Cyberpunk Renaissance” and “Neon Underworld,” [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Frames are cropped from that recording; see [media provenance](docs/media/README.md).

## Requirements

- **macOS 26 or later, Apple silicon.** Intel Macs and earlier macOS versions are unsupported. To check, open Apple menu → About This Mac: it should say Chip Apple M… and macOS 26.
- **Spotify or Apple Music desktop app** for playback controls. The visualiser responds to system audio.
- A notched MacBook is the intended home. Displays without a notch use a floating pill.

## Privacy and permissions

No Magnetite account, analytics, telemetry or crash reporter. Audio is processed in memory on your Mac; it is never saved or uploaded.

- **Automation / Apple Events** (the same macOS permission used by AppleScript): reads now-playing information and controls the local Spotify or Music app through ScriptingBridge. Ordinary playback needs no Spotify Web API connection.
- **System audio recording:** a CoreAudio process tap reads the system mix for the ferrofluid visualiser. It does not record your microphone or upload audio.
- **Artwork downloads:** fetches the current cover from the URL supplied by the music player, then uses its colours in the interface.
- **Optional Spotify connection:** `user-library-read` and `user-library-modify` read/save/remove liked tracks; `user-read-playback-state` and `user-modify-playback-state` support shuffle/repeat; `user-read-private` checks account capability before offering those controls.

Spotify authorization uses PKCE, without a client secret. Its refresh token is kept in an owner-only (`0600`) file under `~/Library/Application Support/Magnetite`; disconnecting deletes it. Preferences stay in macOS UserDefaults. [Full privacy details](https://magnetite.app/privacy.html).

## FAQ and troubleshooting

<details>
<summary><b>macOS blocked the first launch. What now?</b></summary>

Follow the numbered steps under [Install](#install): double-click the app, click **Done**, then use **System Settings → Privacy & Security → Open Anyway**. The build is not notarised by Apple, which is why macOS asks. The Terminal installer downloads with `curl`, which does not add browser quarantine; it still checks the checksum and code signature. You do not need to disable Gatekeeper system-wide.

</details>

<details>
<summary><b>There is no track, or the liquid is still.</b></summary>

Open Spotify or Music and start a track on this Mac. Check the selected music source in Magnetite's **M** menu. In **System Settings → Privacy & Security → Automation**, allow Magnetite to control that player. For the visualiser, enable Magnetite under **Screen & System Audio Recording** (the label may vary with macOS), then quit and reopen Magnetite. Audio permission and playback permission are separate.

</details>

<details>
<summary><b>Do I need to connect Spotify?</b></summary>

Not for everyday listening: play, pause, skip, seek and the visualiser work with the Spotify desktop app, and Apple Music needs nothing extra. Liked songs, shuffle and repeat need a free Spotify developer app of your own, which takes a few minutes. To connect, choose **Connect Spotify Library…**, create an app in the [Spotify developer dashboard](https://developer.spotify.com/dashboard) with **Web API** and redirect URI `http://127.0.0.1:8888/callback`, then enter its Client ID. Apple Music favourites need no Spotify setup.

</details>

<details>
<summary><b>Does it work without a notch or in fullscreen?</b></summary>

Notchless displays get a floating pill. It hides on lock, screensaver and detected fullscreen, per display. Automatic menu-bar hiding limits fullscreen detection; Mission Control is not handled. Calibrate the notch from the **M** menu if the shape does not match your hardware.

</details>

<details>
<summary><b>How do I update or uninstall?</b></summary>

Rerun the installer or replace the app with the latest release. To uninstall, disconnect Spotify if connected, quit from the **M** menu, then delete Magnetite.app. Optional settings cleanup: remove `~/Library/Application Support/Magnetite` and run `defaults delete com.laks.magnetite` in Terminal.

</details>

## Build from source

Requires macOS 26+, Apple silicon and the Command Line Tools (`xcode-select --install`). No Xcode project is needed.

```sh
git clone https://github.com/scryst/magnetite.git
cd magnetite
./build.sh release
open build.noindex/Magnetite.app
```

To build and install into Applications instead, use `./install.sh --from-source`.

## Contributing

[Bug reports and focused pull requests](CONTRIBUTING.md) are welcome. [PRODUCT.md](PRODUCT.md) has the design principles and [APP.md](APP.md) explains how the app is built. Run `./check.sh` before a PR; [engineering notes](docs/ENGINEERING.md) explain focused checks and release tooling. Report vulnerabilities privately using [SECURITY.md](SECURITY.md).

## Licence

[MIT](LICENSE). The demo soundtrack and its artwork are credited under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); the Gloock font uses the [SIL Open Font License](site/fonts/OFL-Gloock.txt).
