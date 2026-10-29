// The demo's two buttons, and nothing else. The film plays muted while it is on
// screen; Reduce Motion holds its first frame until someone presses Play.
const video = document.querySelector('[data-demo]');
const play = document.querySelector('[data-demo-play]');
const sound = document.querySelector('[data-demo-sound]');
const still = matchMedia('(prefers-reduced-motion: reduce)');

let wanted = !still.matches;
let seen = false;

function sync() {
  if (wanted && seen) video.play().catch(() => { wanted = false; label(); });
  else video.pause();
  label();
}

function label() {
  play.textContent = wanted ? 'Pause' : 'Play';
  sound.textContent = video.muted ? 'Sound on' : 'Sound off';
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
  if (!video.muted) wanted = true;
  sync();
});
still.addEventListener('change', () => { wanted = !still.matches; sync(); });
label();
