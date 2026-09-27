// SPDX-License-Identifier: GPL-3.0-or-later
// Shared memory for the whole core: the page asks for blocks, we bump a
// pointer. Nothing is freed one by one; memory is released in bulk:
//   resetMemory  — everything, back to the bottom (a new image);
//   memoryTop    — where the pointer stands now: a mark (after the image, after
//                  a pass that is still running);
//   freeMemoryTo — everything above a mark (before each computation).
// So memory does not creep upwards with every recompute.

// The bottom of the heap is remembered once.
var bottom: usize = 0;
var top: usize = 0;

pub fn alloc(size: usize) usize {
    if (bottom == 0) bottom = @as(usize, @intCast(@wasmMemorySize(0))) * 65536;
    if (top < bottom) top = bottom;
    const start = (top + 15) & ~@as(usize, 15); // 16-byte alignment
    const end = start + size;
    const need = (end + 65535) / 65536;
    const have = @as(usize, @intCast(@wasmMemorySize(0)));
    if (need > have) {
        if (@wasmMemoryGrow(0, need - have) < 0) return 0; // out of memory
    }
    top = end;
    return start;
}

pub fn reset() void {
    top = bottom;
}

export fn allocMemory(size: usize) usize {
    return alloc(size);
}

export fn resetMemory() void {
    reset();
}

export fn memoryTop() usize {
    return top;
}

export fn freeMemoryTo(mark: usize) void {
    if (mark >= bottom and mark < top) top = mark;
}
