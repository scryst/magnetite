// The film plays muted while on screen; Reduce Motion holds its first frame
// until Play is pressed. Sound is offered, never assumed.
const video = document.querySelector('[data-demo]');
const play = document.querySelector('[data-demo-play]');
const sound = document.querySelector('[data-demo-sound]');
const soundLabel = sound.querySelector('[data-demo-sound-label]');
const still = matchMedia('(prefers-reduced-motion: reduce)');

let wanted = !still.matches;
let seen = false;

function sync() {
  // With sound on, the film plays on off screen.
  if (wanted && (seen || !video.muted)) video.play().catch(() => { wanted = false; label(); });
  else video.pause();
  label();
}

function label() {
  play.textContent = wanted ? 'Pause' : 'Play';
  soundLabel.textContent = video.muted ? 'Play with sound' : 'Sound off';
  sound.setAttribute('aria-pressed', String(!video.muted));
}

if (!wanted) video.removeAttribute('autoplay');
video.pause();

new IntersectionObserver(([entry]) => {
  seen = entry.isIntersecting;
  sync();
}, { threshold: 0.25 }).observe(video);

play.addEventListener('click', () => { wanted = !wanted; sync(); });
sound.addEventListener('click', () => {
  video.muted = !video.muted;
  if (!video.muted) { wanted = true; seen = true; }
  sync();
});
still.addEventListener('change', () => { wanted = !still.matches; sync(); redraw(); });
label();

// The light and the desktop take the film's song, each drawn into one small
// canvas from the song's stills (magnetite.css says why not as layers). The song
// coming in fades in over the one going; both are opaque, so at the film's loop
// back to the first song that reads as the last one fading out over it.
const songs = [[7.4, 'pop'], [20, 'sunsetz'], [37.9, 'artdeco'], [Infinity, 'hush']];
const wall = document.querySelector('[data-wall]').getContext('2d');
const glow = document.querySelector('[data-glow]').getContext('2d');
const load = (src) => new Promise((done) => { const i = new Image(); i.onload = () => done(i); i.onerror = () => done(null); i.src = src; });
const art = {};
let shown = 'pop', went = 'pop', changed = -Infinity, onScreen = false, drawing = 0, lightDue = true;

// The second copy of a field is tinted as hue-rotate(28deg) saturate(1.3): the
// two filter-effects matrices, multiplied, applied to its pixels once.
const TINT = [0.986, -0.542, 0.556, 0.056, 1.128, -0.183, -0.512, 0.331, 1.181];
function tinted(img) {
  const c = new OffscreenCanvas(img.width, img.height), x = c.getContext('2d');
  x.drawImage(img, 0, 0);
  const d = x.getImageData(0, 0, c.width, c.height), p = d.data, m = TINT;
  for (let i = 0; i < p.length; i += 4) {
    const [r, g, b] = [p[i], p[i + 1], p[i + 2]];
    for (let k = 0; k < 3; k++) p[i + k] = m[k * 3] * r + m[k * 3 + 1] * g + m[k * 3 + 2] * b;
  }
  x.putImageData(d, 0, 0);
  return c;
}

// One song's desktop at t seconds: the field turns once in 47 s, its tinted copy,
// wider, the other way in 76 s, screened over it at 0.7, and the pair swells
// (1 to 1.18, drifting) and back every 26 s. Sizes are in screen widths and heights.
const desk = new OffscreenCanvas(160, 104), deskX = desk.getContext('2d');
function drawDesk(song, t) {
  const { field, tint } = art[song], w = 160, h = 104;
  const k = (1 - Math.cos(Math.PI * (t / 13 % 2))) / 2;
  deskX.globalCompositeOperation = 'source-over'; deskX.globalAlpha = 1;
  deskX.setTransform(1, 0, 0, 1, 0, 0); deskX.fillStyle = '#000'; deskX.fillRect(0, 0, w, h);
  deskX.translate(w / 2 + w * (-0.04 + 0.09 * k), h / 2 + h * (0.02 - 0.05 * k));
  deskX.scale(1 + 0.18 * k, 1 + 0.18 * k);
  deskX.save(); deskX.rotate(2 * Math.PI * t / 47); deskX.drawImage(field, -0.7 * w, -1.1 * h, 1.4 * w, 2.2 * h); deskX.restore();
  deskX.rotate(-2 * Math.PI * t / 76); deskX.globalCompositeOperation = 'screen'; deskX.globalAlpha = 0.7;
  deskX.drawImage(tint, -0.9 * w, -1.4 * h, 1.8 * w, 2.8 * h);
  return desk;
}

// The light is still between changes, so it is drawn only while one fades.
function draw(now) {
  drawing = 0;
  if (!art.ready) return;
  const fade = still.matches ? 0 : 1600, t = still.matches ? 0 : now / 1000;
  const k = fade ? Math.min(1, (now - changed) / fade) : 1;
  const layers = k < 1 ? [[went, 1], [shown, k]] : [[shown, 1]];
  for (const [song, a] of layers) { wall.globalAlpha = a; wall.drawImage(drawDesk(song, t), 0, 0); }
  if (lightDue) {
    for (const [song, a] of layers) { glow.globalCompositeOperation = 'source-over'; glow.globalAlpha = a; glow.drawImage(art[song].glow, 0, 0, 120, 80); }
    glow.globalCompositeOperation = 'destination-in'; glow.globalAlpha = 1; glow.drawImage(art.mask, 0, 0, 120, 80);
    lightDue = k < 1;
  }
  if (onScreen && (lightDue || !still.matches)) drawing = requestAnimationFrame(draw);
}
const redraw = () => { if (!drawing) drawing = requestAnimationFrame(draw); };

Promise.all(songs.map(async ([, song]) => {
  const [field, light] = await Promise.all([load(`media/field-${song}.webp`), load(`media/glow-${song}.webp`)]);
  art[song] = { field, tint: tinted(field), glow: light };
}).concat(load('media/glow-mask.webp').then((m) => { art.mask = m; }))).then(() => { art.ready = true; redraw(); }, () => {});

new IntersectionObserver(([entry]) => { onScreen = entry.isIntersecting; redraw(); }).observe(wall.canvas);
video.addEventListener('timeupdate', () => {
  const song = songs.find(([end]) => video.currentTime < end)[1];
  if (song === shown) return;
  went = shown; shown = song; changed = performance.now(); lightDue = true;
  redraw();
});

// The clips play only on screen, and never under Reduce Motion.
const clips = new IntersectionObserver((entries) => {
  for (const e of entries) e.isIntersecting && !still.matches ? e.target.play().catch(() => {}) : e.target.pause();
}, { threshold: 0.4 });
for (const clip of document.querySelectorAll('[data-clip]')) clips.observe(clip);

// The dock shows once no Download button is seen. The hero's stays in the window,
// faded out, while the film holds it, so a faded one does not count.
const dock = document.querySelector('[data-dock]');
const downloads = [...document.querySelectorAll('[data-download]')];
const inSight = (b) => {
  const r = b.getBoundingClientRect();
  return r.bottom > 0 && r.top < innerHeight
    && (b.checkVisibility?.({ opacityProperty: true, visibilityProperty: true, checkOpacity: true, checkVisibilityCSS: true }) ?? true);
};
let due = 0;
const dockSync = () => { due = 0; dock.toggleAttribute('data-shown', !downloads.some(inSight)); };
const later = () => { due ||= setTimeout(dockSync, 120); };
addEventListener('scroll', later, { passive: true });
addEventListener('resize', later);
dockSync();

// A phone can't run a Mac app: the button sends the page to the Mac instead.
const phone = /iPhone|iPad|iPod|Android/.test(navigator.userAgent)
  || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
if (phone) {
  for (const button of document.querySelectorAll('[data-share]')) {
    const text = button.querySelector('[data-share-label]');
    text.textContent = navigator.share ? 'Send to your Mac' : 'Copy link for your Mac';
    button.addEventListener('click', async (event) => {
      event.preventDefault();
      const url = 'https://magnetite.app/';
      try {
        if (navigator.share) await navigator.share({ title: 'Magnetite', url });
        else { await navigator.clipboard.writeText(url); text.textContent = 'Link copied'; }
      } catch { /* the share sheet was closed */ }
    });
  }
}
dock.hidden = false;
