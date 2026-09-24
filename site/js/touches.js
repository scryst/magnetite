// The hand in the film, drawn on it as it moves.
//
// The recording shows what the app did, not what the hand did: a two-finger
// swipe happens on the trackpad, out of shot, and all the footage shows is
// the player's title leaning and the track changing. So the page draws the
// two fingers on the desktop under the player as they swipe, the way they
// went (right is forward, as the app reads it; down pauses and plays), a
// ripple where the pointer clicks and a press where it drags the seek strip,
// and lights the line of the how-to the footage is doing. Timed to the
// footage's own clock, so each lands on the frame it happened on, and only in
// the journey, where the desktop is laid out in its own points: every
// coordinate below is one.

import { FOOTAGE } from './tunnel.js';

/**
 * Seconds into media/film.mp4 and points on the display it was recorded on.
 * The take was played by a script (every gesture a real event, at a logged
 * second), and the film opens 6.6s into it; the script's clock runs 1.17s
 * behind the recording's, measured from the pointer's first move. So each
 * time below is the script's, moved onto the film's.
 */
export const CUES = [
  // Forward: two fingers right, 120pt of trackpad in 0.3s; the next track comes in.
  { kind: 'swipe', axis: 'x', dir: 1, down: 1.295, up: 1.595 },
  // Back, inside the new track's first seconds: the track before it.
  { kind: 'swipe', axis: 'x', dir: -1, down: 3.1, up: 3.4 },
  // Down: pause. The liquid settles into the notch.
  { kind: 'swipe', axis: 'y', dir: 1, down: 6.204, up: 6.504 },
  // Down again: play.
  { kind: 'swipe', axis: 'y', dir: 1, down: 9.111, up: 9.411 },
  // The pointer clicks the next button.
  { kind: 'click', at: 12.873, x: 792, y: 128 },
  // It presses the seek strip on the player's bottom edge, holds, drags it
  // right along the script's own eased glide, and lets go. The recorded
  // pointer trails a drag's events by about 0.05s, read off the take mid-glide
  // where it moves fastest, so the ring does too.
  { kind: 'scrub', y: 155, down: 17.108, from: 17.228, to: 19.028, x0: 640, x1: 870, up: 19.13 },
  // Away from the player, which goes back into the notch; then up to the
  // notch again, and it opens.
  { kind: 'hover', from: 28.39, to: 30.1 },
];

/** Where the fingers rest, on the desktop under the player's middle, and how far a swipe carries them. */
export const HAND = { x: 756, y: 215, reach: 56 };

const unit = (x) => Math.max(0, Math.min(1, x));
const out = (t) => 1 - (1 - t) ** 3;
/** The script's own glide: eased in and out, a cubic either side of halfway. */
const inOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);
/** Seconds a touch takes to land, and to lift and go. */
const LAND = 0.08;
const LIFT = 0.22;

/**
 * The drawing at `t` seconds into the footage: the fingers (how much of them
 * shows, their offset and how hard they press), the ring (where, how much
 * and how big), and which line of the how-to is being done. Pure, so a check
 * can hold the swipes to the app's direction.
 */
export function touchesAt(t) {
  const hand = { shown: 0, dx: 0, dy: 0, press: 0 };
  const ring = { shown: 0, size: 1, x: 0, y: 0 };
  let doing = null;
  for (const cue of CUES) {
    if (cue.kind === 'swipe') {
      if (t < cue.down || t > cue.up + LIFT) continue;
      const gone = unit((t - cue.up) / LIFT);
      hand.shown = unit((t - cue.down) / LAND) * (1 - gone);
      // Along the gesture's own eased travel, and a touch further as they lift.
      const along = cue.dir * HAND.reach * (inOut(unit((t - cue.down) / (cue.up - cue.down))) + 0.1 * gone);
      if (cue.axis === 'x') hand.dx = along;
      else hand.dy = along;
      hand.press = hand.shown;
      doing = 'swipe';
    } else if (cue.kind === 'click') {
      const u = (t - cue.at) / 0.5;
      if (u < 0 || u > 1) continue;
      Object.assign(ring, { shown: 1 - u ** 2, size: 0.6 + out(u) * 1.1, x: cue.x, y: cue.y });
    } else if (cue.kind === 'scrub') {
      if (t < cue.down || t > cue.up + LIFT) continue;
      const gone = unit((t - cue.up) / LIFT);
      const held = unit((t - cue.down) / LAND);
      Object.assign(ring, {
        shown: held * (1 - gone),
        size: 1 - 0.15 * held + 0.3 * gone,
        x: cue.x0 + (cue.x1 - cue.x0) * inOut(unit((t - cue.from) / (cue.to - cue.from))),
        y: cue.y,
      });
      if (gone < 1) doing = 'scrub';
    } else if (cue.kind === 'hover') {
      if (t >= cue.from && t <= cue.to) doing = 'hover';
    }
  }
  return { hand, ring, doing };
}

/**
 * Draws the cues over `video` as it plays; `how` is the how-to list. They go
 * in the footage's own box, which lies on the desktop at FOOTAGE's corner, so
 * they come and go with the footage.
 */
export function startTouches(video, how) {
  const stage = video && video.parentElement;
  if (!stage) return null;
  const origin = { x: FOOTAGE.x, y: FOOTAGE.y };
  const hand = document.createElement('div');
  hand.className = 'touch';
  hand.setAttribute('aria-hidden', 'true');
  hand.style.left = `${HAND.x - origin.x}px`;
  hand.style.top = `${HAND.y - origin.y}px`;
  hand.innerHTML = '<i class="touch__tip"></i><i class="touch__tip"></i>';
  const ring = document.createElement('i');
  ring.className = 'touch__ring';
  ring.setAttribute('aria-hidden', 'true');
  stage.append(hand, ring);

  let last = '';
  function draw(t) {
    const { hand: h, ring: r, doing } = touchesAt(t);
    const handAt = `translate3d(${h.dx.toFixed(2)}px, ${h.dy.toFixed(2)}px, 0) `
      + `scale(${(1.18 - 0.18 * h.press).toFixed(3)})`;
    const ringAt = `translate3d(${(r.x - origin.x).toFixed(1)}px, ${(r.y - origin.y).toFixed(1)}px, 0) `
      + `scale(${r.size.toFixed(3)})`;
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
  // the frame it happened on; the page's frames otherwise, while it plays.
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
