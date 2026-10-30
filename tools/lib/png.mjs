// Zero-dependency PNG codec and a tiny bitmap font, shared by the site's visual checks
// (tools/filmcheck.mjs, tools/flickercheck.mjs). 8-bit, non-interlaced images only,
// which is what ffmpeg, Chromium and WebKit screenshots produce.

import { deflateSync, inflateSync } from 'node:zlib';
import * as zlib from 'node:zlib';

const CRC = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; }
  return t;
})();
const crc32 = (buf) => {
  if (typeof zlib.crc32 === 'function') return zlib.crc32(buf) >>> 0;
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};

function chunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, 'latin1');
  Buffer.from(data.buffer ?? data, data.byteOffset ?? 0, data.length).copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

// rgb: Uint8Array of width*height*3 (channels = 3) or *4 (channels = 4) or *1 (gray, channels = 1).
export function encodePNG(width, height, pixels, channels = 3) {
  const type = { 1: 0, 3: 2, 4: 6 }[channels];
  const stride = width * channels;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0;
    Buffer.from(pixels.buffer, pixels.byteOffset + y * stride, stride).copy(raw, y * (stride + 1) + 1);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = type; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw, { level: 6 })), chunk('IEND', Buffer.alloc(0))]);
}

// Returns { width, height, channels, data } with data unfiltered, 8 bits per sample.
export function decodePNG(buf) {
  if (buf.readUInt32BE(0) !== 0x89504e47) throw new Error('not a PNG');
  let pos = 8, width = 0, height = 0, depth = 0, ctype = 0, interlace = 0;
  const idat = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos), type = buf.toString('latin1', pos + 4, pos + 8);
    const body = buf.subarray(pos + 8, pos + 8 + len);
    if (type === 'IHDR') { width = body.readUInt32BE(0); height = body.readUInt32BE(4); depth = body[8]; ctype = body[9]; interlace = body[12]; }
    else if (type === 'IDAT') idat.push(body);
    else if (type === 'IEND') break;
    pos += 12 + len;
  }
  if (depth !== 8 || interlace) throw new Error(`unsupported PNG (depth ${depth}, interlace ${interlace})`);
  const channels = { 0: 1, 2: 3, 4: 2, 6: 4 }[ctype];
  if (!channels) throw new Error(`unsupported PNG color type ${ctype}`);
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * channels, data = new Uint8Array(stride * height);
  for (let y = 0; y < height; y++) {
    const f = raw[y * (stride + 1)], src = y * (stride + 1) + 1, dst = y * stride;
    for (let i = 0; i < stride; i++) {
      const x = raw[src + i];
      const a = i >= channels ? data[dst + i - channels] : 0;
      const b = y ? data[dst - stride + i] : 0;
      const c = i >= channels && y ? data[dst - stride + i - channels] : 0;
      let v;
      if (f === 0) v = x;
      else if (f === 1) v = x + a;
      else if (f === 2) v = x + b;
      else if (f === 3) v = x + ((a + b) >> 1);
      else {
        const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        v = x + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c);
      }
      data[dst + i] = v & 255;
    }
  }
  return { width, height, channels, data };
}

// ---- drawing on an RGB buffer ---------------------------------------------------------
export function fillRect(img, x0, y0, w, h, [r, g, b]) {
  const { width, height, data } = img;
  for (let y = Math.max(0, y0); y < Math.min(height, y0 + h); y++) for (let x = Math.max(0, x0); x < Math.min(width, x0 + w); x++) {
    const o = (y * width + x) * 3; data[o] = r; data[o + 1] = g; data[o + 2] = b;
  }
}
export const newImage = (width, height, [r, g, b] = [32, 32, 32]) => {
  const data = new Uint8Array(width * height * 3);
  for (let i = 0; i < data.length; i += 3) { data[i] = r; data[i + 1] = g; data[i + 2] = b; }
  return { width, height, data };
};
// Copy an RGB tile (w x h, packed) into img at x, y.
export function blit(img, x0, y0, w, h, tile) {
  for (let y = 0; y < h; y++) {
    const yy = y0 + y; if (yy < 0 || yy >= img.height) continue;
    for (let x = 0; x < w; x++) {
      const xx = x0 + x; if (xx < 0 || xx >= img.width) continue;
      const s = (y * w + x) * 3, d = (yy * img.width + xx) * 3;
      img.data[d] = tile[s]; img.data[d + 1] = tile[s + 1]; img.data[d + 2] = tile[s + 2];
    }
  }
}

// 5x7 glyphs, one byte per row (low 5 bits), upper-case only; anything else draws as a blank.
const G = {
  A: [14, 17, 17, 31, 17, 17, 17], B: [30, 17, 17, 30, 17, 17, 30], C: [14, 17, 16, 16, 16, 17, 14], D: [30, 17, 17, 17, 17, 17, 30],
  E: [31, 16, 16, 30, 16, 16, 31], F: [31, 16, 16, 30, 16, 16, 16], G: [14, 17, 16, 23, 17, 17, 15], H: [17, 17, 17, 31, 17, 17, 17],
  I: [14, 4, 4, 4, 4, 4, 14], J: [7, 2, 2, 2, 2, 18, 12], K: [17, 18, 20, 24, 20, 18, 17], L: [16, 16, 16, 16, 16, 16, 31],
  M: [17, 27, 21, 21, 17, 17, 17], N: [17, 17, 25, 21, 19, 17, 17], O: [14, 17, 17, 17, 17, 17, 14], P: [30, 17, 17, 30, 16, 16, 16],
  Q: [14, 17, 17, 17, 21, 18, 13], R: [30, 17, 17, 30, 20, 18, 17], S: [15, 16, 16, 14, 1, 1, 30], T: [31, 4, 4, 4, 4, 4, 4],
  U: [17, 17, 17, 17, 17, 17, 14], V: [17, 17, 17, 17, 17, 10, 4], W: [17, 17, 17, 21, 21, 21, 10], X: [17, 17, 10, 4, 10, 17, 17],
  Y: [17, 17, 10, 4, 4, 4, 4], Z: [31, 1, 2, 4, 8, 16, 31],
  0: [14, 17, 19, 21, 25, 17, 14], 1: [4, 12, 4, 4, 4, 4, 14], 2: [14, 17, 1, 2, 4, 8, 31], 3: [31, 2, 4, 2, 1, 17, 14],
  4: [2, 6, 10, 18, 31, 2, 2], 5: [31, 16, 30, 1, 1, 17, 14], 6: [6, 8, 16, 30, 17, 17, 14], 7: [31, 1, 2, 4, 8, 8, 8],
  8: [14, 17, 17, 14, 17, 17, 14], 9: [14, 17, 17, 15, 1, 2, 12],
  '.': [0, 0, 0, 0, 0, 12, 12], ':': [0, 12, 12, 0, 12, 12, 0], '-': [0, 0, 0, 31, 0, 0, 0], '#': [10, 10, 31, 10, 31, 10, 10],
  '@': [14, 17, 23, 21, 23, 16, 14], '+': [0, 4, 4, 31, 4, 4, 0], '/': [1, 1, 2, 4, 8, 16, 16], '%': [24, 25, 2, 4, 8, 19, 3],
  '=': [0, 0, 31, 0, 31, 0, 0], ',': [0, 0, 0, 0, 12, 4, 8], '(': [2, 4, 8, 8, 8, 4, 2], ')': [8, 4, 2, 2, 2, 4, 8],
  '>': [16, 8, 4, 2, 4, 8, 16], '<': [1, 2, 4, 8, 4, 2, 1], '[': [14, 8, 8, 8, 8, 8, 14], ']': [14, 2, 2, 2, 2, 2, 14],
  _: [0, 0, 0, 0, 0, 0, 31], '|': [4, 4, 4, 4, 4, 4, 4], x: [0, 0, 17, 10, 4, 10, 17],
};
export const textWidth = (s, scale = 2) => s.length * 6 * scale;
export function drawText(img, x0, y0, text, { scale = 2, fg = [255, 255, 255], bg = null } = {}) {
  const s = String(text).replace(/[a-z]/g, (c) => c.toUpperCase());
  if (bg) fillRect(img, x0 - scale, y0 - scale, textWidth(s, scale) + scale, 7 * scale + 2 * scale, bg);
  for (let i = 0; i < s.length; i++) {
    const rows = G[s[i]];
    if (!rows) continue;
    for (let r = 0; r < 7; r++) for (let c = 0; c < 5; c++) if (rows[r] & (16 >> c)) fillRect(img, x0 + (i * 6 + c) * scale, y0 + r * scale, scale, scale, fg);
  }
}
