// The press. Every picture on the page is printed here, the way a
// risograph prints: three spot inks, each drawn by hand as a coverage plate
// (alpha is tone), screened into round dots at its own angle, misregistered a
// hair, multiplied together. The canvas prints white where no ink lands and CSS
// multiplies it onto the page's paper, so a print has no edge of its own.
//
// The film is the one picture that never comes through here. It is the proof
// of what the app looks like, and a screened copy would promise a look the app
// does not have.

/** Riso's own inks, as they print on uncoated stock. */
export const INK = {
  black: [0x22, 0x20, 0x22],
  pink: [0xFF, 0x48, 0xB0],
  blue: [0x00, 0x78, 0xBF],
};

/**
 * Where each plate lands, in CSS pixels, once the press is in register — a
 * real riso never quite is. And where each lands on the first sheet of the run,
 * before the drum settles: the entrance eases from the second to the first.
 */
export const REGISTER = {
  rest: { black: [0, 0], pink: [1.1, -0.7], blue: [-0.8, 0.9] },
  first: { black: [0, 0], pink: [-9, 6], blue: [8, -7] },
};

const VERT = 'attribute vec2 a; void main() { gl_Position = vec4(a, 0.0, 1.0); }';

const FRAG = `
precision highp float;
uniform sampler2D uK;
uniform sampler2D uP;
uniform sampler2D uB;
uniform vec2 uCss;
uniform float uDpr;
uniform float uH;
uniform float uPitch;
uniform vec3 uInkK;
uniform vec3 uInkP;
uniform vec3 uInkB;
uniform vec2 uOffK;
uniform vec2 uOffP;
uniform vec2 uOffB;

float hash(vec2 p) {
  p = fract(p * vec2(443.897, 441.423));
  p += dot(p, p.yx + 19.19);
  return fract((p.x + p.y) * p.x);
}
float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

// Amplitude-modulated round dots on a rotated grid, sized so the printed area
// matches the coverage. Past 78% the dots merge and the holes close, so a
// solid prints solid.
float screen(sampler2D t, vec2 css, float ang, vec2 off) {
  vec2 p = css - off;
  float c = texture2D(t, p / uCss).a;
  if (c < 0.004) return 0.0;
  float s = sin(ang);
  float co = cos(ang);
  vec2 q = vec2(co * p.x + s * p.y, -s * p.x + co * p.y) / uPitch;
  vec2 f = fract(q) - 0.5;
  float d = length(f) * 1.41421356;
  float r = c < 0.785 ? sqrt(c / 1.5708) : mix(0.7071, 1.04, (c - 0.785) / 0.215);
  float aa = 1.41421356 / (uPitch * uDpr);
  return 1.0 - smoothstep(r - aa, r + aa, d);
}

void main() {
  vec2 css = vec2(gl_FragCoord.x, uH - gl_FragCoord.y) / uDpr;
  // The drum skips: a few dots in a hundred never take ink.
  float holes = step(0.03, hash(floor(css * 1.4)));
  float b = screen(uB, css, radians(75.0), uOffB) * (0.82 + 0.18 * noise(css / 70.0 + 3.1)) * holes;
  float p = screen(uP, css, radians(15.0), uOffP) * (0.86 + 0.14 * noise(css / 64.0 + 11.7)) * holes;
  float k = screen(uK, css, radians(45.0), uOffK) * (0.9 + 0.1 * noise(css / 90.0 + 23.3));
  vec3 col = vec3(1.0);
  col *= mix(vec3(1.0), uInkB, b);
  col *= mix(vec3(1.0), uInkP, p);
  col *= mix(vec3(1.0), uInkK, k);
  gl_FragColor = vec4(col, 1.0);
}`;

/** Three coverage plates the size of a print, drawn in CSS pixels. */
export function makePlates() {
  const plates = {};
  for (const key of Object.keys(INK)) {
    const canvas = document.createElement('canvas');
    plates[key] = canvas;
  }
  return plates;
}

/**
 * Clear every plate and set it to draw in CSS pixels at `scale` device pixels
 * each. Returns the three 2D contexts.
 */
export function clearPlates(plates, scale) {
  const ctx = {};
  for (const [key, canvas] of Object.entries(plates)) {
    const c = canvas.getContext('2d');
    c.setTransform(1, 0, 0, 1, 0, 0);
    c.clearRect(0, 0, canvas.width, canvas.height);
    c.setTransform(scale, 0, 0, scale, 0, 0);
    ctx[key] = c;
  }
  return ctx;
}

/**
 * A press on `canvas`, or null where WebGL is unavailable — the caller then
 * leaves the canvas blank and the page's words carry it.
 *
 * pitch(cssWidth) is the dot pitch in CSS pixels.
 */
export function createPress(canvas, { pitch }) {
  const gl = canvas.getContext('webgl', { antialias: false, premultipliedAlpha: false, preserveDrawingBuffer: true });
  if (!gl) return null;
  const compile = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  const program = gl.createProgram();
  gl.attachShader(program, compile(gl.VERTEX_SHADER, VERT));
  gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FRAG));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
  gl.useProgram(program);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const aLoc = gl.getAttribLocation(program, 'a');
  gl.enableVertexAttribArray(aLoc);
  gl.vertexAttribPointer(aLoc, 2, gl.FLOAT, false, 0, 0);
  const U = (name) => gl.getUniformLocation(program, name);
  const unit = (v) => v.map((x) => x / 255);

  const textures = [['black', 'uK'], ['pink', 'uP'], ['blue', 'uB']].map(([key, name], i) => {
    const tex = gl.createTexture();
    gl.activeTexture(gl.TEXTURE0 + i);
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.uniform1i(U(name), i);
    return { key, i, tex };
  });
  gl.uniform3fv(U('uInkK'), unit(INK.black));
  gl.uniform3fv(U('uInkP'), unit(INK.pink));
  gl.uniform3fv(U('uInkB'), unit(INK.blue));
  const offsets = { black: U('uOffK'), pink: U('uOffP'), blue: U('uOffB') };

  let sized = false;
  const press = {
    /** Size the press to its box. Returns the device pixel ratio it prints at. */
    resize(w, h) {
      const dpr = Math.min(2, globalThis.devicePixelRatio || 1);
      sized = w > 0 && h > 0;
      canvas.width = Math.max(1, Math.round(w * dpr));
      canvas.height = Math.max(1, Math.round(h * dpr));
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.uniform2f(U('uCss'), w, h);
      gl.uniform1f(U('uDpr'), canvas.width / w);
      gl.uniform1f(U('uH'), canvas.height);
      gl.uniform1f(U('uPitch'), pitch(w));
      return dpr;
    },
    /** How far out of register the run still is: 1 on the first sheet, 0 settled. */
    register(amount) {
      for (const [key, loc] of Object.entries(offsets)) {
        const [rx, ry] = REGISTER.rest[key];
        const [fx, fy] = REGISTER.first[key];
        gl.uniform2f(loc, rx + (fx - rx) * amount, ry + (fy - ry) * amount);
      }
    },
    /** Print three coverage plates: {black, pink, blue} canvases. */
    print(plates) {
      if (!sized) return;
      for (const t of textures) {
        gl.activeTexture(gl.TEXTURE0 + t.i);
        gl.bindTexture(gl.TEXTURE_2D, t.tex);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, plates[t.key]);
      }
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    },
  };
  press.register(0);
  return press;
}
