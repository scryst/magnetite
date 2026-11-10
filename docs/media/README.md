# Media

The README's loops are animated WebP, because GitHub does not play a video in a
README on its own. `tools/readme-loops` rebuilds all of them from the site's films
in `site/media/`: `hero` and `ink` are stretches of `demo.mp4` over a held lyric
whose last 0.4 s crossfade into their first frames; `hover`, `swipe`, `drag`,
`lyrics` and `closed` are the site's own loops, cropped and scaled. The black
around the player is made transparent so it sits on either GitHub theme. Each frame is encoded on its own with
`cwebp` (auto deblocking, sharp YUV) after a light denoise, which keeps the films'
grain from turning into blocks.

The films are screen recordings of the shipping app playing a "Magnetite film"
Spotify playlist: "Pop" by ILLIT, "Sunsetz" by Cigarettes After Sex, "Art Deco" by
Lana Del Rey and "Hush" by The Marías. Every one has synced lyrics on LRCLIB, so the
panel shows its lyrics stage throughout. `tools/notchtake` hovers the notch open,
swipes two fingers to skip, drags the seek edge into a sung part of each song, and
lets the panel fold and reopen, with real pointer and trackpad events. Meanwhile
`tools/notchrec` films only Magnetite's windows (400 by 256 points at two pixels a
point, 800 by 512 pixels) and records Spotify's own sound, before the system
volume, into the same file. `site/media/demo-poster.webp` is its first frame.

The page credits each song by title and artist, linked to the track.
