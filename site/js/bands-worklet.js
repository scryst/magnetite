/**
 * The analyser's seat on the audio thread.
 *
 * An AudioWorklet hands audio over in 128-frame blocks; the app's tap hands
 * its analyser 512-frame device buffers. Four blocks are gathered into one
 * 512-frame hop before the analyser runs, so the port publishes at the same
 * cadence as the shipping pipeline (~94 Hz at 48k against ~86 at 44.1k) and
 * the meter's attack and release mean the same thing on both sides.
 *
 * Channels are meaned here, before the hop buffer, exactly where the Swift
 * means its interleaved buffer. Bands go to the main thread per publish;
 * the LevelPump there decides at its own 30 Hz what the page may show.
 */
import { BandAnalyser, BAND_COUNT } from './bands.js';

const HOP = 512;

class BandsProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.analyser = new BandAnalyser();
    this.hop = new Float32Array(HOP);
    this.filled = 0;
    this.out = new Float32Array(BAND_COUNT);
  }

  process(inputs) {
    const input = inputs[0];
    if (!input || input.length === 0) return true;
    const frames = input[0].length;
    for (let i = 0; i < frames; i++) {
      let sum = 0;
      for (let c = 0; c < input.length; c++) sum += input[c][i];
      this.hop[this.filled++] = sum / input.length;
      if (this.filled === HOP) {
        this.filled = 0;
        this.analyser.feed(this.hop);
        this.analyser.levels(this.out);
        this.port.postMessage(this.out);
      }
    }
    return true;
  }
}

registerProcessor('bands', BandsProcessor);
