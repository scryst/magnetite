# The stills, clips and lights under the film, all cut from media/demo.mp4.
#
#   cd site/media
#   ffmpeg -ss 32.4 -t 3.3 -i demo.mp4 -an -vf crop=640:72:80:0 -c:v libx264 -crf 22 -pix_fmt yuv420p -movflags +faststart closed.mp4
#   ffmpeg -ss 39.5 -t 7 -i demo.mp4 -an -c:v libx264 -crf 26 -pix_fmt yuv420p -movflags +faststart lyrics.mp4
#   posters: the first frame of each, as webp; tint-<song>.webp: frames at 3.0, 16.5, 27.0 and 44.0 s
#   python3 -I ../test/bake-glow.py . .
#
# The film's songs change at 7.4, 20 and 37.9 s; site.js names them by those times.
#
# Bakes a soft glow per song from the film's own frame: the panel's colors,
# the band of bare panel under the controls, averaged to a few cells, brightened, under a round falloff with alpha.
import sys, math
from PIL import Image, ImageEnhance, ImageFilter
media = sys.argv[1]; out = sys.argv[2]
W, H = 120, 80
for song in ['pop', 'sunsetz', 'artdeco', 'hush']:
    im = Image.open(f'{media}/tint-{song}.webp').convert('RGB').crop((40, 290, 760, 350)).filter(ImageFilter.MedianFilter(9))
    cells = im.resize((4, 1), Image.BOX).resize((4, 3), Image.NEAREST)
    # Each cell keeps its hue, at one brightness and a lifted saturation, so
    # the four songs glow equally and a dim cover does not glow brown.
    hsv = cells.convert('HSV'); px = hsv.load()
    for y in range(hsv.height):
        for x in range(hsv.width):
            h, s, v = px[x, y]
            px[x, y] = (h, min(190, max(90, int(s * 2))), 205)
    big = hsv.convert('RGB').resize((W, H), Image.BICUBIC).filter(ImageFilter.GaussianBlur(10))
    a = Image.new('L', (W, H))
    px = a.load()
    for y in range(H):
        for x in range(W):
            dx = (x + .5 - W / 2) / (W / 2); dy = (y + .5 - H / 2) / (H / 2)
            r2 = dx * dx + dy * dy
            px[x, y] = int(255 * 0.85 * math.exp(-r2 * 2.6) * max(0, 1 - r2) ** 0.5)
    big.putalpha(a)
    big.save(f'{out}/glow-{song}.webp', 'WEBP', quality=90, method=6)
    print(song, cells.resize((1, 1), Image.BOX).getpixel((0, 0)))
