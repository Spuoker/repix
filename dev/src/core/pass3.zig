// SPDX-License-Identifier: GPL-3.0-or-later
// Pass 3: merging clusters into paints across the whole work.
//
// Pass 2 joins NEIGHBOURING cells into connected clusters. But one paint lies
// in many places: two highlights on glass, shadows left and right, a dozen bits
// of background between leaves. Each becomes its own cluster with a slightly
// different color, and instead of a palette of twenty paints there are a
// thousand near-copies.
//
// Here clusters merge into PAINTS across the whole work, regardless of
// adjacency. Order — from the largest cluster to the smallest: large ones set
// the palette, small ones join paints already there. Weight decides, not the
// order of a scan.
//
// The threshold comes from weight, as in pass 2 from group size:
//     threshold = (sqrt(min paint / weight) - 1) x median difference between
//                 cluster colors of this work, per axis
// Weight is counted over the WHOLE work: clusters of exactly the same color are
// summed first. A paint of five cells in the whole work is almost surely a
// leftover; a paint of five hundred is the author's, even if scattered.

const memory = @import("memory.zig");
const std = @import("std");

/// Splits a color difference into lightness (along the grey axis) and tone
/// (across it).
fn split(ar: f64, ag: f64, ab: f64, br: f64, bg: f64, bb: f64, dS: *f64, dT: *f64) void {
    const dr = ar - br;
    const dg = ag - bg;
    const db = ab - bb;
    const along = (dr + dg + db) / 1.7320508075688772;
    var across = dr * dr + dg * dg + db * db - along * along;
    if (across < 0) across = 0;
    dS.* = if (along < 0) -along else along;
    dT.* = @sqrt(across);
}

fn roundByte(v: f64) u8 {
    if (v <= 0) return 0;
    if (v >= 255) return 255;
    return @intFromFloat(v + 0.5);
}

/// NEIGHBOURS ARE JUDGED STRICTER. Two paints whose areas touch are a border
/// the author drew: different paints on purpose. Two look-alike paints from
/// distant parts of the work are usually one paint split apart. So the
/// threshold between neighbours is multiplied by this: 1 — like any pair,
/// 0.5 — twice as strict, 0 — neighbours never merge.
var NEIGHBOUR_STRICTNESS: f64 = 0.5;
export fn setNeighbourStrictness(v: f64) void {
    NEIGHBOUR_STRICTNESS = if (v >= 0) v else 0;
}

/// DRIFT FROM SOURCE — a ceiling on the threshold in color units. A light
/// cluster gets a huge weight-based threshold and may drift far to a foreign
/// paint; this caps it whatever inflated it. 0 — no cap.
var MAX_DRIFT: f64 = 0;
export fn setMaxDrift(v: f64) void {
    MAX_DRIFT = if (v > 0) v else 0;
}

var PAINTS: u32 = 0; // how many paints came out
// Paint numbers in use, the absorbed ones included: when paints merge (max
// paints), the living ones keep their numbers, with gaps below them.
var SLOTS: u32 = 0;

/// Merging clusters into paints.
///   label    — cluster of each cell (pass 2 output), `total` long;
///   clusters — how many clusters there are;
///   color    — color of each cluster, three bytes;
///   mS, mT   — median difference between cluster colors: the unit;
///   min_paint — weight from which a paint stands on its own;
///   max_paints — how many paints to keep at most; 0 — no limit;
///   out      — color of each CELL after merging (three bytes);
///   target   — paint number of each cluster (u32).
/// Returns the number of paints, in one call.
export fn pass3(
    label: [*]const i32,
    total: usize,
    NX_3: usize,
    NY_3: usize,
    clusters: u32,
    color: [*]const u8,
    mS: f64,
    mT: f64,
    min_paint: u32,
    max_paints: u32,
    out: [*]u8,
    target: [*]u32,
) u32 {
    if (pass3Begin(label, total, NX_3, NY_3, clusters, color, mS, mT, min_paint, max_paints, out, target) != 1) return 0;
    _ = pass3Clusters(clusters);
    return pass3End();
}

/// THE PASS IN PARTS, like passes 1 and 2: begun (weights, order, neighbours),
/// its clusters laid into paints a number at a time — from the largest to the
/// smallest — and ended (the cells painted). Between the parts the page may
/// show the paints as they stand (pass3Preview). The result is that of one
/// whole call.
const NB = 8; // neighbours kept for each cluster
const Pass = struct {
    label: [*]const i32 = undefined,
    total: usize = 0,
    gg: usize = 0,
    color: [*]const u8 = undefined,
    mS: f64 = 0,
    mT: f64 = 0,
    min_paint: u32 = 0,
    max_paints: u32 = 0,
    out: [*]u8 = undefined,
    target: [*]u32 = undefined,
    size: [*]u32 = undefined,
    order: [*]u32 = undefined,
    psum: [*]f64 = undefined,
    pweight: [*]f64 = undefined,
    paint_weight: [*]u32 = undefined,
    nbr: [*]u32 = undefined,
    nnb: [*]u32 = undefined,
    moved: [*]u32 = undefined,
    assigned: [*]u8 = undefined,
    n_paints: usize = 0,
    alive: usize = 0,
    q: usize = 0,
};
var T: Pass = .{};

/// Begins pass 3: the same arguments as pass3. Returns 1, or 0 — nothing to do.
export fn pass3Begin(
    label: [*]const i32,
    total: usize,
    NX_3: usize,
    NY_3: usize,
    clusters: u32,
    color: [*]const u8,
    mS: f64,
    mT: f64,
    min_paint: u32,
    max_paints: u32,
    out: [*]u8,
    target: [*]u32,
) u32 {
    const gg = @as(usize, clusters);
    T.gg = 0;
    // A pass that fails to begin leaves no paints of the one before.
    PAINTS = 0;
    SLOTS = 0;
    if (gg == 0 or total == 0) {
        PAINTS = 0;
        return 0;
    }

    // CLUSTER WEIGHT — how many cells it holds. It sets the order.
    const size_a = memory.alloc(gg * 4);
    const order_a = memory.alloc(gg * 4);
    // palette: color sum and weight of each paint (the mean is kept on the fly)
    const psum_a = memory.alloc(gg * 3 * 8);
    const pweight_a = memory.alloc(gg * 8);
    if (size_a == 0 or order_a == 0 or psum_a == 0 or pweight_a == 0) return 0;
    const size = @as([*]u32, @ptrFromInt(size_a));
    const order = @as([*]u32, @ptrFromInt(order_a));
    const psum = @as([*]f64, @ptrFromInt(psum_a));
    const pweight = @as([*]f64, @ptrFromInt(pweight_a));

    var i: usize = 0;
    while (i < gg) : (i += 1) size[i] = 0;
    var c: usize = 0;
    while (c < total) : (c += 1) {
        const g = label[c];
        if (g < 0) continue;
        const gu = @as(usize, @intCast(g));
        if (gu < gg) size[gu] += 1;
    }

    i = 0;
    while (i < gg) : (i += 1) order[i] = @intCast(i);
    const By = struct {
        fn larger(r: [*]u32, a: u32, b: u32) bool {
            return r[@as(usize, a)] > r[@as(usize, b)];
        }
        fn byColor(k: [*]u32, a: u32, b: u32) bool {
            return k[@as(usize, a)] < k[@as(usize, b)];
        }
    };
    std.mem.sort(u32, order[0..gg], size, By.larger);

    // WEIGHT OF THE PAINT, NOT OF THE CLUSTER: clusters of exactly the same
    // color are one paint, and their weights are summed.
    const key_a = memory.alloc(gg * 4);
    const bycolor_a = memory.alloc(gg * 4);
    const pw_a = memory.alloc(gg * 4);
    if (key_a == 0 or bycolor_a == 0 or pw_a == 0) return 0;
    const key = @as([*]u32, @ptrFromInt(key_a));
    const bycolor = @as([*]u32, @ptrFromInt(bycolor_a));
    const paint_weight = @as([*]u32, @ptrFromInt(pw_a));
    i = 0;
    while (i < gg) : (i += 1) {
        key[i] = (@as(u32, color[i * 3]) << 16) | (@as(u32, color[i * 3 + 1]) << 8) | @as(u32, color[i * 3 + 2]);
        bycolor[i] = @intCast(i);
        paint_weight[i] = size[i];
    }
    std.mem.sort(u32, bycolor[0..gg], key, By.byColor);
    {
        var a2: usize = 0;
        while (a2 < gg) {
            var b2 = a2 + 1;
            var sum: u32 = size[@as(usize, bycolor[a2])];
            while (b2 < gg and key[@as(usize, bycolor[b2])] == key[@as(usize, bycolor[a2])]) : (b2 += 1) {
                sum += size[@as(usize, bycolor[b2])];
            }
            var c2 = a2;
            while (c2 < b2) : (c2 += 1) paint_weight[@as(usize, bycolor[c2])] = sum;
            a2 = b2;
        }
    }

    // NEIGHBOURS OF EACH CLUSTER — up to eight, sharing a side.
    const nb_a = memory.alloc(gg * NB * 4);
    const nnb_a = memory.alloc(gg * 4);
    if (nb_a == 0 or nnb_a == 0) return 0;
    const nbr = @as([*]u32, @ptrFromInt(nb_a));
    const nnb = @as([*]u32, @ptrFromInt(nnb_a));
    i = 0;
    while (i < gg) : (i += 1) nnb[i] = 0;
    {
        var y: usize = 0;
        while (y < NY_3) : (y += 1) {
            var x: usize = 0;
            while (x < NX_3) : (x += 1) {
                const c2 = y * NX_3 + x;
                const g1 = label[c2];
                if (g1 < 0 or @as(usize, @intCast(g1)) >= gg) continue;
                const gu1 = @as(usize, @intCast(g1));
                var d: usize = 0;
                while (d < 2) : (d += 1) {
                    const t = if (d == 0) (if (x + 1 < NX_3) c2 + 1 else continue) else (if (y + 1 < NY_3) c2 + NX_3 else continue);
                    const g2 = label[t];
                    if (g2 < 0 or g2 == g1 or @as(usize, @intCast(g2)) >= gg) continue;
                    const gu2 = @as(usize, @intCast(g2));
                    // both ways, once each
                    for ([_][2]usize{ .{ gu1, gu2 }, .{ gu2, gu1 } }) |pair| {
                        const a3 = pair[0];
                        const b3 = pair[1];
                        if (nnb[a3] >= NB) continue;
                        var known = false;
                        var q3: usize = 0;
                        while (q3 < nnb[a3]) : (q3 += 1) {
                            if (nbr[a3 * NB + q3] == @as(u32, @intCast(b3))) {
                                known = true;
                                break;
                            }
                        }
                        if (!known) {
                            nbr[a3 * NB + nnb[a3]] = @intCast(b3);
                            nnb[a3] += 1;
                        }
                    }
                }
            }
        }
    }

    // FROM LARGE TO SMALL. A cluster joins the closest paint that fits both
    // thresholds, otherwise it starts its own. `moved` records where a paint
    // went when it was merged into another to make room.
    const mv_a = memory.alloc(gg * 4);
    if (mv_a == 0) return 0;
    const moved = @as([*]u32, @ptrFromInt(mv_a));
    i = 0;
    while (i < gg) : (i += 1) moved[i] = @intCast(i);

    const done_a = memory.alloc(gg);
    if (done_a == 0) return 0;
    const assigned = @as([*]u8, @ptrFromInt(done_a));
    i = 0;
    while (i < gg) : (i += 1) assigned[i] = 0;
    T = .{ .label = label, .total = total, .gg = gg, .color = color, .mS = mS, .mT = mT,
        .min_paint = min_paint, .max_paints = max_paints, .out = out, .target = target,
        .size = size, .order = order, .psum = psum, .pweight = pweight,
        .paint_weight = paint_weight, .nbr = nbr, .nnb = nnb, .moved = moved,
        .assigned = assigned, .n_paints = 0, .alive = 0, .q = 0 };
    return 1;
}

/// Lays the next `count` clusters into paints. Returns 1 — clusters are left;
/// 3 — all laid (call pass3End).
export fn pass3Clusters(count: u32) u32 {
    const gg = T.gg;
    const color = T.color;
    const mS = T.mS;
    const mT = T.mT;
    const min_paint = T.min_paint;
    const max_paints = T.max_paints;
    const target = T.target;
    const size = T.size;
    const order = T.order;
    const psum = T.psum;
    const pweight = T.pweight;
    const paint_weight = T.paint_weight;
    const nbr = T.nbr;
    const nnb = T.nnb;
    const moved = T.moved;
    const assigned = T.assigned;
    var n_paints = T.n_paints;
    var alive = T.alive;
    var q = T.q;
    const last = @min(gg, q + @as(usize, count));
    while (q < last) : (q += 1) {
        const g = @as(usize, order[q]);
        if (size[g] == 0) {
            target[g] = 0;
            continue;
        }
        const r = @as(f64, @floatFromInt(color[g * 3]));
        const gc = @as(f64, @floatFromInt(color[g * 3 + 1]));
        const b = @as(f64, @floatFromInt(color[g * 3 + 2]));
        // MARGIN BY WEIGHT, as in pass 2, but never below one unit: even the
        // largest paint forgives its neighbour one median difference.
        var margin: f64 = 1;
        if (min_paint > 1) {
            const N = @as(f64, @floatFromInt(min_paint));
            const m = @as(f64, @floatFromInt(@max(1, paint_weight[g])));
            if (m < N) {
                const z = @sqrt(N / m) - 1;
                if (z > 1) margin = z;
            }
        }
        var pY = margin * mS;
        var pT = margin * mT;
        if (MAX_DRIFT > 0) {
            if (pY > MAX_DRIFT) pY = MAX_DRIFT;
            if (pT > MAX_DRIFT) pT = MAX_DRIFT;
        }
        var best: usize = n_paints;
        var best_d: f64 = 1e30;
        var k: usize = 0;
        while (k < n_paints) : (k += 1) {
            const w = pweight[k];
            var dS: f64 = 0;
            var dT: f64 = 0;
            split(r, gc, b, psum[k * 3] / w, psum[k * 3 + 1] / w, psum[k * 3 + 2] / w, &dS, &dT);
            // a neighbouring paint is judged stricter: it is a border, not a copy
            var kf: f64 = 1;
            {
                var q3: usize = 0;
                while (q3 < nnb[g]) : (q3 += 1) {
                    const sg = @as(usize, nbr[g * NB + q3]);
                    if (assigned[sg] == 1 and target[sg] == @as(u32, @intCast(k))) {
                        kf = NEIGHBOUR_STRICTNESS;
                        break;
                    }
                }
            }
            // "not more than", not "less than": two identical colors differ by
            // zero, and zero fits any threshold.
            const fits = dS <= pY * kf and dT <= pT * kf;
            const d = dS * dS + dT * dT;
            if (fits and d < best_d) {
                best_d = d;
                best = k;
            }
        }
        // A PALETTE LIMIT THAT THINKS. When the palette is full, two costs are
        // compared — "weight x difference", how many cells change and by how
        // much: pour the newcomer into its closest paint, or merge the two most
        // alike paints already there and give the place to the newcomer.
        if (best == n_paints and max_paints > 0 and alive >= @as(usize, max_paints)) {
            // cost of pouring in: the closest paint and the distance to it
            var cost_pour: f64 = 1e30;
            k = 0;
            while (k < n_paints) : (k += 1) {
                if (pweight[k] <= 0) continue;
                const w = pweight[k];
                var dS: f64 = 0;
                var dT: f64 = 0;
                split(r, gc, b, psum[k * 3] / w, psum[k * 3 + 1] / w, psum[k * 3 + 2] / w, &dS, &dT);
                const d = @sqrt(dS * dS + dT * dT);
                if (d < best_d) {
                    best_d = d;
                    best = k;
                    cost_pour = @as(f64, @floatFromInt(size[g])) * d;
                }
            }
            // cost of merging the most alike pair
            var pa_k: usize = n_paints;
            var pb_k: usize = n_paints;
            var cost_pair: f64 = 1e30;
            var k1: usize = 0;
            while (k1 < n_paints) : (k1 += 1) {
                if (pweight[k1] <= 0) continue;
                var k2: usize = k1 + 1;
                while (k2 < n_paints) : (k2 += 1) {
                    if (pweight[k2] <= 0) continue;
                    var dS: f64 = 0;
                    var dT: f64 = 0;
                    split(psum[k1 * 3] / pweight[k1], psum[k1 * 3 + 1] / pweight[k1], psum[k1 * 3 + 2] / pweight[k1],
                        psum[k2 * 3] / pweight[k2], psum[k2 * 3 + 1] / pweight[k2], psum[k2 * 3 + 2] / pweight[k2], &dS, &dT);
                    const d = @sqrt(dS * dS + dT * dT);
                    const cost = @min(pweight[k1], pweight[k2]) * d;
                    if (cost < cost_pair) {
                        cost_pair = cost;
                        pa_k = k1;
                        pb_k = k2;
                    }
                }
            }
            if (cost_pair < cost_pour and pa_k < n_paints and pb_k < n_paints) {
                // merge the pair: the lighter goes into the heavier, a place frees up
                const heavy = if (pweight[pa_k] >= pweight[pb_k]) pa_k else pb_k;
                const light = if (heavy == pa_k) pb_k else pa_k;
                psum[heavy * 3] += psum[light * 3];
                psum[heavy * 3 + 1] += psum[light * 3 + 1];
                psum[heavy * 3 + 2] += psum[light * 3 + 2];
                pweight[heavy] += pweight[light];
                pweight[light] = 0;
                moved[light] = @intCast(heavy);
                alive -= 1;
                best = n_paints; // the newcomer starts its own paint
            }
        }
        const w_g = @as(f64, @floatFromInt(size[g]));
        if (best == n_paints) {
            psum[n_paints * 3] = r * w_g;
            psum[n_paints * 3 + 1] = gc * w_g;
            psum[n_paints * 3 + 2] = b * w_g;
            pweight[n_paints] = w_g;
            target[g] = @intCast(n_paints);
            assigned[g] = 1;
            n_paints += 1;
            alive += 1;
        } else {
            psum[best * 3] += r * w_g;
            psum[best * 3 + 1] += gc * w_g;
            psum[best * 3 + 2] += b * w_g;
            pweight[best] += w_g;
            target[g] = @intCast(best);
            assigned[g] = 1;
        }
    }
    T.n_paints = n_paints;
    T.alive = alive;
    T.q = last;
    return if (last >= gg) 3 else 1;
}

/// THE PAINTS AS THEY STAND, for the eye only, drawn OVER a picture (RGBA,
/// four bytes a cell): a cell whose cluster is already laid into a paint gets
/// that paint's color so far; the rest is left as it was.
export fn pass3Preview(rgba: [*]u8) void {
    var c: usize = 0;
    while (c < T.total) : (c += 1) {
        const g = T.label[c];
        if (g < 0 or @as(usize, @intCast(g)) >= T.gg) continue;
        const gu = @as(usize, @intCast(g));
        if (T.assigned[gu] == 0) continue;
        var k = @as(usize, T.target[gu]);
        while (T.moved[k] != @as(u32, @intCast(k))) k = @as(usize, T.moved[k]);
        const w = T.pweight[k];
        if (w <= 0) continue;
        rgba[c * 4] = roundByte(T.psum[k * 3] / w);
        rgba[c * 4 + 1] = roundByte(T.psum[k * 3 + 1] / w);
        rgba[c * 4 + 2] = roundByte(T.psum[k * 3 + 2] / w);
        rgba[c * 4 + 3] = 255;
    }
}

/// Ends pass 3: every cell painted with its paint. Returns the number of paints.
export fn pass3End() u32 {
    if (T.gg == 0) return 0;
    const label = T.label;
    const total = T.total;
    const gg = T.gg;
    const out = T.out;
    const target = T.target;
    const moved = T.moved;
    const pweight = T.pweight;
    const psum = T.psum;
    const alive = T.alive;
    var c: usize = 0;

    // PAINT THE CELLS.
    while (c < total) : (c += 1) {
        const g = label[c];
        if (g < 0 or @as(usize, @intCast(g)) >= gg) {
            out[c * 3] = 0;
            out[c * 3 + 1] = 0;
            out[c * 3 + 2] = 0;
            continue;
        }
        var k = @as(usize, target[@as(usize, @intCast(g))]);
        while (moved[k] != @as(u32, @intCast(k))) k = @as(usize, moved[k]);
        target[@as(usize, @intCast(g))] = @intCast(k);
        const w = pweight[k];
        out[c * 3] = roundByte(psum[k * 3] / w);
        out[c * 3 + 1] = roundByte(psum[k * 3 + 1] / w);
        out[c * 3 + 2] = roundByte(psum[k * 3 + 2] / w);
    }

    PAINTS = @intCast(alive);
    SLOTS = @intCast(T.n_paints);
    return @intCast(alive);
}

/// The palette for the page: color and weight of each paint in a row —
/// r, g, b, cells.
var PALETTE: [4096 * 4]f64 = undefined;
export fn paletteAddress() usize {
    return @intFromPtr(&PALETTE);
}

/// Fills PALETTE from the result of the last merge.
export fn gatherPalette(label: [*]const i32, total: usize, target: [*]const u32, clusters: u32, color: [*]const u8) u32 {
    const gg = @as(usize, clusters);
    // every number in use: a paint may live above an absorbed one
    const n = @min(@as(usize, SLOTS), 4096);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        PALETTE[i * 4] = 0;
        PALETTE[i * 4 + 1] = 0;
        PALETTE[i * 4 + 2] = 0;
        PALETTE[i * 4 + 3] = 0;
    }
    var c: usize = 0;
    while (c < total) : (c += 1) {
        const g = label[c];
        if (g < 0 or @as(usize, @intCast(g)) >= gg) continue;
        const k = @as(usize, target[@as(usize, @intCast(g))]);
        if (k >= n) continue;
        const gu = @as(usize, @intCast(g));
        PALETTE[k * 4] += @floatFromInt(color[gu * 3]);
        PALETTE[k * 4 + 1] += @floatFromInt(color[gu * 3 + 1]);
        PALETTE[k * 4 + 2] += @floatFromInt(color[gu * 3 + 2]);
        PALETTE[k * 4 + 3] += 1;
    }
    i = 0;
    while (i < n) : (i += 1) {
        const w = PALETTE[i * 4 + 3];
        if (w > 0) {
            PALETTE[i * 4] /= w;
            PALETTE[i * 4 + 1] /= w;
            PALETTE[i * 4 + 2] /= w;
        }
    }
    return @intCast(n);
}
