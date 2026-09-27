// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic pixel art and its spoiling — everything a known-answer test needs,
// with no files at all. Everything here is deterministic (seeded, no canvas
// smoothing, no browser codecs), so hashes of results are the same in every
// browser. JPEG spoiling uses the browser's encoder and is kept for the
// measuring benches only, never for the regression hashes.

/** A small seeded random generator (mulberry32). */
export function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function hsl(h, s, l) {
  const k = n => (n + h / 30) % 12, a = s * Math.min(l, 1 - l);
  const f = n => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
  return [Math.round(255 * f(0)), Math.round(255 * f(8)), Math.round(255 * f(4))];
}

/** Pixel art made of what real pixel art is made of: flat areas, ramps of a
    few shades, outlines, a dithered region and single-pixel details. */
export function makeArt(seed, w, h) {
  const r = rng(seed);
  const base = r() * 360;
  const pal = [];
  for (let i = 0; i < 12; i++) pal.push(hsl((base + i * 47 + r() * 20) % 360, 0.35 + 0.5 * r(), 0.15 + 0.7 * r()));
  const dark = [20 + (r() * 20 | 0), 18 + (r() * 20 | 0), 30 + (r() * 20 | 0)];
  const data = new Uint8Array(w * h * 3);
  const set = (x, y, c) => {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    const i = (y * w + x) * 3; data[i] = c[0]; data[i + 1] = c[1]; data[i + 2] = c[2];
  };
  // background: bands of a ramp
  const bands = 3 + (r() * 3 | 0);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) set(x, y, pal[Math.floor(y * bands / h)]);
  // a dithered region
  const dx0 = r() * w * 0.5 | 0, dy0 = r() * h * 0.5 | 0, dw = 6 + (r() * w * 0.3 | 0), dh = 4 + (r() * h * 0.2 | 0);
  for (let y = dy0; y < dy0 + dh; y++) for (let x = dx0; x < dx0 + dw; x++) if ((x + y) % 2) set(x, y, pal[6]);
  // outlined discs
  const discs = 3 + (r() * 4 | 0);
  for (let k = 0; k < discs; k++) {
    const cx = r() * w, cy = r() * h, rad = 2 + r() * Math.min(w, h) * 0.18, c = pal[7 + (k % 5)];
    for (let y = Math.floor(cy - rad - 1); y <= cy + rad + 1; y++)
      for (let x = Math.floor(cx - rad - 1); x <= cx + rad + 1; x++) {
        // sqrt, not Math.hypot: hypot may round differently between browsers
        const d = Math.sqrt((x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2);
        if (d <= rad) set(x, y, d > rad - 1 ? dark : c);
      }
  }
  // rectangles
  for (let k = 0; k < 4; k++) {
    const x0 = r() * w | 0, y0 = r() * h | 0, rw = 2 + (r() * w * 0.25 | 0), rh = 2 + (r() * h * 0.25 | 0), c = pal[3 + k];
    for (let y = y0; y < y0 + rh; y++) for (let x = x0; x < x0 + rw; x++) set(x, y, c);
  }
  // single-pixel details and pairs
  for (let k = 0; k < (w * h) / 60; k++) {
    const x = r() * w | 0, y = r() * h | 0, c = pal[r() * 12 | 0];
    set(x, y, c);
    if (r() < 0.3) set(x + 1, y, c);
  }
  return { data, w, h };
}

/** Upscales art by a fractional step with an origin — nearest neighbour, as a
    pixel art picture is shown. A margin of 8 pixels frames the work. */
export function upscale(art, step, ox, oy) {
  const W = Math.ceil(ox + step * art.w) + 8, H = Math.ceil(oy + step * art.h) + 8;
  const data = new Uint8Array(W * H * 3);
  const cx = new Int32Array(W), cy = new Int32Array(H);
  for (let x = 0; x < W; x++) cx[x] = Math.min(art.w - 1, Math.max(0, Math.floor((x - ox) / step)));
  for (let y = 0; y < H; y++) cy[y] = Math.min(art.h - 1, Math.max(0, Math.floor((y - oy) / step)));
  for (let y = 0, p = 0; y < H; y++) {
    const row = cy[y] * art.w;
    for (let x = 0; x < W; x++, p += 3) {
      const i = (row + cx[x]) * 3;
      data[p] = art.data[i]; data[p + 1] = art.data[i + 1]; data[p + 2] = art.data[i + 2];
    }
  }
  return { data, w: W, h: H };
}

/** Deterministic grain: every channel moved by up to ±strength. */
export function grain(img, strength, seed) {
  const r = rng(seed), out = new Uint8Array(img.data.length);
  for (let i = 0; i < out.length; i += 3) {
    const n = (r() * 2 - 1) * strength;
    for (let c = 0; c < 3; c++) out[i + c] = Math.max(0, Math.min(255, Math.round(img.data[i + c] + n)));
  }
  return { data: out, w: img.w, h: img.h };
}

/** Deterministic box blur of radius 1 — smearing across cell borders. */
export function blur(img) {
  const { w, h } = img, out = new Uint8Array(img.data.length);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) for (let c = 0; c < 3; c++) {
    let s = 0, n = 0;
    for (let j = -1; j <= 1; j++) for (let i = -1; i <= 1; i++) {
      const xx = x + i, yy = y + j;
      if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
      s += img.data[(yy * w + xx) * 3 + c]; n++;
    }
    out[(y * w + x) * 3 + c] = Math.round(s / n);
  }
  return { data: out, w, h };
}

/* JPEG through the browser's encoder — for measuring benches only. It runs in
   a worker: in a background tab the browser encodes on the page's own thread
   about once a second, in a worker at full speed. */
const JPEG_WORKER = `onmessage = async e => {
  const { w, h, rgba, quality } = e.data;
  const c = new OffscreenCanvas(w, h);
  c.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(rgba), w, h), 0, 0);
  const bmp = await createImageBitmap(await c.convertToBlob({ type: 'image/jpeg', quality }));
  const c2 = new OffscreenCanvas(bmp.width, bmp.height);
  const g = c2.getContext('2d', { willReadFrequently: true });
  g.drawImage(bmp, 0, 0);
  const d = g.getImageData(0, 0, bmp.width, bmp.height).data;
  postMessage({ w: bmp.width, h: bmp.height, rgba: d.buffer }, [d.buffer]);
};`;
let worker = null, queue = Promise.resolve();
export function jpeg(img, quality) {
  worker = worker || new Worker(URL.createObjectURL(new Blob([JPEG_WORKER], { type: 'text/javascript' })));
  const rgba = new Uint8ClampedArray(img.w * img.h * 4);
  for (let i = 0, j = 0; i < img.w * img.h; i++, j += 4) {
    rgba[j] = img.data[i * 3]; rgba[j + 1] = img.data[i * 3 + 1]; rgba[j + 2] = img.data[i * 3 + 2]; rgba[j + 3] = 255;
  }
  // One picture at a time: answers come back in the order they were asked.
  const job = queue.then(() => new Promise(r => {
    worker.onmessage = e => {
      const { w, h } = e.data, d = new Uint8Array(e.data.rgba), out = new Uint8Array(w * h * 3);
      for (let i = 0, j = 0; i < d.length; i += 4, j += 3) { out[j] = d[i]; out[j + 1] = d[i + 1]; out[j + 2] = d[i + 2]; }
      r({ data: out, w, h });
    };
    worker.postMessage({ w: img.w, h: img.h, rgba: rgba.buffer, quality }, [rgba.buffer]);
  }));
  queue = job;
  return job;
}

/** FNV-1a over any typed array or array of numbers. */
export function hash(...parts) {
  let x = 2166136261 >>> 0;
  for (const p of parts) {
    const b = p instanceof Uint8Array ? p
      : ArrayBuffer.isView(p) ? new Uint8Array(p.buffer, p.byteOffset, p.byteLength)
      : new Uint8Array(new Float64Array(p).buffer);
    for (let i = 0; i < b.length; i++) { x ^= b[i]; x = Math.imul(x, 16777619) >>> 0; }
  }
  return x.toString(16).padStart(8, '0');
}
