// SPDX-License-Identifier: GPL-3.0-or-later
// `zig build`, run in dev/, builds the finished tool:
//   ../repix.html      the program itself, in the project root, kept in git
//   zig-out/Repix.zip  repix.html with README.md, LICENSE and OFL-Tiny5.txt,
//                      for a release
//   zig-out/site/      the web site: the same page as index.html, and what
//                      makes it an installable app — its description, the
//                      script that keeps it for work without the network, icons
//
// repix.html is one self-contained file: the core (WebAssembly) and the font
// are embedded in it, because a page opened from disk may not read a
// neighbouring file. It works anywhere: from disk, a USB stick, any web host,
// a phone.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const core = b.addExecutable(.{
        .name = "core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/core.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            // Fast, not small: pass 1 on a 2560x2560 picture takes half the time
            // (1.3 s instead of 2.6), the result byte for byte the same; the core
            // grows from 57 to 112 KB.
            .optimize = .ReleaseFast,
            .strip = true,
        }),
    });
    core.entry = .disabled;
    core.rdynamic = true;

    const host_tool = struct {
        fn make(bb: *std.Build, name: []const u8, path: []const u8) *std.Build.Step.Compile {
            return bb.addExecutable(.{
                .name = name,
                .root_module = bb.createModule(.{
                    .root_source_file = bb.path(path),
                    .target = bb.graph.host,
                    .optimize = .ReleaseSafe,
                }),
            });
        }
    };

    // the page: template + core + font + pipeline + the core's thread
    const embed = b.addRunArtifact(host_tool.make(b, "embed", "src/tools/embed.zig"));
    embed.addFileArg(b.path("src/ui/template.html"));
    embed.addArtifactArg(core);
    embed.addFileArg(b.path("src/ui/fonts/tiny5.woff2"));
    embed.addFileArg(b.path("src/ui/fonts/OFL-Tiny5.txt"));
    embed.addFileArg(b.path("src/ui/pipeline.js"));
    embed.addFileArg(b.path("src/ui/worker.js"));
    const page = embed.addOutputFileArg("repix.html");

    // the program in the project root
    const program = b.addUpdateSourceFiles();
    program.addCopyFileToSource(page, "../repix.html");
    b.getInstallStep().dependOn(&program.step);

    // the release zip: the page with its licenses and description
    const files = [_]struct { name: []const u8, src: std.Build.LazyPath }{
        .{ .name = "repix.html", .src = page },
        .{ .name = "README.md", .src = b.path("../README.md") },
        .{ .name = "LICENSE", .src = b.path("../LICENSE") },
        .{ .name = "OFL-Tiny5.txt", .src = b.path("src/ui/fonts/OFL-Tiny5.txt") },
    };
    const pack = b.addRunArtifact(host_tool.make(b, "pack", "src/tools/pack.zig"));
    const zip = pack.addOutputFileArg("Repix.zip");
    for (files) |f| pack.addPrefixedFileArg(b.fmt("Repix/{s}=", .{f.name}), f.src);
    b.getInstallStep().dependOn(&b.addInstallFile(zip, "Repix.zip").step);

    // the site: the page as index.html, the app's description and keeper, and
    // the app icons made from the page's own small icon, cell for cell
    const icons = b.addRunArtifact(host_tool.make(b, "icons", "src/tools/icons.zig"));
    icons.addFileArg(b.path("src/ui/template.html"));
    const icon192 = icons.addOutputFileArg("icon-192.png");
    const icon512 = icons.addOutputFileArg("icon-512.png");
    const iconMask = icons.addOutputFileArg("icon-maskable.png");
    const iconApple = icons.addOutputFileArg("icon-apple.png");
    const site = [_]struct { name: []const u8, src: std.Build.LazyPath }{
        .{ .name = "index.html", .src = page },
        .{ .name = "manifest.webmanifest", .src = b.path("src/site/manifest.webmanifest") },
        .{ .name = "sw.js", .src = b.path("src/site/sw.js") },
        .{ .name = "icon-192.png", .src = icon192 },
        .{ .name = "icon-512.png", .src = icon512 },
        .{ .name = "icon-maskable.png", .src = iconMask },
        .{ .name = "icon-apple.png", .src = iconApple },
    };
    for (site) |f| b.getInstallStep().dependOn(&b.addInstallFile(f.src, b.fmt("site/{s}", .{f.name})).step);
}
