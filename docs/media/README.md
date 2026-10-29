# Media

`player.webp`, the README's picture, is the frame at 9 s of
`site/media/demo.mp4`, scaled to 1200 px and encoded with `cwebp -q 86`.

The film is the app's own panel, not a screen recording. `tools/sitefilm`
renders the real SwiftUI view offscreen, frame by frame, with the ferrofluid
driven by the track's audio through the app's own analysis, then muxes that
audio back in. `site/media/demo-poster.webp` is its first frame.

The music is `docs/media/encryption.mp3`, "Encryption" by
[Beat Mekanik](https://freemusicarchive.org/music/beat-mekanik/), from the
[Free Music Archive](https://freemusicarchive.org/music/beat-mekanik/single/encryption/)
under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), re-encoded to
160 kbps MP3; `site/media/cover-encryption.webp` is its cover, resized to 176 px.
The page and the README credit it by artist, title, licence and link.
