const std = @import("std");
const zua = @import("src/zua.zig");

pub fn main() !void {
    const source = "a, b";
    
    var lexer = zua.lex.Lexer.init(source, "test");
    
    std.debug.print("Tokens for '{s}':\n", .{source});
    
    while (true) {
        const token = lexer.next() catch |err| {
            std.debug.print("Lexer error: {any}\n", .{err});
            break;
        };
        
        if (token.id == zua.lex.Token.Id.eof) {
            std.debug.print("EOF\n", .{});
            break;
        }
        
        std.debug.print("  {s} ({any}) [{d}-{d}]\n", .{
            token.nameForDisplay(),
            token.id,
            token.start,
            token.end,
        });
    }
}