# Real-app media

All four stills come from the existing `site/media/film.mp4` screen recording.
No native UI has been recreated. The crop removes unused wallpaper, not controls.

| File (relative to repository root) | Time | Source crop | Output |
| --- | --- | --- | --- |
| `site/media/app-open.webp` | 0.0s | 860 × 390 at 0,0 | 860 × 390 |
| `docs/media/skip.webp` | 2.3s | 860 × 390 at 0,0 | 520 × 236 |
| `docs/media/seek.webp` | 18.2s | 860 × 390 at 0,0 | 520 × 236 |
| `docs/media/retracted.webp` | 25.0s | 860 × 390 at 0,0 | 520 × 236 |

Extract with FFmpeg to PNG, then encode with `cwebp -q 86`. These are still
frames; the README links to recording segments for motion and interaction proof.
The take and gestures are documented in `site/js/touches.js`.

Music and cover art: Punch Deck, “Chrome Funk,” “Cyberpunk Renaissance,” and
“Neon Underworld,” CC BY 4.0. See the site's linked credits. Cropping and
resizing are the only visual modifications.
