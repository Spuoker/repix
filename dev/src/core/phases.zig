// SPDX-License-Identifier: GPL-3.0-or-later
// Grid search in one pass: how well the transitions agree on one phase.
//
// All color transitions in pixel art lie on a lattice: position = origin +
// k * step. All transitions are collected once with their strength, and each
// candidate step is asked how well they sit on a single phase.
//
// The measure is the length of the sum of unit vectors turned by each
// transition's phase (circular statistics). One: all transitions share a
// phase. Zero: scattered at random. The angle of the same sum gives the phase.
//
// The right step scores 0.85..0.99; its fractions (step/2, step/3) score about
// the same, while its multiples (2x, 1.5x) fall to 0.01..0.13, because their
// phases spread around the circle and cancel. Hence one simple rule: take the
// LARGEST step that still explains the transitions.
//
// Both axes are judged together, by the worse of the two: one axis can settle
// on a fraction of the step, both at once cannot.

const std = @import("std");

const AXES = 2;
const MAX_TRANSITIONS = 4096;
// A few hundred transitions are plenty: more only refine the same phase while
// the cost grows linearly. The strongest are kept.
const KEEP = 400;

var pos: [AXES][MAX_TRANSITIONS]f64 = undefined; // where the transition is
var strength: [AXES][MAX_TRANSITIONS]f64 = undefined; // how strong it is
var count: [AXES]usize = .{ 0, 0 };

// How far a candidate's agreement may fall below the best and still count as
// an explanation. Measured on 27 art/reference pairs: below 0.5 too large
// steps get through; above 0.6 nothing changes. 0.6 sits in the flat middle.
const SHARE: f64 = 0.6;

/// Transitions of one edge-strength profile: local maxima with a sub-pixel
/// peak from three points. Weak ones are skipped — noise would take their place.
pub fn collect(axis: usize, p: [*]const f64, n: usize) void {
    count[axis] = 0;
    if (n < 8) return;
    var mean: f64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) mean += p[i];
    mean /= @floatFromInt(n);
    const threshold = mean * 0.8;
    var k: usize = 0;
    i = 1;
    while (i + 1 < n) : (i += 1) {
        if (p[i] < threshold) continue;
        if (p[i] < p[i - 1] or p[i] < p[i + 1]) continue;
        if (k >= MAX_TRANSITIONS) break;
        // vertex of the parabola through three points: sub-pixel accuracy
        const a = p[i - 1];
        const b = p[i];
        const c = p[i + 1];
        const den = a - 2 * b + c;
        var shift: f64 = 0;
        if (@abs(den) > 1e-9) shift = 0.5 * (a - c) / den;
        if (shift > 0.5) shift = 0.5;
        if (shift < -0.5) shift = -0.5;
        pos[axis][k] = @as(f64, @floatFromInt(i)) + shift;
        strength[axis][k] = b;
        k += 1;
    }
    // keep the KEEP strongest: partial selection sort
    if (k > KEEP) {
        var a2: usize = 0;
        while (a2 < KEEP) : (a2 += 1) {
            var best = a2;
            var b2 = a2 + 1;
            while (b2 < k) : (b2 += 1) {
                if (strength[axis][b2] > strength[axis][best]) best = b2;
            }
            const tp = pos[axis][a2];
            const ts = strength[axis][a2];
            pos[axis][a2] = pos[axis][best];
            strength[axis][a2] = strength[axis][best];
            pos[axis][best] = tp;
            strength[axis][best] = ts;
        }
        k = KEEP;
    }
    // Transitions are weighted by edge strength as is: softer weightings were
    // measured and did not do better.
    count[axis] = k;
}

const TAU: f64 = 6.283185307179586;

/// Agreement along one axis: length of the mean unit arrow over the
/// transition phases. Also returns the phase itself.
pub fn agreement(axis: usize, s: f64, phase: *f64) f64 {
    if (s <= 0 or count[axis] < 4) return 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var weight: f64 = 0;
    var i: usize = 0;
    while (i < count[axis]) : (i += 1) {
        const angle = TAU * pos[axis][i] / s;
        sx += strength[axis][i] * @cos(angle);
        sy += strength[axis][i] * @sin(angle);
        weight += strength[axis][i];
    }
    if (weight <= 0) return 0;
    const len = @sqrt(sx * sx + sy * sy) / weight;
    var u = std.math.atan2(sy, sx) / TAU * s;
    while (u < 0) u += s;
    phase.* = u;
    return len;
}

/// Agreement of a step along an axis, without the phase.
pub fn score(axis: usize, s: f64) f64 {
    var f: f64 = 0;
    return agreement(axis, s, &f);
}

/// Agreement on both axes at once: the worse of the two.
fn together(s: f64) f64 {
    var f: f64 = 0;
    const a = agreement(0, s, &f);
    const b = agreement(1, s, &f);
    return if (a < b) a else b;
}

/// Search increment around candidate s. A far transition's phase moves by
/// L*ds/s^2, so the increment grows with s^2: a constant one would be blind on
/// small cells and wasteful on large ones.
fn increment(s: f64, L: f64, share: f64) f64 {
    var d = share * s * s / L;
    if (d < 0.0002) d = 0.0002;
    if (d > 0.5) d = 0.5;
    return d;
}

/// Finds the step (shared by both axes) and the two phases. Returns the
/// agreement of the answer.
pub fn both(
    px: [*]const f64,
    nx: usize,
    py: [*]const f64,
    ny: usize,
    min: f64,
    max: f64,
    step: *f64,
    step_y: *f64,
    fx: *f64,
    fy: *f64,
) f64 {
    collect(0, px, nx);
    collect(1, py, ny);
    if (count[0] < 4 or count[1] < 4) return 0;
    if (!(min > 0) or !(max > min)) return 0;
    const L = @as(f64, @floatFromInt(if (nx > ny) nx else ny));

    // Coarse: what agreement is reachable at all
    var best: f64 = 0;
    var s = min;
    var guard: usize = 0;
    while (s <= max and guard < 60000) : (guard += 1) {
        const d = together(s);
        if (d > best) best = d;
        s += increment(s, L, 0.12);
    }
    if (best <= 0) return 0;

    // The largest step that still explains the transitions
    const enough = best * SHARE;
    var found: f64 = 0;
    s = max;
    guard = 0;
    while (s >= min and guard < 60000) : (guard += 1) {
        if (together(s) >= enough) {
            found = s;
            break;
        }
        s -= increment(s, L, 0.12);
    }
    if (found <= 0) return 0;

    // Fine search around it: the same rule, ten times finer, in a window wider
    // than the coarse increment so the peak is not left outside.
    const fine = increment(found, L, 0.012);
    const window = increment(found, L, 0.5);
    var bs = found;
    var bd = together(found);
    var t = found - window;
    guard = 0;
    while (t <= found + window and guard < 4000) : (guard += 1) {
        const d = together(t);
        if (d > bd) {
            bd = d;
            bs = t;
        }
        t += fine;
    }
    step.* = bs;
    step_y.* = bs;
    _ = agreement(0, bs, fx);
    _ = agreement(1, bs, fy);
    return bd;
}
