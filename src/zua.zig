const std = @import("std");

pub const lex = @import("lex.zig");
pub const parse = @import("parse.zig");
pub const parse_literal = @import("parse_literal.zig");
pub const object = @import("object.zig");
pub const table = @import("table.zig");
pub const opcodes = @import("opcodes.zig");
pub const dump = @import("dump.zig");
pub const compiler = @import("compiler.zig");
pub const ast = @import("ast.zig");
pub const debug = @import("debug.zig");
pub const vm = @import("vm.zig");
pub const gc = @import("gc.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try repl(allocator);
        return;
    }

    // Run a file
    if (std.mem.eql(u8, args[1], "-e") or std.mem.eql(u8, args[1], "--execute")) {
        if (args.len < 3) {
            std.debug.print("Usage: zua -e \"code\"\n", .{});
            return;
        }
        try executeString(allocator, args[2]);
    } else {
        try runFile(allocator, args[1]);
    }
}

pub fn repl(allocator: std.mem.Allocator) !void {
    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    const stdin_file = std.fs.File.stdin();
    var stdin_reader = stdin_file.reader(&stdin_buf);
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);

    try stdout_writer.interface.print("Zua 0.1.0 (Lua 5.1 compatible, Zig implementation)\n", .{});
    try stdout_writer.interface.print("Type 'exit' to quit\n\n", .{});

    while (true) {
        try stdout_writer.interface.print("> ", .{});

        const line = stdin_reader.interface.takeDelimiterExclusive('\n') catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };

        if (std.mem.eql(u8, line, "exit") or std.mem.eql(u8, line, "quit")) {
            break;
        }

        if (line.len == 0) continue;

        executeString(allocator, line) catch |err| {
            try stdout_writer.interface.print("Error: {}\n", .{err});
        };
    }
}

pub fn runFile(allocator: std.mem.Allocator, filename: []const u8) !void {
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(source);

    try executeString(allocator, source);
}

pub fn executeString(allocator: std.mem.Allocator, source: []const u8) !void {
    var state = try vm.LuaState.init(allocator);
    defer state.deinit();

    try state.load(source, "[string]");
    try state.run();
}

test "zua" {
    std.testing.refAllDecls(@This());
}
