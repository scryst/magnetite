# Media

`player.webp`, the README's picture, is a frame of `site/media/demo.mp4` with
lyrics on screen, at its full 800 px, encoded with `cwebp -q 86`.

The film is a screen recording of the shipping app playing a "Magnetite film"
Spotify playlist: "Pop" by ILLIT, "Sunsetz" by Cigarettes After Sex, "Art Deco" by
Lana Del Rey and "Hush" by The Marías. Every one has synced lyrics on LRCLIB, so the
panel shows its lyrics stage throughout. `tools/notchtake` hovers the notch open,
swipes two fingers to skip, drags the seek edge into a sung part of each song, and
lets the panel fold and reopen, with real pointer and trackpad events. Meanwhile
`tools/notchrec` films only Magnetite's windows (400 by 256 points at two pixels a
point, 800 by 512 pixels) and records Spotify's own sound, before the system
volume, into the same file. `site/media/demo-poster.webp` is its first frame.

The page credits each song by title and artist, linked to the track.
