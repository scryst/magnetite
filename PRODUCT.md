# Design principles

Magnetite is for people who listen to music while they work on a MacBook. It
puts playback controls in the space around the camera notch. Closed, it stays
inside the menu bar. Open, it is a small player whose black liquid moves with
the audio and settles back into the notch.

## Avoid

- Mirrored equaliser bars or rows of identical spikes.
- Motion that visibly repeats: sine waves, springs, bounces.
- Separate bubbles, circles or droplets floating over the player.
- Layers of unrelated shapes and gradients.
- A player that stays open below the menu bar when nobody is using it.

## Principles

1. One continuous surface. The outline bends with the music, and every peak
   stays attached to it.
2. Audio causes events. The clock only advances the simulation.
3. The music decides which frequencies break the surface, how far they pull
   it, and how neighbouring peaks share the movement.
4. Respect the hardware. Never draw through the camera cutout, and never cover
   window chrome while closed.
5. Familiar controls. The liquid is the one unusual thing; everything else
   behaves like a normal Mac utility.

## Accessibility

Keep text readable against the artwork and use native control semantics.
Every state change must be visible, and every control that is drawn must work.
Motion follows the system's Reduce Motion setting.
