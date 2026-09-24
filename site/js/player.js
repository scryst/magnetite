// The soundtrack's circles at the foot of the window.
//
// What site.js leaves to this file is the part that reads the playhead: the
// ring round the play circle is the track's progress, and site.js is held to
// never naming the film's playhead, so it names none. It also marks which
// sleeve is playing.

/** @param {HTMLElement} host  @param {HTMLAudioElement} audio */
export function startPlayer(host, audio) {
  const ring = host.querySelector('[data-player-ring]');
  const tracks = [...host.querySelectorAll('[data-soundtrack-track]')];
  const draw = () => {
    const at = audio.duration > 0 ? audio.currentTime / audio.duration : 0;
    if (ring) ring.style.strokeDashoffset = String(1 - Math.min(1, Math.max(0, at)));
  };
  for (const type of ['timeupdate', 'durationchange', 'seeked', 'emptied']) {
    audio.addEventListener(type, draw);
  }
  draw();
  return {
    /** The sleeve at `index` is the one playing. */
    show(index) {
      tracks.forEach((track, i) => track.setAttribute('aria-pressed', String(i === index)));
    },
  };
}
