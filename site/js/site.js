// The film's two buttons, the dock, and the download on a phone.
// The film plays muted while it is on screen; Reduce Motion holds its first
// frame until someone presses Play. Sound is offered, never assumed.
const video = document.querySelector('[data-demo]');
const play = document.querySelector('[data-demo-play]');
const sound = document.querySelector('[data-demo-sound]');
const soundLabel = sound.querySelector('[data-demo-sound-label]');
const still = matchMedia('(prefers-reduced-motion: reduce)');

let wanted = !still.matches;
let seen = false;

function sync() {
  // With sound on the film is the soundtrack, so it keeps playing off screen.
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

// The dock shows once no Download button is on screen.
const dock = document.querySelector('[data-dock]');
const showing = new Set();
const io = new IntersectionObserver((entries) => {
  for (const e of entries) e.isIntersecting ? showing.add(e.target) : showing.delete(e.target);
  dock.toggleAttribute('data-shown', showing.size === 0);
});
for (const target of document.querySelectorAll('[data-download]')) io.observe(target);

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
