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
pub const state = @import("state.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    // Interactive REPL mode
    if (std.mem.eql(u8, args[1], "-i") or std.mem.eql(u8, args[1], "--interactive")) {
        try repl(allocator);
        return;
    }

    // Execute Lua string
    if (std.mem.eql(u8, args[1], "-e") or std.mem.eql(u8, args[1], "--execute")) {
        if (args.len < 3) {
            std.debug.print("Usage: zua -e \"code\"\n", .{});
            return;
        }
        try executeString(allocator, args[2]);
        return;
    }

    // Show help
    if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        printUsage();
        return;
    }

    // Run a file (default behavior)
    try runFile(allocator, args[1]);
}

fn printUsage() void {
    std.debug.print(
        \\Usage: zua [options] [file]
        \\
        \Options:
        \  -i, --interactive    Start interactive REPL mode
        \  -e, --execute CODE   Execute Lua code string
        \  -h, --help           Show this help message
        \\
        \Examples:
        \  zua script.lua       Execute a Lua file
        \  zua -e "print(1+2)"  Execute Lua code
        \  zua -i               Start REPL mode
        \\n    , .{});
}

pub fn repl(allocator: std.mem.Allocator) !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    // Write welcome message
    const welcome = "Zua 0.1.0 (Lua 5.1 compatible, Zig implementation)\n";
    _ = try stdout.write(welcome);
    const prompt = "Type 'exit' to quit\n\n";
    _ = try stdout.write(prompt);

    var buffer: [4096]u8 = undefined;

    while (true) {
        // Write prompt
        const prompt_char = "> ";
        _ = try stdout.write(prompt_char);

        // Read line
        const len = try stdin.read(&buffer);
        if (len == 0) break;

        const line = buffer[0..len];
        const trimmed_line = std.mem.trim(u8, line, &std.ascii.whitespace);

        if (std.mem.eql(u8, trimmed_line, "exit") or std.mem.eql(u8, trimmed_line, "quit")) {
            break;
        }

        if (trimmed_line.len == 0) continue;

        // Execute code
        executeString(allocator, trimmed_line) catch |err| {
            var err_buf: [4096]u8 = undefined;
            const err_str = std.fmt.bufPrint(&err_buf, "Error: {}\n", .{err}) catch "Error: unknown error\n";
            _ = try stdout.write(err_str);
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
    var lua_state = try vm.LuaState.init(allocator);
    defer lua_state.deinit();

    try lua_state.load(source, "[string]");
    try lua_state.run();
}

test "zua" {
    std.testing.refAllDecls(@This());
}
