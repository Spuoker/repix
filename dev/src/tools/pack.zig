// SPDX-License-Identifier: GPL-3.0-or-later
// Packs files into a deflated zip:
//   pack <out.zip> <name-in-zip>=<file> ...
// Timestamps are fixed, so the same inputs always give the same zip.
const std = @import("std");
const flate = std.compress.flate;

fn put16(list: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
    try list.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
}
fn put32(list: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
    try list.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
}

const Entry = struct { name: []const u8, crc: u32, size: u32, packed_size: u32, offset: u32 };

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 3) return error.Usage;

    const cwd = std.Io.Dir.cwd();
    var zip: std.ArrayList(u8) = .empty;
    var entries: std.ArrayList(Entry) = .empty;
    const DOS_TIME: u16 = 0;
    const DOS_DATE: u16 = (1 << 5) | 1; // 1980-01-01

    for (args[2..]) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.Usage;
        const name = arg[0..eq];
        const data = try cwd.readFileAlloc(io, arg[eq + 1 ..], a, .limited(64 * 1024 * 1024));

        // the compressor needs room in its output from the start
        var out = try std.Io.Writer.Allocating.initCapacity(a, data.len + 1024);
        const window = try a.alloc(u8, flate.max_window_len);
        var comp = try flate.Compress.init(&out.writer, window, .raw, .default);
        try comp.writer.writeAll(data);
        try comp.finish();
        const packed_data = out.written();

        const crc = std.hash.Crc32.hash(data);
        const offset: u32 = @intCast(zip.items.len);
        try put32(&zip, a, 0x04034b50); // local file header
        try put16(&zip, a, 20); // version needed
        try put16(&zip, a, 0); // flags
        try put16(&zip, a, 8); // deflate
        try put16(&zip, a, DOS_TIME);
        try put16(&zip, a, DOS_DATE);
        try put32(&zip, a, crc);
        try put32(&zip, a, @intCast(packed_data.len));
        try put32(&zip, a, @intCast(data.len));
        try put16(&zip, a, @intCast(name.len));
        try put16(&zip, a, 0); // extra length
        try zip.appendSlice(a, name);
        try zip.appendSlice(a, packed_data);
        try entries.append(a, .{ .name = name, .crc = crc, .size = @intCast(data.len), .packed_size = @intCast(packed_data.len), .offset = offset });
    }

    const dir_start: u32 = @intCast(zip.items.len);
    for (entries.items) |e| {
        try put32(&zip, a, 0x02014b50); // central directory header
        try put16(&zip, a, 20); // version made by
        try put16(&zip, a, 20); // version needed
        try put16(&zip, a, 0);
        try put16(&zip, a, 8);
        try put16(&zip, a, DOS_TIME);
        try put16(&zip, a, DOS_DATE);
        try put32(&zip, a, e.crc);
        try put32(&zip, a, e.packed_size);
        try put32(&zip, a, e.size);
        try put16(&zip, a, @intCast(e.name.len));
        try put16(&zip, a, 0); // extra
        try put16(&zip, a, 0); // comment
        try put16(&zip, a, 0); // disk
        try put16(&zip, a, 0); // internal attributes
        try put32(&zip, a, 0); // external attributes
        try put32(&zip, a, e.offset);
        try zip.appendSlice(a, e.name);
    }
    const dir_size: u32 = @as(u32, @intCast(zip.items.len)) - dir_start;
    try put32(&zip, a, 0x06054b50); // end of central directory
    try put16(&zip, a, 0);
    try put16(&zip, a, 0);
    try put16(&zip, a, @intCast(entries.items.len));
    try put16(&zip, a, @intCast(entries.items.len));
    try put32(&zip, a, dir_size);
    try put32(&zip, a, dir_start);
    try put16(&zip, a, 0);

    try cwd.writeFile(io, .{ .sub_path = args[1], .data = zip.items });
}
