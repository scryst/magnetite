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
still.addEventListener('change', () => { wanted = !still.matches; sync(); });
label();

// The light and the desktop take the film's song (magnetite.css fades was to on),
// once the scroll rests: a change mid-scroll made a phone's page judder.
const songs = [[7.4, 'pop'], [20, 'sunsetz'], [37.9, 'artdeco'], [Infinity, 'hush']];
let shown = 'pop', moved = 0;
video.addEventListener('timeupdate', () => {
  const song = songs.find(([end]) => video.currentTime < end)[1];
  if (song === shown || performance.now() - moved < 400) return;
  for (const i of document.querySelectorAll('[data-glow] i')) i.className = i.dataset.for === song ? 'on' : i.dataset.for === shown ? 'was' : '';
  shown = song;
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
const later = () => { moved = performance.now(); due ||= setTimeout(dockSync, 120); };
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
