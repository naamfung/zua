const std = @import("std");
const zua = @import("zua.zig");
const Instruction = zua.opcodes.Instruction;
const Allocator = std.mem.Allocator;

// =============================================================================
// Forward Declarations
// =============================================================================

pub const LuaState = opaque {};

// =============================================================================
// GC Object Header
// =============================================================================

pub const GCObject = struct {
    next: ?*GCObject = null,
    marked: u8 = 0,
    obj_type: GCObjectType,

    pub const GCObjectType = enum(u8) {
        string,
        table,
        closure,
        c_closure,
        userdata,
        thread,
        upvalue,
        proto,
    };
};

// =============================================================================
// Value
// =============================================================================

pub const Value = union(enum) {
    none: void,
    nil: void,
    boolean: bool,
    light_userdata: *anyopaque,
    number: f64,
    string: *String,
    table: *Table,
    closure: *Closure,
    c_closure: *CClosure,
    userdata: *UserData,
    thread: *Thread,

    /// Type enum for bytecode serialization
    pub const Type = enum(u8) {
        nil = 0,
        boolean = 1,
        light_userdata = 2,
        number = 3,
        string = 4,
        table = 5,
        function = 6,
        userdata = 7,
        thread = 8,

        pub fn bytecodeId(self: Type) u8 {
            return @intFromEnum(self);
        }
    };

    pub fn isCollectable(self: Value) bool {
        return switch (self) {
            .string, .table, .closure, .c_closure, .userdata, .thread => true,
            else => false,
        };
    }

    pub fn getTypeName(self: Value) []const u8 {
        return switch (self) {
            .none => "none",
            .nil => "nil",
            .boolean => "boolean",
            .light_userdata => "userdata",
            .number => "number",
            .string => "string",
            .table => "table",
            .closure, .c_closure => "function",
            .userdata => "userdata",
            .thread => "thread",
        };
    }

    pub fn toBoolean(self: Value) bool {
        return switch (self) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }

    pub fn isFalsy(self: Value) bool {
        return switch (self) {
            .nil => true,
            .boolean => |b| !b,
            else => false,
        };
    }

    pub fn isTruthy(self: Value) bool {
        return !self.isFalsy();
    }

    pub fn eql(a: Value, b: Value) bool {
        const a_tag = std.meta.activeTag(a);
        const b_tag = std.meta.activeTag(b);

        if (a_tag != b_tag) return false;

        return switch (a) {
            .nil => true,
            .boolean => |v| v == b.boolean,
            .number => |v| v == b.number,
            .string => |v| v == b.string,
            .table => |v| v == b.table,
            .closure => |v| v == b.closure,
            .c_closure => |v| v == b.c_closure,
            .userdata => |v| v == b.userdata,
            .thread => |v| v == b.thread,
            .light_userdata => |v| v == b.light_userdata,
            .none => true,
        };
    }

    pub fn lt(a: Value, b: Value) bool {
        if (a == .number and b == .number) {
            return a.number < b.number;
        }
        if (a == .string and b == .string) {
            return std.mem.order(u8, a.string.asSlice(), b.string.asSlice()) == .lt;
        }
        return false;
    }

    pub fn le(a: Value, b: Value) bool {
        if (a == .number and b == .number) {
            return a.number <= b.number;
        }
        if (a == .string and b == .string) {
            return std.mem.order(u8, a.string.asSlice(), b.string.asSlice()) != .gt;
        }
        return false;
    }

    pub const KeyContext = struct {
        pub fn hash(self: @This(), key: Value) u32 {
            _ = self;
            return switch (key) {
                .boolean => |v| @as(u32, @intFromBool(v)) +% 0x9e3779b9,
                .number => |v| @as(u32, @truncate(@as(u64, @bitCast(v)))),
                .string => |v| @as(u32, @truncate(v.hash)),
                .table => |v| @as(u32, @truncate(@intFromPtr(v))),
                .closure => |v| @as(u32, @truncate(@intFromPtr(v))),
                .c_closure => |v| @as(u32, @truncate(@intFromPtr(v))),
                .userdata => |v| @as(u32, @truncate(@intFromPtr(v))),
                .thread => |v| @as(u32, @truncate(@intFromPtr(v))),
                .light_userdata => |v| @as(u32, @truncate(@intFromPtr(v))),
                .nil => 0,
                .none => 1,
            };
        }

        pub fn eql(self: @This(), a: Value, b: Value) bool {
            _ = self;
            return Value.eql(a, b);
        }
    };
};

// =============================================================================
// String
// =============================================================================

pub const String = struct {
    gc: GCObject,
    hash: u64,
    len: usize,
    data: [*]const u8,

    pub fn init(allocator: Allocator, str: []const u8) !*String {
        const ptr = try allocator.create(String);
        const data_ptr = try allocator.dupe(u8, str);
        ptr.* = .{
            .gc = .{ .obj_type = .string },
            .hash = std.hash.Wyhash.hash(0, str),
            .len = str.len,
            .data = data_ptr.ptr,
        };
        return ptr;
    }

    pub fn initWithGC(allocator: Allocator, gc: *zua.gc.GC, str: []const u8) !*String {
        const ptr = try String.init(allocator, str);
        gc.addObject(&ptr.gc);
        return ptr;
    }

    pub fn deinit(self: *String, allocator: Allocator) void {
        const slice = self.data[0..self.len];
        allocator.free(slice);
        allocator.destroy(self);
    }

    pub fn asSlice(self: *const String) []const u8 {
        return self.data[0..self.len];
    }

    pub fn eql(self: *const String, other: *const String) bool {
        if (self.hash != other.hash) return false;
        if (self.len != other.len) return false;
        return std.mem.eql(u8, self.asSlice(), other.asSlice());
    }

    pub fn cast(obj: *GCObject) *String {
        return @ptrCast(@alignCast(obj));
    }
};

// =============================================================================
// Table
// =============================================================================

pub const Table = struct {
    gc: GCObject,
    array: std.ArrayList(Value),
    map: std.HashMap(Value, Value, Value.KeyContext, std.hash_map.default_max_load_percentage),
    metatable: ?*Table = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Table {
        return .{
            .gc = .{ .obj_type = .table },
            .array = .empty,
            .map = std.HashMap(Value, Value, Value.KeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Table) void {
        self.array.deinit(self.allocator);
        self.map.deinit();
    }

    pub fn get(self: *Table, key: Value) Value {
        switch (key) {
            .nil => return .nil,
            .number => |n| {
                if (n >= 1.0 and n == @trunc(n)) {
                    const idx: usize = @intFromFloat(n);
                    if (idx > 0 and idx <= self.array.items.len) {
                        const val = self.array.items[idx - 1];
                        if (val != .nil) return val;
                    }
                }
            },
            else => {},
        }

        if (self.map.get(key)) |val| {
            return val;
        }
        return .nil;
    }

    pub fn set(self: *Table, key: Value, value: Value) !void {
        if (key == .nil) {
            return error.TableIndexIsNil;
        }

        switch (key) {
            .number => |n| {
                if (n >= 1.0 and n == @trunc(n)) {
                    const idx: usize = @intFromFloat(n);
                    if (idx > 0 and idx <= 50) { // Only use array for small indices
                        while (self.array.items.len < idx) {
                            try self.array.append(self.allocator, .nil);
                        }
                        self.array.items[idx - 1] = value;
                        return;
                    }
                }
            },
            else => {},
        }

        if (value == .nil) {
            _ = self.map.remove(key);
        } else {
            try self.map.put(key, value);
        }
    }

    pub fn length(self: *Table) usize {
        var i: usize = self.array.items.len;
        while (i > 0) : (i -= 1) {
            if (self.array.items[i - 1] != .nil) {
                return i;
            }
        }
        return 0;
    }

    pub fn next(self: *Table, key: Value) ?struct { key: Value, value: Value } {
        var start_idx: usize = 0;

        if (key != .nil) {
            switch (key) {
                .number => |n| {
                    if (n >= 1.0 and n == @trunc(n)) {
                        const idx: usize = @intFromFloat(n);
                        if (idx > 0 and idx <= self.array.items.len) {
                            start_idx = idx;
                        }
                    }
                },
                else => {},
            }
        }

        // Search array portion
        var i: usize = start_idx;
        while (i < self.array.items.len) : (i += 1) {
            if (self.array.items[i] != .nil) {
                return .{ .key = .{ .number = @floatFromInt(i + 1) }, .value = self.array.items[i] };
            }
        }

        // Search hash portion
        if (key == .nil) {
            var iter = self.map.iterator();
            if (iter.next()) |entry| {
                return .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
            }
        } else {
            var found = false;
            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                if (found) {
                    return .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
                }
                if (Value.eql(entry.key_ptr.*, key)) {
                    found = true;
                }
            }
        }

        return null;
    }

    pub fn cast(obj: *GCObject) *Table {
        return @ptrCast(@alignCast(obj));
    }
};

// =============================================================================
// UpValue
// =============================================================================

pub const UpValue = struct {
    gc: GCObject,
    value: *Value,
    closed: Value,
    is_open: bool = true,
    next: ?*UpValue = null,

    pub fn init(value: *Value) UpValue {
        return .{
            .gc = .{ .obj_type = .upvalue },
            .value = value,
            .closed = .nil,
            .is_open = true,
        };
    }

    pub fn close(self: *UpValue) void {
        self.closed = self.value.*;
        self.is_open = false;
        self.value = &self.closed;
    }

    pub fn getValue(self: *UpValue) *Value {
        return self.value;
    }

    pub fn cast(obj: *GCObject) *UpValue {
        return @ptrCast(@alignCast(obj));
    }
};

// =============================================================================
// Function Prototype
// =============================================================================

pub const Function = struct {
    gc: GCObject,
    name: []const u8,
    code: []const Instruction,
    constants: []const Constant,
    protos: []*Function,
    varargs: VarArgs = .{},
    max_stack_size: u8,
    num_params: u8 = 0,
    num_upvalues: u8 = 0,
    line_info: []i32,
    source: []const u8,
    allocator: ?Allocator = null,

    pub const VarArgs = struct {
        has_arg: bool = false,
        is_var_arg: bool = false,
        needs_arg: bool = false,

        pub fn dump(self: *const VarArgs) u8 {
            var dumped: u8 = 0;
            if (self.has_arg) dumped |= 1;
            if (self.is_var_arg) dumped |= 2;
            if (self.needs_arg) dumped |= 4;
            return dumped;
        }

        pub fn undump(dumped: u8) VarArgs {
            return .{
                .has_arg = (dumped & 1) == 1,
                .is_var_arg = (dumped & 2) == 2,
                .needs_arg = (dumped & 4) == 4,
            };
        }
    };

    pub fn deinit(self: *Function) void {
        if (self.allocator) |alloc| {
            for (self.constants) |c| {
                if (c == .string) alloc.free(c.string);
            }
            alloc.free(self.constants);
            alloc.free(self.code);
            alloc.free(self.protos);
            alloc.free(self.line_info);
            alloc.free(self.source);
            alloc.free(self.name);
        }
    }

    pub fn printCode(self: *Function) void {
        std.debug.print("function <{s}>\n", .{if (self.name.len > 0) self.name else "main"});
        for (self.code, 0..) |instruction, i| {
            const op = instruction.op;
            const a: i32 = instruction.a;
            const abc: Instruction.ABC = @bitCast(instruction);
            const abx: Instruction.ABx = @bitCast(instruction);

            std.debug.print("\t{d}\t{s: <9}\t", .{ i + 1, @tagName(op) });

            switch (op.getOpMode()) {
                .iABC => {
                    std.debug.print("{d}", .{a});
                    if (op.getBMode() != .NotUsed) {
                        const b: i32 = if (zua.opcodes.rkIsConstant(abc.b))
                            -1 - @as(i32, @intCast(zua.opcodes.rkGetConstantIndex(abc.b)))
                        else
                            abc.b;
                        std.debug.print(" {d}", .{b});
                    }
                    if (op.getCMode() != .NotUsed) {
                        const c: i32 = if (zua.opcodes.rkIsConstant(abc.c))
                            -1 - @as(i32, @intCast(zua.opcodes.rkGetConstantIndex(abc.c)))
                        else
                            abc.c;
                        std.debug.print(" {d}", .{c});
                    }
                },
                .iABx => {
                    if (op.getBMode() == .ConstantOrRegisterConstant) {
                        std.debug.print("{d} {d}", .{ a, -1 - @as(i32, @intCast(abx.bx)) });
                    } else {
                        std.debug.print("{d} {d}", .{ a, abx.bx });
                    }
                },
                .iAsBx => {
                    const asbx: Instruction.AsBx = @bitCast(instruction);
                    std.debug.print("{d} {d}", .{ a, asbx.getSignedBx() });
                },
            }
            std.debug.print("\n", .{});
        }
    }

    pub fn cast(obj: *GCObject) *Function {
        return @ptrCast(@alignCast(obj));
    }
};

// =============================================================================
// Closure (Lua Function)
// =============================================================================

pub const Closure = struct {
    gc: GCObject,
    proto: *Function,
    upvalues: []*UpValue,

    pub fn init(allocator: Allocator, proto: *Function) !*Closure {
        const ptr = try allocator.create(Closure);
        const upvalues = try allocator.alloc(*UpValue, proto.num_upvalues);
        @memset(upvalues, undefined);

        ptr.* = .{
            .gc = .{ .obj_type = .closure },
            .proto = proto,
            .upvalues = upvalues,
        };
        return ptr;
    }

    pub fn initWithGC(allocator: Allocator, gc: *zua.gc.GC, proto: *Function) !*Closure {
        const ptr = try Closure.init(allocator, proto);
        gc.addObject(&ptr.gc);
        return ptr;
    }

    pub fn deinit(self: *Closure, allocator: Allocator) void {
        allocator.free(self.upvalues);
        allocator.destroy(self);
    }

    pub fn cast(obj: *GCObject) *Closure {
        return @ptrCast(@alignCast(obj));
    }
};

// =============================================================================
// C Closure
// =============================================================================

pub const CFunction = *const fn (*LuaState) callconv(.c) i32;

pub const CClosure = struct {
    gc: GCObject,
    func: CFunction,
    upvalues: []Value,
    env: ?*Table = null,

    pub fn init(allocator: Allocator, func: CFunction, num_upvalues: usize) !*CClosure {
        const ptr = try allocator.create(CClosure);
        const upvalues = try allocator.alloc(Value, num_upvalues);
        @memset(upvalues, .nil);

        ptr.* = .{
            .gc = .{ .obj_type = .c_closure },
            .func = func,
            .upvalues = upvalues,
        };
        return ptr;
    }

    pub fn deinit(self: *CClosure, allocator: Allocator) void {
        allocator.free(self.upvalues);
        allocator.destroy(self);
    }

    pub fn cast(obj: *GCObject) *CClosure {
        return @ptrCast(@alignCast(obj));
    }
};

// =============================================================================
// User Data
// =============================================================================

pub const UserData = struct {
    gc: GCObject,
    data: *anyopaque,
    env: ?*Table = null,
    finalizer: ?CFunction = null,

    pub fn init(data: *anyopaque) UserData {
        return .{
            .gc = .{ .obj_type = .userdata },
            .data = data,
        };
    }

    pub fn cast(obj: *GCObject) *UserData {
        return @ptrCast(@alignCast(obj));
    }
};

// =============================================================================
// Thread / Coroutine
// =============================================================================

pub const Thread = struct {
    gc: GCObject,
    status: Status = .ok,
    allocator: Allocator,

    // Stack
    stack: []Value,
    stack_top: usize = 0,
    stack_last: usize = 0,

    // Call stack
    ci: CallInfo,
    base_ci: std.ArrayList(CallInfo),

    // Open upvalues
    open_upval: ?*UpValue = null,

    // Globals and registry
    globals: *Table,
    registry: *Table,

    // Error handling
    errfunc: i32 = 0,
    error_msg: ?[]const u8 = null,

    pub const Status = enum(u8) {
        ok,
        yield,
        err,
    };

    pub const CallInfo = struct {
        func: Value = .nil,
        base: usize = 0,
        saved_pc: usize = 0,
        num_results: i32 = 0,
        is_lua: bool = true,
        tailcalls: usize = 0,
    };

    pub fn init(allocator: Allocator, stack_size: usize) !*Thread {
        const ptr = try allocator.create(Thread);
        const stack = try allocator.alloc(Value, stack_size);
        @memset(stack, .nil);

        const globals = try allocator.create(Table);
        globals.* = Table.init(allocator);

        const registry = try allocator.create(Table);
        registry.* = Table.init(allocator);

        ptr.* = .{
            .gc = .{ .obj_type = .thread },
            .allocator = allocator,
            .stack = stack,
            .stack_top = 0,
            .stack_last = stack_size,
            .ci = .{},
            .base_ci = .empty,
            .open_upval = null,
            .globals = globals,
            .registry = registry,
        };

        try ptr.base_ci.append(allocator, .{});
        return ptr;
    }

    pub fn deinit(self: *Thread) void {
        self.allocator.free(self.stack);
        self.base_ci.deinit(self.allocator);
        self.globals.deinit();
        self.allocator.destroy(self.globals);
        self.registry.deinit();
        self.allocator.destroy(self.registry);
        if (self.error_msg) |msg| {
            self.allocator.free(msg);
        }
        self.allocator.destroy(self);
    }

    pub fn getTop(self: *Thread) usize {
        return self.stack_top;
    }

    pub fn setTop(self: *Thread, idx: usize) void {
        while (self.stack_top < idx) : (self.stack_top += 1) {
            self.stack[self.stack_top] = .nil;
        }
        self.stack_top = idx;
    }

    pub fn push(self: *Thread, value: Value) !void {
        if (self.stack_top >= self.stack.len) {
            return error.StackOverflow;
        }
        self.stack[self.stack_top] = value;
        self.stack_top += 1;
    }

    pub fn pop(self: *Thread) Value {
        std.debug.assert(self.stack_top > 0);
        self.stack_top -= 1;
        const val = self.stack[self.stack_top];
        self.stack[self.stack_top] = .nil;
        return val;
    }

    pub fn getValue(self: *Thread, idx: i32) Value {
        if (idx > 0) {
            const uidx: usize = @intCast(idx);
            if (uidx <= self.stack_top) {
                return self.stack[uidx - 1];
            }
            return .nil;
        } else {
            const uidx: usize = @intCast(self.stack_top + idx);
            if (uidx >= 1) {
                return self.stack[uidx];
            }
            return .nil;
        }
    }

    pub fn setValue(self: *Thread, idx: i32, value: Value) void {
        var target_idx: usize = undefined;
        if (idx > 0) {
            target_idx = @intCast(idx - 1);
        } else {
            target_idx = @intCast(self.stack_top + idx);
        }
        if (target_idx < self.stack.len) {
            self.stack[target_idx] = value;
        }
    }

    pub fn cast(obj: *GCObject) *Thread {
        return @ptrCast(@alignCast(obj));
    }
};

// =============================================================================
// Constant
// =============================================================================

pub const Constant = union(enum) {
    string: []const u8,
    number: f64,
    nil: void,
    boolean: bool,

    pub const HashContext = struct {
        pub fn hash(self: @This(), constant: Constant) u64 {
            _ = self;
            return switch (constant) {
                .boolean => |v| @as(u64, @intFromBool(v)) +% 0x9e3779b9,
                .number => |v| @as(u64, @bitCast(v)),
                .string => |v| std.hash.Wyhash.hash(0, v),
                .nil => 0,
            };
        }

        pub fn eql(self: @This(), a: Constant, b: Constant) bool {
            _ = self;
            const a_tag = std.meta.activeTag(a);
            const b_tag = std.meta.activeTag(b);
            if (a_tag != b_tag) return false;

            return switch (a) {
                .string => |v| std.mem.eql(u8, v, b.string),
                .number => |v| v == b.number,
                .boolean => |v| v == b.boolean,
                .nil => true,
            };
        }
    };

    pub const Map = std.HashMap(Constant, usize, Constant.HashContext, std.hash_map.default_max_load_percentage);
};

// =============================================================================
// Helper Functions
// =============================================================================

pub fn getChunkId(source: []const u8, buf: []u8) []u8 {
    if (source.len == 0) {
        const str = "[string \"\"]";
        @memcpy(buf[0..str.len], str);
        return buf[0..str.len];
    }

    const buf_end: usize = buf_end: {
        switch (source[0]) {
            '=' => {
                const source_for_display = source[1..@min(buf.len + 1, source.len)];
                @memcpy(buf[0..source_for_display.len], source_for_display);
                break :buf_end source_for_display.len;
            },
            '@' => {
                var source_for_display = source[1..];
                const ellipsis = "...";
                const max_truncated_len = buf.len - ellipsis.len;
                var buf_index: usize = 0;
                if (source_for_display.len > max_truncated_len) {
                    const source_start_index = source_for_display.len - max_truncated_len;
                    source_for_display = source_for_display[source_start_index..];
                    @memcpy(buf[0..ellipsis.len], ellipsis);
                    buf_index += ellipsis.len;
                }
                @memcpy(buf[buf_index..][0..source_for_display.len], source_for_display);
                break :buf_end buf_index + source_for_display.len;
            },
            else => {
                const prefix = "[string \"";
                const suffix = "\"]";
                const ellipsis = "...";
                const min_display_len = prefix.len + ellipsis.len + suffix.len;
                std.debug.assert(buf.len >= min_display_len);

                const first_newline_index = std.mem.indexOfAny(u8, source, "\r\n");
                var source_for_display: []const u8 = if (first_newline_index != null) source[0..first_newline_index.?] else source;

                const max_source_len = buf.len - min_display_len;
                const needed_truncation = source_for_display.len > max_source_len;
                if (needed_truncation) {
                    source_for_display.len = max_source_len;
                }

                var fbs = std.io.fixedBufferStream(buf);
                const writer = fbs.writer();
                writer.writeAll(prefix) catch unreachable;
                writer.writeAll(source_for_display) catch unreachable;
                if (needed_truncation) {
                    writer.writeAll(ellipsis) catch unreachable;
                }
                writer.writeAll(suffix) catch unreachable;
                break :buf_end fbs.getPos() catch unreachable;
            },
        }
    };
    return buf[0..buf_end];
}

pub const max_floating_point_byte = 0b1111 << (0b11111 - 1);
pub const FloatingPointByteIntType = std.math.IntFittingRange(0, max_floating_point_byte);

pub fn intToFloatingPointByte(_x: FloatingPointByteIntType) u8 {
    std.debug.assert(_x <= max_floating_point_byte);
    var x = _x;
    var e: u8 = 0;
    while (x >= 16) {
        x = (x + 1) >> 1;
        e += 1;
    }
    if (x < 8) {
        return @intCast(x);
    } else {
        return @intCast(((e + 1) << 3) | (@as(u8, @intCast(x)) - 8));
    }
}

pub fn floatingPointByteToInt(_x: u8) FloatingPointByteIntType {
    const x: FloatingPointByteIntType = _x;
    const e: u5 = @intCast(x >> 3);
    if (e == 0) {
        return x;
    } else {
        return ((x & 7) + 8) << (e - 1);
    }
}

// =============================================================================
// Tests
// =============================================================================

test "Value eql" {
    try std.testing.expect(Value.eql(.nil, .nil));
    try std.testing.expect(Value.eql(.{ .boolean = true }, .{ .boolean = true }));
    try std.testing.expect(Value.eql(.{ .number = 3.14 }, .{ .number = 3.14 }));
    try std.testing.expect(!Value.eql(.nil, .{ .boolean = false }));
}

test "Value truthiness" {
    try std.testing.expect((Value{ .nil = {} }).isFalsy());
    try std.testing.expect((Value{ .boolean = false }).isFalsy());
    try std.testing.expect((Value{ .boolean = true }).isTruthy());
    try std.testing.expect((Value{ .number = 0 }).isTruthy());
    try std.testing.expect((Value{ .number = 1 }).isTruthy());
}

test "getChunkId" {
    var buf: [50]u8 = undefined;
    try std.testing.expectEqualStrings("something", getChunkId("=something", &buf));
    try std.testing.expectEqualStrings("[string \"something\"]", getChunkId("something", &buf));
}

test "intToFloatingPointByte" {
    try std.testing.expectEqual(@as(u8, 0), intToFloatingPointByte(0));
    try std.testing.expectEqual(@as(u8, 8), intToFloatingPointByte(8));
    try std.testing.expectEqual(@as(FloatingPointByteIntType, 52), floatingPointByteToInt(29));
}

test "Table operations" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator);
    defer table.deinit();

    try table.set(.{ .number = 1 }, .{ .number = 100 });
    try table.set(.{ .number = 2 }, .{ .number = 200 });

    try std.testing.expectEqual(@as(f64, 100), table.get(.{ .number = 1 }).number);
    try std.testing.expectEqual(@as(f64, 200), table.get(.{ .number = 2 }).number);

    try table.set(.{ .number = 1 }, .nil);
    try std.testing.expectEqual(Value.nil, table.get(.{ .number = 1 }));
}
