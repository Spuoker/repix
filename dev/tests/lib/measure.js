// SPDX-License-Identifier: GPL-3.0-or-later
// Measures against the truth (the hand-made art at its native resolution).
//
// LOSSES — the main one. A cell is lost when it is closer to ANOTHER paint of
// the truth than to its own: stages 2 and 3 will pull it the wrong way and
// nothing brings it back. How far it drifted does not matter otherwise.
// Truth shades closer than JOIN are one paint (the clustering could not
// separate them either).

export const JOIN = 10;

export async function loadRGB(url) {
  const bmp = await createImageBitmap(await (await fetch(url)).blob());
  const c = new OffscreenCanvas(bmp.width, bmp.height);
  const g = c.getContext('2d', { willReadFrequently: true });
  g.imageSmoothingEnabled = false;
  g.drawImage(bmp, 0, 0);
  return canvasRGB(c);
}

export function canvasRGB(c) {
  const d = c.getContext('2d', { willReadFrequently: true }).getImageData(0, 0, c.width, c.height).data;
  const out = new Uint8Array(c.width * c.height * 3);
  for (let i = 0, j = 0; i < d.length; i += 4, j += 3) { out[j] = d[i]; out[j + 1] = d[i + 1]; out[j + 2] = d[i + 2]; }
  return { data: out, w: c.width, h: c.height };
}

/** The truth's palette joined into paints. */
export function paints(t) {
  const shades = [], index = new Map(), shade = new Int32Array(t.w * t.h);
  for (let i = 0; i < t.w * t.h; i++) {
    const k = (t.data[i * 3] << 16) | (t.data[i * 3 + 1] << 8) | t.data[i * 3 + 2];
    let s = index.get(k);
    if (s === undefined) { s = shades.length; index.set(k, s); shades.push([t.data[i * 3], t.data[i * 3 + 1], t.data[i * 3 + 2]]); }
    shade[i] = s;
  }
  const parent = shades.map((_, i) => i);
  const root = i => { while (parent[i] !== i) i = parent[i] = parent[parent[i]]; return i; };
  for (let a = 0; a < shades.length; a++) for (let b = a + 1; b < shades.length; b++) {
    const d = Math.hypot(shades[a][0] - shades[b][0], shades[a][1] - shades[b][1], shades[a][2] - shades[b][2]);
    if (d < JOIN) { const x = root(a), y = root(b); if (x !== y) parent[x] = y; }
  }
  const number = new Map(), paintOf = new Int32Array(shades.length);
  for (let i = 0; i < shades.length; i++) {
    const r = root(i);
    if (!number.has(r)) number.set(r, number.size);
    paintOf[i] = number.get(r);
  }
  const cell = new Int32Array(t.w * t.h);
  for (let i = 0; i < cell.length; i++) cell[i] = paintOf[shade[i]];
  return { shades, paintOf, cell, shade, count: number.size };
}

/** Losses and mean error of `art` (w x h) against the truth, with the truth
    placed at offset (dx, dy) inside the art. */
export function losses(art, w, h, p, tw, th, dx, dy) {
  let lost = 0, err = 0, n = 0;
  for (let y = 0; y < th; y++) for (let x = 0; x < tw; x++) {
    const ox = x + dx, oy = y + dy;
    if (ox < 0 || oy < 0 || ox >= w || oy >= h) continue;
    const a = (oy * w + ox) * 3, i = y * tw + x;
    const r = art[a], g = art[a + 1], b = art[a + 2];
    let best = -1, bd = 1e18;
    for (let s = 0; s < p.shades.length; s++) {
      const c = p.shades[s], d = (r - c[0]) ** 2 + (g - c[1]) ** 2 + (b - c[2]) ** 2;
      if (d < bd) { bd = d; best = s; }
    }
    const o = p.shades[p.shade[i]];
    err += Math.hypot(r - o[0], g - o[1], b - o[2]); n++;
    if (p.paintOf[best] !== p.cell[i]) lost++;
  }
  return { losses: n ? 100 * lost / n : 100, error: n ? err / n : Infinity, n };
}

/** The best alignment of art against truth within a small search window. */
export function align(art, w, h, p, tw, th, reach = 3) {
  let best = null;
  for (let dy = -reach; dy <= reach + Math.max(0, h - th); dy++)
    for (let dx = -reach; dx <= reach + Math.max(0, w - tw); dx++) {
      const l = losses(art, w, h, p, tw, th, dx, dy);
      if (l.n < tw * th * 0.5) continue;
      if (!best || l.error < best.error) best = { dx, dy, ...l };
    }
  return best;
}

/** Truth clusters: connected areas of one exact shade. */
export function truthClusters(p, tw, th) {
  const label = new Int32Array(tw * th).fill(-1), stack = new Int32Array(tw * th), size = [];
  let n = 0;
  for (let s = 0; s < tw * th; s++) {
    if (label[s] >= 0) continue;
    const sh = p.shade[s];
    let top = 0, count = 0;
    stack[top++] = s; label[s] = n;
    while (top > 0) {
      const c = stack[--top]; count++;
      const x = c % tw, y = (c - x) / tw;
      for (const d of [x > 0 ? c - 1 : -1, x < tw - 1 ? c + 1 : -1, y > 0 ? c - tw : -1, y < th - 1 ? c + tw : -1])
        if (d >= 0 && label[d] < 0 && p.shade[d] === sh) { label[d] = n; stack[top++] = d; }
    }
    size.push(count); n++;
  }
  return { label, size, count: n };
}

export const SPOT_SIZES = [[1, 1], [2, 2], [3, 4], [5, 9], [10, 1e9]];
export const SPOT_NAMES = ['single', 'pair', '3-4', '5-9', '10+'];

/** Spots by size: how many of their cells went to a NEIGHBOURING paint. The
    reference for "own" is the mean of our colors over the whole paint, so a
    single-cell spot is measured too. */
export function spotLosses(art, w, h, cl, p, tw, th, dx, dy) {
  const sum = Array.from({ length: p.count }, () => [0, 0, 0, 0]);
  for (let y = 0; y < th; y++) for (let x = 0; x < tw; x++) {
    const ox = x + dx, oy = y + dy;
    if (ox < 0 || oy < 0 || ox >= w || oy >= h) continue;
    const a = (oy * w + ox) * 3, k = p.cell[y * tw + x];
    sum[k][0] += art[a]; sum[k][1] += art[a + 1]; sum[k][2] += art[a + 2]; sum[k][3]++;
  }
  const mean = sum.map(s => s[3] ? [s[0] / s[3], s[1] / s[3], s[2] / s[3]] : null);
  const bySize = SPOT_SIZES.map(() => ({ cells: 0, lost: 0, spots: 0, broken: 0 }));
  const lostIn = new Int32Array(cl.count);
  let lost = 0, total = 0;
  for (let y = 0; y < th; y++) for (let x = 0; x < tw; x++) {
    const ox = x + dx, oy = y + dy;
    if (ox < 0 || oy < 0 || ox >= w || oy >= h) continue;
    const a = (oy * w + ox) * 3, i = y * tw + x, mine = p.cell[i];
    if (!mean[mine]) continue;
    const r = art[a], g = art[a + 1], b = art[a + 2];
    const own = (r - mean[mine][0]) ** 2 + (g - mean[mine][1]) ** 2 + (b - mean[mine][2]) ** 2;
    let other = 1e18;
    for (let ny = -1; ny <= 1; ny++) for (let nx = -1; nx <= 1; nx++) {
      const xx = x + nx, yy = y + ny;
      if ((!nx && !ny) || xx < 0 || yy < 0 || xx >= tw || yy >= th) continue;
      const k = p.cell[yy * tw + xx];
      if (k === mine || !mean[k]) continue;
      const d = (r - mean[k][0]) ** 2 + (g - mean[k][1]) ** 2 + (b - mean[k][2]) ** 2;
      if (d < other) other = d;
    }
    total++;
    if (other < own) { lost++; lostIn[cl.label[i]]++; }
  }
  for (let m = 0; m < cl.count; m++) {
    const k = SPOT_SIZES.findIndex(([a, b]) => cl.size[m] >= a && cl.size[m] <= b);
    bySize[k].cells += cl.size[m]; bySize[k].lost += lostIn[m]; bySize[k].spots++;
    if (lostIn[m] * 2 > cl.size[m]) bySize[k].broken++;
  }
  return { share: total ? 100 * lost / total : 0, bySize };
}
