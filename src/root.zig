//! Public entry point for the `dap` module. Re-exports the DSL surface from
//! the core implementation in `dap.zig`.

pub const App = @import("dap.zig").App;
pub const String = @import("dap.zig").String;
pub const Kind = @import("dap.zig").Kind;
pub const Default = @import("dap.zig").Default;
pub const defaultValue = @import("dap.zig").defaultValue;
pub const Option = @import("dap.zig").Option;
pub const Argument = @import("dap.zig").Argument;
pub const Group = @import("dap.zig").Group;
pub const Enum = @import("dap.zig").Enum;
pub const Enumeration = @import("dap.zig").Enumeration;
pub const CommandMeta = @import("dap.zig").CommandMeta;
pub const Command = @import("dap.zig").Command;
pub const Commands = @import("dap.zig").Commands;
pub const Validate = @import("dap.zig").Validate;
pub const DecodeError = @import("dap.zig").DecodeError;
pub const ParseError = @import("dap.zig").ParseError;
pub const Diag = @import("dap.zig").Diag;
pub const HelpData = @import("dap.zig").HelpData;
pub const HelpRendererStyle = @import("dap.zig").HelpRendererStyle;
pub const HelpRendererHighlight = @import("dap.zig").HelpRendererHighlight;
pub const HelpHighlight = @import("dap.zig").HelpHighlight;
pub const generate = @import("dap.zig").generate;
