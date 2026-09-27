// SPDX-License-Identifier: GPL-3.0-or-later
// The Repix core, built to WebAssembly: memory, grid search, passes 1, 2 and 3.
comptime {
    _ = @import("memory.zig");
    _ = @import("grid.zig");
    _ = @import("phases.zig");
    _ = @import("pass1.zig");
    _ = @import("pass2.zig");
    _ = @import("pass3.zig");
}
