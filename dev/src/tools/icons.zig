// SPDX-License-Identifier: GPL-3.0-or-later
// Makes the app icons from the page's own small icon, cell for cell:
//   icons <template.html> <icon-192.png> <icon-512.png> <icon-maskable.png> <icon-apple.png>
// The icon lives in the page (its rel="icon" as a PNG in base64), and nowhere
// else: it is taken from there.
// The icon is pixel art, so it is scaled by whole numbers and never smoothed.
// The maskable one is for systems that cut icons into circles and rounded
// squares (Android): the icon stands on its own teal with room around it, so
// the cut takes only the field.
const std = @import("std");
const flate = std.compress.flate;

const Image = struct { w: usize, h: usize, px: []u8 }; // RGBA, row by row

const SIGNATURE = "\x89PNG\r\n\x1a\n";
const TEAL = [4]u8{ 0x00, 0x80, 0x80, 0xff }; // the canvas of the 98 theme

/// Reads an 8-bit RGBA, non-interlaced PNG — what the icon is.
fn decode(a: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], SIGNATURE)) return error.NotPng;
    var w: usize = 0;
    var h: usize = 0;
    var idat: std.ArrayList(u8) = .empty;
    var pos: usize = 8;
    while (pos + 12 <= data.len) {
        const n = std.mem.readInt(u32, data[pos..][0..4], .big);
        const kind = data[pos + 4 .. pos + 8];
        const d = data[pos + 8 .. pos + 8 + n];
        if (std.mem.eql(u8, kind, "IHDR")) {
            w = std.mem.readInt(u32, d[0..4], .big);
            h = std.mem.readInt(u32, d[4..8], .big);
            if (d[8] != 8 or d[9] != 6 or d[12] != 0) return error.UnsupportedPng;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(a, d);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
        pos += 12 + n;
    }
    var in: std.Io.Reader = .fixed(idat.items);
    const window = try a.alloc(u8, flate.max_window_len);
    var dec = flate.Decompress.init(&in, .zlib, window);
    const raw = try dec.reader.allocRemaining(a, .unlimited);

    // Rows come filtered: each byte is told relative to its left, upper and
    // upper-left neighbours.
    const stride = w * 4;
    if (raw.len < h * (stride + 1)) return error.ShortPng;
    const px = try a.alloc(u8, h * stride);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const filter = raw[y * (stride + 1)];
        const line = raw[y * (stride + 1) + 1 ..][0..stride];
        const row = px[y * stride ..][0..stride];
        var i: usize = 0;
        while (i < stride) : (i += 1) {
            const left: u8 = if (i >= 4) row[i - 4] else 0;
            const up: u8 = if (y > 0) px[(y - 1) * stride + i] else 0;
            const corner: u8 = if (y > 0 and i >= 4) px[(y - 1) * stride + i - 4] else 0;
            const guess: u8 = switch (filter) {
                0 => 0,
                1 => left,
                2 => up,
                3 => @intCast((@as(u16, left) + up) / 2),
                4 => paeth(left, up, corner),
                else => return error.BadFilter,
            };
            row[i] = line[i] +% guess;
        }
    }
    return .{ .w = w, .h = h, .px = px };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}

/// The icon at k× on a square canvas of `side`, placed at `off`. With a
/// field, the canvas and the icon's transparent pixels take its color.
fn scale(a: std.mem.Allocator, src: Image, k: usize, side: usize, off: usize, field: ?[4]u8) !Image {
    const px = try a.alloc(u8, side * side * 4);
    const bg = field orelse [4]u8{ 0, 0, 0, 0 };
    var q: usize = 0;
    while (q < side * side) : (q += 1) @memcpy(px[q * 4 ..][0..4], &bg);
    var y: usize = 0;
    while (y < src.h) : (y += 1) {
        var x: usize = 0;
        while (x < src.w) : (x += 1) {
            var c: [4]u8 = src.px[(y * src.w + x) * 4 ..][0..4].*;
            if (c[3] == 0) c = bg;
            var dy: usize = 0;
            while (dy < k) : (dy += 1) {
                var dx: usize = 0;
                while (dx < k) : (dx += 1)
                    @memcpy(px[((off + y * k + dy) * side + off + x * k + dx) * 4 ..][0..4], &c);
            }
        }
    }
    return .{ .w = side, .h = side, .px = px };
}

fn chunk(a: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(a, &len);
    try out.appendSlice(a, kind);
    try out.appendSlice(a, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try out.appendSlice(a, &sum);
}

fn encode(a: std.mem.Allocator, img: Image) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, SIGNATURE);
    var head: [13]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], @intCast(img.w), .big);
    std.mem.writeInt(u32, head[4..8], @intCast(img.h), .big);
    head[8] = 8; // bits per channel
    head[9] = 6; // RGBA
    head[10] = 0;
    head[11] = 0;
    head[12] = 0;
    try chunk(a, &out, "IHDR", &head);

    const stride = img.w * 4;
    const raw = try a.alloc(u8, img.h * (stride + 1));
    var y: usize = 0;
    while (y < img.h) : (y += 1) {
        raw[y * (stride + 1)] = 0; // no filter: big flat blocks pack well anyway
        @memcpy(raw[y * (stride + 1) + 1 ..][0..stride], img.px[y * stride ..][0..stride]);
    }
    var packed_data = try std.Io.Writer.Allocating.initCapacity(a, raw.len + 1024);
    const window = try a.alloc(u8, flate.max_window_len);
    var comp = try flate.Compress.init(&packed_data.writer, window, .zlib, .default);
    try comp.writer.writeAll(raw);
    try comp.finish();
    try chunk(a, &out, "IDAT", packed_data.written());
    try chunk(a, &out, "IEND", "");
    return out.items;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 6) return error.Usage;
    const cwd = std.Io.Dir.cwd();
    const page = try cwd.readFileAlloc(io, args[1], a, .limited(64 * 1024 * 1024));
    const mark = "rel=\"icon\" type=\"image/png\" href=\"data:image/png;base64,";
    const at = (std.mem.indexOf(u8, page, mark) orelse return error.NoIcon) + mark.len;
    const len = std.mem.indexOfScalarPos(u8, page, at, '"') orelse return error.NoIcon;
    const b64 = page[at..len];
    const dec = std.base64.standard.Decoder;
    const png = try a.alloc(u8, try dec.calcSizeForSlice(b64));
    try dec.decode(png, b64);
    const icon = try decode(a, png);
    if (icon.w != icon.h) return error.NotSquare;
    // 192 and 512 are what the systems ask for; a 16-cell icon goes into them
    // whole 12 and 32 times.
    const s192 = 192 / icon.w;
    const s512 = 512 / icon.w;
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = try encode(a, try scale(a, icon, s192, 192, (192 - icon.w * s192) / 2, null)) });
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = try encode(a, try scale(a, icon, s512, 512, (512 - icon.w * s512) / 2, null)) });
    // Maskable: a system may cut the icon to a circle of 0.4 of the side
    // round the middle (the safe zone). The icon's square must fit inside it
    // whole, corners too: its side at most 0.8 of the side over √2 — 289 of
    // 512, so a 16-cell icon goes in 18 times.
    const sm = @as(usize, @intFromFloat(@floor(512.0 * 0.8 / std.math.sqrt2))) / icon.w;
    try cwd.writeFile(io, .{ .sub_path = args[4], .data = try encode(a, try scale(a, icon, sm, 512, (512 - icon.w * sm) / 2, TEAL)) });
    // The iPhone takes its own 180 and fills transparency with black: the
    // icon whole times into it, on the teal field.
    const sa = 180 / icon.w;
    try cwd.writeFile(io, .{ .sub_path = args[5], .data = try encode(a, try scale(a, icon, sa, 180, (180 - icon.w * sa) / 2, TEAL)) });
}
