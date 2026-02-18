const std = @import("std");
const vm = @import("vm.zig");
const LuaState = vm.LuaState;
const Value = @import("object.zig").Value;
const String = @import("object.zig").String;
const Table = @import("object.zig").Table;
const Closure = @import("object.zig").Closure;
const CClosure = @import("object.zig").CClosure;

// =============================================================================
// Base Library
// =============================================================================

pub fn openBase(L: *LuaState) void {
    L.pushCFunction(base_print) catch return;
    _ = L.setGlobal("print") catch return;

    L.pushCFunction(base_type) catch return;
    _ = L.setGlobal("type") catch return;

    L.pushCFunction(base_tostring) catch return;
    _ = L.setGlobal("tostring") catch return;

    L.pushCFunction(base_tonumber) catch return;
    _ = L.setGlobal("tonumber") catch return;

    L.pushCFunction(base_error) catch return;
    _ = L.setGlobal("error") catch return;

    L.pushCFunction(base_assert) catch return;
    _ = L.setGlobal("assert") catch return;

    L.pushCFunction(base_pairs) catch return;
    _ = L.setGlobal("pairs") catch return;

    L.pushCFunction(base_next) catch return;
    _ = L.setGlobal("next") catch return;

    L.pushCFunction(base_ipairs) catch return;
    _ = L.setGlobal("ipairs") catch return;

    L.pushCFunction(base_pcall) catch return;
    _ = L.setGlobal("pcall") catch return;

    L.pushCFunction(base_select) catch return;
    _ = L.setGlobal("select") catch return;

    L.pushCFunction(base_getmetatable) catch return;
    _ = L.setGlobal("getmetatable") catch return;

    L.pushCFunction(base_setmetatable) catch return;
    _ = L.setGlobal("setmetatable") catch return;

    L.pushCFunction(base_rawget) catch return;
    _ = L.setGlobal("rawget") catch return;

    L.pushCFunction(base_rawset) catch return;
    _ = L.setGlobal("rawset") catch return;

    L.pushCFunction(base_rawequal) catch return;
    _ = L.setGlobal("rawequal") catch return;

    L.pushCFunction(base_setfenv) catch return;
    _ = L.setGlobal("setfenv") catch return;

    L.pushCFunction(base_getfenv) catch return;
    _ = L.setGlobal("getfenv") catch return;

    L.pushCFunction(base_loadstring) catch return;
    _ = L.setGlobal("loadstring") catch return;

    L.pushCFunction(base_loadfile) catch return;
    _ = L.setGlobal("loadfile") catch return;

    L.pushCFunction(base_dofile) catch return;
    _ = L.setGlobal("dofile") catch return;

    // Register _G
    L.pushValue(.{ .table = L.globals }) catch return;
    _ = L.setGlobal("_G") catch return;

    // Register _VERSION
    L.pushString("Lua 5.1") catch return;
    _ = L.setGlobal("_VERSION") catch return;
}

fn base_print(L: *LuaState) callconv(.c) i32 {
    const n = L.getTop();
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout = stdout_file.writer(&stdout_buf);

    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        if (i > 1) {
            stdout.interface.print("\t", .{}) catch {};
        }
        const val = L.toValue(i);
        printValue(&stdout.interface, val) catch {};
    }
    stdout.interface.print("\n", .{}) catch {};
    return 0;
}

fn printValue(writer: anytype, val: Value) !void {
    switch (val) {
        .nil => try writer.print("nil", .{}),
        .boolean => |b| try writer.print("{}", .{b}),
        .number => |n| try writer.print("{d}", .{n}),
        .string => |s| try writer.print("{s}", .{s.asSlice()}),
        .table => try writer.print("table: {x}", .{@intFromPtr(val.table)}),
        .closure => try writer.print("function: {x}", .{@intFromPtr(val.closure)}),
        .c_closure => try writer.print("function: {x}", .{@intFromPtr(val.c_closure)}),
        .userdata => try writer.print("userdata: {x}", .{@intFromPtr(val.userdata)}),
        .thread => try writer.print("thread: {x}", .{@intFromPtr(val.thread)}),
        .light_userdata => try writer.print("userdata: {x}", .{@intFromPtr(val.light_userdata)}),
        .none => try writer.print("none", .{}),
    }
}

fn base_type(L: *LuaState) callconv(.c) i32 {
    L.pushString(L.typeName(1)) catch return 0;
    return 1;
}

fn base_tostring(L: *LuaState) callconv(.c) i32 {
    const val = L.toValue(1);

    switch (val) {
        .nil => {
            L.pushString("nil") catch return 0;
        },
        .boolean => |b| {
            L.pushString(if (b) "true" else "false") catch return 0;
        },
        .number => |n| {
            var buf: [64]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "NaN";
            L.pushString(str) catch return 0;
        },
        .string => {
            L.pushValue(val) catch return 0;
        },
        .table => {
            var buf: [64]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "table: {x}", .{@intFromPtr(val.table)}) catch "table";
            L.pushString(str) catch return 0;
        },
        .closure => {
            var buf: [64]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "function: {x}", .{@intFromPtr(val.closure)}) catch "function";
            L.pushString(str) catch return 0;
        },
        .c_closure => {
            var buf: [64]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "function: {x}", .{@intFromPtr(val.c_closure)}) catch "function";
            L.pushString(str) catch return 0;
        },
        else => {
            L.pushString(val.getTypeName()) catch return 0;
        },
    }
    return 1;
}

fn base_tonumber(L: *LuaState) callconv(.c) i32 {
    if (L.isNumber(1)) {
        const n = L.toNumber(1) orelse 0;
        L.pushNumber(n) catch return 0;
        return 1;
    }

    if (L.isString(1)) {
        const str = L.toString(1) orelse "";
        const base: i32 = if (L.getTop() >= 2) @intFromFloat(L.toNumber(2) orelse 10) else 10;

        if (base == 10) {
            if (std.fmt.parseFloat(f64, str)) |n| {
                L.pushNumber(n) catch return 0;
                return 1;
            } else |_| {}
        } else if (base >= 2 and base <= 36) {
            if (std.fmt.parseInt(i64, str, @intCast(base))) |n| {
                L.pushNumber(@floatFromInt(n)) catch return 0;
                return 1;
            } else |_| {}
        }
    }

    L.pushNil() catch return 0;
    return 1;
}

fn base_error(L: *LuaState) callconv(.c) i32 {
    const n = L.getTop();
    if (n > 0) {
        const val = L.toValue(1);
        L.pushValue(val) catch return 0;
    } else {
        L.pushString("error") catch return 0;
    }
    return 1;
}

fn base_assert(L: *LuaState) callconv(.c) i32 {
    if (L.toBoolean(1)) {
        return L.getTop();
    }

    if (L.getTop() >= 2) {
        const val = L.toValue(2);
        L.pushValue(val) catch return 0;
    } else {
        L.pushString("assertion failed!") catch return 0;
    }
    return 1;
}

fn base_pairs(L: *LuaState) callconv(.c) i32 {
    L.pushCFunction(base_next) catch return 0;
    L.pushValue(L.toValue(1)) catch return 0;
    L.pushNil() catch return 0;
    return 3;
}

fn base_next(L: *LuaState) callconv(.c) i32 {
    return L.next(1);
}

fn base_ipairs(L: *LuaState) callconv(.c) i32 {
    L.pushCFunction(ipairs_aux) catch return 0;
    L.pushValue(L.toValue(1)) catch return 0;
    L.pushNumber(0) catch return 0;
    return 3;
}

fn ipairs_aux(L: *LuaState) callconv(.c) i32 {
    const i = L.toNumber(2) orelse 0;
    L.pushNumber(i + 1) catch return 0;
    L.pushNumber(i + 1) catch return 0;
    L.getTable(-3) catch return 0;
    if (L.isNil(-1)) {
        return 1;
    }
    return 2;
}

fn base_pcall(L: *LuaState) callconv(.c) i32 {
    const n = L.getTop();

    L.call(n - 1, -1) catch {
        L.pushBoolean(false);
        L.insert(-2) catch {};
        return 2;
    };

    L.pushBoolean(true);
    L.insert(-2) catch {};
    return L.getTop();
}

fn base_select(L: *LuaState) callconv(.c) i32 {
    const n = L.getTop();

    if (L.isString(1)) {
        const s = L.toString(1) orelse "";
        if (s.len > 0 and s[0] == '#') {
            L.pushNumber(@floatFromInt(n - 1));
            return 1;
        }
    }

    const idx = L.toNumber(1) orelse 1;
    if (idx < 0) {
        const count = @as(i32, @intFromFloat(-(idx))) + 1;
        if (count <= n - 1) {
            const start = n - count;
            var i: i32 = @intCast(start);
            while (i < n) : (i += 1) {
                L.pushValue(L.toValue(i + 1)) catch return 0;
            }
            return count;
        }
    } else if (idx > 0 and idx < n) {
        var i: i32 = @intFromFloat(idx);
        while (i < n) : (i += 1) {
            L.pushValue(L.toValue(i + 1)) catch return 0;
        }
        return n - @as(i32, @intFromFloat(idx));
    }

    return 0;
}

fn base_getmetatable(L: *LuaState) callconv(.c) i32 {
    const val = L.toValue(1);

    switch (val) {
        .table => |t| {
            if (t.metatable) |mt| {
                L.pushValue(.{ .table = mt }) catch return 0;
            } else {
                L.pushNil();
            }
        },
        else => {
            L.pushNil();
        },
    }
    return 1;
}

fn base_setmetatable(L: *LuaState) callconv(.c) i32 {
    if (!L.isTable(1)) return 0;

    const t = L.toTable(1) orelse return 0;

    if (L.isNil(2)) {
        t.metatable = null;
    } else if (L.isTable(2)) {
        t.metatable = L.toTable(2);
    }

    L.pushValue(L.toValue(1)) catch return 0;
    return 1;
}

fn base_rawget(L: *LuaState) callconv(.c) i32 {
    const t = L.toTable(1) orelse {
        L.pushNil();
        return 1;
    };
    const k = L.toValue(2);
    L.pushValue(t.get(k)) catch return 0;
    return 1;
}

fn base_rawset(L: *LuaState) callconv(.c) i32 {
    const t = L.toTable(1) orelse return 0;
    const k = L.toValue(2);
    const v = L.toValue(3);
    t.set(k, v) catch return 0;
    L.pushValue(.{ .table = t }) catch return 0;
    return 1;
}

fn base_rawequal(L: *LuaState) callconv(.c) i32 {
    L.pushBoolean(L.rawEqual(1, 2));
    return 1;
}

fn base_setfenv(L: *LuaState) callconv(.c) i32 {
    const n = L.getTop();
    if (n < 1) return 0;

    // TODO: Implement proper fenv handling
    // For now, just return the argument
    L.pushValue(L.toValue(1)) catch return 0;
    return 1;
}

fn base_getfenv(L: *LuaState) callconv(.c) i32 {
    const n = L.getTop();
    if (n == 0) {
        // Return current environment
        L.pushValue(.{ .table = L.globals }) catch return 0;
    } else {
        // TODO: Implement proper fenv handling
        // For now, return nil
        L.pushNil() catch return 0;
    }
    return 1;
}

fn base_loadstring(L: *LuaState) callconv(.c) i32 {
    const source = L.toString(1) orelse "";

    L.load(source, "[string]") catch {
        L.pushNil();
        L.pushString("error loading string") catch {};
        return 2;
    };

    return 1;
}

fn base_loadfile(L: *LuaState) callconv(.c) i32 {
    const filename = L.toString(1) orelse "";

    const file = std.fs.cwd().openFile(filename, .{}) catch {
        L.pushNil();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "cannot open {s}", .{filename}) catch "cannot open file";
        L.pushString(msg) catch {};
        return 2;
    };
    defer file.close();

    const source = file.readToEndAlloc(L.allocator, 1024 * 1024) catch {
        L.pushNil();
        L.pushString("error reading file") catch {};
        return 2;
    };
    defer L.allocator.free(source);

    L.load(source, filename) catch {
        L.pushNil();
        L.pushString("error loading file") catch {};
        return 2;
    };

    return 1;
}

fn base_dofile(L: *LuaState) callconv(.c) i32 {
    const filename = if (L.getTop() >= 1) L.toString(1) else null;

    if (filename) |f| {
        L.load(f, f) catch return 0;
    } else {
        L.load("", "[string]") catch return 0;
    }

    const n = L.getTop() - 1;
    L.call(0, -1) catch return 0;
    return L.getTop() - n;
}

// =============================================================================
// Table Library
// =============================================================================

pub fn openTable(L: *LuaState) void {
    L.pushCFunction(table_getn) catch return;
    L.setGlobal("table.getn") catch return;

    L.pushCFunction(table_setn) catch return;
    L.setGlobal("table.setn") catch return;

    L.pushCFunction(table_insert) catch return;
    L.setGlobal("table.insert") catch return;

    L.pushCFunction(table_remove) catch return;
    L.setGlobal("table.remove") catch return;

    L.pushCFunction(table_concat) catch return;
    L.setGlobal("table.concat") catch return;

    L.pushCFunction(table_sort) catch return;
    L.setGlobal("table.sort") catch return;

    L.pushCFunction(table_maxn) catch return;
    L.setGlobal("table.maxn") catch return;
}

fn table_getn(L: *LuaState) callconv(.c) i32 {
    const t = L.toTable(1) orelse {
        L.pushNumber(0) catch return 0;
        return 1;
    };
    L.pushNumber(@floatFromInt(t.length())) catch return 0;
    return 1;
}

fn table_setn(L: *LuaState) callconv(.c) i32 {
    _ = L;
    // Deprecated in Lua 5.1, does nothing
    return 0;
}

fn table_insert(L: *LuaState) callconv(.c) i32 {
    const t = L.toTable(1) orelse return 0;
    const n = L.getTop();

    if (n == 2) {
        // Insert at end
        const pos = t.length() + 1;
        t.set(.{ .number = @floatFromInt(pos) }, L.toValue(2)) catch return 0;
    } else if (n == 3) {
        // Insert at position
        const pos: usize = @intFromFloat(L.toNumber(2) orelse 1);
        const len = t.length();

        // Shift elements
        var i: usize = len;
        while (i >= pos) : (i -= 1) {
            const val = t.get(.{ .number = @floatFromInt(i) });
            t.set(.{ .number = @floatFromInt(i + 1) }, val) catch return 0;
        }
        t.set(.{ .number = @floatFromInt(pos) }, L.toValue(3)) catch return 0;
    }

    return 0;
}

fn table_remove(L: *LuaState) callconv(.c) i32 {
    const t = L.toTable(1) orelse {
        L.pushNil();
        return 1;
    };

    const len = t.length();
    if (len == 0) {
        L.pushNil() catch return 0;
        return 1;
    }

    const pos: usize = if (L.getTop() >= 2)
        @intFromFloat(L.toNumber(2) orelse @as(f64, @floatFromInt(len)))
    else
        len;

    const val = t.get(.{ .number = @floatFromInt(pos) });
    L.pushValue(val) catch return 0;

    // Shift elements
    var i: usize = pos;
    while (i < len) : (i += 1) {
        const next_val = t.get(.{ .number = @floatFromInt(i + 1) });
        t.set(.{ .number = @floatFromInt(i) }, next_val) catch return 0;
    }
    t.set(.{ .number = @floatFromInt(len) }, .nil) catch return 0;

    return 1;
}

fn table_concat(L: *LuaState) callconv(.c) i32 {
    const t = L.toTable(1) orelse {
        L.pushString("") catch return 0;
        return 1;
    };

    const sep = if (L.getTop() >= 2) L.toString(2) else "";
    const start: usize = if (L.getTop() >= 3)
        @intFromFloat(L.toNumber(3) orelse 1)
    else
        1;
    const end: usize = if (L.getTop() >= 4)
        @intFromFloat(L.toNumber(4) orelse @as(f64, @floatFromInt(t.length())))
    else
        t.length();

    var result = std.ArrayList(u8).init(L.allocator);

    var i: usize = start;
    while (i <= end) : (i += 1) {
        if (i > start and sep.len > 0) {
            result.appendSlice(sep) catch {};
        }
        const val = t.get(.{ .number = @floatFromInt(i) });
        if (val == .string) {
            result.appendSlice(val.string.asSlice()) catch {};
        } else if (val == .number) {
            var buf: [64]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{val.number}) catch "";
            result.appendSlice(str) catch {};
        }
    }

    const str = result.toOwnedSlice() catch "";
    L.pushString(str) catch return 0;
    L.allocator.free(str);

    return 1;
}

fn table_sort(L: *LuaState) callconv(.c) i32 {
    const t = L.toTable(1) orelse return 0;

    // Collect all array elements
    var elements = std.ArrayList(Value){};
    elements.* = std.ArrayList(Value).init(L.allocator);
    defer elements.deinit();

    const len = t.length();
    var i: usize = 1;
    while (i <= len) : (i += 1) {
        const val = t.get(.{ .number = @floatFromInt(i) });
        try elements.append(val);
    }

    // Simple insertion sort
    var j: usize = 1;
    while (j < elements.items.len) : (j += 1) {
        const key = elements.items[j];
        var k: usize = j - 1;
        while (k >= 0) : (k -= 1) {
            // TODO: Use custom comparator if provided
            const a = elements.items[k];
            const b = key;
            var less = false;

            switch (a) {
                .number => |n1| {
                    if (b == .number) {
                        less = n1 < b.number;
                    } else if (b == .string) {
                        less = true; // number < string
                    }
                },
                .string => |s1| {
                    if (b == .string) {
                        less = std.mem.lessThan(u8, s1.asSlice(), b.string.asSlice());
                    } else if (b == .number) {
                        less = false; // string > number
                    }
                },
                else => {},
            }

            if (!less) break;
            elements.items[k + 1] = elements.items[k];
            if (k == 0) break;
        }
        elements.items[k + 1] = key;
    }

    // Write sorted elements back to the table
    i = 1;
    for (elements.items) |val| {
        t.set(.{ .number = @floatFromInt(i) }, val) catch return 0;
        i += 1;
    }

    return 0;
}

fn table_maxn(L: *LuaState) callconv(.c) i32 {
    const t = L.toTable(1) orelse {
        L.pushNumber(0) catch return 0;
        return 1;
    };

    var max: f64 = 0;
    var iter = t.map.iterator();
    while (iter.next()) |entry| {
        if (entry.key_ptr.* == .number) {
            const n = entry.key_ptr.*.number;
            if (n > max and n == @trunc(n) and n >= 1) {
                max = n;
            }
        }
    }

    L.pushNumber(max) catch return 0;
    return 1;
}

// =============================================================================
// String Library
// =============================================================================

pub fn openString(L: *LuaState) void {
    L.pushCFunction(string_len) catch return;
    L.setGlobal("string.len") catch return;

    L.pushCFunction(string_sub) catch return;
    L.setGlobal("string.sub") catch return;

    L.pushCFunction(string_lower) catch return;
    L.setGlobal("string.lower") catch return;

    L.pushCFunction(string_upper) catch return;
    L.setGlobal("string.upper") catch return;

    L.pushCFunction(string_rep) catch return;
    L.setGlobal("string.rep") catch return;

    L.pushCFunction(string_find) catch return;
    L.setGlobal("string.find") catch return;

    L.pushCFunction(string_format) catch return;
    L.setGlobal("string.format") catch return;

    L.pushCFunction(string_byte) catch return;
    L.setGlobal("string.byte") catch return;

    L.pushCFunction(string_char) catch return;
    L.setGlobal("string.char") catch return;
}

fn string_len(L: *LuaState) callconv(.c) i32 {
    const s = L.toString(1) orelse "";
    L.pushNumber(@floatFromInt(s.len)) catch return 0;
    return 1;
}

fn string_sub(L: *LuaState) callconv(.c) i32 {
    const s = L.toString(1) orelse "";
    const len: i32 = @intCast(s.len);

    var start: i32 = @intFromFloat(L.toNumber(2) orelse 1);
    if (start < 0) start = len + start + 1;
    if (start < 1) start = 1;

    var end: i32 = if (L.getTop() >= 3)
        @intFromFloat(L.toNumber(3) orelse @as(f64, @floatFromInt(len)))
    else
        len;
    if (end < 0) end = len + end + 1;
    if (end > len) end = len;

    if (start > end) {
        L.pushString("") catch return 0;
        return 1;
    }

    const start_idx: usize = @intCast(start - 1);
    const end_idx: usize = @intCast(end);

    L.pushString(s[start_idx..end_idx]) catch return 0;
    return 1;
}

fn string_lower(L: *LuaState) callconv(.c) i32 {
    const s = L.toString(1) orelse "";
    var result = std.ArrayList(u8){};
    result.* = std.ArrayList(u8).init(L.allocator);

    for (s) |c| {
        result.append(std.ascii.toLower(c)) catch {};
    }

    const str = result.toOwnedSlice() catch "";
    L.pushString(str) catch return 0;
    L.allocator.free(str);
    return 1;
}

fn string_upper(L: *LuaState) callconv(.c) i32 {
    const s = L.toString(1) orelse "";
    var result = std.ArrayList(u8){};
    result.* = std.ArrayList(u8).init(L.allocator);

    for (s) |c| {
        result.append(std.ascii.toUpper(c)) catch {};
    }

    const str = result.toOwnedSlice() catch "";
    L.pushString(str) catch return 0;
    L.allocator.free(str);
    return 1;
}

fn string_rep(L: *LuaState) callconv(.c) i32 {
    const s = L.toString(1) orelse "";
    const n: usize = @intFromFloat(L.toNumber(2) orelse 0);

    var result = std.ArrayList(u8){};
    result.* = std.ArrayList(u8).init(L.allocator);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        result.appendSlice(s) catch {};
    }

    const str = result.toOwnedSlice() catch "";
    L.pushString(str) catch return 0;
    L.allocator.free(str);
    return 1;
}

fn string_find(L: *LuaState) callconv(.c) i32 {
    const s = L.toString(1) orelse "";
    const pattern = L.toString(2) orelse "";

    // Simple string find (no pattern matching)
    const start_idx: usize = if (L.getTop() >= 3)
        @intFromFloat(@max(1, L.toNumber(3) orelse 1) - 1)
    else
        0;

    if (std.mem.indexOfPos(u8, s, start_idx, pattern)) |idx| {
        L.pushNumber(@floatFromInt(idx + 1)) catch return 0;
        L.pushNumber(@floatFromInt(idx + pattern.len)) catch return 0;
        return 2;
    }

    L.pushNil() catch return 0;
    return 1;
}

fn string_format(L: *LuaState) callconv(.c) i32 {
    const fmt = L.toString(1) orelse "";

    // Very simplified format implementation
    var result = std.ArrayList(u8){};
    result.* = std.ArrayList(u8).init(L.allocator);
    var arg_idx: i32 = 2;
    var i: usize = 0;

    while (i < fmt.len) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            i += 1;
            switch (fmt[i]) {
                's' => {
                    if (L.getTop() >= arg_idx) {
                        if (L.toString(arg_idx)) |s| {
                            result.appendSlice(s) catch {};
                        }
                        arg_idx += 1;
                    }
                },
                'd' => {
                    if (L.getTop() >= arg_idx) {
                        if (L.toNumber(arg_idx)) |n| {
                            result.writer().print("{d}", .{@as(i64, @intFromFloat(n))}) catch {};
                        }
                        arg_idx += 1;
                    }
                },
                'f' => {
                    if (L.getTop() >= arg_idx) {
                        if (L.toNumber(arg_idx)) |n| {
                            result.writer().print("{d}", .{n}) catch {};
                        }
                        arg_idx += 1;
                    }
                },
                '%' => {
                    result.append('%') catch {};
                },
                else => {
                    result.append(fmt[i]) catch {};
                },
            }
        } else {
            result.append(fmt[i]) catch {};
        }
        i += 1;
    }

    const str = result.toOwnedSlice() catch "";
    L.pushString(str) catch {};
    L.allocator.free(str);
    return 1;
}

fn string_byte(L: *LuaState) callconv(.c) i32 {
    const s = L.toString(1) orelse "";
    const len: i32 = @intCast(s.len);

    const start: i32 = @intFromFloat(L.toNumber(2) orelse 1);
    const end: i32 = if (L.getTop() >= 3)
        @intFromFloat(L.toNumber(3) orelse @as(f64, @floatFromInt(start)))
    else
        start;

    var count: i32 = 0;
    var i: i32 = start;
    while (i <= end and i <= len) : (i += 1) {
        if (i >= 1) {
            L.pushNumber(@as(f64, @floatFromInt(s[@intCast(i - 1)])));
            count += 1;
        }
    }

    return count;
}

fn string_char(L: *LuaState) callconv(.c) i32 {
    const n = L.getTop();
    var result = std.ArrayList(u8).init(L.allocator);

    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        const c: u8 = @intFromFloat(@mod(L.toNumber(i) orelse 0, 256));
        result.append(c) catch {};
    }

    const str = result.toOwnedSlice() catch "";
    L.pushString(str) catch {};
    L.allocator.free(str);
    return 1;
}

// =============================================================================
// Math Library
// =============================================================================

pub fn openMath(L: *LuaState) void {
    L.pushNumber(std.math.pi) catch return;
    L.setGlobal("math.pi") catch return;

    L.pushNumber(std.math.e) catch return;
    L.setGlobal("math.huge") catch return;

    L.pushCFunction(math_abs) catch return;
    L.setGlobal("math.abs") catch return;

    L.pushCFunction(math_floor) catch return;
    L.setGlobal("math.floor") catch return;

    L.pushCFunction(math_ceil) catch return;
    L.setGlobal("math.ceil") catch return;

    L.pushCFunction(math_sqrt) catch return;
    L.setGlobal("math.sqrt") catch return;

    L.pushCFunction(math_pow) catch return;
    L.setGlobal("math.pow") catch return;

    L.pushCFunction(math_min) catch return;
    L.setGlobal("math.min") catch return;

    L.pushCFunction(math_max) catch return;
    L.setGlobal("math.max") catch return;

    L.pushCFunction(math_sin) catch return;
    L.setGlobal("math.sin") catch return;

    L.pushCFunction(math_cos) catch return;
    L.setGlobal("math.cos") catch return;

    L.pushCFunction(math_tan) catch return;
    L.setGlobal("math.tan") catch return;

    L.pushCFunction(math_log) catch return;
    L.setGlobal("math.log") catch return;

    L.pushCFunction(math_exp) catch return;
    L.setGlobal("math.exp") catch return;

    L.pushCFunction(math_random) catch return;
    L.setGlobal("math.random") catch return;

    L.pushCFunction(math_randomseed) catch return;
    L.setGlobal("math.randomseed") catch return;

    L.pushCFunction(math_modf) catch return;
    L.setGlobal("math.modf") catch return;

    L.pushCFunction(math_fmod) catch return;
    L.setGlobal("math.fmod") catch return;
}

fn math_abs(L: *LuaState) callconv(.c) i32 {
    const n = L.toNumber(1) orelse 0;
    L.pushNumber(@abs(n));
    return 1;
}

fn math_floor(L: *LuaState) callconv(.c) i32 {
    const n = L.toNumber(1) orelse 0;
    L.pushNumber(@floor(n));
    return 1;
}

fn math_ceil(L: *LuaState) callconv(.c) i32 {
    const n = L.toNumber(1) orelse 0;
    L.pushNumber(@ceil(n));
    return 1;
}

fn math_sqrt(L: *LuaState) callconv(.c) i32 {
    const n = L.toNumber(1) orelse 0;
    L.pushNumber(std.math.sqrt(n));
    return 1;
}

fn math_pow(L: *LuaState) callconv(.c) i32 {
    const x = L.toNumber(1) orelse 0;
    const y = L.toNumber(2) orelse 0;
    L.pushNumber(std.math.pow(f64, x, y));
    return 1;
}

fn math_min(L: *LuaState) callconv(.c) i32 {
    const n = L.getTop();
    if (n == 0) {
        L.pushNumber(0);
        return 1;
    }

    var min = L.toNumber(1) orelse 0;
    var i: i32 = 2;
    while (i <= n) : (i += 1) {
        const val = L.toNumber(i) orelse min;
        if (val < min) min = val;
    }

    L.pushNumber(min);
    return 1;
}

fn math_max(L: *LuaState) callconv(.c) i32 {
    const n = L.getTop();
    if (n == 0) {
        L.pushNumber(0);
        return 1;
    }

    var max = L.toNumber(1) orelse 0;
    var i: i32 = 2;
    while (i <= n) : (i += 1) {
        const val = L.toNumber(i) orelse max;
        if (val > max) max = val;
    }

    L.pushNumber(max);
    return 1;
}

fn math_sin(L: *LuaState) callconv(.c) i32 {
    const n = L.toNumber(1) orelse 0;
    L.pushNumber(std.math.sin(n));
    return 1;
}

fn math_cos(L: *LuaState) callconv(.c) i32 {
    const n = L.toNumber(1) orelse 0;
    L.pushNumber(std.math.cos(n));
    return 1;
}

fn math_tan(L: *LuaState) callconv(.c) i32 {
    const n = L.toNumber(1) orelse 0;
    L.pushNumber(std.math.tan(n));
    return 1;
}

fn math_log(L: *LuaState) callconv(.c) i32 {
    const n = L.toNumber(1) orelse 0;
    if (L.getTop() >= 2) {
        const base = L.toNumber(2) orelse std.math.e;
        L.pushNumber(std.math.log(n) / std.math.log(base));
    } else {
        L.pushNumber(std.math.log(n));
    }
    return 1;
}

fn math_exp(L: *LuaState) callconv(.c) i32 {
    const n = L.toNumber(1) orelse 0;
    L.pushNumber(std.math.exp(n));
    return 1;
}

// Random state
threadlocal var random_state: ?std.Random.DefaultPrng = null;

fn math_random(L: *LuaState) callconv(.c) i32 {
    if (random_state == null) {
        random_state = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    }

    const n = L.getTop();

    if (n == 0) {
        L.pushNumber(random_state.?.random().float(f64));
    } else if (n == 1) {
        const upper: i64 = @intFromFloat(L.toNumber(1) orelse 1);
        L.pushNumber(@floatFromInt(random_state.?.random().intRangeAtMost(i64, 1, upper)));
    } else {
        const lower: i64 = @intFromFloat(L.toNumber(1) orelse 1);
        const upper: i64 = @intFromFloat(L.toNumber(2) orelse lower);
        L.pushNumber(@floatFromInt(random_state.?.random().intRangeAtMost(i64, lower, upper)));
    }

    return 1;
}

fn math_randomseed(L: *LuaState) callconv(.c) i32 {
    const seed: u64 = @bitCast(L.toNumber(1) orelse 0);
    random_state = std.Random.DefaultPrng.init(seed);
    return 0;
}

fn math_modf(L: *LuaState) callconv(.c) i32 {
    const n = L.toNumber(1) orelse 0;
    const int_part = @trunc(n);
    const frac_part = n - int_part;
    L.pushNumber(int_part);
    L.pushNumber(frac_part);
    return 2;
}

fn math_fmod(L: *LuaState) callconv(.c) i32 {
    const x = L.toNumber(1) orelse 0;
    const y = L.toNumber(2) orelse 1;
    L.pushNumber(@mod(x, y));
    return 1;
}

// =============================================================================
// Open All Libraries
// =============================================================================

pub fn openLibs(L: *LuaState) void {
    openBase(L);
    openTable(L);
    openString(L);
    openMath(L);
}
