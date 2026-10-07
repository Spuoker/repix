// SPDX-License-Identifier: GPL-3.0-or-later
// Grid search: the cell size and the two origins.
//
// One principle. Every color transition in pixel art lies on a lattice:
// position = origin + k * step. So all transitions are collected once, with
// their strength, and every candidate step is asked one question: how well do
// the transitions agree on a single phase. The measure itself lives in
// phases.zig; this file prepares the input (the art's frame, edge profiles) and
// refines the answer once by the actual peaks.

const memory = @import("memory.zig");
const phases = @import("phases.zig");

var prof_x: [*]f64 = undefined;
var prof_y: [*]f64 = undefined;
var nx: usize = 0;
var ny: usize = 0;

// Where a transition really is near an expected position: the centre of mass
// of the peak, counting everything at least half as high, in a window around
// the position.
fn peakAt(p: [*]const f64, n: usize, pos: f64, window: f64) f64 {
    var l = @as(i64, @intFromFloat(@round(pos - window)));
    var r = @as(i64, @intFromFloat(@round(pos + window)));
    if (l < 1) l = 1;
    if (r > @as(i64, @intCast(n)) - 1) r = @as(i64, @intCast(n)) - 1;
    if (r <= l) return -1;
    var mx: f64 = 0;
    var i = l;
    while (i <= r) : (i += 1) if (p[@intCast(i)] > mx) {
        mx = p[@intCast(i)];
    };
    if (mx <= 0) return -1;
    var sum: f64 = 0;
    var weight: f64 = 0;
    i = l;
    while (i <= r) : (i += 1) {
        const w = if (p[@intCast(i)] >= mx * 0.5) p[@intCast(i)] else 0;
        sum += w * @as(f64, @floatFromInt(i));
        weight += w;
    }
    return if (weight > 0) sum / weight else -1;
}

// STEP REFINEMENT by the actual transitions. The coarse search stops on its
// grid of candidates; over a hundred lines a half-percent error adds up to
// more than half a cell. So every expected line is matched to the real
// transition next to it, and a least-squares line is fitted through them.
// Three rounds: after the first one the lines sit closer and match better.
fn refine(p: [*]const f64, n: usize, step: *f64, phase: *f64) void {
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        const s = step.*;
        const f = phase.*;
        if (s <= 0) return;
        const window = @min(1.2, s * 0.45);
        var sk: f64 = 0;
        var sp: f64 = 0;
        var skk: f64 = 0;
        var skp: f64 = 0;
        var m: f64 = 0;
        var k = @as(i64, @intFromFloat(@ceil(-f / s)));
        const k1 = @as(i64, @intFromFloat(@floor((@as(f64, @floatFromInt(n)) - f) / s)));
        while (k <= k1) : (k += 1) {
            const expected = f + @as(f64, @floatFromInt(k)) * s;
            const t = peakAt(p, n, expected, window);
            if (t < 0) continue;
            const kf = @as(f64, @floatFromInt(k));
            sk += kf;
            sp += t;
            skk += kf * kf;
            skp += kf * t;
            m += 1;
        }
        if (m < 8) return;
        const den = skk - sk * sk / m;
        if (@abs(den) < 1e-9) return;
        const fitted = (skp - sk * sp / m) / den;
        if (fitted <= 0 or @abs(fitted - s) > s * 0.1) return; // drifted too far: distrust
        step.* = fitted;
        phase.* = sp / m - fitted * (sk / m);
    }
}

// A PIXEL IS FOUR NUMBERS: its color, premultiplied by how much of it is
// there, and that amount (alpha). A pixel that is not there at all is
// (0, 0, 0, 0) whatever color a file left under it; the edge between a pixel
// and nothing is as strong as any edge of color. A picture with no
// transparency has alpha 255 everywhere and is measured as it always was.
const CH = 4;

/// Finds the grid of the art in an RGBA image (premultiplied, see CH).
/// out[0] — cell size, out[1..2] — origin x and y, out[3..6] — the art's frame
/// (x0, y0, x1, y1), out[7] — agreement of the answer.
/// Returns 1 on success, 0 when no grid is found.
export fn findGrid(
    img: [*]const u8,
    W: u32,
    H: u32,
    min: f64,
    max_given: f64,
    out: [*]f64,
) u32 {
    const Wu = @as(usize, @intCast(W));
    const Hu = @as(usize, @intCast(H));
    if (Wu < 8 or Hu < 8) return 0;

    // ---- frame: the canvas edges know nothing about the grid, take the part
    // occupied by the art. The background is the median of each channel.
    var hist: [CH][256]u32 = .{.{0} ** 256} ** CH;
    var i: usize = 0;
    while (i < Wu * Hu) : (i += 1) {
        var ch: usize = 0;
        while (ch < CH) : (ch += 1) hist[ch][img[i * CH + ch]] += 1;
    }
    var bg: [CH]u32 = undefined;
    var c: usize = 0;
    while (c < CH) : (c += 1) {
        var total: u32 = 0;
        var v: usize = 0;
        while (v < 256) : (v += 1) {
            total += hist[c][v];
            if (total * 2 >= @as(u32, @intCast(Wu * Hu))) {
                bg[c] = @intCast(v);
                break;
            }
        }
    }
    // A row or column counts as occupied only when enough of its pixels differ
    // from the background: one noisy pixel in a corner must not stretch the
    // frame over the whole canvas.
    const countXAddr = memory.alloc(Wu * 4);
    const countYAddr = memory.alloc(Hu * 4);
    const countX = @as([*]u32, @ptrFromInt(countXAddr));
    const countY = @as([*]u32, @ptrFromInt(countYAddr));
    var line: usize = 0;
    while (line < Wu) : (line += 1) countX[line] = 0;
    line = 0;
    while (line < Hu) : (line += 1) countY[line] = 0;
    var y: usize = 0;
    while (y < Hu) : (y += 1) {
        var x: usize = 0;
        while (x < Wu) : (x += 1) {
            const b = (y * Wu + x) * CH;
            var d: u32 = 0;
            var k: usize = 0;
            while (k < CH) : (k += 1) {
                const a = @as(i32, img[b + k]) - @as(i32, @intCast(bg[k]));
                d += @intCast(if (a < 0) -a else a);
            }
            if (d > 24) {
                countX[x] += 1;
                countY[y] += 1;
            }
        }
    }
    const thresholdX = @max(@as(u32, 3), @as(u32, @intCast(Hu / 50)));
    const thresholdY = @max(@as(u32, 3), @as(u32, @intCast(Wu / 50)));
    var x0: usize = Wu;
    var x1: usize = 0;
    var y0: usize = Hu;
    var y1: usize = 0;
    line = 0;
    while (line < Wu) : (line += 1) {
        if (countX[line] >= thresholdX) {
            if (line < x0) x0 = line;
            x1 = line + 1;
        }
    }
    line = 0;
    while (line < Hu) : (line += 1) {
        if (countY[line] >= thresholdY) {
            if (line < y0) y0 = line;
            y1 = line + 1;
        }
    }
    // No art found at all: check before subtracting, unsigned 0 - W wraps.
    if (x1 <= x0 or y1 <= y0) return 0;
    const sw = x1 - x0;
    const sh = y1 - y0;
    if (sw < 8 or sh < 8) return 0;

    // ---- edge strength profiles inside the frame
    nx = sw - 1;
    ny = sh - 1;
    prof_x = @ptrFromInt(memory.alloc(nx * 8));
    prof_y = @ptrFromInt(memory.alloc(ny * 8));
    i = 0;
    while (i < nx) : (i += 1) prof_x[i] = 0;
    i = 0;
    while (i < ny) : (i += 1) prof_y[i] = 0;
    y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x + 1 < x1) : (x += 1) {
            const a = (y * Wu + x) * CH;
            const b = (y * Wu + x + 1) * CH;
            var d: f64 = 0;
            var k: usize = 0;
            while (k < CH) : (k += 1) {
                const r = @as(f64, @floatFromInt(img[a + k])) - @as(f64, @floatFromInt(img[b + k]));
                d += if (r < 0) -r else r;
            }
            prof_x[x - x0] += d;
        }
    }
    y = y0;
    while (y + 1 < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const a = (y * Wu + x) * CH;
            const b = ((y + 1) * Wu + x) * CH;
            var d: f64 = 0;
            var k: usize = 0;
            while (k < CH) : (k += 1) {
                const r = @as(f64, @floatFromInt(img[a + k])) - @as(f64, @floatFromInt(img[b + k]));
                d += if (r < 0) -r else r;
            }
            prof_y[y - y0] += d;
        }
    }

    // ---- place the grid
    {
        var sx0: f64 = 0;
        var sy0: f64 = 0;
        var f1: f64 = 0;
        var f2: f64 = 0;
        // A cell cannot be smaller than one pixel: that is the floor.
        const min_s = if (min > 1.0) min else 1.0;
        const shorter = if (sw < sh) sw else sh;
        var max_s = @as(f64, @floatFromInt(shorter)) / 6.0;
        if (max_given > 0 and max_given < max_s) max_s = max_given;
        const d = phases.both(prof_x, nx, prof_y, ny, min_s, max_s, &sx0, &sy0, &f1, &f2);
        if (d <= 0 or sx0 <= 0 or sy0 <= 0) return 0;
        // The agreement measure gives the step to hundredths; refinement by
        // the real peaks removes the rest. It is accepted only when the same
        // agreement measure improves with it.
        var sx = sx0;
        var sy = sy0;
        var rx = sx0;
        var ry = sy0;
        var gx = f1;
        var gy = f2;
        refine(prof_x, nx, &rx, &gx);
        refine(prof_y, ny, &ry, &gy);
        if (phases.score(0, rx) > phases.score(0, sx)) {
            sx = rx;
            f1 = gx;
        }
        if (phases.score(1, ry) > phases.score(1, sy)) {
            sy = ry;
            f2 = gy;
        }
        // One step for both axes: separate steps measured worse.
        const step = (sx + sy) / 2;
        out[0] = step;
        out[1] = @mod(@as(f64, @floatFromInt(x0)) + f1 + 1.0, step);
        out[2] = @mod(@as(f64, @floatFromInt(y0)) + f2 + 1.0, step);
        out[3] = @floatFromInt(x0);
        out[4] = @floatFromInt(y0);
        out[5] = @floatFromInt(x1);
        out[6] = @floatFromInt(y1);
        out[7] = d;
        return 1;
    }
}
