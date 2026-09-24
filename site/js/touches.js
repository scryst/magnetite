// The hand in the film, drawn on it as it moves.
//
// The recording shows what the app did, not what the hand did: a two-finger
// swipe happens on the trackpad, out of shot, and all the footage shows is
// the player's title leaning and the track changing. So the page draws the
// two fingers on the desktop under the player as they swipe, the way they
// went (right is forward, as the app reads it), a ripple where the pointer
// clicks and a press where it drags the seek strip, and lights the line of the
// how-to the footage is doing. Timed to the footage's own clock, so each lands
// on the frame it was read from, and only in the journey, where the footage is
// laid out in its own points: every coordinate below is one.

/**
 * Seconds into media/demo.mp4 and points on its 512 by 240 frame, read off
 * the frames: a swipe's title leans with the fingers' travel and the swipe
 * fires once they have gone far enough, where the fingers lift.
 */
export const CUES = [
  // Back: leans left from 5.00s and restarts the track at 5.80s.
  { kind: 'swipe', dir: -1, down: 4.98, travel: 0.22, up: 5.78 },
  // Forward: leans right from 8.87s and fires at 9.08s; the next track fades in.
  { kind: 'swipe', dir: 1, down: 8.85, travel: 0.2, up: 9.08 },
  // The pointer clicks the next button.
  { kind: 'click', at: 18.0, x: 291, y: 127 },
  // It presses the seek strip on the player's bottom edge and drags it right.
  {
    kind: 'scrub', y: 156, up: 25.6,
    path: [[23.65, 164], [23.9, 164], [24.07, 166], [24.23, 170], [24.4, 181],
      [24.57, 198], [24.73, 220], [24.9, 246], [25.07, 263], [25.23, 273],
      [25.4, 281], [25.57, 283]],
  },
];

/** Where the fingers rest, on the desktop under the player's middle, and how far a swipe carries them. */
export const HAND = { x: 256, y: 200, reach: 56 };

const unit = (x) => Math.max(0, Math.min(1, x));
const out = (t) => 1 - (1 - t) ** 3;
/** Seconds a touch takes to land, and to lift and go. */
const LAND = 0.08;
const LIFT = 0.22;

/** The x a scrub's path has at `t`, straight between the frames it was read from. */
function along(path, t) {
  if (t <= path[0][0]) return path[0][1];
  for (let i = 1; i < path.length; i += 1) {
    const [t1, x1] = path[i];
    if (t <= t1) {
      const [t0, x0] = path[i - 1];
      return x0 + (x1 - x0) * ((t - t0) / (t1 - t0));
    }
  }
  return path[path.length - 1][1];
}

/**
 * The drawing at `t` seconds into the footage: the fingers (how much of them
 * shows, their offset and how hard they press), the ring
 * (where, how much and how big), and which line of the how-to is being done.
 * Pure, so a check can hold the swipes to the app's direction.
 */
export function touchesAt(t) {
  const hand = { shown: 0, dx: 0, press: 0 };
  const ring = { shown: 0, size: 1, x: 0, y: 0 };
  let doing = null;
  for (const cue of CUES) {
    if (cue.kind === 'swipe') {
      if (t < cue.down || t > cue.up + LIFT) continue;
      const u = unit((t - cue.down) / cue.travel);
      const gone = unit((t - cue.up) / LIFT);
      hand.shown = unit((t - cue.down) / LAND) * (1 - gone);
      // Most of the way at once, then still pushing until the app counts it
      // (SwipeRecogniser fires on the distance travelled, not on the lift).
      const push = unit((t - cue.down) / (cue.up - cue.down));
      hand.dx = cue.dir * HAND.reach * (0.8 * out(u) + 0.2 * push + 0.1 * gone);
      hand.press = unit((t - cue.down) / LAND) * (1 - gone);
      doing = 'swipe';
    } else if (cue.kind === 'click') {
      const u = (t - cue.at) / 0.5;
      if (u < 0 || u > 1) continue;
      Object.assign(ring, { shown: 1 - u ** 2, size: 0.6 + out(u) * 1.1, x: cue.x, y: cue.y });
    } else if (cue.kind === 'scrub') {
      const from = cue.path[0][0];
      if (t < from || t > cue.up + LIFT) continue;
      const gone = unit((t - cue.up) / LIFT);
      Object.assign(ring, {
        shown: unit((t - from) / LAND) * (1 - gone),
        size: 1 - 0.15 * unit((t - from) / LAND) + 0.3 * gone,
        x: along(cue.path, t),
        y: cue.y,
      });
      if (gone < 1) doing = 'scrub';
    }
  }
  return { hand, ring, doing };
}

/** Draws the cues over `video` as it plays; `how` is the how-to list. */
export function startTouches(video, how) {
  const stage = video && video.parentElement;
  if (!stage) return null;
  const hand = document.createElement('div');
  hand.className = 'touch';
  hand.setAttribute('aria-hidden', 'true');
  hand.style.left = `${HAND.x}px`;
  hand.style.top = `${HAND.y}px`;
  hand.innerHTML = '<i class="touch__tip"></i><i class="touch__tip"></i>';
  const ring = document.createElement('i');
  ring.className = 'touch__ring';
  ring.setAttribute('aria-hidden', 'true');
  stage.append(hand, ring);

  let last = '';
  function draw(t) {
    const { hand: h, ring: r, doing } = touchesAt(t);
    const handAt = `translate3d(${h.dx.toFixed(2)}px, 0, 0) scale(${(1.18 - 0.18 * h.press).toFixed(3)})`;
    const ringAt = `translate3d(${r.x.toFixed(1)}px, ${r.y.toFixed(1)}px, 0) scale(${r.size.toFixed(3)})`;
    const key = `${h.shown.toFixed(3)}|${handAt}|${r.shown.toFixed(3)}|${ringAt}|${doing}`;
    if (key === last) return;
    last = key;
    hand.style.opacity = h.shown.toFixed(3);
    hand.style.transform = handAt;
    ring.style.opacity = r.shown.toFixed(3);
    ring.style.transform = ringAt;
    if (how) {
      if (doing) how.dataset.doing = doing;
      else delete how.dataset.doing;
    }
  }

  // The footage's own frames where the browser offers them, so a cue lands on
  // the frame it was read from; the page's frames otherwise, while it plays.
  if ('requestVideoFrameCallback' in video) {
    const frame = (now, meta) => {
      draw(meta.mediaTime);
      video.requestVideoFrameCallback(frame);
    };
    video.requestVideoFrameCallback(frame);
  } else {
    const frame = () => {
      if (!video.paused) draw(video.currentTime);
      requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  }
  draw(video.currentTime);
  return { draw };
}
