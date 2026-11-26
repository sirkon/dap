//! Test-only `std.process.Init` builder.
//!
//! Test blocks import this file directly. Production code and `root.zig`
//! never do, so library builds never analyse it.

const std = @import("std");

/// Builds a `std.process.Init` from an environment for tests.
///
/// The struct must not be copied after `setup`: `value.arena` and
/// `value.environ_map` point at this struct's own fields. Initialize it in
/// place instead:
///
/// ```zig
/// var t: TestInit = undefined;
/// t.setup(std.process.Environ.empty);
/// defer t.deinit();
/// ```
pub const TestInit = struct {
    arena: std.heap.ArenaAllocator,
    environ_map: std.process.Environ.Map,
    value: std.process.Init,

    /// Builds the owned map and arena in place and wires `value` to them.
    /// The borrowed `environ` block is not owned.
    pub fn setup(self: *TestInit, environ: std.process.Environ) void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.environ_map = environ.createMap(std.testing.allocator) catch unreachable;
        self.value = .{
            .minimal = .{ .args = .{ .vector = &.{} }, .environ = environ },
            .arena = &self.arena,
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .environ_map = &self.environ_map,
            .preopens = std.process.Preopens.empty,
        };
    }

    /// Frees the map, then the arena. The borrowed `environ` is not freed.
    pub fn deinit(self: *TestInit) void {
        self.environ_map.deinit();
        self.arena.deinit();
    }
};
