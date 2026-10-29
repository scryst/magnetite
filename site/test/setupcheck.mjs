// Focused regression for the notch (js/notch.js): the lyric column sings the
// section crossing the read line, and dragging its foot seeks the page.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../js/notch.js', import.meta.url), 'utf8');
const el = (extra = {}) => ({
  style: { setProperty() {} }, dataset: {}, listeners: {},
  addEventListener(type, fn) { this.listeners[type] = fn; },
  setAttribute() {}, contains: () => false, ...extra,
});
const tops = { '#a': 0, '#b': 900, '#c': 1800 };
let scrolled = 0, seekTo = null;
const sections = Object.fromEntries(Object.keys(tops).map((id) =>
  [id, { getBoundingClientRect: () => ({ top: tops[id] - scrolled }) }]));
const rows = Object.keys(tops).map((hash, n) =>
  el({ offsetTop: n * 30, querySelector: () => ({ hash }) }));
const parts = {
  '[data-notch-pill]': el(), '[data-player]': el({ scrollHeight: 300 }),
  '[data-notch-edge]': el({ getBoundingClientRect: () => ({ left: 100, width: 400 }), setPointerCapture() {} }),
  '[data-notch-trace]': el(), '[data-notch-column]': el({ children: rows }),
  '[data-notch-elapsed]': el(), '[data-notch-left]': el(),
};
const root = el({ querySelector: (s) => parts[s] });
const frames = [];
const context = vm.createContext({
  document: { querySelector: (s) => sections[s], documentElement: { scrollHeight: 2800 } },
  innerHeight: 800,
  get scrollY() { return scrolled; },
  scrollTo: ({ top }) => { seekTo = top; },
  addEventListener() {},
  requestAnimationFrame: (fn) => frames.push(fn),
  setTimeout: () => 0, clearTimeout() {}, performance: { now: () => 0 },
});
vm.runInContext(source.replace('export function startNotch', 'function startNotch')
  .replace('export function inkTitles', 'function inkTitles'), context);
context.startNotch(root, { reduceMotion: false, audio: null });

const sung = () => rows.findIndex((row) => row.dataset.state === 'sung');
assert.equal(sung(), 0, 'at the top the first section is sung');
scrolled = 600; // #b's top is at 300, under the read line (0.4 × 800 = 320)
parts['[data-notch-pill]'].listeners.click();
assert.equal(sung(), 1, 'the section crossing the read line is the one sung');
assert.equal(rows[2].dataset.state, 'next', 'the section after it waits beneath');
assert.equal(rows[0].dataset.state, 'past');

const edge = parts['[data-notch-edge]'];
edge.listeners.pointerdown({ clientX: 300, pointerId: 1, preventDefault() {} });
assert.equal(seekTo, 1000, 'pressing halfway along the foot seeks halfway down the page');
edge.listeners.pointermove({ clientX: 600 });
assert.equal(seekTo, 2000, 'dragging past the end clamps to the bottom');
edge.listeners.pointerup();
edge.listeners.pointermove({ clientX: 100 });
assert.equal(seekTo, 2000, 'moving after release does not seek');
console.log('setupcheck: notch sings the section in view and its foot scrubs the page');
