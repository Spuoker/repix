// SPDX-License-Identifier: GPL-3.0-or-later
// The core for the tests, taken from the BUILT repix.html — the very file that
// is shipped — driven by the program's own pipeline (src/ui/pipeline.js): the
// same functions the page calls, not a copy of them. Nothing of the program
// depends on this file; it only adapts the pipeline to plain images:
// img = {data: RGB bytes, w, h}.
import * as P from '../../src/ui/pipeline.js';
export { borders } from '../../src/ui/pipeline.js';

let E = null;

/** Loads the core embedded in the built repix.html in the project root.
    Returns its size in bytes. */
export async function loadCore(page = '../../repix.html') {
  const html = await (await fetch(page + '?' + Date.now())).text();
  const m = html.match(/const CORE_B64="([A-Za-z0-9+/=]+)"/);
  if (!m) throw new Error('no embedded core in ' + page + ' — run `zig build` first');
  const bin = atob(m[1]);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const { instance } = await WebAssembly.instantiate(bytes, { env: { rowDone() {} } });
  E = instance.exports;
  return bytes.length;
}

// Every call starts from empty core memory with the image at its start. The
// core reads four bytes a pixel (premultiplied RGBA); a test image is plain
// RGB, all of it there.
function fresh(img) {
  E.resetMemory();
  const n = img.w * img.h, p = E.allocMemory(n * 4) >>> 0;
  const m = new Uint8Array(E.memory.buffer, p, n * 4);
  for (let i = 0, j = 0; i < n * 3; i += 3, j += 4) { m[j] = img.data[i]; m[j + 1] = img.data[i + 1]; m[j + 2] = img.data[i + 2]; m[j + 3] = 255; }
  return p;
}
// The core's cells are RGBA; the tests read RGB.
const rgbOf = a => { const o = new Uint8Array(a.length / 4 * 3); for (let i = 0, j = 0; i < a.length; i += 4, j += 3) { o[j] = a[i]; o[j + 1] = a[i + 1]; o[j + 2] = a[i + 2]; } return o; };

/** Grid search, as the page does it on opening. */
export function findGrid(img) {
  const g = P.searchGrid(E, fresh(img), img.w, img.h);
  return g && { step: g.step, ox: g.ox, oy: g.oy, agreement: g.coherence };
}

/** Pass 1 with the stage 1 knobs k (see pipeline.js) and an agreement share. */
function run1(img, gx, gy, k, share) {
  const r = P.pass1(E, fresh(img), img.w, img.h, gx, gy, k, share);
  if (r.code !== 1) return null;
  const rgba = new Uint8Array(E.memory.buffer, r.out, r.nx * r.ny * 4).slice();
  return { w: r.nx, h: r.ny, meas: r.meas, rgba, art: rgbOf(rgba) };
}

/** Pass 1 with a fixed tolerance and agreement: {overlap, tolerance, agreement}. */
export function pass1(img, gx, gy, p) {
  if (gx.length < 2 || gy.length < 2) return null;
  const k = { ...P.KNOB_START, overlap: p.overlap, colorTolerance: p.tolerance,
              noiseMultiple: 0, cap: 0, agreement: p.agreement };
  return run1(img, gx, gy, k, 0);
}

/** Stage 1 as the page runs it: first with the knobs where they start, then
    again with the core's advice. */
export function stage1(img, grid) {
  const gx = P.borders(img.w, grid.step, grid.ox), gy = P.borders(img.h, grid.step, grid.oy);
  if (gx.length < 2 || gy.length < 2) return null;
  const first = run1(img, gx, gy, P.KNOB_START, P.AGREEMENT_SHARE_START);
  if (!first) return null;
  const a = P.advice(E, grid.step, first.meas);
  const k = { ...P.KNOB_START, colorTolerance: a.colorTolerance, noiseMultiple: a.noiseMultiple,
              cap: a.cap, overlap: a.overlap, agreement: a.agreement };
  if (a.jitter !== null) k.jitter = a.jitter;
  const r = run1(img, gx, gy, k, a.agreementShare);
  if (!r) return null;
  r.knobs = k;
  return r;
}

/** Stage 2 with its automatic settings. */
export function stage2(s1) {
  const joints = P.jointsOf(s1.rgba, s1.w, s1.h);
  const k = P.groupAdvice(s1.w, s1.h, joints, s1.meas, s1.knobs.jitter);
  E.resetMemory();
  const r = P.pass2(E, s1.rgba, s1.w, s1.h, k, joints);
  return { w: s1.w, h: s1.h, groups: r.groups, rgba: r.art, art: rgbOf(r.art), label: r.label };
}

/** Stage 3 with its automatic settings; knobs may override them. */
export function stage3(s2, knobs = {}) {
  const cc = P.clusterColors(s2.rgba, s2.label);
  const spread = P.spreadOf(cc);
  const k = { ...P.KNOB_START, ...P.mergeAdvice(s2.w, s2.h, spread), ...knobs };
  E.resetMemory();
  const r = P.pass3(E, s2.label, s2.w, s2.h, cc, k, spread);
  // the palette as the tests know it: r, g, b, cells
  const pal = [];
  for (let i = 0; i < r.palette.length; i += 5) pal.push(r.palette[i], r.palette[i + 1], r.palette[i + 2], r.palette[i + 4]);
  return { w: s2.w, h: s2.h, paints: r.paints, art: rgbOf(r.art), palette: pal };
}

/** Everything the page does, end to end, with the automatic settings. */
export function pipeline(img) {
  const grid = findGrid(img);
  if (!grid) return { grid: null };
  const s1 = stage1(img, grid);
  if (!s1) return { grid };
  const s2 = stage2(s1);
  const s3 = stage3(s2);
  return { grid, s1, s2, s3 };
}
