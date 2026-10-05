const std = @import("std");
const dap = @import("dap");

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
    .target = dap.Argument([]const u8){
        .name = "string",
        .help = "The target string.",
    },
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
    const arena = init.arena.allocator();

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
    const cli = try CLI.parse(arena, init.minimal.environ, args, &diag);

    if (cli.source) |src| switch (src) {
        .file => |p| try stdout.print("file   = {s}\n", .{p.file}),
        .net => |p| try stdout.print("net    = {s}\n", .{p.url}),
    };
    try stdout.print("last   = {}\n", .{cli.last});
    try stdout.print("count  = {}\n", .{cli.count});
    try stdout.print("string = {s}\n", .{cli.target});
    try stdout.flush();
}
