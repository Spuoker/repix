// SPDX-License-Identifier: GPL-3.0-or-later
// Embeds into the page template the core and the font as base64, and as they
// are the font's license, the pipeline script and the core's thread:
//   embed <template.html> <core.wasm> <font.woff2> <OFL.txt> <pipeline.js> <worker.js> <out.html>
// Placeholders in the template: __CORE__, __FONT__, __FONT_LICENSE__,
// __PIPELINE__, __WORKER__. Plain texts go inside <script> elements, so they must not
// hold "</script".
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 8) return error.Usage;

    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(64 * 1024 * 1024);
    var html: []const u8 = try cwd.readFileAlloc(io, args[1], a, limit);
    const marks = [_]struct { name: []const u8, base64: bool }{
        .{ .name = "__CORE__", .base64 = true },
        .{ .name = "__FONT__", .base64 = true },
        .{ .name = "__FONT_LICENSE__", .base64 = false },
        .{ .name = "__PIPELINE__", .base64 = false },
        .{ .name = "__WORKER__", .base64 = false },
    };
    for (marks, 0..) |mark, i| {
        var data = try cwd.readFileAlloc(io, args[2 + i], a, limit);
        if (mark.base64) {
            const enc = std.base64.standard.Encoder;
            const b64 = try a.alloc(u8, enc.calcSize(data.len));
            _ = enc.encode(b64, data);
            data = b64;
        } else if (std.ascii.indexOfIgnoreCase(data, "</script") != null) return error.BreaksScript;
        const at = std.mem.indexOf(u8, html, mark.name) orelse return error.MissingPlaceholder;
        html = try std.mem.concat(a, u8, &.{ html[0..at], data, html[at + mark.name.len ..] });
    }
    try cwd.writeFile(io, .{ .sub_path = args[7], .data = html });
}
