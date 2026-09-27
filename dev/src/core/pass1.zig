// SPDX-License-Identifier: GPL-3.0-or-later
// Pass 1: from the image to one color per grid cell.
//
// Order:
//   1. ANCHOR — the pixel in the middle of the cell: the first guess at what
//      the cell is. If almost nothing in the cell agrees with it (a lone
//      compression artifact), the anchor moves to a real paint of the cell.
//   2. INSIDE — every pixel of the cell votes with a weight that falls with its
//      distance from the anchor in color and from the centre in place
//      (a bilateral weight). Nothing is thrown away, far pixels just go quiet.
//   3. OVERLAP — a band past the cell border, judged per neighbouring cell: a
//      neighbour's piece of the same paint is taken whole, a piece of another
//      paint is not taken at all. Its voice is capped by "surround weight".
//   4. RESULT — the weighted mean of the inside and the accepted overlap.
//
// While visiting every pixel anyway, the pass also measures the image for
// free: noise inside cells, differences between neighbours, slope and jitter.
// Those measurements drive the automatic settings.

const memory = @import("memory.zig");

// Provided by the page: called after each finished row of cells, so the
// result can be drawn while it is being computed.
extern "env" fn rowDone(j: u32) void;

fn sq(x: f64) f64 {
    return x * x;
}

fn dist2(a: [*]const f64, i: usize, b: [*]const f64, j: usize) f64 {
    return sq(a[i * 3] - b[j * 3]) +
        sq(a[i * 3 + 1] - b[j * 3 + 1]) +
        sq(a[i * 3 + 2] - b[j * 3 + 2]);
}

// Pixels in a cell window with its overlap, sized for the worst case the knobs
// allow (step 40, overlap 3 gives 283x283). If a window still does not fit,
// the pass refuses instead of computing on a cut-off piece.
const MAX_WINDOW = 81225;

// SURROUND WEIGHT — how much voice the accepted neighbour pieces get, as a
// share of the inside's voice. Above one is allowed on purpose: on a cell that
// straddles two paints, a clean neighbour knows its paint better than the
// cell's own few smeared pixels.
var OVERLAP_WEIGHT: f64 = 1.0;

// SPATIAL WIDTH of the inside average, as a share of the cell side: the
// farther a pixel is from the middle, the quieter it is. The best value
// differs between works, so it is a knob for the user.
var PLACE_WIDTH: f64 = 0.12;
export fn setPlaceWidth(v: f64) void {
    PLACE_WIDTH = v;
}
export fn setSurroundWeight(v: f64) void {
    OVERLAP_WEIGHT = v;
}

// Scratch buffers, so nothing is allocated per cell.
var color: [MAX_WINDOW * 3]f64 = undefined;
var weight: [MAX_WINDOW]f64 = undefined;
var inside: [MAX_WINDOW]bool = undefined;
var offx: [MAX_WINDOW]f64 = undefined; // pixel offset from the cell centre
var offy: [MAX_WINDOW]f64 = undefined;
var own: [MAX_WINDOW]u32 = undefined; // indices of the pixels inside the cell
var edge: [MAX_WINDOW]bool = undefined; // a pixel inside the cell that touches its border
var inner_idx: [MAX_WINDOW]u32 = undefined; // the cell's pixels off its border
var edge_idx: [MAX_WINDOW]u32 = undefined; // the cell's pixels on its border
var neighbour: [MAX_WINDOW]u8 = undefined; // which neighbour cell an overlap pixel belongs to
var med_buf: [MAX_WINDOW]f64 = undefined; // for per-channel medians

// Percent of the cell that must agree with the middle pixel for it to stay
// the anchor.
const LONELY: usize = 45;

/// Median of the first n values of med_buf (insertion sort in place).
fn median(n: usize) f64 {
    if (n == 0) return 0;
    var a: usize = 1;
    while (a < n) : (a += 1) {
        const v = med_buf[a];
        var b = a;
        while (b > 0 and med_buf[b - 1] > v) : (b -= 1) med_buf[b] = med_buf[b - 1];
        med_buf[b] = v;
    }
    return med_buf[n / 2];
}

// Overlap pixels are grouped by the neighbour cell they lie in, up to five
// cells away, so each neighbour's piece is judged on its own.
const MAX_SHIFT: i64 = 5;
const NEIGHBOURS: usize = 121; // (2*5+1)^2
var sumN: [NEIGHBOURS][3]f64 = undefined;
var cntN: [NEIGHBOURS]f64 = undefined;
var colShift: [512]i8 = undefined; // column offset of a pixel from the cell
var rowShift: [512]i8 = undefined; // the same for rows

/// Which cell pixel p lies in, counted from cell i. Pixel p belongs to cell k
/// when ceil(g[k]) <= p < ceil(g[k+1]).
fn cellShift(g: [*]const f64, n: usize, i: usize, p: i64, limit: i64) i64 {
    var d: i64 = 0;
    var k: i64 = @intCast(i);
    while (d > -limit and k > 0 and
        p < @as(i64, @intFromFloat(@ceil(g[@intCast(k)])))) : (k -= 1) d -= 1;
    while (d < limit and k + 1 <= @as(i64, @intCast(n)) and
        p >= @as(i64, @intFromFloat(@ceil(g[@intCast(k + 1)])))) : (k += 1) d += 1;
    return d;
}

/// THE PASS IN PARTS. The page must show the art growing row by row, and a
/// browser paints only between calls: one call over the whole picture would
/// show it only when done. So the pass is begun, run a number of rows at a
/// time, and ended; the page lets the browser paint between the parts. The
/// work of a row is the same as in one whole call, and so is the result.
const Pass = struct {
    img: [*]const u8 = undefined,
    W: u32 = 0,
    H: u32 = 0,
    gx: [*]const f64 = undefined,
    nx: u32 = 0,
    gy: [*]const f64 = undefined,
    ny: u32 = 0,
    overlap: f64 = 0,
    tolerance: f64 = 0,
    agree: f64 = 0,
    out: [*]u8 = undefined,
    broken: [*]u8 = undefined,
    meas: [*]f64 = undefined,
    rows: [*]f64 = undefined,
    next: usize = 0,
};
var P: Pass = .{};

/// Computes the art from EXPLICIT cell borders, in one call.
/// gx — nx+1 vertical borders, gy — ny+1 horizontal borders. Usually an even
/// grid from step and origin, but single lines may have been moved by hand.
/// tolerance — "color tolerance", overlap — "overlap", agree — "agreement".
/// out — nx*ny RGB cells; broken — 1 where the anchor had to move;
/// meas — the measurements (see the end of the file).
/// Returns 1 — done; 0 — too few borders; 2 — a cell window does not fit.
export fn pass1(
    img: [*]const u8,
    W: u32,
    H: u32,
    gx: [*]const f64,
    nx: u32,
    gy: [*]const f64,
    ny: u32,
    overlap: f64,
    tolerance: f64,
    agree: f64,
    out: [*]u8,
    broken: [*]u8,
    meas: [*]f64,
) u32 {
    const begun = pass1Begin(img, W, H, gx, nx, gy, ny, overlap, tolerance, agree, out, broken, meas);
    if (begun != 1) return begun;
    if (pass1Rows(ny) == 2) return 2;
    return pass1End();
}

/// Begins a pass: the same arguments as pass1. Returns 1, or 0 — too few borders.
export fn pass1Begin(
    img: [*]const u8,
    W: u32,
    H: u32,
    gx: [*]const f64,
    nx: u32,
    gy: [*]const f64,
    ny: u32,
    overlap: f64,
    tolerance: f64,
    agree: f64,
    out: [*]u8,
    broken: [*]u8,
    meas: [*]f64,
) u32 {
    if (nx == 0 or ny == 0) return 0;
    const NX = @as(usize, @intCast(nx));

    var kl: usize = 0;
    while (kl < NL) : (kl += 1) {
        var kb: usize = 0;
        while (kb < NB) : (kb += 1) hist[kl][kb] = 0;
    }
    kl = 0;
    while (kl < NG) : (kl += 1) {
        hSlope[kl] = 0;
        hJitter[kl] = 0;
        hJitterSmall[kl] = 0;
        hInner[kl] = 0;
        hEdge[kl] = 0;
    }

    // The INSIDE color of the last two rows of cells, for the neighbour
    // difference. It is taken before the overlap and does not depend on it.
    const rowsAddr = memory.alloc(NX * 6 * @sizeOf(f64));
    if (rowsAddr == 0) return 0;
    const rows = @as([*]f64, @ptrFromInt(rowsAddr));
    var clear: usize = 0;
    while (clear < NX * 6) : (clear += 1) rows[clear] = -1e9;

    P = .{ .img = img, .W = W, .H = H, .gx = gx, .nx = nx, .gy = gy, .ny = ny,
        .overlap = overlap, .tolerance = tolerance, .agree = agree,
        .out = out, .broken = broken, .meas = meas, .rows = rows, .next = 0 };
    return 1;
}

/// Runs the next `count` rows of cells. Returns 1 — rows are left; 3 — all
/// rows are done (call pass1End); 2 — a cell window does not fit.
export fn pass1Rows(count: u32) u32 {
    const img = P.img;
    const W = P.W;
    const H = P.H;
    const gx = P.gx;
    const nx = P.nx;
    const gy = P.gy;
    const ny = P.ny;
    const overlap = P.overlap;
    const tolerance = P.tolerance;
    const agree = P.agree;
    const out = P.out;
    const broken = P.broken;
    const rows = P.rows;
    const NX = @as(usize, @intCast(nx));
    const NY = @as(usize, @intCast(ny));
    const n2 = tolerance * tolerance;
    const s2 = agree * agree;
    var j: usize = P.next;
    const last = @min(NY, j + @as(usize, count));
    while (j < last) : (j += 1) {
        const y0 = gy[j];
        const y1 = gy[j + 1];
        const hy = y1 - y0;
        const ovy = hy * overlap;
        const cy = (y0 + y1) / 2 - 0.5;
        const iy0 = @as(i64, @intFromFloat(@ceil(y0)));
        const iy1 = @as(i64, @intFromFloat(@ceil(y1)));
        const oy0 = @as(i64, @intFromFloat(@floor(y0 - ovy)));
        const oy1 = @as(i64, @intFromFloat(@ceil(y1 + ovy)));

        {
            var pyy = oy0;
            while (pyy < oy1) : (pyy += 1) {
                const idx = pyy - oy0;
                if (idx < 0 or idx >= 512) continue;
                rowShift[@intCast(idx)] = @intCast(cellShift(gy, NY, j, pyy, MAX_SHIFT));
            }
        }

        var i: usize = 0;
        while (i < NX) : (i += 1) {
            const x0 = gx[i];
            const x1 = gx[i + 1];
            const hx = x1 - x0;
            const ovx = hx * overlap;
            const cx = (x0 + x1) / 2 - 0.5;
            const ix0 = @as(i64, @intFromFloat(@ceil(x0)));
            const ix1 = @as(i64, @intFromFloat(@ceil(x1)));
            const ox0 = @as(i64, @intFromFloat(@floor(x0 - ovx)));
            const ox1 = @as(i64, @intFromFloat(@ceil(x1 + ovx)));

            if ((hx * (1 + 2 * overlap) + 3) * (hy * (1 + 2 * overlap) + 3) >
                @as(f64, @floatFromInt(MAX_WINDOW))) return 2;

            {
                var pxx = ox0;
                while (pxx < ox1) : (pxx += 1) {
                    const idx = pxx - ox0;
                    if (idx < 0 or idx >= 512) continue;
                    colShift[@intCast(idx)] = @intCast(cellShift(gx, NX, i, pxx, MAX_SHIFT));
                }
            }

            var m: usize = 0;
            var mid: usize = 0;
            var has_mid = false;
            const tx = @as(i64, @intFromFloat(@round(cx)));
            const ty = @as(i64, @intFromFloat(@round(cy)));

            var py = oy0;
            while (py < oy1) : (py += 1) {
                if (py < 0 or py >= @as(i64, @intCast(H))) continue;
                var px = ox0;
                while (px < ox1) : (px += 1) {
                    if (px < 0 or px >= @as(i64, @intCast(W))) continue;
                    if (m >= MAX_WINDOW) break;
                    const src = (@as(usize, @intCast(py)) * @as(usize, @intCast(W)) +
                        @as(usize, @intCast(px))) * 3;
                    color[m * 3] = @floatFromInt(img[src]);
                    color[m * 3 + 1] = @floatFromInt(img[src + 1]);
                    color[m * 3 + 2] = @floatFromInt(img[src + 2]);
                    inside[m] = (py >= iy0 and py < iy1 and px >= ix0 and px < ix1);
                    edge[m] = inside[m] and (py == iy0 or py == iy1 - 1 or px == ix0 or px == ix1 - 1);
                    if (!inside[m]) {
                        const dxi = @as(i64, colShift[@intCast(px - ox0)]);
                        const dyi = @as(i64, rowShift[@intCast(py - oy0)]);
                        neighbour[m] = @intCast((dyi + MAX_SHIFT) * (2 * MAX_SHIFT + 1) + (dxi + MAX_SHIFT));
                    }
                    const dy = @as(f64, @floatFromInt(py)) - cy;
                    const dx = @as(f64, @floatFromInt(px)) - cx;
                    weight[m] = 1.0 / (1.0 + @sqrt(dx * dx + dy * dy));
                    offx[m] = dx;
                    offy[m] = dy;
                    if (py == ty and px == tx) {
                        mid = m;
                        has_mid = true;
                    }
                    m += 1;
                }
            }
            const cell = (j * NX + i) * 3;
            if (m == 0) {
                out[cell] = 0;
                out[cell + 1] = 0;
                out[cell + 2] = 0;
                broken[j * NX + i] = 0;
                continue;
            }
            if (!has_mid) mid = 0;

            var kn: usize = 0;
            var p: usize = 0;
            while (p < m) : (p += 1) {
                if (inside[p]) {
                    own[kn] = @intCast(p);
                    kn += 1;
                }
            }
            var bit: u8 = 0;
            var anchor: [3]f64 = .{ color[mid * 3], color[mid * 3 + 1], color[mid * 3 + 2] };
            {
                // THE MIDDLE PIXEL, UNLESS IT IS ALONE. The anchor stays the
                // middle pixel, but if almost nothing in the cell backs it,
                // it is a compression artifact and the anchor moves.
                var backers: usize = 0;
                var a2: usize = 0;
                while (a2 < kn) : (a2 += 1) {
                    if (dist2(&color, @as(usize, own[a2]), &color, mid) < n2) backers += 1;
                }
                // A CELL IS ONE PAINT, NOT A MIX OF TWO. Where a paint border
                // crosses the cell, compression leaves a strip of blurred
                // pixels that look alike, and a middle pixel caught in it is
                // not alone. So the cell's pixels are first split in two by
                // the largest gap along the line between the two most distant
                // ones. If the gap is clear, the anchor becomes the median of
                // the larger side.
                if (kn >= 4) {
                    var da: usize = 0;
                    var db: usize = 0;
                    var dmax: f64 = -1;
                    a2 = 0;
                    while (a2 < kn) : (a2 += 1) {
                        var b2: usize = a2 + 1;
                        while (b2 < kn) : (b2 += 1) {
                            const d = dist2(&color, @as(usize, own[a2]), &color, @as(usize, own[b2]));
                            if (d > dmax) {
                                dmax = d;
                                da = a2;
                                db = b2;
                            }
                        }
                    }
                    // splitting only makes sense when the ends differ by more than the tolerance
                    if (dmax > 4 * n2) {
                        const pa = @as(usize, own[da]);
                        const pb = @as(usize, own[db]);
                        var axis: [3]f64 = .{ color[pb * 3] - color[pa * 3], color[pb * 3 + 1] - color[pa * 3 + 1], color[pb * 3 + 2] - color[pa * 3 + 2] };
                        const len = @sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
                        var ch: usize = 0;
                        while (ch < 3) : (ch += 1) axis[ch] /= len;
                        // projections on the line, sorted
                        a2 = 0;
                        while (a2 < kn) : (a2 += 1) {
                            const pq = @as(usize, own[a2]);
                            med_buf[a2] = (color[pq * 3] - color[pa * 3]) * axis[0] +
                                (color[pq * 3 + 1] - color[pa * 3 + 1]) * axis[1] +
                                (color[pq * 3 + 2] - color[pa * 3 + 2]) * axis[2];
                        }
                        var iq: usize = 1;
                        while (iq < kn) : (iq += 1) {
                            const v = med_buf[iq];
                            var jq = iq;
                            while (jq > 0 and med_buf[jq - 1] > v) : (jq -= 1) med_buf[jq] = med_buf[jq - 1];
                            med_buf[jq] = v;
                        }
                        var cut: f64 = 0;
                        var gap: f64 = -1;
                        iq = 1;
                        while (iq < kn) : (iq += 1) {
                            const pr = med_buf[iq] - med_buf[iq - 1];
                            if (pr > gap) {
                                gap = pr;
                                cut = (med_buf[iq] + med_buf[iq - 1]) / 2;
                            }
                        }
                        // the gap must be real: wider than the tolerance
                        if (gap > @sqrt(n2)) {
                            var n_low: usize = 0;
                            var n_high: usize = 0;
                            a2 = 0;
                            while (a2 < kn) : (a2 += 1) {
                                const pq = @as(usize, own[a2]);
                                const t = (color[pq * 3] - color[pa * 3]) * axis[0] +
                                    (color[pq * 3 + 1] - color[pa * 3 + 1]) * axis[1] +
                                    (color[pq * 3 + 2] - color[pa * 3 + 2]) * axis[2];
                                if (t < cut) n_low += 1 else n_high += 1;
                            }
                            if (n_low > 0 and n_high > 0) {
                                const low_wins = n_low > n_high;
                                // The MEDIAN of the winning side, not its mean:
                                // half-blurred edge pixels pull a mean into the mix.
                                ch = 0;
                                while (ch < 3) : (ch += 1) {
                                    var nq: usize = 0;
                                    var aq: usize = 0;
                                    while (aq < kn) : (aq += 1) {
                                        const pq = @as(usize, own[aq]);
                                        const t = (color[pq * 3] - color[pa * 3]) * axis[0] +
                                            (color[pq * 3 + 1] - color[pa * 3 + 1]) * axis[1] +
                                            (color[pq * 3 + 2] - color[pa * 3 + 2]) * axis[2];
                                        if ((t < cut) != low_wins) continue;
                                        med_buf[nq] = color[pq * 3 + ch];
                                        nq += 1;
                                    }
                                    anchor[ch] = median(nq);
                                }
                                // the middle pixel landed on the losing side: the cell is broken
                                const dt = sq(color[mid * 3] - anchor[0]) + sq(color[mid * 3 + 1] - anchor[1]) +
                                    sq(color[mid * 3 + 2] - anchor[2]);
                                if (dt > n2) bit = 1;
                                backers = kn; // the anchor is chosen, loneliness no longer matters
                            }
                        }
                    }
                }
                if (backers * 100 < kn * LONELY) {
                    // THE MEDIAN, SNAPPED TO A REAL PAINT. The per-channel
                    // median alone smears edges into an in-between color, so
                    // it is only an aim: the anchor becomes the pixel closest
                    // to it that has at least one look-alike in the cell.
                    var med: [3]f64 = undefined;
                    var ch: usize = 0;
                    while (ch < 3) : (ch += 1) {
                        var b2: usize = 0;
                        while (b2 < kn) : (b2 += 1) med_buf[b2] = color[@as(usize, own[b2]) * 3 + ch];
                        med[ch] = median(kn);
                    }
                    anchor = med;
                    var best: usize = kn;
                    var best_d: f64 = 1e30;
                    a2 = 0;
                    while (a2 < kn) : (a2 += 1) {
                        const pa = @as(usize, own[a2]);
                        var backed: usize = 0;
                        var b2: usize = 0;
                        while (b2 < kn) : (b2 += 1) {
                            if (b2 == a2) continue;
                            if (dist2(&color, pa, &color, @as(usize, own[b2])) < n2) {
                                backed += 1;
                                break;
                            }
                        }
                        if (backed == 0) continue;
                        const d = sq(color[pa * 3] - med[0]) + sq(color[pa * 3 + 1] - med[1]) +
                            sq(color[pa * 3 + 2] - med[2]);
                        if (d < best_d) {
                            best_d = d;
                            best = pa;
                        }
                    }
                    if (best != kn) anchor = .{ color[best * 3], color[best * 3 + 1], color[best * 3 + 2] };
                    bit = 1;
                }
            }
            broken[j * NX + i] = bit;

            var sx: f64 = 0;
            var sy: f64 = 0;
            var sz: f64 = 0;
            var total: f64 = 0;

            // BILATERAL WEIGHT: the farther from the anchor in color and from
            // the centre in place, the quieter. Color width — the tolerance,
            // place width — PLACE_WIDTH of the cell.
            const rs2 = sq((hx + hy) * PLACE_WIDTH);
            var q: usize = 0;
            while (q < kn) : (q += 1) {
                const pq = own[q];
                const dc = sq(color[pq * 3] - anchor[0]) + sq(color[pq * 3 + 1] - anchor[1]) +
                    sq(color[pq * 3 + 2] - anchor[2]);
                const dr = offx[pq] * offx[pq] + offy[pq] * offy[pq];
                const w = @exp(-dc / (2 * n2)) * @exp(-dr / (2 * rs2));
                sx += color[pq * 3] * w;
                sy += color[pq * 3 + 1] * w;
                sz += color[pq * 3 + 2] * w;
                total += w;
            }
            if (total <= 0) {
                sx = anchor[0];
                sy = anchor[1];
                sz = anchor[2];
                total = 1;
            }
            const cx0 = sx / total;
            const cy0 = sy / total;
            const cz0 = sz / total;

            var rs: usize = 0;
            while (rs < NEIGHBOURS) : (rs += 1) {
                sumN[rs][0] = 0;
                sumN[rs][1] = 0;
                sumN[rs][2] = 0;
                cntN[rs] = 0;
            }
            p = 0;
            while (p < m) : (p += 1) {
                if (inside[p]) continue;
                const rr = @as(usize, neighbour[p]);
                sumN[rr][0] += color[p * 3];
                sumN[rr][1] += color[p * 3 + 1];
                sumN[rr][2] += color[p * 3 + 2];
                cntN[rr] += 1;
            }
            var ax: f64 = 0;
            var ay: f64 = 0;
            var az: f64 = 0;
            var an: f64 = 0;
            rs = 0;
            while (rs < NEIGHBOURS) : (rs += 1) {
                const k = cntN[rs];
                if (k == 0) continue;
                const d = sq(sumN[rs][0] / k - cx0) + sq(sumN[rs][1] / k - cy0) +
                    sq(sumN[rs][2] / k - cz0);
                if (d >= s2) continue; // a neighbour of another paint: its piece is not taken
                ax += sumN[rs][0];
                ay += sumN[rs][1];
                az += sumN[rs][2];
                an += k;
            }
            var itx = sx;
            var ity = sy;
            var itz = sz;
            var itn = total;
            if (an > 0) {
                // The overlap has a low voice: at most OVERLAP_WEIGHT of the inside.
                var w: f64 = 1.0;
                const limit = OVERLAP_WEIGHT * total;
                if (an > limit) w = limit / an;
                itx += ax * w;
                ity += ay * w;
                itz += az * w;
                itn += an * w;
            }

            out[cell] = roundByte(itx / itn);
            out[cell + 1] = roundByte(ity / itn);
            out[cell + 2] = roundByte(itz / itn);

            // MEASUREMENTS FOR FREE. Spread — over the inside pixels already
            // visited. Neighbour difference — with the left and upper cells,
            // already computed.
            var q1: [3]f64 = .{ 0, 0, 0 };
            var q2: [3]f64 = .{ 0, 0, 0 };
            var qn: f64 = 0;
            p = 0;
            while (p < m) : (p += 1) {
                if (!inside[p]) continue;
                var c: usize = 0;
                while (c < 3) : (c += 1) {
                    const v = color[p * 3 + c];
                    q1[c] += v;
                    q2[c] += v * v;
                }
                qn += 1;
            }
            var spread: f64 = 0;
            if (qn >= 2) {
                var c: usize = 0;
                while (c < 3) : (c += 1) {
                    var d = q2[c] / qn - (q1[c] / qn) * (q1[c] / qn);
                    if (d < 0) d = 0;
                    spread += d;
                }
                spread = @sqrt(spread);
            }
            // neighbour difference — by the INSIDE color, with the left and upper cells
            const now = (j % 2) * NX * 3 + i * 3;
            const prev = ((j + 1) % 2) * NX * 3 + i * 3;
            const mine: [3]f64 = .{ cx0, cy0, cz0 };
            var diff: f64 = 0;
            if (i > 0 and rows[now - 3] > -1e8) {
                var d: f64 = 0;
                var c: usize = 0;
                while (c < 3) : (c += 1) {
                    const r = mine[c] - rows[now - 3 + c];
                    d += r * r;
                }
                diff = @sqrt(d);
            }
            if (j > 0 and rows[prev] > -1e8) {
                var d: f64 = 0;
                var c: usize = 0;
                while (c < 3) : (c += 1) {
                    const r = mine[c] - rows[prev + c];
                    d += r * r;
                }
                const t = @sqrt(d);
                if (t > diff) diff = t;
            }

            rows[now] = cx0;
            rows[now + 1] = cy0;
            rows[now + 2] = cz0;
            hist[binL(diff)][binB(spread)] += 1;
            // SLOPE and JITTER on joint cells: a plane v = a + b*dx + c*dy is
            // fitted to the cell's pixels per channel. The tilt is the slope
            // (blur), the remainder is the jitter (noise). Cells of fewer than
            // six pixels cannot hold a plane; they measure spread around their
            // mean instead, used only when the regular measure is empty.
            if (binL(diff) != 0 and kn >= 2 and kn < 6) {
                const nf = @as(f64, @floatFromInt(kn));
                var d2: f64 = 0;
                var c5: usize = 0;
                while (c5 < 3) : (c5 += 1) {
                    var sm: f64 = 0;
                    var kv: f64 = 0;
                    var q5: usize = 0;
                    while (q5 < kn) : (q5 += 1) {
                        const v = color[@as(usize, own[q5]) * 3 + c5];
                        sm += v;
                        kv += v * v;
                    }
                    d2 += @max(0, kv - sm * sm / nf) / (nf - 1);
                }
                var km = @as(usize, @intFromFloat(@sqrt(d2) / SCALE_G));
                if (km >= NG) km = NG - 1;
                hJitterSmall[km] += 1;
            }
            if (binL(diff) != 0 and kn >= 6) {
                var n0: f64 = 0;
                var psx: f64 = 0;
                var psy: f64 = 0;
                var psxx: f64 = 0;
                var psxy: f64 = 0;
                var psyy: f64 = 0;
                var q4: usize = 0;
                while (q4 < kn) : (q4 += 1) {
                    const pp = own[q4];
                    n0 += 1;
                    psx += offx[pp];
                    psy += offy[pp];
                    psxx += offx[pp] * offx[pp];
                    psxy += offx[pp] * offy[pp];
                    psyy += offy[pp] * offy[pp];
                }
                // centred: work with deviations from the mean offset
                const mx = psx / n0;
                const my = psy / n0;
                const cxx = psxx - n0 * mx * mx;
                const cxy = psxy - n0 * mx * my;
                const cyy = psyy - n0 * my * my;
                const det = cxx * cyy - cxy * cxy;
                if (@abs(det) > 1e-6) {
                    var slope2: f64 = 0;
                    var jitter2: f64 = 0;
                    var c4: usize = 0;
                    while (c4 < 3) : (c4 += 1) {
                        var psv: f64 = 0;
                        var psxv: f64 = 0;
                        var psyv: f64 = 0;
                        q4 = 0;
                        while (q4 < kn) : (q4 += 1) {
                            const pp = own[q4];
                            const v = color[pp * 3 + c4];
                            psv += v;
                            psxv += (offx[pp] - mx) * v;
                            psyv += (offy[pp] - my) * v;
                        }
                        const mv = psv / n0;
                        const b1 = (cyy * psxv - cxy * psyv) / det;
                        const b2 = (cxx * psyv - cxy * psxv) / det;
                        // how far the color creeps from one edge of the cell to the other
                        const rise = @abs(b1) * hx + @abs(b2) * hy;
                        slope2 += rise * rise;
                        // what is left after the plane
                        var rest: f64 = 0;
                        q4 = 0;
                        while (q4 < kn) : (q4 += 1) {
                            const pp = own[q4];
                            const pred = mv + b1 * (offx[pp] - mx) + b2 * (offy[pp] - my);
                            const r = color[pp * 3 + c4] - pred;
                            rest += r * r;
                        }
                        jitter2 += rest / n0;
                    }
                    const slope = @sqrt(slope2);
                    const jitter = @sqrt(jitter2);
                    var ks = @as(usize, @intFromFloat(slope / SCALE_G));
                    if (ks >= NG) ks = NG - 1;
                    var kd = @as(usize, @intFromFloat(jitter / SCALE_G));
                    if (kd >= NG) kd = NG - 1;
                    hSlope[ks] += 1;
                    hJitter[kd] += 1;
                }
            }
            // THE INSIDE AND THE EDGE, apart. A plane is fitted to the pixels
            // that touch no border of the cell; what is left after it is the
            // noise of the inside. How far the border pixels stand from that
            // same plane is the noise of the edge: ringing, and what bleeds in
            // from the neighbours. Measured on the same joint cells as the
            // jitter, and only measured: nothing is computed from it yet.
            if (binL(diff) != 0) {
                var ni: usize = 0;
                var ne: usize = 0;
                var q6: usize = 0;
                while (q6 < kn) : (q6 += 1) {
                    const pp = own[q6];
                    if (edge[pp]) {
                        edge_idx[ne] = pp;
                        ne += 1;
                    } else {
                        inner_idx[ni] = pp;
                        ni += 1;
                    }
                }
                var pl: Plane = .{};
                if (ne > 0 and fitPlane(inner_idx[0..ni], &pl)) {
                    hInner[binG(@sqrt(offPlane(inner_idx[0..ni], &pl)))] += 1;
                    hEdge[binG(@sqrt(offPlane(edge_idx[0..ne], &pl)))] += 1;
                }
            }
        }
        rowDone(@intCast(j));
    }
    P.next = last;
    return if (last >= NY) 3 else 1;
}

/// Ends a pass: the measurements of the picture. Returns 1.
export fn pass1End() u32 {
    const gx = P.gx;
    const gy = P.gy;
    const meas = P.meas;

    // Summary. "Flat" is a neighbour of the same paint (zero difference bin),
    // "joint" a neighbour of another paint (everything above). Splitting by
    // rank fails here: in pixel art over 80% of neighbours are the same paint.
    var cells: usize = 0;
    var kl2: usize = 0;
    while (kl2 < NL) : (kl2 += 1) {
        var kb: usize = 0;
        while (kb < NB) : (kb += 1) cells += hist[kl2][kb];
    }
    meas[0] = 0;
    meas[1] = 0;
    meas[2] = 0;
    meas[3] = (gx[1] - gx[0]) * (gy[1] - gy[0]);
    meas[4] = @floatFromInt(cells);
    meas[5] = 0;
    if (cells < 8) return 1;

    var flat: [NB]u32 = undefined;
    var joint: [NB]u32 = undefined;
    var kb2: usize = 0;
    while (kb2 < NB) : (kb2 += 1) {
        flat[kb2] = 0;
        joint[kb2] = 0;
    }
    var joints: usize = 0;
    var joint_sum: f64 = 0;
    kl2 = 0;
    while (kl2 < NL) : (kl2 += 1) {
        kb2 = 0;
        while (kb2 < NB) : (kb2 += 1) {
            const c = hist[kl2][kb2];
            if (c == 0) continue;
            if (kl2 == 0) flat[kb2] += c;
            if (kl2 >= 1) {
                joint[kb2] += c;
                joints += c;
                joint_sum += @as(f64, @floatFromInt(c)) *
                    (@as(f64, @floatFromInt(kl2)) + 0.5) * SCALE_L;
            }
        }
    }
    meas[0] = medianB(&flat);
    meas[1] = medianB(&joint);
    meas[7] = @as(f64, @floatFromInt(joints)) / @as(f64, @floatFromInt(cells));
    meas[2] = if (joints > 0) joint_sum / @as(f64, @floatFromInt(joints)) else 0;

    // medians of slope and jitter over the joint cells
    meas[8] = medianG(&hSlope);
    meas[9] = medianG(&hJitter);
    {
        var measured: u32 = 0;
        for (hJitter) |v| measured += v;
        if (measured == 0) meas[9] = medianG(&hJitterSmall);
    }
    // the inside and the edge of the joint cells, apart (0 — cells too small
    // to have an inside that holds a plane)
    meas[10] = medianG(&hInner);
    meas[11] = medianG(&hEdge);

    // CLOSEST PAINTS — how close two DIFFERENT colors of the work come. Only
    // pairs further apart than twice the joint noise count as different:
    // closer than that, paints cannot be told apart anyway.
    meas[6] = 0;
    if (meas[1] > 0) {
        const threshold = meas[1] * 2.0;
        var total_r: usize = 0;
        var kl3: usize = 1;
        while (kl3 < NL) : (kl3 += 1) {
            if ((@as(f64, @floatFromInt(kl3)) + 0.5) * SCALE_L <= threshold) continue;
            var kb3: usize = 0;
            while (kb3 < NB) : (kb3 += 1) total_r += hist[kl3][kb3];
        }
        if (total_r > 0) {
            var got: usize = 0;
            kl3 = 1;
            while (kl3 < NL) : (kl3 += 1) {
                const value = (@as(f64, @floatFromInt(kl3)) + 0.5) * SCALE_L;
                if (value <= threshold) continue;
                var v: usize = 0;
                var kb3: usize = 0;
                while (kb3 < NB) : (kb3 += 1) v += hist[kl3][kb3];
                got += v;
                if (got * 10 >= total_r) {
                    meas[6] = value;
                    break;
                }
            }
        }
    }
    return 1;
}

fn roundByte(v: f64) u8 {
    var r = @floor(v);
    const rest = v - r;
    if (rest > 0.5) {
        r += 1;
    } else if (rest == 0.5) {
        if (@mod(r, 2) != 0) r += 1; // .5 goes to even
    }
    if (r <= 0) return 0;
    if (r >= 255) return 255;
    return @intFromFloat(r);
}

// MEASUREMENTS AS A BY-PRODUCT, all kept in fixed-size histograms: however
// many cells there are, the memory is the same.
//   meas[0] — noise inside flat cells;
//   meas[1] — noise inside joint cells;
//   meas[2] — mean difference between different neighbouring paints;
//   meas[3] — pixels per cell;
//   meas[4] — cells measured;
//   meas[5] — unused, always 0;
//   meas[6] — how close different paints come (ceiling for the tolerance);
//   meas[7] — share of joint cells;
//   meas[8] — slope inside joint cells (blur);
//   meas[9] — jitter inside joint cells (noise);
//   meas[10] — noise of the INSIDE of joint cells: off the plane through the
//              pixels that touch no border;
//   meas[11] — noise of the EDGE of joint cells: how far the border pixels
//              stand from that plane.
// Spread inside a cell is JPEG noise, small and needed precisely: 0..64 in
// 128 bins. Neighbour difference goes up to 442 and needs no such precision.
const NB = 128; // spread bins
const NL = 128; // difference bins
const SCALE_B = 64.0 / @as(f64, NB);
const SCALE_L = 442.0 / @as(f64, NL);
var hist: [NL][NB]u32 = undefined;
const NG = 64;
const SCALE_G = 64.0 / @as(f64, NG);
var hSlope: [NG]u32 = undefined;
var hJitter: [NG]u32 = undefined;
var hJitterSmall: [NG]u32 = undefined; // jitter of small cells, the fallback
var hInner: [NG]u32 = undefined; // noise of the inside of joint cells
var hEdge: [NG]u32 = undefined; // noise of their edge, against the inside's plane

fn binB(v: f64) usize {
    const k = @as(usize, @intFromFloat(@max(0.0, v) / SCALE_B));
    return if (k >= NB) NB - 1 else k;
}
fn binL(v: f64) usize {
    const k = @as(usize, @intFromFloat(@max(0.0, v) / SCALE_L));
    return if (k >= NL) NL - 1 else k;
}
// median over bins: the value below which half of the entries lie
fn binG(v: f64) usize {
    const k = @as(usize, @intFromFloat(@max(0.0, v) / SCALE_G));
    return if (k >= NG) NG - 1 else k;
}
/// A PLANE through some of the cell's pixels, per channel:
/// v = mv + b1*(dx - mx) + b2*(dy - my). False when they do not hold one:
/// fewer than six pixels, or all on one line.
const Plane = struct {
    mx: f64 = 0,
    my: f64 = 0,
    mv: [3]f64 = .{ 0, 0, 0 },
    b1: [3]f64 = .{ 0, 0, 0 },
    b2: [3]f64 = .{ 0, 0, 0 },
};
fn fitPlane(pick: []const u32, pl: *Plane) bool {
    if (pick.len < 6) return false;
    const n0 = @as(f64, @floatFromInt(pick.len));
    var psx: f64 = 0;
    var psy: f64 = 0;
    var psxx: f64 = 0;
    var psxy: f64 = 0;
    var psyy: f64 = 0;
    for (pick) |pp| {
        psx += offx[pp];
        psy += offy[pp];
        psxx += offx[pp] * offx[pp];
        psxy += offx[pp] * offy[pp];
        psyy += offy[pp] * offy[pp];
    }
    const mx = psx / n0;
    const my = psy / n0;
    const cxx = psxx - n0 * mx * mx;
    const cxy = psxy - n0 * mx * my;
    const cyy = psyy - n0 * my * my;
    const det = cxx * cyy - cxy * cxy;
    if (@abs(det) <= 1e-6) return false;
    var c: usize = 0;
    while (c < 3) : (c += 1) {
        var psv: f64 = 0;
        var psxv: f64 = 0;
        var psyv: f64 = 0;
        for (pick) |pp| {
            const v = color[@as(usize, pp) * 3 + c];
            psv += v;
            psxv += (offx[pp] - mx) * v;
            psyv += (offy[pp] - my) * v;
        }
        pl.mv[c] = psv / n0;
        pl.b1[c] = (cyy * psxv - cxy * psyv) / det;
        pl.b2[c] = (cxx * psyv - cxy * psxv) / det;
    }
    pl.mx = mx;
    pl.my = my;
    return true;
}
/// The mean over the pixels of the squared distance from the plane, the three
/// channels together — its root is a noise in units of color.
fn offPlane(pick: []const u32, pl: *const Plane) f64 {
    var sum: f64 = 0;
    for (pick) |pp| {
        var c: usize = 0;
        while (c < 3) : (c += 1) {
            const pred = pl.mv[c] + pl.b1[c] * (offx[pp] - pl.mx) + pl.b2[c] * (offy[pp] - pl.my);
            const r = color[@as(usize, pp) * 3 + c] - pred;
            sum += r * r;
        }
    }
    return sum / @as(f64, @floatFromInt(pick.len));
}
fn medianG(h: *const [NG]u32) f64 {
    var total: usize = 0;
    var k: usize = 0;
    while (k < NG) : (k += 1) total += h[k];
    if (total == 0) return 0;
    var got: usize = 0;
    k = 0;
    while (k < NG) : (k += 1) {
        got += h[k];
        if (got * 2 >= total) return (@as(f64, @floatFromInt(k)) + 0.5) * SCALE_G;
    }
    return 64.0;
}

fn medianB(h: *const [NB]u32) f64 {
    var total: usize = 0;
    var k: usize = 0;
    while (k < NB) : (k += 1) total += h[k];
    if (total == 0) return 0;
    var got: usize = 0;
    k = 0;
    while (k < NB) : (k += 1) {
        got += h[k];
        if (got * 2 >= total) return (@as(f64, @floatFromInt(k)) + 0.5) * SCALE_B;
    }
    return 64.0;
}

/// AUTOMATIC SETTINGS from the measurements. The core measures; this derives.
/// out: [noise multiple, overlap, agreement, tolerance floor, tolerance ceiling].
///   FLOOR — from 8-bit color: rounding alone gives plus-minus one, a
///           tolerance under two tells nothing apart.
///   MULTIPLE — of our own noise; the only tuned number here: 2.
///   CEILING — from the work's palette: no wider than where two different
///             paints meet ("closest paints"), with a fifth to spare.
export fn autoParams(step: f64, meas: [*]const f64, out: [*]f64) void {
    const closest = meas[6];
    const measured = meas[4] > 0;

    const FLOOR: f64 = 2.0; // 8-bit color
    const MULTIPLE: f64 = 2.0; // our own noise, tuned by measurement

    out[0] = MULTIPLE;
    out[1] = 1.5; // overlap, as a share of the cell side
    // OVERLAP AGREEMENT is a function of the step, not a number: on a small
    // cell there are few own pixels and neighbours should be let in
    // generously; a large cell is its own master. Line through the measured
    // optima: 1.2 - 0.11 * step, clamped to [0.2, 1.0].
    {
        var agree = 1.2 - 0.11 * step;
        if (agree < 0.2) agree = 0.2;
        if (agree > 1.0) agree = 1.0;
        out[2] = agree;
    }
    out[3] = FLOOR;
    out[4] = 0; // no ceiling until there is something to take it from

    if (!measured) return;
    if (closest > 2 * FLOOR) out[4] = closest * 0.8;
}

/// How many cells a grid gives — the page counts by the same rule to set up
/// its buffers before computing.
export fn cellCount(W: u32, H: u32, step: f64, ox: f64, oy: f64, out: [*]u32) void {
    const Wf = @as(f64, @floatFromInt(W));
    const Hf = @as(f64, @floatFromInt(H));
    const k0x = @as(i64, @intFromFloat(@ceil(-ox / step)));
    const k1x = @as(i64, @intFromFloat(@floor((Wf - ox) / step))) - 1;
    const k0y = @as(i64, @intFromFloat(@ceil(-oy / step)));
    const k1y = @as(i64, @intFromFloat(@floor((Hf - oy) / step))) - 1;
    out[0] = if (k1x >= k0x) @intCast(k1x - k0x + 1) else 0;
    out[1] = if (k1y >= k0y) @intCast(k1y - k0y + 1) else 0;
}
