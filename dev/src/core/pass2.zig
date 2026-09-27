// SPDX-License-Identifier: GPL-3.0-or-later
// Pass 2: cells into clusters, one color per cluster.
//
// All links between neighbouring cells (eight neighbours) are measured first,
// then resolved from the strongest to the weakest. Weak borders are reached
// last, when groups have already formed.
//
// A cell is compared with the GROUP, with its mean color, not with its
// neighbour: linking neighbour to neighbour lets paints leak through a bridge
// and the whole work runs into one patch.
//
// There is no global merging threshold. It comes from the size of the smaller
// group: a single cell gets a generous margin, a group as large as the
// "min paint" knob gets one unit. The unit is the median difference between
// neighbouring cells of this very picture ("gauge"), set by the page.

const memory = @import("memory.zig");
const std = @import("std");

// ───────────────────────── color measure ─────────────────────────

// A COLOR DIFFERENCE IS SPLIT IN TWO. One RGB number cannot tell a change in
// lightness from a change in tone, and in pixel art these are different events:
//   lightness — the same paint darker or lighter (a ramp the author drew);
//   tone      — another paint.
// dS — along the grey axis (equal change in all three channels), dT — what is
// left across it.
fn split(ar: f64, ag: f64, ab: f64, br: f64, bg: f64, bb: f64, dS: *f64, dT: *f64) void {
    const dr = ar - br;
    const dg = ag - bg;
    const db = ab - bb;
    const along = (dr + dg + db) / 1.7320508075688772; // projection on the grey axis
    var across = dr * dr + dg * dg + db * db - along * along;
    if (across < 0) across = 0;
    dS.* = if (along < 0) -along else along;
    dT.* = @sqrt(across);
}

/// Does a color belong with a group: within the lightness threshold AND the
/// tone threshold. Two separate gates, so the thresholds do not pull at each other.
fn same(ar: f64, ag: f64, ab: f64, br: f64, bg: f64, bb: f64, pY: f64, pT: f64) bool {
    var dS: f64 = 0;
    var dT: f64 = 0;
    split(ar, ag, ab, br, bg, bb, &dS, &dT);
    return dS < pY and dT < pT;
}

/// Round color distance between two cells.
fn dist(art: [*]const u8, a: usize, b: usize) f64 {
    var dS: f64 = 0;
    var dT: f64 = 0;
    split(@floatFromInt(art[a * 3]), @floatFromInt(art[a * 3 + 1]), @floatFromInt(art[a * 3 + 2]),
        @floatFromInt(art[b * 3]), @floatFromInt(art[b * 3 + 1]), @floatFromInt(art[b * 3 + 2]), &dS, &dT);
    return @sqrt(dS * dS + dT * dT);
}

fn roundByte(v: f64) u8 {
    var r = @floor(v);
    const rest = v - r;
    if (rest > 0.5) {
        r += 1;
    } else if (rest == 0.5) {
        if (@mod(r, 2) != 0) r += 1;
    }
    if (r <= 0) return 0;
    if (r >= 255) return 255;
    return @intFromFloat(r);
}

// ───────────────────────── neighbourhood ─────────────────────────

const DIRECTIONS = 4; // links: right, down, down-right, down-left

/// A cell's neighbour in one of the four link directions. Four cover all eight
/// neighbours: the opposite ones come from the same link seen from the other end.
fn neighbour(NX: usize, NY: usize, x: usize, y: usize, d: usize, out: *usize) bool {
    var nx2: i64 = @intCast(x);
    var ny2: i64 = @intCast(y);
    if (d >= 4) return false;
    switch (d) {
        0 => nx2 += 1,
        1 => ny2 += 1,
        2 => {
            nx2 += 1;
            ny2 += 1;
        },
        else => {
            nx2 -= 1;
            ny2 += 1;
        },
    }
    if (nx2 < 0 or ny2 < 0 or nx2 >= @as(i64, @intCast(NX)) or ny2 >= @as(i64, @intCast(NY))) return false;
    out.* = @as(usize, @intCast(ny2)) * NX + @as(usize, @intCast(nx2));
    return true;
}

fn cellAt(NX: usize, NY: usize, x: i64, y: i64) ?usize {
    if (x < 0 or y < 0 or x >= @as(i64, @intCast(NX)) or y >= @as(i64, @intCast(NY))) return null;
    return @as(usize, @intCast(y)) * NX + @as(usize, @intCast(x));
}

/// Root in the union-find, with path compression.
fn root(parent: [*]u32, a: usize) usize {
    var x = a;
    while (@as(usize, parent[x]) != x) {
        parent[x] = parent[@as(usize, parent[x])];
        x = @as(usize, parent[x]);
    }
    return x;
}

// ───────────────────────── settings from the page ─────────────────────────

// CELL NOISE, measured by pass 1: jitter divided by the square root of the
// pixels in a cell. Thresholds never go below it — a cell shakes that much by
// itself. This is a measurement of the work, not a knob.
var CELL_NOISE: f64 = 0;
export fn setCellNoise(v: f64) void {
    CELL_NOISE = if (v > 0) v else 0;
}

var LINK_UNIT: f64 = 0; // median non-zero neighbour difference of the picture
var MIN_GROUP: u32 = 0; // up to how many cells a group counts as small
var UNIT_Y: f64 = 0; // margin unit in color: lightness
var UNIT_T: f64 = 0; // and tone
/// The margin unit in color — the median joint difference of the picture,
/// from the page.
export fn setGauge(by: f64, bt: f64) void {
    UNIT_Y = by;
    UNIT_T = bt;
}
/// Min paint: 0 and 1 — size is not considered.
export fn setMinGroup(n: u32) void {
    MIN_GROUP = n;
}

/// MARGIN FOR SMALL GROUPS. The smaller of the two groups, the larger the
/// margin added to the pair threshold: full for a single cell, one unit for a
/// group of "min paint" size and larger. Never below one: otherwise two pieces
/// of one gradient background could only merge at exactly equal color and
/// long straight seams remained. Square root: gentle at the start, still
/// growing at large values.
inline fn margin(na: f64, nb: f64) f64 {
    if (MIN_GROUP <= 1) return 0;
    const m = @min(na, nb);
    const N = @as(f64, @floatFromInt(MIN_GROUP));
    if (m >= N) return 1;
    const z = @sqrt(N / m) - 1;
    return if (z > 1) z else 1;
}

// ───────────────────────── resolving links ─────────────────────────

const Groups = struct {
    NX: usize,
    NY: usize,
    parent: [*]u32,
    sum: [*]f64,
    count: [*]f64,
    ymin: [*]f64, // darkest and lightest cell of the group: its range
    ymax: [*]f64,
};

/// Merge two groups: the smaller hangs on the larger.
fn merge(P: *const Groups, ra: usize, rb: usize) void {
    const big = if (P.count[ra] >= P.count[rb]) ra else rb;
    const small = if (big == ra) rb else ra;
    P.parent[small] = @intCast(big);
    P.sum[big * 3] += P.sum[small * 3];
    P.sum[big * 3 + 1] += P.sum[small * 3 + 1];
    P.sum[big * 3 + 2] += P.sum[small * 3 + 2];
    P.count[big] += P.count[small];
    P.ymin[big] = @min(P.ymin[big], P.ymin[small]);
    P.ymax[big] = @max(P.ymax[big], P.ymax[small]);
}

/// Lightness of a color — its projection on the grey axis.
inline fn lightness(r: f64, g: f64, b: f64) f64 {
    return (r + g + b) / 1.7320508075688772;
}

/// How many median joints a group's range may stretch to, however strict the
/// pair threshold is.
const RANGE_LIMIT: f64 = 6;

/// GROUP RANGE. The pair threshold looks at two means, and a ramp can slide
/// through it step by step. So the future group's range, darkest to lightest,
/// is kept in check too — with its own, wider limit: a smooth gradient
/// background spans tens of units by itself.
inline fn rangeOk(P: *const Groups, ra: usize, rb: usize, thr: f64) bool {
    const low = @min(P.ymin[ra], P.ymin[rb]);
    const high = @max(P.ymax[ra], P.ymax[rb]);
    return high - low <= @max(thr, RANGE_LIMIT * UNIT_Y);
}

/// Decides one link: merge the two groups or not.
fn decide(P: *const Groups, a0: usize, b0: usize) void {
    const ra = root(P.parent, a0);
    const rb = root(P.parent, b0);
    if (ra == rb) return;
    const na = P.count[ra];
    const nb = P.count[rb];
    const pb = margin(na, nb);
    // Never finer than the cell's own noise, on either axis.
    const thr_y = @max(UNIT_Y * pb, CELL_NOISE);
    const thr_t = @max(UNIT_T * pb, CELL_NOISE);
    if (rangeOk(P, ra, rb, thr_y) and
        same(P.sum[ra * 3] / na, P.sum[ra * 3 + 1] / na, P.sum[ra * 3 + 2] / na,
            P.sum[rb * 3] / nb, P.sum[rb * 3 + 1] / nb, P.sum[rb * 3 + 2] / nb, thr_y, thr_t)) merge(P, ra, rb);
}

// ───────────────────────── pass 2 ─────────────────────────

/// THE PASS IN PARTS, like pass 1: begun (links measured and sorted), its
/// links resolved a number at a time, and ended (clusters numbered and
/// colored). Between the parts the page may show the groups as they stand
/// (pass2Preview). The work and the result are those of one whole call.
const Pass = struct {
    art: [*]const u8 = undefined,
    NX: usize = 0,
    NY: usize = 0,
    total: usize = 0,
    out: [*]u8 = undefined,
    label: [*]u32 = undefined,
    G: Groups = undefined,
    sorted: [*]u32 = undefined,
    n_links: usize = 0,
    next: usize = 0,
    bucket: [*]u32 = undefined,
    phase: u8 = 0, // 0 — counting links into buckets, 1 — laying them out, 2 — ready
    cell: usize = 0, // the next cell of the phase
};
const BUCKETS = 2048;
const BUCKET_STEP = 4.0 / @as(f64, BUCKETS);
var S: Pass = .{};

/// art — pass 1 output, nx by ny cells, three bytes each.
/// out — color of each cell after merging; label — cluster of each cell.
/// Returns the number of clusters, in one call.
export fn pass2(
    art: [*]const u8,
    nx: u32,
    ny: u32,
    out: [*]u8,
    label: [*]u32,
) u32 {
    if (pass2Begin(art, nx, ny, out, label) != 1) return 0;
    while (pass2Links(0xFFFFFFFF) == 1) {}
    return pass2End();
}

/// Begins pass 2: the same arguments as pass2. Returns 1, or 0 — nothing to do.
export fn pass2Begin(
    art: [*]const u8,
    nx: u32,
    ny: u32,
    out: [*]u8,
    label: [*]u32,
) u32 {
    const NX = @as(usize, @intCast(nx));
    const NY = @as(usize, @intCast(ny));
    const total = NX * NY;
    if (total == 0) return 0;
    S.total = 0;

    const parent_addr = memory.alloc(total * 4);
    const sum_addr = memory.alloc(total * 3 * 8);
    const count_addr = memory.alloc(total * 8);
    const ymin_addr = memory.alloc(total * 8);
    const ymax_addr = memory.alloc(total * 8);
    if (parent_addr == 0 or sum_addr == 0 or count_addr == 0 or
        ymin_addr == 0 or ymax_addr == 0) return 0;
    const parent = @as([*]u32, @ptrFromInt(parent_addr));
    const sum = @as([*]f64, @ptrFromInt(sum_addr));
    const count = @as([*]f64, @ptrFromInt(count_addr));
    const ymin = @as([*]f64, @ptrFromInt(ymin_addr));
    const ymax = @as([*]f64, @ptrFromInt(ymax_addr));

    var c: usize = 0;
    while (c < total) : (c += 1) {
        parent[c] = @intCast(c);
        sum[c * 3] = @floatFromInt(art[c * 3]);
        sum[c * 3 + 1] = @floatFromInt(art[c * 3 + 1]);
        sum[c * 3 + 2] = @floatFromInt(art[c * 3 + 2]);
        count[c] = 1;
        ymin[c] = lightness(@floatFromInt(art[c * 3]), @floatFromInt(art[c * 3 + 1]), @floatFromInt(art[c * 3 + 2]));
        ymax[c] = ymin[c];
    }

    // LINKS, sorted by strength into buckets. Eight neighbours, not four: in a
    // checkerboard, cells of one shade touch only at corners.
    // The sorted links: room for all of them, however many there turn out to be.
    const sorted_addr = memory.alloc(total * DIRECTIONS * 4);
    const bucket_addr = memory.alloc((BUCKETS + 1) * 4);
    if (sorted_addr == 0 or bucket_addr == 0) return 0;
    const sorted = @as([*]u32, @ptrFromInt(sorted_addr));
    const bucket = @as([*]u32, @ptrFromInt(bucket_addr));
    var k0: usize = 0;
    while (k0 <= BUCKETS) : (k0 += 1) bucket[k0] = 0;
    // THE LINK UNIT: median of the non-zero neighbour differences of this
    // picture. It sets the order of resolution and does not depend on knobs.
    {
        const N_SAMPLES = 4096;
        var samples: [N_SAMPLES]f64 = undefined;
        var n_s: usize = 0;
        const stride: usize = @max(1, total / N_SAMPLES);
        var c2: usize = 0;
        while (c2 < total and n_s < N_SAMPLES) : (c2 += stride) {
            const x2 = c2 % NX;
            const y2 = c2 / NX;
            if (x2 + 1 < NX) {
                const d = dist(art, c2, c2 + 1);
                if (d > 0) {
                    samples[n_s] = d;
                    n_s += 1;
                }
            }
            if (y2 + 1 < NY and n_s < N_SAMPLES) {
                const d = dist(art, c2, c2 + NX);
                if (d > 0) {
                    samples[n_s] = d;
                    n_s += 1;
                }
            }
        }
        if (n_s > 0) {
            std.mem.sort(f64, samples[0..n_s], {}, std.sort.asc(f64));
            LINK_UNIT = samples[n_s / 2];
        } else LINK_UNIT = 1;
    }
    S = .{ .art = art, .NX = NX, .NY = NY, .total = total, .out = out, .label = label,
        .G = Groups{
            .NX = NX,
            .NY = NY,
            .parent = parent,
            .sum = sum,
            .count = count,
            .ymin = ymin,
            .ymax = ymax,
        },
        .sorted = sorted, .n_links = 0, .next = 0,
        .bucket = bucket, .phase = 0, .cell = 0 };
    return 1;
}

/// PREPARING THE LINKS, a share of cells at a time: first every link is
/// counted into its bucket of strength, then laid out bucket by bucket —
/// strongest first. Cells and directions go in the same order both times, so
/// the order inside a bucket is that of one whole run. Returns true when ready.
fn prepare(cells: usize) bool {
    const art = S.art;
    const NX = S.NX;
    const NY = S.NY;
    const bucket = S.bucket;
    const last = @min(S.total, S.cell +| cells);
    var a0 = S.cell;
    while (a0 < last) : (a0 += 1) {
        const x0 = a0 % NX;
        const y0 = a0 / NX;
        var d: usize = 0;
        while (d < DIRECTIONS) : (d += 1) {
            var b0: usize = 0;
            if (!neighbour(NX, NY, x0, y0, d, &b0)) continue;
            const ki = bucketOf(art, a0, b0, BUCKET_STEP, BUCKETS);
            if (S.phase == 0) {
                bucket[ki] += 1;
                S.n_links += 1;
            } else {
                S.sorted[bucket[ki]] = @intCast(a0 * DIRECTIONS + d);
                bucket[ki] += 1;
            }
        }
    }
    S.cell = last;
    if (last < S.total) return false;
    if (S.phase == 0) {
        // bucket counts become bucket starts
        var start: u32 = 0;
        var k0: usize = 0;
        while (k0 < BUCKETS) : (k0 += 1) {
            const t = bucket[k0];
            bucket[k0] = start;
            start += t;
        }
        S.phase = 1;
        S.cell = 0;
        return false;
    }
    S.phase = 2;
    return true;
}

/// RESOLVE the next `count` links, from the strongest to the weakest. Returns
/// 1 — links are left; 3 — all resolved (call pass2End).
export fn pass2Links(count: u32) u32 {
    // Still preparing: the same share of work goes to it — a cell has up to
    // eight links.
    if (S.phase < 2) {
        if (!prepare(@max(1, @as(usize, count) / DIRECTIONS))) return 1;
        return if (S.n_links == 0) 3 else 1;
    }
    const NX = S.NX;
    const NY = S.NY;
    var q0 = S.next;
    const last = @min(S.n_links, q0 +| @as(usize, count));
    while (q0 < last) : (q0 += 1) {
        const code = S.sorted[q0];
        const a0 = @as(usize, code) / DIRECTIONS;
        var b0: usize = 0;
        _ = neighbour(NX, NY, a0 % NX, a0 / NX, @as(usize, code) % DIRECTIONS, &b0);
        decide(&S.G, a0, b0);
    }
    S.next = last;
    return if (last >= S.n_links) 3 else 1;
}

/// THE GROUPS AS THEY STAND, for the eye only, drawn OVER a picture (RGBA,
/// four bytes a cell): a cell that has joined a group gets the group's mean
/// color so far; a cell still on its own is left as it was — the previous
/// result, or empty. The final colors are counted differently (pass2End).
export fn pass2Preview(rgba: [*]u8) void {
    var c: usize = 0;
    while (c < S.total) : (c += 1) {
        const r = root(S.G.parent, c);
        const n = S.G.count[r];
        if (n < 2) continue;
        rgba[c * 4] = roundByte(S.G.sum[r * 3] / n);
        rgba[c * 4 + 1] = roundByte(S.G.sum[r * 3 + 1] / n);
        rgba[c * 4 + 2] = roundByte(S.G.sum[r * 3 + 2] / n);
        rgba[c * 4 + 3] = 255;
    }
}

/// Ends pass 2: clusters numbered in a row and colored. Returns their number.
export fn pass2End() u32 {
    const art = S.art;
    const NX = S.NX;
    const NY = S.NY;
    const total = S.total;
    const out = S.out;
    const label = S.label;
    const parent = S.G.parent;
    var c: usize = 0;

    // cluster numbers in a row
    var groups: u32 = 0;
    while (c < total) : (c += 1) label[c] = 0xFFFFFFFF;
    c = 0;
    while (c < total) : (c += 1) {
        const r = root(parent, c);
        if (label[r] == 0xFFFFFFFF) {
            label[r] = groups;
            groups += 1;
        }
        label[c] = label[r];
    }

    // CLUSTER COLOR — from its INNER cells. A cell on the edge stands next to
    // another paint and has some of it smeared in; an inner cell is surrounded
    // by its own. If there are no inner cells (a thin or small cluster), all
    // cells are used.
    const sums_addr = memory.alloc(@as(usize, groups) * 8 * 8);
    const colors_addr = memory.alloc(@as(usize, groups) * 3 * 8);
    if (sums_addr == 0 or colors_addr == 0) return 0;
    const sums = @as([*]f64, @ptrFromInt(sums_addr));
    const colors = @as([*]f64, @ptrFromInt(colors_addr));
    var g: usize = 0;
    while (g < @as(usize, groups) * 8) : (g += 1) sums[g] = 0;
    c = 0;
    while (c < total) : (c += 1) {
        const x = c % NX;
        const y = c / NX;
        var inner = true;
        var dy: i64 = -1;
        while (dy <= 1 and inner) : (dy += 1) {
            var dx: i64 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                const s = cellAt(NX, NY, @as(i64, @intCast(x)) + dx, @as(i64, @intCast(y)) + dy) orelse continue;
                if (label[s] != label[c]) {
                    inner = false;
                    break;
                }
            }
        }
        const base = @as(usize, label[c]) * 8 + @as(usize, if (inner) 0 else 4);
        sums[base] += @floatFromInt(art[c * 3]);
        sums[base + 1] += @floatFromInt(art[c * 3 + 1]);
        sums[base + 2] += @floatFromInt(art[c * 3 + 2]);
        sums[base + 3] += 1;
    }
    g = 0;
    while (g < groups) : (g += 1) {
        const base = g * 8 + @as(usize, if (sums[g * 8 + 3] > 0) 0 else 4);
        const n = sums[base + 3];
        var ch: usize = 0;
        while (ch < 3) : (ch += 1) colors[g * 3 + ch] = if (n > 0) sums[base + ch] / n else 0;
    }
    c = 0;
    while (c < total) : (c += 1) {
        const gr = @as(usize, label[c]);
        out[c * 3] = roundByte(colors[gr * 3]);
        out[c * 3 + 1] = roundByte(colors[gr * 3 + 1]);
        out[c * 3 + 2] = roundByte(colors[gr * 3 + 2]);
    }
    return groups;
}

/// Bucket of a link by its strength: the color distance of the two cells,
/// scaled to the picture's own link unit. Knobs do not touch it, so the order
/// of resolution is the same whatever the knobs say.
fn bucketOf(art: [*]const u8, a0: usize, b0: usize, step: f64, buckets: usize) usize {
    var dS: f64 = 0;
    var dT: f64 = 0;
    split(@floatFromInt(art[a0 * 3]), @floatFromInt(art[a0 * 3 + 1]), @floatFromInt(art[a0 * 3 + 2]),
        @floatFromInt(art[b0 * 3]), @floatFromInt(art[b0 * 3 + 1]), @floatFromInt(art[b0 * 3 + 2]), &dS, &dT);
    const unit = @max(1.0, LINK_UNIT); // median joint of the picture itself
    var strength = @sqrt(dS * dS + dT * dT) / unit;
    if (strength > 4.0) strength = 4.0;
    const ki = @as(usize, @intFromFloat(strength / step));
    return if (ki < buckets) ki else buckets - 1;
}
