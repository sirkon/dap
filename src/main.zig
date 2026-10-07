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
    if (cli.command2) |c| try stdout.print("value  = {s}\n", .{c.value});
    try stdout.flush();
}
