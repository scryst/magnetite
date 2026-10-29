// The soundtrack's circles at the foot of the window.
//
// What site.js leaves to this file is the part that touches the playhead: the
// ring round the play circle is the track's progress, and site.js is held to
// never naming the film's playhead, so it names none — not even to rewind the
// soundtrack. It also marks which sleeve is playing.

/** @param {HTMLElement} host  @param {HTMLAudioElement} audio */
export function startPlayer(host, audio) {
  const ring = host.querySelector('[data-player-ring]');
  const tracks = [...host.querySelectorAll('[data-soundtrack-track]')];
  const draw = () => {
    const at = audio.duration > 0 ? audio.currentTime / audio.duration : 0;
    if (!ring) return;
    ring.style.strokeDashoffset = String(1 - Math.min(1, Math.max(0, at)));
    // With nothing played, the dash's antialiased end still drew a speck.
    ring.style.visibility = at > 0 ? '' : 'hidden';
  };
  for (const type of ['timeupdate', 'durationchange', 'seeked', 'emptied']) {
    audio.addEventListener(type, draw);
  }
  draw();
  // A muted try that nobody heard still leaves a played range behind.
  let unheard = false;
  audio.addEventListener('play', () => { unheard = false; });
  return {
    /**
     * What is playing, for the band's idle pill: seconds in, of how many, its
     * sleeve's source, and whether the soundtrack has played at all.
     */
    now() {
      const playing = tracks.find((track) => track.getAttribute('aria-pressed') === 'true');
      return {
        at: audio.currentTime || 0,
        of: audio.duration > 0 ? audio.duration : 0,
        src: playing?.querySelector('img')?.getAttribute('src') ?? null,
        played: !unheard && audio.played.length > 0,
      };
    },
    /** Stopped before a note was heard: back to its top, and not played. */
    rewind() {
      audio.currentTime = 0;
      unheard = true;
    },
    /** The sleeve at `index` is the one playing. */
    show(index) {
      tracks.forEach((track, i) => track.setAttribute('aria-pressed', String(i === index)));
    },
  };
}
