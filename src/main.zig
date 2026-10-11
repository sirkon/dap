const std = @import("std");
const dap = @import("dap");

const CustomType = struct {
    const Self = @This();

    nums: []const u16,

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) dap.DecodeError!Self {
        var list: std.ArrayList(u16) = .empty;
        errdefer list.deinit(allocator);

        var it = std.mem.tokenizeScalar(u8, data, ',');
        while (it.next()) |raw| {
            const tok = std.mem.trim(u8, raw, " \t");
            const n = std.fmt.parseInt(u16, tok, 10) catch return error.InvalidWire;
            try list.append(allocator, n);
        }

        return .{
            .nums = try list.toOwnedSlice(allocator),
        };
    }

    pub fn encode(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (self.nums, 0..) |n, i| {
            if (i != 0) try out.append(allocator, ',');
            try out.print(allocator, "{}", .{n});
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.nums);
    }
};

const def = .{
    .source = dap.Alt(.{
        .file = .{
            .file = dap.Flag([]const u8){
                .short = "s",
                .help = "Source file path.",
            },
        },
        .net = dap.VariantNamed("net", .{
            .url = dap.Flag([]const u8){
                .help = "Source URL.",
            },
        }),
    }),
    .last = dap.Flag(bool){
        .short = "l",
        .default = dap.defaultValue(bool, false),
        .help = "Only the last item.",
    },
    .count = dap.Flag(isize){
        .short = "c",
        .default = dap.defaultValue(isize, 1),
        .help = "How many items.",
    },
    .required = dap.Flag(isize){
        .help = "Mandatory value reflected into the usage header.",
    },
    .option = dap.Optional(dap.Flag(isize){
        .help = "Optional flag.",
    }),
    .flag = dap.Flag(bool){
        .short = "f",
        .help = "Flag to show off in the usage header.",
    },
    .custom = dap.Flag(CustomType){
        .long = "custom",
        .default = dap.defaultValue(CustomType, CustomType{
            .nums = &.{},
        }),
        .help = "Custom type translating 1,2,3 into [1, 2, 3].",
    },
    .command1 = dap.Command(
        .{ .name = "command-1", .help = "Command 1." },
        .{},
    ),
    .command2 = dap.Command(
        .{ .name = "command-2", .help = "Command 2." },
        .{
            .value = dap.Flag(dap.String){
                .default = dap.defaultValue(dap.String, ""),
                .help = "Command 2 value.",
            },
            .info = dap.Command(
                .{ .help = "Info about command 2." },
                .{
                    .details = dap.Flag(dap.String){
                        .default = dap.defaultValue(dap.String, ""),
                        .help = "Info details.",
                    },
                },
            ),
        },
    ),
};

const CLI = dap.generate(
    dap.App{
        .name = "dap-example",
        .help = "Manual test of the dap module.",
        .help_renderer = .{
            .highlight = .color,
        },
    },
    def,
);

pub fn main(init: std.process.Init) !void {
    const arena = std.heap.page_allocator;

    var stdout_buffer: [0x400]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const argv = try init.minimal.args.toSlice(arena);
    const args = argv[1..];

    var diag: dap.Diag = .{};
    defer diag.deinit(arena);

    // Parse errors and --help/-h requests are handled inside parse: help is
    // rendered to stdout with a clean exit, failures print the diagnostics
    // plus help to stderr and exit with code 1.
    var cli = try CLI.parse(arena, init.minimal.environ, args, &diag);
    defer CLI.deinit(&cli, arena);

    if (cli.source) |src| switch (src) {
        .file => |p| try stdout.print("file   = {s}\n", .{p.file}),
        .net => |p| try stdout.print("net    = {s}\n", .{p.url}),
    };
    try stdout.print("last   = {}\n", .{cli.last});
    try stdout.print("count  = {}\n", .{cli.count});
    try stdout.print("custom_type = {}\n", .{cli.custom});
    if (CLI.command(cli)) |cmd| switch (cmd) {
        .command1 => try stdout.print("command = command-1\n", .{}),
        .command2 => |c| try stdout.print("value  = {s}\n", .{c.value}),
    };

    std.debug.print("checkpoint\n", .{});
    try CLI.usage(cli);

    try stdout.flush();
}
