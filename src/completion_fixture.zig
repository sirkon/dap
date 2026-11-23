//! Fixture application for the shell completion integration tests.
//!
//! `src/completion_test.zig` renders this declaration's scripts and invokes
//! this executable through the hidden completion route. It is never installed
//! and is only built by the `completion-test` step.

const std = @import("std");
const dap = @import("dap");

/// Callback predictor used by the `--cb` flag and the `pick` command's first
/// argument. It returns two values, one carrying help.
fn callback(
    allocator: std.mem.Allocator,
    cur: []const u8,
    line: []const []const u8,
) anyerror![]const dap.Completion.Suggestion {
    _ = cur;
    _ = line;
    const items = try allocator.alloc(dap.Completion.Suggestion, 2);
    errdefer allocator.free(items);
    items[0] = .{ .value = try allocator.dupe(u8, "alpha") };
    errdefer allocator.free(items[0].value);
    items[0].help = try allocator.dupe(u8, "Alpha value.");
    errdefer allocator.free(items[0].help.?);
    items[1] = .{ .value = try allocator.dupe(u8, "beta") };
    errdefer allocator.free(items[1].value);
    return items;
}

pub const CLI = dap.generate(dap.App{
    .name = "dap predictor test",
    .help = "Prediction integration test.",
}, .{
    .cb = dap.Flag(dap.String){
        .long = "cb",
        .help = "Callback.",
        .completion = dap.Completion.custom(callback),
    },
    .native = dap.Flag(dap.String){
        .long = "native",
        .help = "Native files.",
        .completion = dap.Completion.fs(.{}),
    },
    .dirs = dap.Flag(dap.String){
        .long = "dirs",
        .help = "Native directories.",
        .completion = dap.Completion.fs(.{ .type = .dir }),
    },
    .assets = dap.Flag(dap.String){
        .long = "assets",
        .help = "Rooted files.",
        .completion = dap.Completion.fs(.{ .root = "assets", .wildcard = "*.txt" }),
    },
    .off = dap.Flag(dap.String){
        .long = "off",
        .help = "Disabled.",
        .completion = dap.Completion.disabled(),
    },
    .launch = dap.Flag(dap.String){
        .long = "launch",
        .help = "Launched command.",
        .completion = dap.Completion.launch(.{ "printf", "%s\\n", "launched", "$cur" }),
    },
    .call = dap.Flag(dap.String){
        .long = "call",
        .help = "Called expression.",
        .completion = dap.Completion.call("printf '%s\\n' \"$cur\"one \"$cur\"two"),
    },
    .plain = dap.Flag(dap.String){
        .long = "plain",
        .help = "No predictor.",
    },
    .pick = dap.Command(.{ .help = "Pick." }, .{
        .item = dap.Argument(dap.String){
            .help = "Item.",
            .completion = dap.Completion.custom(callback),
        },
        .path = dap.Argument(dap.String){
            .help = "Path.",
            .completion = dap.Completion.fs(.{ .wildcard = "*.txt" }),
        },
    }),
});

pub fn main(init: std.process.Init) !void {
    const arena = std.heap.page_allocator;

    const argv = try init.minimal.args.toSlice(arena);
    var diag: dap.Diag = .{};
    defer diag.deinit(arena);

    var cli = try CLI.parse(arena, init.minimal.environ, null, argv[1..], &diag);
    defer CLI.deinit(&cli, arena);
}
