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

const Shell = dap.Enumeration(.{
    .bash = dap.Enum{},
    .zsh = dap.Enum{},
    .fish = dap.Enum{},
});

const def = .{
    .source = dap.Alt(.{
        .file = .{
            .file = dap.Flag([]const u8){
                .short = "s",
                .help = "Source file path.",
                .i18n = "source_file",
            },
        },
        .net = dap.VariantNamed("net", .{
            .url = dap.Flag([]const u8){
                .help = "Source URL.",
                .i18n = "source_url",
            },
        }),
    }),
    .last = dap.Flag(bool){
        .short = "l",
        .default = dap.defaultValue(bool, false),
        .help = "Only the last item.",
        .i18n = "last",
    },
    .count = dap.Flag(isize){
        .short = "c",
        .default = dap.defaultValue(isize, 1),
        .help = "How many items.",
        .i18n = "count",
    },
    .required = dap.Flag(isize){
        .help = "Mandatory value reflected into the usage header.",
        .i18n = "required",
    },
    .option = dap.Optional(dap.Flag(isize){
        .help = "Optional flag.",
        .i18n = "option",
    }),
    .path = dap.Flag([]const u8){
        .help = "File path.",
        .i18n = "path",
        .default = dap.defaultValue([]const u8, ""),
        .completion = .{ .fs = .{} },
    },
    .flag = dap.Flag(bool){
        .short = "f",
        .help = "Flag to show off in the usage header.",
        .i18n = "flag",
    },
    .custom = dap.Flag(CustomType){
        .long = "custom",
        .default = dap.defaultValue(CustomType, CustomType{
            .nums = &.{},
        }),
        .help = "Custom type translating 1,2,3 into [1, 2, 3].",
        .i18n = "custom",
    },
    .command1 = dap.Command(
        .{ .name = "command-1", .help = "Command 1.", .i18n = "command1" },
        .{},
    ),
    .command2 = dap.Command(
        .{ .name = "command-2", .help = "Command 2.", .i18n = "command2" },
        .{
            .value = dap.Flag(dap.String){
                .default = dap.defaultValue(dap.String, ""),
                .help = "Command 2 value.",
                .i18n = "command2_value",
            },
            .info = dap.Command(
                .{ .help = "Info about command 2.", .i18n = "info" },
                .{
                    .details = dap.Flag(dap.String){
                        .default = dap.defaultValue(dap.String, ""),
                        .help = "Info details.",
                        .i18n = "details",
                    },
                },
            ),
        },
    ),
    .completion = dap.Command(
        .{ .help = "Print a shell completion script.", .i18n = "completion_cmd" },
        .{
            .shell = dap.Argument(Shell){
                .help = "Shell dialect to generate.",
                .i18n = "shell",
            },
        },
    ),
};

const CLI = dap.generate(
    dap.App{
        .name = "dap-example",
        .help = "Manual test of the dap module.",
        .i18n = "app_help",
        .help_renderer = .{
            .highlight = .color,
        },
    },
    def,
);

// Locales are registered under language tags, so a standard environment such
// as `LANG=ru_RU.UTF-8` reaches the `ru` entry through the language fallback.
// Without a matching environment tag the declaration's generated English
// locale is used, byte-for-byte as before. Every key declared above must be
// supplied: a missing one is a compile error at `append`.
const translations = CLI.i18n()
    .append("ru", dap.I18n.ru.withUser(.{
        .app_help = "Ручной тест модуля dap.",
        .source_file = "Путь к исходному файлу.",
        .source_url = "URL источника.",
        .last = "Только последний элемент.",
        .count = "Сколько элементов.",
        .required = "Обязательное значение, отражаемое в строке использования.",
        .option = "Необязательный флаг.",
        .path = "Путь к файлу.",
        .flag = "Флаг для демонстрации в строке использования.",
        .custom = "Пользовательский тип, превращающий 1,2,3 в [1, 2, 3].",
        .command1 = "Команда 1.",
        .command2 = "Команда 2.",
        .command2_value = "Значение команды 2.",
        .info = "Информация о команде 2.",
        .details = "Детали информации.",
        .completion_cmd = "Печать сценария автодополнения оболочки.",
        .shell = "Диалект оболочки для генерации.",
    }))
    .append("es", dap.I18n.es.withUser(.{
        .app_help = "Prueba manual del módulo dap.",
        .source_file = "Ruta del archivo de origen.",
        .source_url = "URL de origen.",
        .last = "Solo el último elemento.",
        .count = "Cuántos elementos.",
        .required = "Valor obligatorio reflejado en la cabecera de uso.",
        .option = "Bandera opcional.",
        .path = "Ruta del archivo.",
        .flag = "Bandera para mostrar en la cabecera de uso.",
        .custom = "Tipo personalizado que convierte 1,2,3 en [1, 2, 3].",
        .command1 = "Comando 1.",
        .command2 = "Comando 2.",
        .command2_value = "Valor del comando 2.",
        .info = "Información sobre el comando 2.",
        .details = "Detalles de la información.",
        .completion_cmd = "Imprimir un script de autocompletado de shell.",
        .shell = "Dialecto de shell a generar.",
    }))
    .append("zh", dap.I18n.zh.withUser(.{
    .app_help = "dap 模块的手动测试。",
    .source_file = "源文件路径。",
    .source_url = "源 URL。",
    .last = "仅最后一项。",
    .count = "项目数量。",
    .required = "反映到用法标题中的必填值。",
    .option = "可选标志。",
    .path = "文件路径。",
    .flag = "用于在用法标题中展示的标志。",
    .custom = "将 1,2,3 转换为 [1, 2, 3] 的自定义类型。",
    .command1 = "命令 1。",
    .command2 = "命令 2。",
    .command2_value = "命令 2 的值。",
    .info = "关于命令 2 的信息。",
    .details = "信息详情。",
    .completion_cmd = "打印 shell 补全脚本。",
    .shell = "要生成的 shell 方言。",
}));

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
    var cli = try CLI.parse(arena, init, &translations, args, &diag);
    defer CLI.deinit(&cli, arena);

    if (CLI.command(cli)) |cmd| switch (cmd) {
        .completion => |c| {
            const completion = CLI.completion(
                arena,
                "dap-example",
                switch (c.shell.view) {
                    .bash => .bash,
                    .zsh => .zsh,
                    .fish => .fish,
                },
                translations.locale(init.minimal.environ),
            );
            try completion.show(init.io);
            return;
        },
        .command1 => try stdout.print("command = command-1\n", .{}),
        .command2 => |c| try stdout.print("value  = {s}\n", .{c.value}),
    };

    if (cli.source) |src| switch (src) {
        .file => |p| try stdout.print("file   = {s}\n", .{p.file}),
        .net => |p| try stdout.print("net    = {s}\n", .{p.url}),
    };
    try stdout.print("last   = {}\n", .{cli.last});
    try stdout.print("count  = {}\n", .{cli.count});
    try stdout.print("custom_type = {}\n", .{cli.custom});

    std.debug.print("checkpoint\n", .{});
    try CLI.usage(cli);

    try stdout.flush();
}
