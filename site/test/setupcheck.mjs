// Focused regression: new FAQ text must displace the floating soundtrack,
// including when a details toggle changes layout without a scroll event.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../js/corner.js', import.meta.url), 'utf8');
const listeners = new Map();
const frames = [];
const timers = new Map();
let timer = 0, open = false, aside = false;
const paragraph = {
  closest: () => null,
  matches: () => false,
  checkVisibility: () => open,
  querySelectorAll: () => [],
};
const textNode = { data: 'System audio stays on your Mac.' };
const context = vm.createContext({
  document: {
    readyState: 'complete',
    querySelectorAll: (selector) => selector.split(',').some(s => s.trim() === '.setup p') ? [paragraph] : [],
    querySelector: () => null,
    createRange: () => ({ selectNodeContents() {}, getBoundingClientRect: () => ({ left: 240, right: 360, top: 820, bottom: 845, width: 120 }) }),
    createTreeWalker: () => { let read = false; return { nextNode: () => read ? null : (read = true, textNode) }; },
    addEventListener: (type, fn, capture) => { assert.equal(capture, true); listeners.set(type, fn); },
  },
  NodeFilter: { SHOW_TEXT: 4 },
  addEventListener: (type, fn) => listeners.set(type, fn),
  requestAnimationFrame: (fn) => frames.push(fn),
  setTimeout: (fn) => { timers.set(++timer, fn); return timer; },
  clearTimeout: (id) => timers.delete(id),
});
vm.runInContext(source.replace('export function startCorner', 'function startCorner'), context);
context.startCorner({
  getBoundingClientRect: () => ({ left: 220, right: 375, top: 800, bottom: 865 }),
  toggleAttribute: (name, value) => { assert.equal(name, 'data-aside'); aside = value; },
  removeAttribute: () => { aside = false; },
}, { journey: false, notch: null });
const flush = () => { while (frames.length) frames.shift()(); };
flush();
for (const fn of timers.values()) fn();
assert.equal(aside, false, 'closed answers leave soundtrack available');
open = true;
assert.ok(listeners.has('toggle'), 'FAQ toggles must trigger collision checking');
listeners.get('toggle')();
flush();
assert.equal(aside, true, 'opening FAQ text under the soundtrack must hide it');
assert.equal(timers.size, 0, 'opening an answer cancels pending player reappearance');
open = false;
listeners.get('toggle')();
flush();
for (const fn of timers.values()) fn();
assert.equal(aside, false, 'closing the answer restores the player when clear');
console.log('setupcheck: FAQ text and toggle collision regression passed');
